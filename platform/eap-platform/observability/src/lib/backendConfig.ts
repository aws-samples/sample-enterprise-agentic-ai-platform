/**
 * backendConfig.ts — pure, AWS-free Backend_Configuration resolution for the
 * OTel_Collector's THIRD-PARTY export layer (design "Backend_Configuration
 * Mechanism"; Requirement 16).
 *
 * `resolveBackends` maps a deployment `BackendConfiguration` to the ordered set
 * of third-party OTLP exporters the collector should render (task 7.3). It is
 * the single swap point that lets an operator point the third-party leg at
 * Langfuse (default), an alternate such as Fiddler/Datadog (`replace`), or both
 * (`add`) — with no agent application code change (R16.1–16.4, R9.1, R12.3).
 *
 * Design invariants enforced here (property-tested in task 7.2 — Property 13):
 *   - empty/absent config (or all backends disabled) → default Langfuse only;
 *   - `mode = "replace"` → the alternate(s) in place of Langfuse;
 *   - `mode = "add"`     → Langfuse PLUS the alternate(s);
 *   - every resolved exporter's `otlpEndpoint` equals EXACTLY its configured
 *     endpoint;
 *   - the result is ALWAYS third-party OTLP — it produces NO AWS-native
 *     exporter (`awsxray`/`awsemf`/`awscloudwatchlogs`) and references no agent
 *     artifact (R16.5, R16.6, R12.2).
 *
 * The default Langfuse OTLP endpoint is NOT hardcoded: it is injected via
 * `options.defaultLangfuseEndpoint` (the in-stack Langfuse OTLP receiver URL,
 * supplied by Terraform at render time). This keeps the resolver a total,
 * deterministic pure function with no AWS calls and no environment coupling, so
 * it can be exhaustively property-tested without mocking.
 */

import type { BackendConfiguration, ThirdPartyBackend } from './types';

// ---------------------------------------------------------------------------
// AWS-native exporter names (for negative assertions) — R16.5, R12.2
// ---------------------------------------------------------------------------

/**
 * The OTel Collector exporter type names that target the AWS-native leg. This
 * resolver NEVER emits any of these: the AWS-native leg is delivered by a
 * separate AgentCore-managed pipeline that no Backend_Configuration value can
 * add, remove, reroute, or disable (structural independence — R16.5, 16.6,
 * 12.6, 8.3). Exposed so consumers/tests can assert their absence.
 */
export const AWS_NATIVE_EXPORTER_NAMES = [
  'awsxray',
  'awsemf',
  'awscloudwatchlogs',
] as const;

// ---------------------------------------------------------------------------
// Resolved exporter output shape
// ---------------------------------------------------------------------------

/**
 * A single resolved third-party exporter, ready for the collector config
 * render (task 7.3). `kind` is a fixed discriminant (`'otlphttp'`) making it
 * structurally impossible for a resolved exporter to be AWS-native.
 */
export interface ResolvedExporter {
  /** Backend name, e.g. "langfuse" | "fiddler" | "datadog". */
  name: string;
  /**
   * Exporter kind. Always `'otlphttp'` — this resolver only ever produces
   * third-party OTLP/HTTP exporters, never an AWS-native exporter.
   */
  kind: 'otlphttp';
  /** OTLP receiver URL. Equals EXACTLY the configured endpoint (R16.2). */
  otlpEndpoint: string;
  /** Optional Secrets Manager ref for the auth header (omitted when absent). */
  authSecretArn?: string;
}

/** Options carrying the injected default-backend (Langfuse) coordinates. */
export interface ResolveBackendsOptions {
  /**
   * In-stack Langfuse OTLP endpoint (e.g. `https://<langfuse-alb>/api/public/otel`).
   * Injected by Terraform at render time — NOT hardcoded here (R16.4).
   */
  defaultLangfuseEndpoint: string;
  /** Optional Secrets Manager ref for the default Langfuse auth header. */
  defaultLangfuseAuthSecretArn?: string;
  /** Name for the default backend exporter. Defaults to `"langfuse"`. */
  defaultLangfuseName?: string;
}

// ---------------------------------------------------------------------------
// Helpers (total, never throw)
// ---------------------------------------------------------------------------

/** Coerce an unknown to a string ('' for non-strings); used for endpoints. */
function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

