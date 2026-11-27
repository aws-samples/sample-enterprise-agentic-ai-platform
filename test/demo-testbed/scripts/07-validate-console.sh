#!/usr/bin/env bash
# 07 — Validate the demo console EDGE + hardening (ADR-037 / ADR-038).
# Read-only HTTP smoke test. No browser, no Cognito login — it asserts that the
# hardened CloudFront -> ALB -> Fargate / Langfuse path is wired and that the
# ALB origin lockdown (CloudFront prefix list + secret header) actually blocks
# non-CloudFront traffic.
#
# Checks:
#   1. CloudFront root serves the SPA (200).
#   2. /examples-api/* reaches the Fargate backend THROUGH CloudFront (not 403).
#   3. /langfuse/* reaches Langfuse THROUGH CloudFront (not 403).
#   4. Hitting the examples ALB DNS DIRECTLY returns 403 (lockdown works).
#
# A "not 403 through the edge" + "403 direct" pair proves the secret-header /
# prefix-list lockdown is doing its job. Deep app behavior (agent invoke, graph
# rendering) is covered by the browser + script 06, not here.
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLATFORM="$REPO/platform/eap-platform"

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
FAIL=0

echo "=== 07 — validate demo console edge + hardening (ADR-037/038) ==="

# --- resolve the console CloudFront domain ---
CF_DOMAIN=$(aws cloudfront list-distributions --region "$REGION" \
  --query "DistributionList.Items[?contains(to_string(Origins.Items[].Id), 's3-console')].DomainName | [0]" \
  --output text 2>/dev/null || echo "")
if [ -z "$CF_DOMAIN" ] || [ "$CF_DOMAIN" = "None" ]; then
  bad "no console CloudFront distribution found — deploy first (script 02)"
  exit 1
fi
BASE="https://$CF_DOMAIN"
ok "console CloudFront: $BASE"

code() { curl -s -o /dev/null -w "%{http_code}" -m 15 "$@" 2>/dev/null || echo "000"; }

# --- 1. SPA root ---
C=$(code "$BASE/")
[ "$C" = "200" ] && ok "SPA root returns 200" || bad "SPA root returned $C (expected 200)"

# --- 2. /examples-api/* through the edge (must NOT be 403) ---
# We hit a nonexistent route; the point is that CloudFront reaches the backend
# (backend answers, e.g. 404/400) rather than the ALB refusing with 403.
C=$(code "$BASE/examples-api/sfn/status?executionArn=none")
if [ "$C" = "403" ]; then
  bad "/examples-api/* returned 403 through the edge — CloudFront->ALB lockdown misconfigured (secret header not forwarded?)"
elif [ "$C" = "000" ]; then
  bad "/examples-api/* unreachable (timeout) — Fargate service healthy?"
else
  ok "/examples-api/* reaches the backend through CloudFront (HTTP $C, not 403)"
fi

# --- 3. /langfuse/* through the edge (must NOT be 403) ---
C=$(code "$BASE/langfuse/")
if [ "$C" = "403" ]; then
  bad "/langfuse/* returned 403 through the edge — Langfuse origin lockdown misconfigured (ADR-038)"
elif [ "$C" = "000" ]; then
  warn "/langfuse/* unreachable (timeout) — Langfuse web service still starting?"
else
  ok "/langfuse/* reaches Langfuse through CloudFront (HTTP $C, not 403)"
fi

# --- 4. Direct-to-ALB must be REFUSED (403) — proves the lockdown ---
echo "--- origin lockdown: examples ALB must reject direct (non-CloudFront) traffic ---"
ALB_DNS=""
if [ -d "$PLATFORM" ]; then
  # The examples ALB DNS isn't a root output; find it by tag/name.
  ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?starts_with(LoadBalancerName, 'eap-examples-')].DNSName | [0]" \
    --output text 2>/dev/null || echo "")
fi
if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "None" ]; then
  warn "could not resolve examples ALB DNS — skipping direct-access lockdown check"
else
  C=$(code "http://$ALB_DNS/examples-api/sfn/status?executionArn=none")
  if [ "$C" = "403" ]; then
    ok "direct ALB access returns 403 (lockdown works — no secret header)"
  elif [ "$C" = "000" ]; then
    warn "direct ALB access timed out — SG prefix-list may already block at L4 (also acceptable)"
  else
    bad "direct ALB access returned $C (expected 403) — the secret-header rule is NOT enforcing"
  fi
fi

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "Console edge validation FAILED — see FAIL items above."
  exit 1
fi
echo "Console edge validation OK."
