/**
 * collectorConfig.ts — pure, AWS-free render of the OTel_Collector configuration
 * for the platform's THIRD-PARTY telemetry leg (design "OTel_Collector Pipeline
 * Detail (Third-Party Leg Only)"; tasks 7.3 + 7.6).
 *
 * `renderCollectorConfig` maps a deployment `BackendConfiguration` (resolved via
 * `resolveBackends`, task 7.1) to a complete, YAML-serializable OpenTelemetry
 * Collector config containing:
 *   - an OTLP receiver (gRPC + HTTP) for the duplicated span stream emitted by
 *     the base-image Additional_Span_Exporter (R12.1);
 *   - a `batch` processor on the third-party path;
 *   - one `otlphttp/<name>` exporter per resolved third-party backend, each with
 *     its OWN non-blocking `sending_queue` (`enabled: true, blocking: false`)
 *     and `retry_on_failure` (`enabled: true`) for per-exporter failure
 *     isolation (task 7.6 — R9.4, R12.5);
 *   - a single `traces/thirdparty` pipeline wiring the receiver → batch →
 *     the resolved third-party exporters.
 *
 * HARD STRUCTURAL INVARIANT (R12.2, R12.3, R16.5, R16.6): the rendered config
 * contains ZERO AWS-native exporters or pipelines. There is no `awsxray`,
 * `awsemf`, or `awscloudwatchlogs` exporter, and no `traces/aws`,
 * `metrics/aws`, or `logs/aws` pipeline. The AWS-native leg is delivered by a
 * separate AgentCore-managed pipeline that never traverses this collector, so
 * no `BackendConfiguration` value can add, remove, reroute, or disable it.
 *
 * PURITY: this function is total, deterministic, and AWS-free — it never throws
 * and makes no AWS/network call, so the property tests (tasks 7.4 / 7.5 / 7.7)
 * can exercise it exhaustively without mocking. All external coordinates (the
 * default Langfuse endpoint, receiver bind addresses, queue/retry sizing) are
 * injected via `options`; nothing is hardcoded to a live resource.
 *
 * PER-BU ROUTING (task 10.4 — IMPLEMENTED): when a set of per-BU
 * `LangfuseProjectBinding`s is supplied via `options.langfuseProjectBindings`
 * (together with the shared `options.langfuseOtelEndpoint`), the render instead
 * emits per-BU routing:
 *   - one `otlphttp/langfuse-<bu>` exporter per resolvable BU binding, pointed at
 *     the shared Langfuse `/api/public/otel` endpoint and carrying that project's
 *     per-BU Basic-auth `${env:...}` header seam (reusing the task-7.6 isolation
 *     pattern — its OWN non-blocking `sending_queue` + `retry_on_failure`);
 *   - a `routing` connector keyed on the `deployment.environment` (BU) resource
 *     attribute that fans each BU's spans to that BU's exporter (fail-closed: an
 *     unresolved/ambiguous BU is not added to the routing table and drops out of
 *     the third-party leg rather than risk cross-BU delivery);
 *   - a `traces/thirdparty` pipeline (otlp receiver → batch → routing connector)
 *     plus one `traces/langfuse-<bu>` pipeline per BU (routing connector → that
 *     BU's otlphttp exporter).
 * Per-BU routes are derived via `resolveLangfuseRoute` (task 10.2), keeping the
 * whole render TOTAL and deterministic. The hard structural invariant is
 * preserved in BOTH branches: every emitted exporter is a third-party `otlphttp`
 * exporter — ZERO AWS-native exporters/pipelines. When NO bindings are supplied
 * (or none resolve), behavior is UNCHANGED (single default third-party pipeline).
 */

import { resolveBackends, type ResolveBackendsOptions, type ResolvedExporter } from './backendConfig';
import { resolveLangfuseRoute } from './langfuseRouting';
import type { BackendConfiguration, LangfuseProjectBinding } from './types';

// ---------------------------------------------------------------------------
// Public constants (for negative assertions in property tests)
// ---------------------------------------------------------------------------

/**
 * AWS-native OTel exporter type names that this render NEVER emits (R16.5,
 * R12.2). Re-exported for consumers/tests that assert their absence.
 */
