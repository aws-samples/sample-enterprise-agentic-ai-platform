#!/usr/bin/env bash
# 98 — Pre-destroy cleanup. Removes the resources that `terraform destroy` in
# 99-teardown.sh CANNOT remove on its own, and MUST run BEFORE it.
#
# WHY THIS EXISTS
#   1. Pipeline-deployed agent runtimes. Script 08 pushes agent code, and the
#      deploy pipeline's OWN `terraform apply` (a SEPARATE state) creates the
#      per-app AgentCore runtimes + their endpoints. The platform stack does not
#      manage them, so the platform `terraform destroy` never deletes them. In
#      VPC mode those runtimes attach `agentic_ai` ENIs into the enterprise VPC's
#      private subnets — lingering ENIs then block the VPC/subnet/SG destroy with
#      DependencyViolation. So they must be deleted here, FIRST, endpoint-first
#      (a runtime with a live endpoint returns ConflictException on delete).
#   2. Non-empty ECR repos. The platform ECR repos are created WITHOUT
#      force_delete (deliberate — a repo you can `terraform apply` should not be
#      silently nuke-able on an accidental destroy). Once the pipeline has pushed
#      images, `terraform destroy` fails on them with RepositoryNotEmptyException.
#      We empty the repos here so the subsequent destroy of the (now-empty) repo
#      succeeds. We NEVER delete the repos themselves — Terraform owns those.
#   (The Terraform state bucket is NOT touched here — 99-teardown.sh purges +
#   deletes it under --with-bootstrap AFTER the platform destroy, so state is
#   never removed before the resources it manages are gone.)
#
# SCOPE: this only removes the OUT-OF-BAND / destroy-blocking resources. It does
# NOT run terraform destroy — 99-teardown.sh does that, and it must be called
# AFTER this. The platform-owned ADE runtime (team_bu_1_agent_deployment_engineer)
# is left for the platform `terraform destroy` to remove (it is in platform
# state), so it is NOT deleted here.
#
# Usage:
#   scripts/98-predestroy.sh                 # delete pipeline agents + empty ECR repos
#   scripts/98-predestroy.sh --yes           # no prompt
#   scripts/98-predestroy.sh --with-bootstrap  # (flag accepted for symmetry; state bucket is handled by 99 post-destroy)
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
DOMAIN_PREFIX="team_bu_1"          # pipeline-deployed app domain (team-bu-1)
SPARE="team_bu_1_agent_deployment_engineer"  # platform ADE — left for platform destroy

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
echo " ENTERPRISE TEST BED — PRE-DESTROY cleanup (account: $ACCOUNT, region: $REGION)"
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
  # Delete each named endpoint first (a runtime with a live endpoint conflicts).
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
  # Delete runtimes, retrying on ConflictException while endpoints drain.
  DEADLINE=$(( $(date +%s) + 300 ))
  while IFS=$'\t' read -r NAME RID; do
    [ -z "$NAME" ] && continue
    [ "$NAME" = "$SPARE" ] && continue
    while :; do
      OUT="$(aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id "$RID" --region "$REGION" 2>&1 || true)"
      if echo "$OUT" | grep -q '"status"'; then echo "  runtime delete requested: $NAME"; break
      elif echo "$OUT" | grep -qi 'ResourceNotFound'; then echo "  runtime already gone: $NAME"; break
      elif echo "$OUT" | grep -qi 'Conflict'; then
        [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "  TIMEOUT waiting on endpoint for $NAME — re-run 98 if VPC destroy later fails"; break; }
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

# Resolve repo names from platform outputs when available; else the known defaults.
ECR_REPOS=()
if [ -d "$PLATFORM" ]; then
  for OUT_NAME in ecr_repository_url ecr_base_image_repository_url ecr_terraform_image_repository_url; do
    URL="$(cd "$PLATFORM" && terraform output -raw "$OUT_NAME" 2>/dev/null || true)"
    [ -n "$URL" ] && ECR_REPOS+=("${URL##*/}")
  done
fi
# Fallback / ensure the three known repos are covered even without TF outputs.
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
# 3. (optional) Purge the versioned Terraform state bucket object versions.
# ---------------------------------------------------------------------------
# NOTE — the Terraform state bucket is deliberately NOT touched here.
# It is purged + deleted by 99-teardown.sh (under --with-bootstrap) AFTER the
# platform `terraform destroy` completes. Purging the state bucket BEFORE the
# destroy would strand the ~hundreds of platform resources with no state to
# destroy them through (this ordering bug once caused a full state loss).
# ---------------------------------------------------------------------------

echo ""
echo "Pre-destroy cleanup complete. Now run:  ./99-teardown.sh"
