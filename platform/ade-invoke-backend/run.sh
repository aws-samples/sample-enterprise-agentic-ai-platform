#!/usr/bin/env bash
# Run the ADE invoke backend locally for development (ADR-040).
# Uses your ambient AWS credentials (env vars or ~/.aws profile) to SigV4-sign
# AgentCore calls. Set the same env the Fargate task gets in production.
set -euo pipefail
cd "$(dirname "$0")"

export AWS_REGION="${AWS_REGION:-us-east-1}"
export PORT="${PORT:-8080}"
# Auth issuer: platform Cognito pool id, OR an external OIDC_ISSUER.
# export COGNITO_USER_POOL_ID="us-east-1_xxxxxxxxx"
# export OIDC_ISSUER="https://<your-idp>/"
# Requirement-11 allow-list source (single source of truth):
# export LIFECYCLE_TABLE="agent-school-lifecycle-team-bu-1-dev"
# Default ADE target when the client sends no runtimeArn:
# export ADE_RUNTIME_ARN="arn:aws:bedrock-agentcore:us-east-1:<acct>:runtime/team_bu_1_agent_deployment_engineer-xxxx"
# export ADE_ENDPOINT_QUALIFIER="DEFAULT"

echo "=== EAP ADE Invoke Backend (local) ==="
echo "Region: $AWS_REGION   Port: $PORT"
echo "Endpoint: POST /ade-api/invoke   Health: GET /healthz"
echo ""

npm install --silent
npm run start
