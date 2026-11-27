import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

// Stub for Node-only AWS SDK credential providers that get pulled in
// by @aws-sdk/credential-providers but aren't used in browser.
const nodeStub = path.resolve(__dirname, 'src/stubs/node-provider-stub.ts')

export default defineConfig({
  plugins: [react()],
  // Dev-only: forward /examples-api/* to the local Examples backend (ADR-037).
  // The backend serves the same /examples-api/* prefix, so no rewrite is needed
  // (matches the production CloudFront path pattern). Ignored in the built
  // bundle. Override the target with VITE_API_PROXY if needed.
  server: {
    proxy: {
      '/examples-api': {
        target: process.env.VITE_API_PROXY || 'http://localhost:8080',
        changeOrigin: true,
      },
      // Dev-only: forward /ade-api/* to the local ADE invoke backend (ADR-040).
      // Same-prefix passthrough (no rewrite). Run the backend on 8081 locally
      // (PORT=8081) or override with VITE_ADE_API_PROXY.
      '/ade-api': {
        target: process.env.VITE_ADE_API_PROXY || 'http://localhost:8081',
        changeOrigin: true,
      },
    },
  },
  build: {
    outDir: 'dist',
    sourcemap: false,
  },
  resolve: {
    alias: {
      // Replace Node-only credential providers with browser-safe stubs.
      // The app only uses fromCognitoIdentityPool which is browser-compatible.
      '@aws-sdk/credential-provider-login': nodeStub,
      '@aws-sdk/credential-provider-process': nodeStub,
      '@aws-sdk/credential-provider-sso': nodeStub,
      '@aws-sdk/credential-provider-ini': nodeStub,
      '@aws-sdk/credential-provider-node': nodeStub,
    },
  },
})
