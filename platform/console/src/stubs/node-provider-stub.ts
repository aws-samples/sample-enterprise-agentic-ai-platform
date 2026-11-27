/**
 * Browser stub for Node-only AWS SDK credential providers.
 *
 * The @aws-sdk/credential-providers barrel export pulls in Node-only
 * providers (SSO, process, login, ini) that use node:fs, node:child_process, etc.
 * Since we only use fromCognitoIdentityPool in the browser, we stub these out
 * to allow Vite/Rollup to bundle successfully.
 *
 * This file is mapped via resolve.alias in vite.config.ts.
 */

// Default export to satisfy any default import patterns
export default {}

// Named exports that various modules expect
export function fromLoginCredentials() {
  throw new Error('Not available in browser')
}

export function fromProcess() {
  throw new Error('Not available in browser')
}

export function fromSSO() {
  throw new Error('Not available in browser')
}

export function fromIni() {
  throw new Error('Not available in browser')
}

export function fromNodeProviderChain() {
  throw new Error('Not available in browser')
}

export const isLoginProfile = () => false
export const isSsoProfile = () => false
export const resolveProcessCredentials = () => Promise.reject(new Error('Not available in browser'))
export const resolveSSOCredentials = () => Promise.reject(new Error('Not available in browser'))