export const AWS_NATIVE_EXPORTER_NAMES = [
  'awsxray',
  'awsemf',
  'awscloudwatchlogs',
] as const;

/**
 * AWS-native pipeline names this render NEVER emits (R16.6). Exposed so tests
 * can assert the rendered `service.pipelines` contains none of them.
 */
export const AWS_NATIVE_PIPELINE_NAMES = [
  'traces/aws',
  'metrics/aws',
  'logs/aws',
] as const;

/**
 * The resource attribute the per-BU `routing` connector keys on (task 10.4).
 * The observability module stamps each span's owning Business_Unit onto this
 * attribute; the collector routes by it to the owning BU's Langfuse project
 * (R14.4). Exposed so the HCL mirror and tests can assert the same key.
 */
export const BU_ROUTING_RESOURCE_ATTRIBUTE = 'deployment.environment';

// ---------------------------------------------------------------------------
// Config shapes (YAML-serializable) — third-party leg only
// ---------------------------------------------------------------------------

/** Non-blocking sending queue — task 7.6 (R9.4, R12.5). */
export interface SendingQueueConfig {
  enabled: true;
  /** Always false: a stalled endpoint must never block the pipeline. */
  blocking: false;
  queue_size: number;
}

/** Retry-on-failure — task 7.6 (R9.4). */
export interface RetryOnFailureConfig {
  enabled: true;
  max_elapsed_time: string;
}

/** A single third-party `otlphttp` exporter with its own isolation policy. */
export interface OtlpHttpExporterConfig {
  endpoint: string;
  headers?: Record<string, string>;
  sending_queue: SendingQueueConfig;
  retry_on_failure: RetryOnFailureConfig;
}

/** A single collector pipeline. `processors` is omitted for connector-fed
 *  per-BU pipelines (task 10.4), which go straight from the routing connector
 *  to that BU's exporter. */
export interface PipelineConfig {
  receivers: string[];
  processors?: string[];
  exporters: string[];
}

/** One entry in the `routing` connector table — routes spans whose BU resource
 *  attribute matches `condition` to the given per-BU pipeline(s) (task 10.4). */
export interface RoutingTableEntry {
  /** OTTL context the condition evaluates in. Always `resource` for BU routing. */
  context: 'resource';
  /** OTTL condition, e.g. `attributes["deployment.environment"] == "team-bu-1"`. */
  condition: string;
  /** The per-BU pipeline(s) matching spans are routed to. */
  pipelines: string[];
}

/** The `routing` connector config (task 10.4). Fans the batched third-party
 *  span stream to per-BU pipelines by the BU resource attribute. It declares no
 *  `default_pipelines`, so telemetry whose BU matches no entry is dropped from
 *  the third-party leg (fail-closed tenant isolation — never cross-routed). */
export interface RoutingConnectorConfig {
  routing: {
    error_mode: string;
    table: RoutingTableEntry[];
  };
}

/** The rendered collector config object (third-party leg only). */
export interface CollectorConfig {
  receivers: {
    otlp: {
      protocols: {
        grpc: { endpoint: string };
        http: { endpoint: string };
      };
    };
  };
  processors: {
    batch: Record<string, never>;
  };
  /** Present only in the per-BU routing branch (task 10.4). */
  connectors?: RoutingConnectorConfig;
  exporters: Record<string, OtlpHttpExporterConfig>;
  service: {
    /** `traces/thirdparty` is always present; per-BU `traces/langfuse-<bu>`
     *  pipelines are added in the routing branch (task 10.4). */
    pipelines: { [pipelineName: string]: PipelineConfig };
  };
}

/** The render result: the config object, its YAML text, and exporter keys. */
export interface RenderedCollectorConfig {
  /** The config as a plain, YAML-serializable object. */
  config: CollectorConfig;
  /** Deterministic YAML serialization of `config`. */
  yaml: string;
  /** The `otlphttp/<name>` exporter keys in pipeline order (third-party only). */
  exporterNames: string[];
}

