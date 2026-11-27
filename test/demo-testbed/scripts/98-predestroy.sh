#!/usr/bin/env bash
# 98 — Pre-destroy cleanup. Removes the resources that `terraform destroy` in
# 99-teardown.sh CANNOT remove on its own, and MUST run BEFORE it.
#
# WHY THIS EXISTS
#   1. Pipeline-deployed agent runtimes. Script 04 pushes agent code, and the
#      deploy pipeline's OWN `terraform apply` (a SEPARATE state) creates the
#      per-app AgentCore runtimes + their endpoints. The platform stack does not
#      manage them, so the platform `terraform destroy` never deletes them. They
#      must be deleted here, FIRST, endpoint-first (a runtime with a live
#      endpoint returns ConflictException on delete). The agents are VPC-attached
#      (demo now uses the VPC default), so they must be removed endpoint-first
#      BEFORE the platform VPC destroy — and they bill if left, so clean them up.
#   2. Non-empty ECR repos. The platform ECR repos are created WITHOUT
#      force_delete (deliberate). Once the pipeline has pushed images,
#      `terraform destroy` fails with RepositoryNotEmptyException. We empty the
#      repos here (never delete the repos — Terraform owns those).
#   (The Terraform state bucket is NOT touched here — 99-teardown.sh purges +
#   deletes it under --with-bootstrap AFTER the platform destroy, so state is
#   never removed before the resources it manages are gone.)
#
# The platform-owned ADE runtime (team_bu_1_agent_deployment_engineer) is LEFT
# for the platform `terraform destroy` to remove (it is in platform state).
#
# Usage:
#   scripts/98-predestroy.sh                    # delete pipeline agents + empty ECR
#   scripts/98-predestroy.sh --yes
#   scripts/98-predestroy.sh --with-bootstrap
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
DOMAIN_PREFIX="team_bu_1"
SPARE="team_bu_1_agent_deployment_engineer"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLATFORM="$REPO/platform/eap-platform"

AUTO=""
WITH_BOOTSTRAP=""
for a in "$@"; do
  [ "$a" = "--yes" ] && AUTO="yes"
  [ "$a" = "--with-bootstrap" ] && WITH_BOOTSTRAP="yes"
done

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo UNKNOWN)"

echo "==================================================================="
echo " DEMO TEST BED — PRE-DESTROY cleanup (account: $ACCOUNT, region: $REGION)"
echo "   * delete pipeline-deployed team-bu-1 agent runtimes (spare ADE)"
echo "   * empty the platform ECR repos (repos themselves left for terraform)"
echo " Run 99-teardown.sh AFTER this."
echo "==================================================================="
if [ "$AUTO" != "yes" ]; then
  read -r -p "Proceed with pre-destroy cleanup? [type 'yes']: " ans
  [ "$ans" = "yes" ] || { echo "aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# 1. Delete pipeline-deployed agent runtimes (endpoint-first), sparing ADE.
# ---------------------------------------------------------------------------
echo ""
echo ">>> [1/3] deleting pipeline-deployed team-bu-1 agent runtimes (endpoint-first)"

LIST="$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --query "agentRuntimes[?starts_with(agentRuntimeName,'${DOMAIN_PREFIX}_')].[agentRuntimeName,agentRuntimeId]" \
  --output text 2>/dev/null | sort || true)"

if [ -z "$LIST" ]; then
  echo "  (no team-bu-1 runtimes found — nothing to delete)"
else
  while IFS=$'\t' read -r NAME RID; do
    [ -z "$NAME" ] && continue
    [ "$NAME" = "$SPARE" ] && { echo "  SKIP $NAME (platform ADE — left for platform destroy)"; continue; }
    OUT="$(aws bedrock-agentcore-control delete-agent-runtime-endpoint \
      --agent-runtime-id "$RID" --endpoint-name "${NAME}_endpoint" --region "$REGION" 2>&1 || true)"
    if echo "$OUT" | grep -q '"status"'; then echo "  endpoint delete requested: $NAME"
    elif echo "$OUT" | grep -qi 'ResourceNotFound'; then echo "  endpoint already gone: $NAME"
    else echo "  endpoint note ($NAME): $(echo "$OUT" | tr '\n' ' ' | head -c 100)"; fi
  done <<< "$LIST"

  echo "  waiting for endpoints to finish deleting..."
  DEADLINE=$(( $(date +%s) + 300 ))
  while IFS=$'\t' read -r NAME RID; do
    [ -z "$NAME" ] && continue
    [ "$NAME" = "$SPARE" ] && continue
    while :; do
      OUT="$(aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id "$RID" --region "$REGION" 2>&1 || true)"
      if echo "$OUT" | grep -q '"status"'; then echo "  runtime delete requested: $NAME"; break
      elif echo "$OUT" | grep -qi 'ResourceNotFound'; then echo "  runtime already gone: $NAME"; break
      elif echo "$OUT" | grep -qi 'Conflict'; then
        [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "  TIMEOUT waiting on endpoint for $NAME — re-run 98"; break; }
        sleep 15
      else echo "  runtime note ($NAME): $(echo "$OUT" | tr '\n' ' ' | head -c 100)"; break; fi
    done
  done <<< "$LIST"
fi

# ---------------------------------------------------------------------------
# 2. Empty the platform ECR repos (never delete the repos — Terraform owns them).
# ---------------------------------------------------------------------------
echo ""
echo ">>> [2/3] emptying platform ECR repos (deleting all images; repos kept)"

ECR_REPOS=()
if [ -d "$PLATFORM" ]; then
  for OUT_NAME in ecr_repository_url ecr_base_image_repository_url ecr_terraform_image_repository_url; do
    URL="$(cd "$PLATFORM" && terraform output -raw "$OUT_NAME" 2>/dev/null || true)"
    [ -n "$URL" ] && ECR_REPOS+=("${URL##*/}")
  done
fi
for DEF in eap-agents eap-agents-base-strands eap-terraform; do
  case " ${ECR_REPOS[*]:-} " in *" $DEF "*) : ;; *) ECR_REPOS+=("$DEF") ;; esac
done

for R in "${ECR_REPOS[@]}"; do
  aws ecr describe-repositories --repository-names "$R" --region "$REGION" >/dev/null 2>&1 || { echo "  (repo $R not present — skip)"; continue; }
  IDS="$(aws ecr list-images --repository-name "$R" --region "$REGION" --query 'imageIds[*]' --output json 2>/dev/null || echo '[]')"
  if [ "$IDS" = "[]" ] || [ -z "$IDS" ]; then echo "  $R already empty"; continue; fi
  aws ecr batch-delete-image --repository-name "$R" --region "$REGION" --image-ids "$IDS" >/dev/null 2>&1 \
    && echo "  emptied $R" || echo "  (failed to empty $R — check permissions)"
done

# ---------------------------------------------------------------------------
# NOTE — the Terraform state bucket is deliberately NOT touched here.
# It is purged + deleted by 99-teardown.sh (under --with-bootstrap) AFTER the
# platform `terraform destroy` completes. Purging the state bucket BEFORE the
# destroy would strand the ~hundreds of platform resources with no state to
# destroy them through (this ordering bug once caused a full state loss).
# ---------------------------------------------------------------------------

echo ""
echo "Pre-destroy cleanup complete. Now run:  ./99-teardown.sh"
