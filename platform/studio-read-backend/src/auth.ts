// Studio-Read Backend — request authentication (ADR-047)
// -----------------------------------------------------------------------------
// When these read routes moved off API Gateway (which provided a managed
// Cognito JWT authorizer) onto this ALB→Fargate backend, the JWT gate moved
// into the service. ADR-047: the gate verifies the token SIGNATURE against the
// identity provider's JWKS (aws-jwt-verify), plus expiry and issuer. A token
// with the right `iss` but no valid signature is rejected.
//
// Issuer resolution mirrors ADR-028:
//   * Platform Cognito  — COGNITO_USER_POOL_ID.
//   * External OIDC IdP — OIDC_ISSUER. The JWKS URI is OIDC_JWKS_URI when set,
//     otherwise read from the issuer's /.well-known/openid-configuration.
// Tokens from any app client of the configured issuer are accepted (an
// enterprise BYO UI may use its own client). If neither issuer is set the
// service refuses to start.
//
// Kept as a copy in each backend (ade-invoke-backend/src/auth.ts) because
// every backend ships as a self-contained container image.

import { CognitoJwtVerifier, JwtRsaVerifier } from 'aws-jwt-verify';

const COGNITO_USER_POOL_ID = process.env.COGNITO_USER_POOL_ID || '';
const OIDC_ISSUER = (process.env.OIDC_ISSUER || '').replace(/\/$/, '');
const OIDC_AUDIENCE = process.env.OIDC_AUDIENCE || '';
const OIDC_JWKS_URI = process.env.OIDC_JWKS_URI || '';

type Payload = { sub?: unknown };
type Verify = (token: string) => Promise<Payload>;

/**
 * Fail fast at boot if no auth issuer is configured. Called once from server.ts
 * so the container crash-loops on a misconfigured deploy instead of running
 * open.
 */
export function assertAuthConfigured(): void {
  if (!OIDC_ISSUER && !COGNITO_USER_POOL_ID) {
    throw new Error(
      'Auth misconfigured: set COGNITO_USER_POOL_ID (platform Cognito) or OIDC_ISSUER (external IdP). Refusing to start without a token issuer to validate against.',
    );
  }
}

async function discoverJwksUri(issuer: string): Promise<string> {
  const res = await fetch(`${issuer}/.well-known/openid-configuration`);
  if (!res.ok) throw new Error(`OIDC discovery failed (${res.status})`);
  const doc = (await res.json()) as { jwks_uri?: unknown };
  if (typeof doc.jwks_uri !== 'string' || !doc.jwks_uri) throw new Error('OIDC discovery has no jwks_uri');
  return doc.jwks_uri;
}

async function buildVerifier(): Promise<Verify> {
  if (OIDC_ISSUER) {
    const v = JwtRsaVerifier.create({
      issuer: OIDC_ISSUER,
      audience: OIDC_AUDIENCE || null,
      jwksUri: OIDC_JWKS_URI || (await discoverJwksUri(OIDC_ISSUER)),
    });
    return (t) => v.verify(t);
  }
  const v = CognitoJwtVerifier.create({ userPoolId: COGNITO_USER_POOL_ID, tokenUse: null, clientId: null });
  return (t) => v.verify(t);
}

// Built on first use. A failed build (e.g. discovery unreachable) is not
// cached, so the next request retries.
let verifierPromise: Promise<Verify> | null = null;
function getVerifier(): Promise<Verify> {
  if (!verifierPromise) {
    verifierPromise = buildVerifier().catch((err) => {
      verifierPromise = null;
      throw err;
    });
  }
  return verifierPromise;
}

export interface JwtResult {
  valid: boolean;
  error?: string;
  /** The `sub` claim (caller id) when valid — used only for logging. */
  sub?: string;
}

/** Verify the caller's bearer token: signature, expiry and issuer. */
export async function validateJwt(authHeader: string | undefined): Promise<JwtResult> {
  if (!authHeader) return { valid: false, error: 'Missing Authorization header' };
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : authHeader.trim();
  if (!token) return { valid: false, error: 'Empty token' };
  try {
    const payload = await (await getVerifier())(token);
    return { valid: true, sub: typeof payload.sub === 'string' ? payload.sub : undefined };
  } catch {
    return { valid: false, error: 'Invalid or expired token' };
  }
}

/** Pull the bearer token from an Express request's Authorization header. */
export function extractAuthHeader(headers: Record<string, unknown>): string | undefined {
  const h = headers['authorization'] ?? headers['Authorization'];
  return typeof h === 'string' ? h : undefined;
}