/** Render options — injected coordinates + optional receiver/queue tuning. */
export interface RenderCollectorConfigOptions extends ResolveBackendsOptions {
  /** OTLP/gRPC receiver bind address. Default `0.0.0.0:4317`. */
  otlpGrpcEndpoint?: string;
  /** OTLP/HTTP receiver bind address. Default `0.0.0.0:4318`. */
  otlpHttpEndpoint?: string;
  /** Per-exporter sending-queue depth. Default `1000`. */
  sendingQueueSize?: number;
  /** Per-exporter retry budget. Default `300s`. */
  retryMaxElapsedTime?: string;
  /**
   * Per-BU Langfuse project bindings (task 10.4). When a non-empty array is
   * supplied together with `langfuseOtelEndpoint`, the render switches to the
   * per-BU routing branch: one `otlphttp/langfuse-<bu>` exporter per resolvable
   * binding, a `routing` connector keyed on the BU resource attribute, and one
   * `traces/langfuse-<bu>` pipeline per BU. When absent/empty (or none resolve),
   * the render is unchanged (single default third-party pipeline).
   */
  langfuseProjectBindings?: LangfuseProjectBinding[];
  /**
   * Shared Langfuse OTLP receiver URL (`https://<langfuse-alb>/api/public/otel`)
   * used by every per-BU exporter (task 10.4). All BUs share this endpoint;
   * per-project isolation is carried by each binding's Basic-auth ref, not a
   * distinct endpoint. Required for the per-BU routing branch.
   */
  langfuseOtelEndpoint?: string;
}

// ---------------------------------------------------------------------------
// Defaults (no live-resource coupling)
// ---------------------------------------------------------------------------

const DEFAULT_OTLP_GRPC_ENDPOINT = '0.0.0.0:4317';
const DEFAULT_OTLP_HTTP_ENDPOINT = '0.0.0.0:4318';
const DEFAULT_SENDING_QUEUE_SIZE = 1000;
const DEFAULT_RETRY_MAX_ELAPSED_TIME = '300s';

// ---------------------------------------------------------------------------
// Helpers (total — never throw)
// ---------------------------------------------------------------------------

function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

/**
 * Sanitize a backend name into a safe OTel component-name suffix
 * (`otlphttp/<suffix>`). Lowercases and keeps `[a-z0-9_-]`; empty/garbage names
 * fall back to `backend`. Uniqueness is enforced by the caller.
 */
function sanitizeComponentName(name: string): string {
  const cleaned = asString(name)
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return cleaned.length > 0 ? cleaned : 'backend';
}

/**
 * Env var name the collector reads the exporter's auth header from, derived
 * deterministically from the (unique) component name. The deploy wiring injects
 * the per-backend Secrets Manager value into this env var — the render itself
 * carries no secret material.
 *
 * Per-BU exporters (task 10.4) derive their auth env var per BU via
 * `perBuAuthEnvVarName` instead.
 */
function authEnvVarName(componentName: string): string {
  return `EAP_OTLP_AUTH_${componentName.toUpperCase().replace(/[^A-Z0-9]+/g, '_')}`;
}

/**
 * Env var name the collector reads a per-BU Langfuse project's Basic-auth value
 * from (task 10.4), derived deterministically from the BU. The deploy wiring
 * (HCL mirror) injects that BU's `otlpBasicAuthRef` Secrets Manager value into
 * this env var (`EAP_OTLP_AUTH_LANGFUSE_<BU>`) via ECS `secrets`
 * valueFrom — the render itself carries no secret material.
 */
function perBuAuthEnvVarName(bu: string): string {
  return `EAP_OTLP_AUTH_LANGFUSE_${asString(bu).toUpperCase().replace(/[^A-Z0-9]+/g, '_')}`;
}

/**
 * Build the ordered exporter map + pipeline exporter-key list from the resolved
 * third-party exporters. Every exporter is `otlphttp` (never AWS-native) and
 * gets its own non-blocking `sending_queue` + `retry_on_failure` (task 7.6).
 */
