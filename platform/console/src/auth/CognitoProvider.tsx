import React, { createContext, useContext, useEffect, useState, useCallback } from 'react'

// --- Auth configuration (set via environment variables at build time) ---
const COGNITO_DOMAIN = import.meta.env.VITE_COGNITO_DOMAIN || ''
const COGNITO_REGION = import.meta.env.VITE_COGNITO_REGION || 'us-east-1'
const CLIENT_ID = import.meta.env.VITE_COGNITO_CLIENT_ID || ''
const REDIRECT_URI = import.meta.env.VITE_REDIRECT_URI || `${window.location.origin}/auth/callback`
const IDENTITY_POOL_ID = import.meta.env.VITE_IDENTITY_POOL_ID || ''
const USER_POOL_ID = import.meta.env.VITE_USER_POOL_ID || ''

// Dev bypass: skip auth when Cognito isn't configured (local dev without AWS)
const DEV_BYPASS = !COGNITO_DOMAIN || !CLIENT_ID

export interface AuthState {
  token: string | null
  userId: string
  username: string
  groups: string[]
  scopes: string[]
  isAuthenticated: boolean
}

interface AuthContextValue extends AuthState {
  login: () => void
  logout: () => void
  getCredentials: () => Promise<unknown>
}

const AuthContext = createContext<AuthContextValue>({
  token: null,
  userId: '',
  username: '',
  groups: [],
  scopes: [],
  isAuthenticated: false,
  login: () => {},
  logout: () => {},
  getCredentials: async () => ({}),
})

export function useAuth(): AuthContextValue {
  return useContext(AuthContext)
}

// --- JWT helpers ---
export function decodeJwtPayload(token: string): Record<string, unknown> | null {
  try {
    const parts = token.split('.')
    if (parts.length !== 3) return null
    const payload = parts[1].replace(/-/g, '+').replace(/_/g, '/')
    return JSON.parse(atob(payload))
  } catch {
    return null
  }
}

export function extractClaims(token: string): { sub: string; groups: string[]; scopes: string[]; username: string } {
  const payload = decodeJwtPayload(token)
  if (!payload) return { sub: '', groups: [], scopes: [], username: '' }
  const sub = (payload.sub as string) || ''
  const groups = (payload['cognito:groups'] as string[]) || []
  const scopeStr = (payload.scope as string) || ''
  const scopes = scopeStr ? scopeStr.split(' ') : []
  const username = (payload['cognito:username'] as string) || (payload.preferred_username as string) || (payload.email as string) || ''
  return { sub, groups, scopes, username }
}

export function isTokenExpired(token: string): boolean {
  const payload = decodeJwtPayload(token)
  if (!payload || typeof payload.exp !== 'number') return true
  return payload.exp <= Math.floor(Date.now() / 1000)
}

function parseTokenFromHash(): string | null {
  const hash = window.location.hash.substring(1)
  const params = new URLSearchParams(hash)
  // Identity Pool requires the id_token (has 'aud' claim), not access_token
  return params.get('id_token') || params.get('access_token')
}

function getLoginUrl(): string {
  return `https://${COGNITO_DOMAIN}.auth.${COGNITO_REGION}.amazoncognito.com/oauth2/authorize?response_type=token&client_id=${CLIENT_ID}&redirect_uri=${encodeURIComponent(REDIRECT_URI)}&scope=${encodeURIComponent('openid profile')}`
}

export function CognitoProvider({ children }: { children: React.ReactNode }) {
  // Dev bypass: if Cognito isn't configured, pretend we're authenticated
  if (DEV_BYPASS) {
    const devState: AuthContextValue = {
      token: 'dev-bypass-token',
      userId: 'dev-user',
      username: 'platform-admin',
      groups: ['bu:team-bu-1'],
      scopes: ['openid', 'profile'],
      isAuthenticated: true,
      login: () => console.warn('[Dev] Cognito not configured. Set VITE_COGNITO_DOMAIN and VITE_COGNITO_CLIENT_ID in .env'),
      logout: () => window.location.reload(),
      getCredentials: async () => ({ region: COGNITO_REGION, devBypass: true }),
    }
    return <AuthContext.Provider value={devState}>{children}</AuthContext.Provider>
  }

  const [token, setToken] = useState<string | null>(() => localStorage.getItem('console_token'))
  const [authState, setAuthState] = useState<AuthState>({
    token: null,
    userId: '',
    username: '',
    groups: [],
    scopes: [],
    isAuthenticated: false,
  })

  // Parse token claims when token changes
  useEffect(() => {
    if (token && !isTokenExpired(token)) {
      const { sub, groups, scopes, username } = extractClaims(token)
      setAuthState({ token, userId: sub, username, groups, scopes, isAuthenticated: true })
    } else if (token && isTokenExpired(token)) {
      // Token expired — clear and redirect
      localStorage.removeItem('console_token')
      setToken(null)
      setAuthState({ token: null, userId: '', username: '', groups: [], scopes: [], isAuthenticated: false })
    } else {
      setAuthState({ token: null, userId: '', username: '', groups: [], scopes: [], isAuthenticated: false })
    }
  }, [token])

  // Handle OAuth callback on mount
  useEffect(() => {
    if (window.location.pathname === '/auth/callback') {
      const t = parseTokenFromHash()
      if (t) {
        localStorage.setItem('console_token', t)
        setToken(t)
        window.history.replaceState({}, '', '/')
      }
    }
  }, [])

  const login = useCallback(() => {
    window.location.href = getLoginUrl()
  }, [])

  const logout = useCallback(() => {
    localStorage.removeItem('console_token')
    setToken(null)
    setAuthState({ token: null, userId: '', username: '', groups: [], scopes: [], isAuthenticated: false })
  }, [])

  // Credential exchange stub — in production uses fromCognitoIdentityPool
  const getCredentials = useCallback(async () => {
    // Stub: returns config for fromCognitoIdentityPool
    // In production, this would use:
    // fromCognitoIdentityPool({
    //   clientConfig: { region: COGNITO_REGION },
    //   identityPoolId: IDENTITY_POOL_ID,
    //   logins: { [`cognito-idp.${COGNITO_REGION}.amazonaws.com/${USER_POOL_ID}`]: token }
    // })
    return {
      identityPoolId: IDENTITY_POOL_ID,
      userPoolId: USER_POOL_ID,
      region: COGNITO_REGION,
      token,
    }
  }, [token])

  return (
    <AuthContext.Provider value={{ ...authState, login, logout, getCredentials }}>
      {children}
    </AuthContext.Provider>
  )
}

export { AuthContext, COGNITO_REGION, IDENTITY_POOL_ID, USER_POOL_ID }