/** Trimmed string, or undefined when empty/non-string (for optional refs). */
function optionalRef(value: unknown): string | undefined {
  const s = typeof value === 'string' ? value.trim() : '';
  return s.length > 0 ? s : undefined;
}

/**
 * Normalize a backend's mode. Only `"replace"` drops Langfuse; anything else
 * (including `"add"`, unknown, or missing) is treated as additive `"add"` so a
 * malformed entry can never silently disable the default backend.
 */
function normalizeMode(mode: unknown): 'replace' | 'add' {
  return mode === 'replace' ? 'replace' : 'add';
}

/** True only for a strictly-enabled backend (fail-safe: default disabled). */
function isEnabled(backend: ThirdPartyBackend): boolean {
  return backend?.enabled === true;
}

/** Build the resolved default Langfuse exporter from injected options. */
function defaultLangfuseExporter(options: ResolveBackendsOptions): ResolvedExporter {
  const exporter: ResolvedExporter = {
    name: optionalRef(options.defaultLangfuseName) ?? 'langfuse',
    kind: 'otlphttp',
    otlpEndpoint: asString(options.defaultLangfuseEndpoint),
  };
  const auth = optionalRef(options.defaultLangfuseAuthSecretArn);
  if (auth) {
    exporter.authSecretArn = auth;
  }
  return exporter;
}

/** Map one configured third-party backend to a resolved exporter. */
function toResolvedExporter(backend: ThirdPartyBackend): ResolvedExporter {
  const exporter: ResolvedExporter = {
    name: asString(backend.name),
    kind: 'otlphttp',
    // Endpoint is copied verbatim so it equals EXACTLY the configured value.
    otlpEndpoint: asString(backend.otlpEndpoint),
  };
  const auth = optionalRef(backend.authSecretArn);
  if (auth) {
    exporter.authSecretArn = auth;
  }
  return exporter;
}

// ---------------------------------------------------------------------------
// The pure resolution — R9.1, R12.3, R16.1, R16.2, R16.3, R16.4
// ---------------------------------------------------------------------------

/**
 * Resolve a `BackendConfiguration` to the ordered set of THIRD-PARTY OTLP
 * exporters for the collector's third-party export layer.
 *
 * Rules (design "Backend_Configuration Mechanism"):
 *   - No enabled backends (empty/absent config, or every entry disabled) →
 *     the default Langfuse exporter only (R16.4).
 *   - Any enabled backend with `mode = "replace"` → the default Langfuse
 *     exporter is dropped and the enabled alternate(s) take its place (R16.3).
 *   - Otherwise (only `mode = "add"` entries) → the default Langfuse exporter
 *     PLUS the enabled alternate(s) (R16.3).
 *
 * The returned list contains ONLY third-party OTLP exporters — never an
 * AWS-native exporter, and it references no agent application artifact
 * (R16.5, R12.2). Total and deterministic: never throws, makes no AWS call.
 *
 * @param backendConfiguration deployment config (may be null/undefined/malformed).
 * @param options injected default-backend (Langfuse) coordinates.
 */
export function resolveBackends(
  backendConfiguration: BackendConfiguration | null | undefined,
  options: ResolveBackendsOptions,
): ResolvedExporter[] {
  const thirdParty = Array.isArray(backendConfiguration?.thirdParty)
    ? (backendConfiguration!.thirdParty as ThirdPartyBackend[])
    : [];

  // Only strictly-enabled, well-formed entries participate (respect `enabled`).
  const enabled = thirdParty.filter(
    (backend): backend is ThirdPartyBackend =>
      backend != null && typeof backend === 'object' && isEnabled(backend),
  );

  // No enabled backends → default Langfuse only (R16.4).
  if (enabled.length === 0) {
    return [defaultLangfuseExporter(options)];
  }

  // Langfuse is kept unless at least one enabled backend replaces it (R16.3).
  const langfuseReplaced = enabled.some(
    (backend) => normalizeMode(backend.mode) === 'replace',
  );

  const exporters: ResolvedExporter[] = [];
  if (!langfuseReplaced) {
    exporters.push(defaultLangfuseExporter(options));
  }
  for (const backend of enabled) {
    exporters.push(toResolvedExporter(backend));
  }
  return exporters;
}
