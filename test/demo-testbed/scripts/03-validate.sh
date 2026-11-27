#!/usr/bin/env bash
# 03 — Validate the DEMO deployment posture. Read-only checks.
#
# DEMO vs enterprise now differ only on the console flag; both run agents in-VPC:
#   * deploy_console = true  -> the public console stack IS present
#     (module.console + the studio-read/ade backends).
#   * agent_network_mode defaults to "VPC" (not overridden) -> agents attach ENIs
#     to the platform-created VPC's private subnets, same as enterprise. The VPC
#     hosts both the agents and the observability leg (Langfuse + OTel collector).
#     (A public agent posture is deprecated — see ADR-031.)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLATFORM="$REPO/platform/eap-platform"

ok()  { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

echo "=== 03 — validate DEMO posture ==="
cd "$PLATFORM"

# Agents in-VPC (demo now uses the VPC default, same as enterprise).
POSTURE=$(terraform output -raw agent_network_posture 2>/dev/null || echo "?")
[ "$POSTURE" = "VPC" ] && ok "agent_network_posture = VPC (agents in the platform VPC)" \
                       || bad "agent_network_posture = $POSTURE (expected VPC)"

# Console stack present (deploy_console=true).
echo "--- console stack should be PRESENT ---"
if terraform state list 2>/dev/null | grep -qE '^module\.console'; then
  ok "module.console present (public CloudFront/S3 console)"
else
  bad "module.console absent — expected present (deploy_console=true)"
fi
if terraform state list 2>/dev/null | grep -qE '^module\.invoke_proxy'; then
  ok "module.invoke_proxy present (browser -> AgentCore invoke path)"
else
  bad "module.invoke_proxy absent — expected present with the console"
fi

# CloudFront distribution actually deployed + enabled.
echo "--- console CloudFront distribution ---"
CF_DOMAIN=$(aws cloudfront list-distributions --region "${AWS_REGION:-us-east-1}" \
  --query "DistributionList.Items[?contains(to_string(Origins.Items[].Id), 's3-console')].DomainName | [0]" \
  --output text 2>/dev/null || echo "")
if [ -n "$CF_DOMAIN" ] && [ "$CF_DOMAIN" != "None" ]; then
  ok "console CloudFront live: https://$CF_DOMAIN"
else
  bad "no console CloudFront distribution found"
fi

# Observability leg still present (Langfuse on in demo).
echo "--- observability leg (Langfuse on) ---"
if terraform state list 2>/dev/null | grep -qiE 'module\.langfuse'; then
  ok "module.langfuse present (self-hosted)"
else
  bad "module.langfuse absent — expected present (deploy_langfuse=true)"
fi

# Examples surface backend (ADR-037): ALB->Fargate signer + WAF, demo only.
echo "--- examples surface backend (ADR-037) ---"
if terraform state list 2>/dev/null | grep -qE '^module\.examples_console'; then
  ok "module.examples_console present (ECS Fargate signer + ALB + WAF)"
else
  bad "module.examples_console absent — expected present (deploy_console=true)"
fi
if terraform state list 2>/dev/null | grep -qE 'module\.examples_console\.aws_ecs_service'; then
  ok "examples backend ECS service present"
else
  bad "examples backend ECS service absent"
fi
if terraform state list 2>/dev/null | grep -qE 'module\.examples_console\.aws_wafv2_web_acl'; then
  ok "examples WAF WebACL present"
else
  bad "examples WAF WebACL absent"
fi

# CloudFront C2: the console distribution should now carry the examples + langfuse
# origins (ADR-037 / ADR-038), not just s3-console.
echo "--- console CloudFront C2 origins (examples-api + langfuse) ---"
if [ -n "${CF_DOMAIN:-}" ] && [ "$CF_DOMAIN" != "None" ]; then
  DIST_ID=$(aws cloudfront list-distributions --region "${AWS_REGION:-us-east-1}" \
    --query "DistributionList.Items[?DomainName=='$CF_DOMAIN'].Id | [0]" --output text 2>/dev/null || echo "")
  if [ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ]; then
    ORIGINS=$(aws cloudfront get-distribution-config --id "$DIST_ID" \
      --query "DistributionConfig.Origins.Items[].Id" --output text 2>/dev/null || echo "")
    echo "$ORIGINS" | grep -q "examples-api" && ok "CloudFront has 'examples-api' origin" || bad "CloudFront missing 'examples-api' origin"
    echo "$ORIGINS" | grep -q "langfuse"     && ok "CloudFront has 'langfuse' origin"     || bad "CloudFront missing 'langfuse' origin (ADR-038)"
  else
    bad "could not resolve CloudFront distribution id for origin check"
  fi
fi

echo ""
echo "Automated edge/lockdown smoke test: run scripts/07-validate-console.sh"
echo ""
echo "Manual checks:"
echo "  - Open the console CloudFront URL and sign in via Cognito."
echo "  - Agents run in-VPC: invoke works via the platform VPC (script 06)."
echo "  - Examples tab: cards show 'Not deployed' until team-bu-1 is seeded"
echo "    (script 04), then flip Deploying -> Ready as the pipeline completes."
echo "  - GenAI Observability: Langfuse is now embedded same-origin at"
echo "    https://<console>/langfuse/ (ADR-038) — reachable publicly via"
echo "    CloudFront, no VPN needed."
