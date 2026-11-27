/**
 * Feature: agentcore-observability, Property 14: Each Agent's third-party
 * telemetry routes to its owning BU's project.
 *
 * Validates R14.4.
 *
 * Property strategy: generate random Agent→BU→project bindings (a set of BUs,
 * each with a distinct Langfuse project + per-project Basic-auth ref) and a
 * random telemetry BU attribute, then assert:
 *   - when the telemetry BU matches a bound BU, the resolver selects EXACTLY
 *     that BU's project/credentials and NEVER another BU's;
 *   - when the telemetry BU is unresolvable (missing/empty/whitespace, unknown,
 *     or ambiguous/duplicate binding), the resolver FAILS CLOSED (returns null),
 *     with no fallback to any other BU's project.
 */

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import {
  resolveLangfuseRoute,
  type ResolveLangfuseRouteOptions,
} from './langfuseRouting';
import type { LangfuseProjectBinding } from './types';

const OTEL_ENDPOINT = 'https://langfuse.internal/api/public/otel';
const options: ResolveLangfuseRouteOptions = { langfuseOtelEndpoint: OTEL_ENDPOINT };

function binding(overrides: Partial<LangfuseProjectBinding> = {}): LangfuseProjectBinding {
  return {
    bu: 'team-bu-1',
    projectId: 'proj-team-bu-1',
    publicKeyRef: 'arn:aws:secretsmanager:us-east-1:123456789012:secret:pk-team-bu-1',
    secretKeyRef: 'arn:aws:secretsmanager:us-east-1:123456789012:secret:sk-team-bu-1',
    otlpBasicAuthRef: 'arn:aws:secretsmanager:us-east-1:123456789012:secret:auth-team-bu-1',
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Unit tests — specific examples and edge cases
// ---------------------------------------------------------------------------

describe('resolveLangfuseRoute', () => {
  it('routes to the owning BU project and returns endpoint + per-project auth (R14.4)', () => {
    const bindings = [
      binding({ bu: 'team-bu-1', projectId: 'proj-1', otlpBasicAuthRef: 'ref-1' }),
      binding({ bu: 'team-bu-2', projectId: 'proj-2', otlpBasicAuthRef: 'ref-2' }),
    ];
    const route = resolveLangfuseRoute('team-bu-2', bindings, options);
    expect(route).toEqual({
      bu: 'team-bu-2',
      projectId: 'proj-2',
      otlpEndpoint: OTEL_ENDPOINT,
      otlpBasicAuthRef: 'ref-2',
    });
  });

  it('never selects another BU project — returns exactly the matching BU', () => {
    const bindings = [
      binding({ bu: 'team-bu-1', projectId: 'proj-1', otlpBasicAuthRef: 'ref-1' }),
      binding({ bu: 'team-bu-2', projectId: 'proj-2', otlpBasicAuthRef: 'ref-2' }),
      binding({ bu: 'team-bu-3', projectId: 'proj-3', otlpBasicAuthRef: 'ref-3' }),
    ];
    const route = resolveLangfuseRoute('team-bu-1', bindings, options);
    expect(route?.projectId).toBe('proj-1');
    expect(route?.otlpBasicAuthRef).toBe('ref-1');
  });

  it('fails closed (null) when no binding matches the BU (no fallback)', () => {
    const bindings = [binding({ bu: 'team-bu-1' }), binding({ bu: 'team-bu-2' })];
    expect(resolveLangfuseRoute('team-bu-99', bindings, options)).toBeNull();
  });

  it('fails closed for missing/empty/whitespace BU attribute', () => {
    const bindings = [binding({ bu: 'team-bu-1' })];
    for (const bu of [null, undefined, '', '   ', '\t\n']) {
      expect(resolveLangfuseRoute(bu as string | null | undefined, bindings, options)).toBeNull();
    }
  });

  it('fails closed when bindings are null/undefined/empty', () => {
    expect(resolveLangfuseRoute('team-bu-1', null, options)).toBeNull();
    expect(resolveLangfuseRoute('team-bu-1', undefined, options)).toBeNull();
    expect(resolveLangfuseRoute('team-bu-1', [], options)).toBeNull();
  });

  it('fails closed on an ambiguous duplicate-BU binding (never guesses)', () => {
    const bindings = [
      binding({ bu: 'team-bu-1', projectId: 'proj-1a', otlpBasicAuthRef: 'ref-1a' }),
      binding({ bu: 'team-bu-1', projectId: 'proj-1b', otlpBasicAuthRef: 'ref-1b' }),
    ];
    expect(resolveLangfuseRoute('team-bu-1', bindings, options)).toBeNull();
  });

  it('fails closed on an incomplete binding (missing projectId or auth ref)', () => {
    expect(
      resolveLangfuseRoute('team-bu-1', [binding({ bu: 'team-bu-1', projectId: '' })], options),
    ).toBeNull();
    expect(
      resolveLangfuseRoute('team-bu-1', [binding({ bu: 'team-bu-1', otlpBasicAuthRef: '  ' })], options),
    ).toBeNull();
  });

  it('fails closed when no Langfuse OTLP endpoint is injected', () => {
    const bindings = [binding({ bu: 'team-bu-1' })];
    expect(resolveLangfuseRoute('team-bu-1', bindings, { langfuseOtelEndpoint: '' })).toBeNull();
  });

  it('is trimmed and case-sensitive on the BU comparison', () => {
    const bindings = [binding({ bu: 'team-bu-1', projectId: 'proj-1', otlpBasicAuthRef: 'ref-1' })];
    // Trimmed match succeeds.
    expect(resolveLangfuseRoute('  team-bu-1  ', bindings, options)?.projectId).toBe('proj-1');
    // Different casing does NOT match (fail closed rather than cross-route).
    expect(resolveLangfuseRoute('Team-BU-1', bindings, options)).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// Property 14 — fast-check, >= 100 iterations
// ---------------------------------------------------------------------------

/** Distinct, non-empty BU tokens so each binding owns a unique BU. */
const buArb = fc
  .tuple(
    fc.constantFrom('team-bu', 'unit', 'org', 'bu', 'tenant'),
    fc.integer({ min: 0, max: 9999 }),
  )
  .map(([prefix, n]) => `${prefix}-${n}`);

/** A set of bindings with UNIQUE BUs, each with a distinct project + auth ref. */
const bindingsArb = fc
  .uniqueArray(buArb, { minLength: 1, maxLength: 8 })
  .map((bus) =>
    bus.map(
      (bu, i): LangfuseProjectBinding => ({
        bu,
        projectId: `proj-${bu}-${i}`,
        publicKeyRef: `ref-pk-${bu}-${i}`,
        secretKeyRef: `ref-sk-${bu}-${i}`,
        otlpBasicAuthRef: `ref-auth-${bu}-${i}`,
      }),
    ),
  );

describe('Property 14: per-BU routing selects exactly the owning BU project', () => {
  it('routes a matching BU to EXACTLY its own project/credentials, never another BU', () => {
    fc.assert(
      fc.property(bindingsArb, fc.nat(), (bindings, idxSeed) => {
        // Pick one bound BU to route.
        const target = bindings[idxSeed % bindings.length];
        const route = resolveLangfuseRoute(target.bu, bindings, options);

        // A route MUST be produced and it MUST be exactly the owning binding.
        expect(route).not.toBeNull();
        expect(route!.bu).toBe(target.bu);
        expect(route!.projectId).toBe(target.projectId);
        expect(route!.otlpBasicAuthRef).toBe(target.otlpBasicAuthRef);
        expect(route!.otlpEndpoint).toBe(OTEL_ENDPOINT);

        // It MUST NOT be any other BU's project or credentials.
        for (const other of bindings) {
          if (other.bu === target.bu) continue;
          expect(route!.projectId).not.toBe(other.projectId);
          expect(route!.otlpBasicAuthRef).not.toBe(other.otlpBasicAuthRef);
        }
      }),
      { numRuns: 200 },
    );
  });

  it('fails closed for an unknown BU — no fallback to any other BU project', () => {
    fc.assert(
      fc.property(bindingsArb, fc.string(), (bindings, raw) => {
        const known = new Set(bindings.map((b) => b.bu));
        // Construct a BU token that is guaranteed not to match any binding.
        const unknownBu = `UNKNOWN::${raw}`;
        fc.pre(!known.has(unknownBu.trim()) && unknownBu.trim().length > 0);

        const route = resolveLangfuseRoute(unknownBu, bindings, options);
        expect(route).toBeNull();
      }),
      { numRuns: 200 },
    );
  });

  it('fails closed for missing/empty/whitespace BU attributes regardless of bindings', () => {
    fc.assert(
      fc.property(
        bindingsArb,
        fc.constantFrom<string | null | undefined>(null, undefined, '', ' ', '\t', '\n', '   '),
        (bindings, emptyBu) => {
          expect(resolveLangfuseRoute(emptyBu, bindings, options)).toBeNull();
        },
      ),
      { numRuns: 100 },
    );
  });

  it('fails closed on ambiguous duplicate-BU bindings (never selects a project)', () => {
    fc.assert(
      fc.property(bindingsArb, fc.nat(), (bindings, idxSeed) => {
        const target = bindings[idxSeed % bindings.length];
        // Inject a second binding for the same BU → ambiguous.
        const ambiguous = [
          ...bindings,
          {
            bu: target.bu,
            projectId: `${target.projectId}-dup`,
            publicKeyRef: `${target.publicKeyRef}-dup`,
            secretKeyRef: `${target.secretKeyRef}-dup`,
            otlpBasicAuthRef: `${target.otlpBasicAuthRef}-dup`,
          },
        ];
        expect(resolveLangfuseRoute(target.bu, ambiguous, options)).toBeNull();
      }),
      { numRuns: 100 },
    );
  });
});
