#!/usr/bin/env bash
# Run the Examples backend locally for development (ADR-037).
# Uses your ambient AWS credentials (env vars or ~/.aws profile) to SigV4-sign
# AgentCore calls and drive Step Functions. Pair with the console's Vite dev
# proxy (npm run dev in platform/console) which forwards /api/* here.
set -euo pipefail
cd "$(dirname "$0")"

export AWS_REGION="${AWS_REGION:-us-east-1}"
export PORT="${PORT:-8080}"

# ADR-046: every /examples-api route verifies the caller JWT and checks the
# target against the lifecycle table, so local runs need the same settings as
# the deployed task. Values come from the platform's terraform outputs.
: "${LIFECYCLE_TABLE:?set LIFECYCLE_TABLE to the lifecycle DynamoDB table name}"
if [[ -z "${OIDC_ISSUER:-}" && ( -z "${COGNITO_USER_POOL_ID:-}" || -z "${COGNITO_APP_CLIENT_ID:-}" ) ]]; then
  echo "Set COGNITO_USER_POOL_ID + COGNITO_APP_CLIENT_ID (platform Cognito) or OIDC_ISSUER (external IdP)." >&2
  exit 1
fi

echo "=== EAP Examples Backend (local) ==="
echo "Region: $AWS_REGION   Port: $PORT"
echo "Endpoints: /examples-api/{invoke,sfn/start,sfn/status,sfn/history,logs} (JWT required)"
echo ""

npm install --silent
npm run start
