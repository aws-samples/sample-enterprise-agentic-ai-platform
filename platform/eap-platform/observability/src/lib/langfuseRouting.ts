/**
 * langfuseRouting.ts — pure, AWS-free per-BU routing resolution for the
 * OTel_Collector's THIRD-PARTY export layer (design "Per-BU Langfuse routing via
 * the `routing` connector"; task 10.2; Requirement 14.4).
 *
 * `resolveLangfuseRoute` selects EXACTLY the `LangfuseProjectBinding` whose `bu`
 * matches the telemetry's Business_Unit attribute — the `deployment.environment`
 * resource attribute the observability module stamps on every span — and returns
 * that project's routing target: its `projectId`, the Langfuse OTLP endpoint
 * (`/api/public/otel`), and the per-project Basic-auth secret ref
 * (`otlpBasicAuthRef`). The collector uses this to fan each agent's duplicated
 * span stream to the owning BU's Langfuse project only (R14.4).
 *
 * TENANT-ISOLATION INVARIANT (property-tested in task 10.3 — Property 14): this
 * resolver NEVER selects another BU's project. It FAILS CLOSED — returning
 * `null` (no route, no credentials) — whenever:
 *   - the BU attribute is missing / empty / whitespace-only / non-string;
 *   - no binding's `bu` matches the telemetry's BU attribute;
 *   - more than one binding matches the same BU (ambiguous misconfiguration —
 *     picking either could leak across projects, so route nothing);
 *   - the matched binding is incomplete (missing `projectId` or
 *     `otlpBasicAuthRef`) or no Langfuse OTLP endpoint was injected.
 * There is deliberately NO fallback to a "default" project — an unresolved BU
 * must drop out of the third-party leg rather than risk cross-BU delivery.
 *
 * The Langfuse OTLP endpoint is NOT hardcoded: it is injected via
 * `options.langfuseOtelEndpoint` (the in-stack Langfuse OTLP receiver URL,
 * `https://<langfuse-alb>/api/public/otel`, supplied by Terraform at render
 * time). All BUs share the same self-hosted Langfuse receiver; per-project
 * isolation is carried by the per-project Basic-auth keys (`otlpBasicAuthRef`),
 * not by a distinct endpoint. Injecting the endpoint keeps this a total,
 * deterministic pure function — no AWS calls, no environment coupling — so it
 * can be exhaustively property-tested without mocking, mirroring
 * `backendConfig.ts` / `collectorConfig.ts` in this directory.
 */

import type { LangfuseProjectBinding } from './types';

// ---------------------------------------------------------------------------
// Resolved route output shape
// ---------------------------------------------------------------------------

/**
 * The routing target for a single BU's telemetry: the Langfuse project it maps
 * to plus the OTLP export coordinates the collector needs. Returned only when a
 * single binding matches the telemetry's BU and the route is complete; otherwise
 * `resolveLangfuseRoute` returns `null` (fail closed — R14.4).
 */
export interface LangfuseRoute {
  /** The Business_Unit this route belongs to (the matched binding's `bu`). */
  bu: string;
  /** The owning BU's Langfuse project id. */
  projectId: string;
  /**
   * Langfuse OTLP receiver URL (`https://<langfuse-alb>/api/public/otel`).
   * Equals EXACTLY the injected `options.langfuseOtelEndpoint`.
   */
  otlpEndpoint: string;
  /**
   * Secrets Manager ref for this project's `base64(public:secret)` Basic-auth
   * header. It is the per-project credential that scopes delivery to this BU's
   * project — NEVER another BU's.
   */
  otlpBasicAuthRef: string;
}

/** Options carrying the injected (shared) Langfuse OTLP endpoint. */
export interface ResolveLangfuseRouteOptions {
  /**
   * In-stack Langfuse OTLP endpoint (e.g. `https://<langfuse-alb>/api/public/otel`).
   * Injected by Terraform at render time — NOT hardcoded here. Shared across all
   * BUs; per-BU isolation comes from `otlpBasicAuthRef`.
   */
  langfuseOtelEndpoint: string;
}

// ---------------------------------------------------------------------------
// Helpers (total — never throw)
// ---------------------------------------------------------------------------

/** Coerce an unknown to a trimmed string ('' for non-strings/empty). */
function asTrimmedString(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

// ---------------------------------------------------------------------------
// The pure resolution — R14.4
// ---------------------------------------------------------------------------

/**
 * Resolve the telemetry's Business_Unit attribute to EXACTLY its owning BU's
 * Langfuse routing target, or `null` when it cannot be resolved to a single,
 * complete binding (fail closed — R14.4).
 *
 * BU comparison is trimmed and case-sensitive, matching `authorizeAgentForBu`
 * in `ownership.ts` so the routing decision cannot be widened by casing. A BU
 * that matches zero — or more than one — binding routes NOTHING rather than
 * risk selecting the wrong project.
 *
 * Total and deterministic: never throws, makes no AWS call. `buAttribute` and
 * `bindings` may be null/undefined/malformed.
 *
 * @param buAttribute the telemetry's `deployment.environment` (BU) resource attribute.
 * @param bindings the per-BU `LangfuseProjectBinding` set (may be null/undefined/empty).
 * @param options injected Langfuse OTLP endpoint coordinates.
 * @returns the owning BU's `LangfuseRoute`, or `null` (fail closed).
 */
export function resolveLangfuseRoute(
  buAttribute: string | null | undefined,
  bindings: LangfuseProjectBinding[] | null | undefined,
  options: ResolveLangfuseRouteOptions,
): LangfuseRoute | null {
  // Fail closed on an unresolved/missing/empty BU attribute — never guess.
  const bu = asTrimmedString(buAttribute);
  if (bu.length === 0) {
    return null;
  }

  // Fail closed when there are no bindings to match against.
  if (!Array.isArray(bindings) || bindings.length === 0) {
    return null;
  }

  // Select EXACTLY the binding(s) whose `bu` matches — never another BU's.
  const matches = bindings.filter(
    (binding): binding is LangfuseProjectBinding =>
      binding != null &&
      typeof binding === 'object' &&
      asTrimmedString(binding.bu) === bu,
  );

  // Zero matches, or an ambiguous multi-match (misconfiguration), route nothing.
  if (matches.length !== 1) {
    return null;
  }

  const binding = matches[0];
  const projectId = asTrimmedString(binding.projectId);
  const otlpBasicAuthRef = asTrimmedString(binding.otlpBasicAuthRef);
  const otlpEndpoint = asTrimmedString(options?.langfuseOtelEndpoint);

  // An incomplete binding (no project or no credentials) or a missing endpoint
  // cannot produce a usable, isolated route — fail closed rather than emit a
  // partial route that could deliver without proper per-project scoping.
  if (projectId.length === 0 || otlpBasicAuthRef.length === 0 || otlpEndpoint.length === 0) {
    return null;
  }

  return {
    bu,
    projectId,
    otlpEndpoint,
    otlpBasicAuthRef,
  };
}
