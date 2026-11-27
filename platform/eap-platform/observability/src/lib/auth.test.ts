import { describe, it, expect } from 'vitest';
import {
  validateJwt,
  deriveBu,
  derivePersonas,
  hasObservabilityPersona,
  toCallerClaims,
  COGNITO_ISSUER,
  OBSERVABILITY_PERSONAS,
  type RawJwtPayload,
} from './auth';

/** Build a compact, unsigned JWT (header.payload.signature) for tests. */
function makeJwt(payload: Record<string, unknown>, sig = 'sig'): string {
  const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${b64({ alg: 'none', typ: 'JWT' })}.${b64(payload)}.${sig}`;
}

const NOW = 1_700_000_000; // fixed clock for deterministic expiry checks

describe('validateJwt (structure / expiry / issuer)', () => {
  it('rejects a missing Authorization header', () => {
    const r = validateJwt(undefined, NOW);
    expect(r.valid).toBe(false);
    expect(r.error).toMatch(/Missing/);
  });

  it('rejects an empty token', () => {
    expect(validateJwt('Bearer ', NOW).valid).toBe(false);
    expect(validateJwt('', NOW).valid).toBe(false);
  });

  it('rejects a token without three parts', () => {
    expect(validateJwt('Bearer not.ajwt', NOW).valid).toBe(false);
  });

  it('rejects an expired token', () => {
    const token = makeJwt({ exp: NOW - 1, iss: COGNITO_ISSUER });
    const r = validateJwt(`Bearer ${token}`, NOW);
    expect(r.valid).toBe(false);
    expect(r.error).toBe('Token expired');
  });

  it('rejects a wrong-issuer token', () => {
    const token = makeJwt({ exp: NOW + 100, iss: 'https://evil.example.com' });
    const r = validateJwt(`Bearer ${token}`, NOW);
    expect(r.valid).toBe(false);
    expect(r.error).toBe('Invalid token issuer');
  });

  it('accepts a well-formed, unexpired, correct-issuer token and returns the payload', () => {
    const token = makeJwt({ sub: 'u1', exp: NOW + 100, iss: COGNITO_ISSUER });
    const r = validateJwt(`Bearer ${token}`, NOW);
    expect(r.valid).toBe(true);
    expect(r.payload?.sub).toBe('u1');
  });

  it('accepts a raw token without the Bearer prefix', () => {
    const token = makeJwt({ exp: NOW + 100, iss: COGNITO_ISSUER });
    expect(validateJwt(token, NOW).valid).toBe(true);
  });

  it('does not throw on undecodable payloads', () => {
    expect(() => validateJwt('Bearer aaa.!!!notbase64json!!!.ccc', NOW)).not.toThrow();
    expect(validateJwt('Bearer aaa.!!!notbase64json!!!.ccc', NOW).valid).toBe(false);
  });
});

describe('deriveBu (R4.1)', () => {
  it('prefers a dedicated bu claim', () => {
    expect(deriveBu({ bu: 'team-bu-1', 'cognito:groups': ['bu:other'] })).toBe('team-bu-1');
  });

  it('falls back to custom:bu', () => {
    expect(deriveBu({ 'custom:bu': 'team-bu-2' } as RawJwtPayload)).toBe('team-bu-2');
  });

  it('reads the bu:<unit> cognito group', () => {
    expect(deriveBu({ 'cognito:groups': ['Developer', 'bu:team-bu-3'] })).toBe('team-bu-3');
  });

  it('returns empty string when no BU is resolvable (caller must fail closed)', () => {
    expect(deriveBu({ 'cognito:groups': ['Developer'] })).toBe('');
    expect(deriveBu({})).toBe('');
    expect(deriveBu(null)).toBe('');
  });
});

describe('derivePersonas + hasObservabilityPersona (R10)', () => {
  it('extracts only recognized personas, de-duplicated and ordered', () => {
    const personas = derivePersonas({
      'cognito:groups': ['Developer', 'Developer', 'AI_Governance_Risk', 'bu:team-bu-1', 'random'],
    });
    expect(personas).toEqual(['AI_Governance_Risk', 'Developer']);
  });

  it('returns no personas when none are present', () => {
    expect(derivePersonas({ 'cognito:groups': ['bu:team-bu-1'] })).toEqual([]);
    expect(hasObservabilityPersona([])).toBe(false);
  });

  it('grants access iff at least one observability persona is held', () => {
    for (const p of OBSERVABILITY_PERSONAS) {
      expect(hasObservabilityPersona([p])).toBe(true);
    }
    expect(hasObservabilityPersona(['SomethingElse'])).toBe(false);
  });
});

describe('toCallerClaims', () => {
  it('assembles derived bu and personas alongside raw fields', () => {
    const payload: RawJwtPayload = {
      sub: 'u9',
      exp: NOW + 100,
      iss: COGNITO_ISSUER,
      'cognito:groups': ['bu:team-bu-1', 'Platform_Operator'],
    };
    expect(toCallerClaims(payload)).toEqual({
      sub: 'u9',
      bu: 'team-bu-1',
      personas: ['Platform_Operator'],
      exp: NOW + 100,
      iss: COGNITO_ISSUER,
    });
  });
});