function buildExporters(
  resolved: ResolvedExporter[],
  queueSize: number,
  retryMaxElapsedTime: string,
): { exporters: Record<string, OtlpHttpExporterConfig>; keys: string[] } {
  const exporters: Record<string, OtlpHttpExporterConfig> = {};
  const keys: string[] = [];
  const seen = new Map<string, number>();

  for (const backend of resolved) {
    // Ensure a unique, safe `otlphttp/<name>` key even on name collisions.
    let suffix = sanitizeComponentName(backend.name);
    const count = seen.get(suffix) ?? 0;
    seen.set(suffix, count + 1);
    if (count > 0) {
      suffix = `${suffix}-${count + 1}`;
    }
    const key = `otlphttp/${suffix}`;

    const exporter: OtlpHttpExporterConfig = {
      endpoint: asString(backend.otlpEndpoint),
      // Task 7.6: per-exporter, non-blocking isolation so one stalled/failing
      // third-party endpoint drops/queues ONLY within this collector and the
      // third-party backends isolate from one another (R9.4, R12.5).
      sending_queue: {
        enabled: true,
        blocking: false,
        queue_size: queueSize,
      },
      retry_on_failure: {
        enabled: true,
        max_elapsed_time: retryMaxElapsedTime,
      },
    };

    // Carry an auth-header seam only when the backend declares an auth secret.
    // The secret value is injected into the env var at deploy time; the render
    // stays pure and secret-free.
    if (backend.authSecretArn) {
      exporter.headers = {
        Authorization: `\${env:${authEnvVarName(suffix)}}`,
      };
    }

    exporters[key] = exporter;
    keys.push(key);
  }

  return { exporters, keys };
}

/** Result of the per-BU Langfuse routing render (task 10.4). */
interface PerBuLangfuseRender {
  exporters: Record<string, OtlpHttpExporterConfig>;
  connector: RoutingConnectorConfig;
  perBuPipelines: Record<string, PipelineConfig>;
  /** `otlphttp/langfuse-<bu>` keys in binding order. */
  exporterNames: string[];
}

/**
 * Build the per-BU Langfuse exporters + `routing` connector + per-BU pipelines
 * from a set of `LangfuseProjectBinding`s (task 10.4, R14.4).
 *
 * For each binding, `resolveLangfuseRoute` (task 10.2) selects EXACTLY that BU's
 * project/credentials — failing closed (returning `null`) for an unresolved,
 * ambiguous (duplicate-BU), or incomplete binding, or when no endpoint was
 * injected. A BU that fails to resolve is simply not added to the routing table
 * or exporter set, so it drops out of the third-party leg rather than risk
 * cross-BU delivery (tenant isolation). Every emitted exporter is a third-party
 * `otlphttp` exporter with its own non-blocking `sending_queue` +
 * `retry_on_failure` (task-7.6 isolation pattern) — never AWS-native.
 *
 * Returns `null` when NO binding resolves, so the caller falls back to the
 * default single-pipeline render (backward compatible).
 */
