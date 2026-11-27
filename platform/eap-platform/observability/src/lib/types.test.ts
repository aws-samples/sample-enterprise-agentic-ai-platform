import { describe, it, expect } from 'vitest';
import * as lib from './index';
import type {
  CallerClaims,
  AgentOwnership,
  DeepLinkResponse,
  AgentMetrics,
  TraceSummary,
  TraceListResponse,
  SpanDetail,
  TraceDetailResponse,
  BackendConfiguration,
  ThirdPartyBackend,
  LangfuseProjectBinding,
} from './types';

/**
 * Compile-time + light runtime checks that every design data-model type is
 * constructible and re-exported from the barrel. If a shape drifts from the
 * design, this file fails to type-check.
 */
describe('data-model types', () => {
  it('constructs each design shape', () => {
    const claims: CallerClaims = {
      sub: 's',
      bu: 'team-bu-1',
      personas: ['Developer'],
      exp: 1,
      iss: 'iss',
    };
    const ownership: AgentOwnership = {
      runtime_arn: 'arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/a',
      agent_name: 'a',
      bu: 'team-bu-1',
      endpoint_qualifier: 'a_endpoint',
    };
    const thirdParty: ThirdPartyBackend = {
      name: 'langfuse',
      otlpEndpoint: 'https://lf/api/public/otel',
      authSecretArn: 'arn:aws:secretsmanager:us-east-1:123456789012:secret:x',
      mode: 'add',
      enabled: true,
    };
    const backendConfig: BackendConfiguration = {
      thirdParty: [thirdParty],
    };
    const binding: LangfuseProjectBinding = {
      bu: 'team-bu-1',
      projectId: 'p1',
      publicKeyRef: 'ref-pub',
      secretKeyRef: 'ref-sec',
      otlpBasicAuthRef: 'ref-basic',
    };
    const deepLink: DeepLinkResponse = { url: 'https://signin', expiresAt: '2024-01-01T00:00:00Z' };
    const metrics: AgentMetrics = {
      agentArn: ownership.runtime_arn,
      bu: 'team-bu-1',
      range: { start: 's', end: 'e' },
      sessionCount: 0,
      latencyMs: { p50: 0, p90: 0, p99: 0 },
      durationMs: { avg: 0, max: 0 },
      tokenUsage: { input: 0, output: 0, total: 0 },
      errorRate: 0,
    };
    const summary: TraceSummary = {
      traceId: 't',
      sessionId: 's',
      startTime: 'st',
      durationMs: 1,
      status: 'ok',
    };
    const list: TraceListResponse = { agentArn: metrics.agentArn, bu: 'team-bu-1', sessionTimeline: [summary] };
    const span: SpanDetail = {
      spanId: 'sp',
      name: 'call',
      kind: 'tool',
      toolCalls: [{ name: 'search', input: {}, output: {} }],
      tokenUsage: { input: 1, output: 2, total: 3 },
      startTime: 'st',
      durationMs: 1,
    };
    const detail: TraceDetailResponse = { traceId: 't', agentArn: metrics.agentArn, bu: 'team-bu-1', spans: [span] };

    // Runtime sanity on a couple of invariants used later.
    // Backend_Configuration governs the third-party leg ONLY (no awsNative field).
    expect(backendConfig.thirdParty).toHaveLength(1);
    expect(span.tokenUsage.total).toBe(span.tokenUsage.input + span.tokenUsage.output);
    expect(list.sessionTimeline).toHaveLength(1);
    expect(detail.spans[0].kind).toBe('tool');
    expect(binding.bu).toBe(claims.bu);
    expect(deepLink.url).toBeTypeOf('string');
  });

  it('re-exports the pure logic from the barrel', () => {
    expect(lib.validateJwt).toBeTypeOf('function');
    expect(lib.deriveBu).toBeTypeOf('function');
    expect(lib.derivePersonas).toBeTypeOf('function');
    expect(lib.isValidRuntimeArn).toBeTypeOf('function');
    expect(lib.sanitizeErrorMessage).toBeTypeOf('function');
  });
});
