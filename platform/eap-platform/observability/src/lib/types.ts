/**
 * Shared observability data-model types (design "Data Models" section).
 *
 * These are pure, AWS-free TypeScript shapes shared across the
 * Deep_Link_Service, Telemetry_API_Service, the OTel_Collector
 * Backend_Configuration resolution logic, and the console workspace. Keeping a
 * single canonical definition ensures the request/response contracts and the
 * collector-config invariants cannot drift between producer and consumer.
 *
 * The shapes match the design document exactly.
 */

// ---------------------------------------------------------------------------
// Cognito Claims (input) — R4.1, R14.2
// ---------------------------------------------------------------------------

/** The observability persona set authorized to consume telemetry. */
export type Persona = 'Platform_Operator' | 'AI_Governance_Risk' | 'Developer';

/**
 * Caller identity derived from the Cognito authorizer claims. `bu` and
 * `personas` are *derived* values (see `deriveBu` / `derivePersonas`); `exp`
 * and `iss` are the raw JWT fields used for structural validation.
 */
export interface CallerClaims {
  sub: string;
  /** Caller's Business_Unit (derived) — R4.1, R14.2. */
  bu: string;
  /** Subset of {Platform_Operator, AI_Governance_Risk, Developer}. */
  personas: string[];
  exp: number;
  /** Must match the platform user pool issuer. */
  iss: string;
}

// ---------------------------------------------------------------------------
// Agent Ownership Record (DynamoDB lifecycle store) — R4, R14.4
// ---------------------------------------------------------------------------

/** ARN ↔ BU mapping resolved from the lifecycle store. */
export interface AgentOwnership {
  /** AgentCore runtime ARN (Agent identity). */
  runtime_arn: string;
  agent_name: string;
  /** Owning Business_Unit. */
  bu: string;
  endpoint_qualifier: string;
}

// ---------------------------------------------------------------------------
// Backend_Configuration (deployment) — R16
// ---------------------------------------------------------------------------

/**
 * A configured third-party OTLP backend. `mode` is relative to the default
 * Langfuse backend — R16.3.
 */
export interface ThirdPartyBackend {
  /** "langfuse" | "fiddler" | "datadog" | ... */
  name: string;
  /** https OTLP receiver URL. */
  otlpEndpoint: string;
  /** Secrets Manager ref for the auth header. */
  authSecretArn: string;
  /** Relative to the default Langfuse — R16.3. */
  mode: 'replace' | 'add';
  enabled: boolean;
}

/**
 * The deployment-level configuration resolved at the OTel_Collector export
 * layer. It governs the OTel_Collector's THIRD-PARTY export ONLY.
 *
 * There is deliberately **no** `awsNative` field: the AWS-native leg
 * (CloudWatch/X-Ray) is delivered by AgentCore auto-instrumentation on a
 * separate pipeline and is NOT part of Backend_Configuration. No value here
 * can add, remove, reroute, or disable it — that independence is *structural*,
 * not template-conditional (R16.5, R16.6, R12.6, R8.3).
 */
export interface BackendConfiguration {
  /** Empty => default Langfuse only — R16.4. */
  thirdParty: ThirdPartyBackend[];
}

// ---------------------------------------------------------------------------
// Langfuse Project Mapping — R14
// ---------------------------------------------------------------------------

/** Per-BU Langfuse project binding used by the collector routing resolution. */
export interface LangfuseProjectBinding {
  /** Business_Unit. */
  bu: string;
  projectId: string;
  /** Secrets Manager ref (per-project). */
  publicKeyRef: string;
  /** Secrets Manager ref (per-project). */
  secretKeyRef: string;
  /** base64(public:secret) for the collector export header. */
  otlpBasicAuthRef: string;
}

// ---------------------------------------------------------------------------
// Deep-Link Response — R1
// ---------------------------------------------------------------------------

/** The federated sign-in URL returned to the ObservabilityWorkspace. */
export interface DeepLinkResponse {
  /** AWS federation sign-in URL → GenAI Observability, agent-prefiltered. */
  url: string;
  /** ISO-8601, always <= now + 60min — R1.5. */
  expiresAt: string;
}

// ---------------------------------------------------------------------------
// Telemetry Shapes (returned to UI) — R2, R6
// ---------------------------------------------------------------------------

/** GET /metrics — R2.2, R6.1–6.3. */
export interface AgentMetrics {
  agentArn: string;
  /** Always the caller's BU — R4.5. */
  bu: string;
  range: { start: string; end: string };
  sessionCount: number;
  latencyMs: { p50: number; p90: number; p99: number };
  durationMs: { avg: number; max: number };
  tokenUsage: { input: number; output: number; total: number };
  /** 0..1. */
  errorRate: number;
}

/** GET /traces — R2.3, R6.4. */
export interface TraceSummary {
  traceId: string;
  sessionId: string;
  startTime: string;
  durationMs: number;
  status: 'ok' | 'error';
}

export interface TraceListResponse {
  agentArn: string;
  bu: string;
  sessionTimeline: TraceSummary[];
}

/** GET /traces/{traceId} — R2.4, R6.5. */
export interface SpanDetail {
  spanId: string;
  name: string;
  kind: 'tool' | 'model' | 'agent' | 'other';
  toolCalls: { name: string; input: unknown; output: unknown }[];
  tokenUsage: { input: number; output: number; total: number };
  startTime: string;
  durationMs: number;
}

export interface TraceDetailResponse {
  traceId: string;
  agentArn: string;
  bu: string;
  spans: SpanDetail[];
}