function buildPerBuLangfuse(
  bindings: LangfuseProjectBinding[],
  langfuseOtelEndpoint: string,
  queueSize: number,
  retryMaxElapsedTime: string,
): PerBuLangfuseRender | null {
  const exporters: Record<string, OtlpHttpExporterConfig> = {};
  const perBuPipelines: Record<string, PipelineConfig> = {};
  const table: RoutingTableEntry[] = [];
  const exporterNames: string[] = [];
  const seenSuffix = new Set<string>();

  for (const binding of bindings) {
    // Derive EXACTLY this BU's route (fails closed on ambiguous/incomplete).
    const route = resolveLangfuseRoute(binding?.bu, bindings, { langfuseOtelEndpoint });
    if (route === null) {
      // Unresolved / ambiguous / incomplete BU: never routed (tenant isolation).
      continue;
    }

    // A safe, unique per-BU component suffix. Duplicate BUs already fail closed
    // in `resolveLangfuseRoute`, so this guard is defensive belt-and-suspenders.
    const suffix = sanitizeComponentName(route.bu);
    if (seenSuffix.has(suffix)) {
      continue;
    }
    seenSuffix.add(suffix);

    const exporterKey = `otlphttp/langfuse-${suffix}`;
    const pipelineKey = `traces/langfuse-${suffix}`;

    exporters[exporterKey] = {
      // Shared Langfuse `/api/public/otel` endpoint (per-project isolation is by
      // the Basic-auth header below, not a distinct endpoint).
      endpoint: route.otlpEndpoint,
      // Per-project Basic-auth header seam. The BU's `otlpBasicAuthRef`
      // (base64(public:secret)) value is injected into this env var at deploy
      // time; the render stays secret-free.
      headers: {
        Authorization: `Basic \${env:${perBuAuthEnvVarName(route.bu)}}`,
      },
      // Task-7.6 isolation: own non-blocking queue + retry so one BU's stalled
      // Langfuse project never blocks or drops another BU's telemetry.
      sending_queue: {
        enabled: true,
        blocking: false,
        queue_size: queueSize,
      },
      retry_on_failure: {
        enabled: true,
        max_elapsed_time: retryMaxElapsedTime,
      },
    };

    perBuPipelines[pipelineKey] = {
      receivers: ['routing'],
      exporters: [exporterKey],
    };

    table.push({
      context: 'resource',
      condition: `attributes[${quoteScalar(BU_ROUTING_RESOURCE_ATTRIBUTE)}] == ${quoteScalar(route.bu)}`,
      pipelines: [pipelineKey],
    });

    exporterNames.push(exporterKey);
  }

  if (exporterNames.length === 0) {
    return null;
  }

  return {
    exporters,
    // No `default_pipelines`: an unmatched BU is dropped from the third-party
    // leg (fail-closed) rather than cross-routed to another BU's project.
    connector: { routing: { error_mode: 'ignore', table } },
    perBuPipelines,
    exporterNames,
  };
}

// ---------------------------------------------------------------------------
// Deterministic YAML serializer (minimal, total, no dependency)
// ---------------------------------------------------------------------------

function quoteScalar(value: string): string {
  // Always double-quote strings so `${env:...}`, ':', and other special
  // characters serialize unambiguously. Escape backslash and double-quote.
  const escaped = value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  return `"${escaped}"`;
}

