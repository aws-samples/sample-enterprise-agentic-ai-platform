// Examples Backend — caller authentication (ADR-046)
// -----------------------------------------------------------------------------
// Every /examples-api/* route requires a valid bearer JWT from the platform's
// identity provider (ADR-028). Unlike the original structural check in the ADE invoke
// backend, this verifies the token SIGNATURE against the IdP's JWKS (via
// aws-jwt-verify), plus expiry, issuer and audience/client id — a forged token
// with the right `iss` is rejected.
//
// Issuer resolution mirrors ADR-028:
//   * Platform Cognito  — COGNITO_USER_POOL_ID (+ COGNITO_APP_CLIENT_ID).
//   * External OIDC IdP — OIDC_ISSUER (+ optional OIDC_AUDIENCE, OIDC_JWKS_URI).
// If neither is set the service refuses to start, so a misconfigured deploy
// crash-loops instead of running open.

import type { NextFunction, Request, Response } from 'express'
import { CognitoJwtVerifier, JwtRsaVerifier } from 'aws-jwt-verify'

const COGNITO_USER_POOL_ID = process.env.COGNITO_USER_POOL_ID || ''
const COGNITO_APP_CLIENT_ID = process.env.COGNITO_APP_CLIENT_ID || ''
const OIDC_ISSUER = process.env.OIDC_ISSUER || ''
const OIDC_AUDIENCE = process.env.OIDC_AUDIENCE || ''
const OIDC_JWKS_URI = process.env.OIDC_JWKS_URI || ''

type Verify = (token: string) => Promise<{ sub?: unknown }>

// Checked at import time: a missing issuer throws here and stops the container.
if (!OIDC_ISSUER && !COGNITO_USER_POOL_ID) {
  throw new Error(
    'Auth misconfigured: set COGNITO_USER_POOL_ID (platform Cognito) or OIDC_ISSUER (external IdP). Refusing to start without a token issuer.',
  )
}
if (!OIDC_ISSUER && !COGNITO_APP_CLIENT_ID) {
  throw new Error('Auth misconfigured: COGNITO_APP_CLIENT_ID is required with COGNITO_USER_POOL_ID.')
}

/** The issuer's JWKS URI from its standard OIDC discovery document. */
async function discoverJwksUri(issuer: string): Promise<string> {
  const res = await fetch(`${issuer}/.well-known/openid-configuration`)
  if (!res.ok) throw new Error(`OIDC discovery failed (${res.status})`)
  const doc = (await res.json()) as { jwks_uri?: unknown }
  if (typeof doc.jwks_uri !== 'string' || !doc.jwks_uri) throw new Error('OIDC discovery has no jwks_uri')
  return doc.jwks_uri
}

async function buildVerifier(): Promise<Verify> {
  if (OIDC_ISSUER) {
    const issuer = OIDC_ISSUER.replace(/\/$/, '')
    const v = JwtRsaVerifier.create({
      issuer,
      audience: OIDC_AUDIENCE || null,
      jwksUri: OIDC_JWKS_URI || (await discoverJwksUri(issuer)),
    })
    return (t) => v.verify(t)
  }
  // The console sends the Cognito id_token (implicit flow); accept id or
  // access tokens, but only ones minted for the console app client.
  const v = CognitoJwtVerifier.create({
    userPoolId: COGNITO_USER_POOL_ID,
    tokenUse: null,
    clientId: COGNITO_APP_CLIENT_ID,
  })
  return (t) => v.verify(t)
}

// Built on first use. A failed build (e.g. discovery unreachable) is not
// cached, so the next request retries.
let verifierPromise: Promise<Verify> | null = null
function getVerifier(): Promise<Verify> {
  if (!verifierPromise) {
    verifierPromise = buildVerifier().catch((err) => {
      verifierPromise = null
      throw err
    })
  }
  return verifierPromise
}

async function verify(token: string): Promise<{ sub?: unknown }> {
  return (await getVerifier())(token)
}

/** Express middleware: 401 unless the request carries a verified bearer JWT. */
export async function requireAuth(req: Request, res: Response, next: NextFunction): Promise<void> {
  const header = req.headers.authorization
  const token = typeof header === 'string' && header.startsWith('Bearer ') ? header.slice(7).trim() : ''
  if (!token) {
    res.status(401).json({ error: 'Missing bearer token' })
    return
  }
  try {
    await verify(token)
    next()
  } catch {
    res.status(401).json({ error: 'Invalid or expired token' })
  }
}
