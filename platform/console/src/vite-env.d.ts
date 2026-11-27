/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_COGNITO_DOMAIN: string
  readonly VITE_COGNITO_REGION: string
  readonly VITE_COGNITO_CLIENT_ID: string
  readonly VITE_REDIRECT_URI: string
  readonly VITE_IDENTITY_POOL_ID: string
  readonly VITE_USER_POOL_ID: string
  readonly VITE_STATE_TABLE: string
  // Public origin (scheme + host) of the self-hosted Langfuse stack (its CloudFront/ALB
  // base URL). Used as the embedded Langfuse iframe `src` origin in the
  // ObservabilityWorkspace. An empty string disables the embed. (task 9.3 / 12.1)
  readonly VITE_LANGFUSE_EMBED_ORIGIN: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