function serializeScalar(value: unknown): string {
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : quoteScalar(String(value));
  return quoteScalar(asString(value));
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Recursively serialize a value to deterministic YAML at the given indent. */
function serializeNode(value: unknown, indent: number): string {
  const pad = '  '.repeat(indent);

  if (Array.isArray(value)) {
    if (value.length === 0) return ' []\n';
    let out = '\n';
    for (const item of value) {
      if (isPlainObject(item) || Array.isArray(item)) {
        // Nested block under a list item.
        const nested = serializeNode(item, indent + 1);
        out += `${pad}-${nested.startsWith('\n') ? nested : ` ${nested.trimStart()}`}`;
      } else {
        out += `${pad}- ${serializeScalar(item)}\n`;
      }
    }
    return out;
  }

  if (isPlainObject(value)) {
    const keys = Object.keys(value);
    if (keys.length === 0) return ' {}\n';
    let out = '\n';
    for (const key of keys) {
      const child = value[key];
      if (isPlainObject(child)) {
        out += Object.keys(child).length === 0
          ? `${pad}${key}: {}\n`
          : `${pad}${key}:${serializeNode(child, indent + 1)}`;
      } else if (Array.isArray(child)) {
        out += `${pad}${key}:${serializeNode(child, indent + 1)}`;
      } else {
        out += `${pad}${key}: ${serializeScalar(child)}\n`;
      }
    }
    return out;
  }

  // Bare scalar (only reached for a top-level scalar; configs are objects).
  return ` ${serializeScalar(value)}\n`;
}

/** Serialize a config object to deterministic YAML text. */
export function toYaml(config: CollectorConfig): string {
  const body = serializeNode(config as unknown as Record<string, unknown>, 0);
  // `serializeNode` for a non-empty object returns a leading newline; trim it.
  return body.startsWith('\n') ? body.slice(1) : body;
}

// ---------------------------------------------------------------------------
// The pure render — tasks 7.3 (third-party only) + 7.6 (failure isolation)
// ---------------------------------------------------------------------------

/**
 * Render the OTel_Collector configuration for the THIRD-PARTY leg only.
 *
 * Emits an OTLP receiver (gRPC + HTTP), a `batch` processor, one
 * `otlphttp/<name>` exporter per resolved third-party backend — each with its
 * own non-blocking `sending_queue` + `retry_on_failure` (task 7.6) — and a
 * single `traces/thirdparty` pipeline. The result contains ZERO AWS-native
 * exporters/pipelines (R12.2, R12.3, R16.5, R16.6).
 *
 * Total and deterministic: never throws, makes no AWS call. Malformed/absent
 * `backendConfiguration` resolves (via `resolveBackends`) to the default
 * Langfuse exporter only.
 *
 * @param backendConfiguration deployment config (may be null/undefined/malformed).
 * @param options injected default-backend coordinates + optional receiver/queue tuning.
 */
export function renderCollectorConfig(
  backendConfiguration: BackendConfiguration | null | undefined,
  options: RenderCollectorConfigOptions,
): RenderedCollectorConfig {
  const queueSize =
    typeof options.sendingQueueSize === 'number' && Number.isFinite(options.sendingQueueSize)
      ? options.sendingQueueSize
      : DEFAULT_SENDING_QUEUE_SIZE;
  const retryMaxElapsedTime = options.retryMaxElapsedTime ?? DEFAULT_RETRY_MAX_ELAPSED_TIME;

  const receivers = {
    otlp: {
      protocols: {
        grpc: { endpoint: options.otlpGrpcEndpoint ?? DEFAULT_OTLP_GRPC_ENDPOINT },
        http: { endpoint: options.otlpHttpEndpoint ?? DEFAULT_OTLP_HTTP_ENDPOINT },
      },
    },
  };

  // ---- PER-BU ROUTING BRANCH (task 10.4, R14.4) --------------------------
  // When per-BU Langfuse bindings + a shared endpoint are supplied, route each
  // BU's spans to its own Langfuse project via a `routing` connector. Falls
  // back to the default single-pipeline render when nothing resolves.
  const bindings = Array.isArray(options.langfuseProjectBindings)
    ? options.langfuseProjectBindings
    : [];
  const langfuseOtelEndpoint =
    typeof options.langfuseOtelEndpoint === 'string' ? options.langfuseOtelEndpoint : '';

  const perBu =
    bindings.length > 0 && langfuseOtelEndpoint.length > 0
      ? buildPerBuLangfuse(bindings, langfuseOtelEndpoint, queueSize, retryMaxElapsedTime)
      : null;

  if (perBu !== null) {
    const config: CollectorConfig = {
      receivers,
      processors: {
        batch: {},
      },
      connectors: perBu.connector,
      // Third-party only: every key is `otlphttp/langfuse-<bu>` — no AWS-native.
      exporters: perBu.exporters,
      service: {
        pipelines: {
          // otlp receiver → batch → routing connector (acting as an exporter).
          'traces/thirdparty': {
            receivers: ['otlp'],
            processors: ['batch'],
            exporters: ['routing'],
          },
          // routing connector (acting as a receiver) → per-BU otlphttp exporter.
          ...perBu.perBuPipelines,
        },
      },
    };

    return {
      config,
      yaml: toYaml(config),
      exporterNames: perBu.exporterNames,
    };
  }

  // ---- DEFAULT BRANCH (unchanged — backward compatible) ------------------
  const resolved = resolveBackends(backendConfiguration, options);
  const { exporters, keys } = buildExporters(resolved, queueSize, retryMaxElapsedTime);

  const config: CollectorConfig = {
    receivers,
    processors: {
      batch: {},
    },
    exporters,
    service: {
      // Default: a single third-party pipeline. Per-BU routing (above) is
      // engaged only when `langfuseProjectBindings` + `langfuseOtelEndpoint`
      // are supplied — still third-party only, never AWS-native, in both paths.
      pipelines: {
        'traces/thirdparty': {
          receivers: ['otlp'],
          processors: ['batch'],
          exporters: keys,
        },
      },
    },
  };

  return {
    config,
    yaml: toYaml(config),
    exporterNames: keys,
  };
}
