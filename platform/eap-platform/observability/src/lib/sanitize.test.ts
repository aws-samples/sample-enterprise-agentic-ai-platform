import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { sanitizeErrorMessage } from './sanitize';

describe('sanitizeErrorMessage', () => {
  it('redacts ARNs', () => {
    const out = sanitizeErrorMessage(
      'failed for arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/foo bar',
    );
    expect(out).toContain('[REDACTED_ARN]');
    expect(out).not.toContain('runtime/foo');
  });

  it('redacts bare 12-digit account IDs', () => {
    expect(sanitizeErrorMessage('account 123456789012 denied')).toBe(
      'account [REDACTED_ACCOUNT] denied',
    );
  });

  it('redacts request IDs and stack traces', () => {
    const raw = 'boom 3f2504e0-4f89-41d3-9a0c-0305e82c3301\n    at Object.<anonymous> (/x/y.ts:1:2)';
    const out = sanitizeErrorMessage(raw);
    expect(out).toContain('[REDACTED_REQUEST_ID]');
    expect(out).not.toMatch(/\n\s*at /);
  });

  it('coerces non-string input without throwing', () => {
    // @ts-expect-error exercising defensive runtime behavior
    expect(() => sanitizeErrorMessage(undefined)).not.toThrow();
  });

  // Harness verification: proves fast-check is wired up. This is NOT one of the
  // design's numbered correctness properties (those are implemented by later
  // tasks); it asserts a basic invariant of the ported utility.
  it('[harness] never leaks a bare 12-digit account id for any message', () => {
    fc.assert(
      fc.property(fc.string(), fc.integer({ min: 100000000000, max: 999999999999 }), (prefix, acct) => {
        const out = sanitizeErrorMessage(`${prefix} ${acct}`);
        // The specific injected 12-digit account id must be redacted.
        expect(out).not.toContain(String(acct));
      }),
      { numRuns: 100 },
    );
  });
});
