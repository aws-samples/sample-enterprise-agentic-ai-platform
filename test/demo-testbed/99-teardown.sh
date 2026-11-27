#!/usr/bin/env bash
# 99 — Tear down the DEMO test bed. MANUAL ONLY. Never called by run-all.sh.
#
# DEMO is simpler to tear down than the enterprise bed: there are NO test-bed fixtures (no
# enterprise VPC, no externalized IAM roles, no jumphost) — the platform created
# its own VPC + all IAM roles + the public console, so a single platform
# `terraform destroy` removes them. The only pre-work is script 98 (delete the
# pipeline-deployed agent runtimes + empty the ECR repos), which plain
# `terraform destroy` cannot do.
#
# After the destroy it also force-purges any Secrets Manager secrets the destroy
# left "scheduled for deletion" (name still reserved), so the next fresh deploy
# doesn't fail with "a secret with this name is already scheduled for deletion".
#
# The Terraform STATE BUCKET (bootstrap) is left in place by default — pass
# --with-bootstrap to also empty (98) + delete it.
#
# Usage:
#   ./99-teardown.sh                 # prompts, keeps state bucket
#   ./99-teardown.sh --yes           # no prompt
#   ./99-teardown.sh --with-bootstrap
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLATFORM="$REPO/platform/eap-platform"
TFVARS="configs/demo.tfvars"

AUTO=""
WITH_BOOTSTRAP=""
for a in "$@"; do
  [ "$a" = "--yes" ] && AUTO="yes"
  [ "$a" = "--with-bootstrap" ] && WITH_BOOTSTRAP="yes"
done

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
echo "==================================================================="
echo " DEMO TEST BED — TEARDOWN (account: $ACCOUNT)"
echo " Pre-destroy (98): delete pipeline agents + empty ECR, then:"
echo " Destroys: the platform (its own VPC + IAM roles + public console)"
[ -n "$WITH_BOOTSTRAP" ] && echo " PLUS: empties + deletes the Terraform state bucket."
echo "==================================================================="
if [ "$AUTO" != "yes" ]; then
  read -r -p "This is destructive. [type 'destroy']: " ans
  [ "$ans" = "destroy" ] || { echo "aborted."; exit 1; }
fi

# Pre-destroy cleanup FIRST: pipeline agents + non-empty ECR repos.
echo ""; echo ">>> pre-destroy cleanup (agents + ECR)"
PREDESTROY_ARGS=(--yes)
[ -n "$WITH_BOOTSTRAP" ] && PREDESTROY_ARGS+=(--with-bootstrap)
bash "$HERE/scripts/98-predestroy.sh" "${PREDESTROY_ARGS[@]}" || \
  echo "  (pre-destroy reported errors — review; terraform destroy may hit blocked resources)"

echo ""; echo ">>> destroy platform (DEMO)"
cd "$PLATFORM"
if [ -f "$TFVARS" ]; then
  # ALBs have deletion protection on by default. Turn it off on just the
  # aws_lb resources so the destroy below can remove them.
  LB_TARGETS=()
  while IFS= read -r r; do LB_TARGETS+=("-target=$r"); done < <(terraform state list 2>/dev/null | grep -E '\.aws_lb\.[a-z_]+(\[[0-9]+\])?$' || true)
  if [ "${#LB_TARGETS[@]}" -gt 0 ]; then
    terraform apply -input=false -auto-approve -var-file="$TFVARS" -var 'studio_build_image=false' \
      -var 'alb_deletion_protection=false' "${LB_TARGETS[@]}" || \
      echo "  (could not disable ALB deletion protection — destroy may fail on the ALBs)"
  fi
  terraform destroy -input=false -auto-approve -var-file="$TFVARS" -var 'studio_build_image=false' -var 'alb_deletion_protection=false' || \
    echo "  (platform destroy reported errors — review; pipeline-created agent runtimes are handled by 98, not here)"
else
  echo "  no $TFVARS — is the platform tree intact?"
fi

# ---------------------------------------------------------------------------
# Force-purge Secrets Manager secrets (POST-destroy).
# `terraform destroy` DELETES the Langfuse/platform secrets, but Secrets Manager
# only SCHEDULES deletion with a recovery window (7-30 days) and keeps the NAME
# reserved. A fresh apply then fails: "a secret with this name is already
# scheduled for deletion." Force-purge them here (no recovery window) so the
# next deploy can recreate them. Runs AFTER destroy so we only purge what the
# destroy just scheduled. --include-planned-deletion is required to list them.
# ---------------------------------------------------------------------------
echo ""; echo ">>> force-purge scheduled-for-deletion secrets (eap*)"
REGION="${AWS_REGION:-us-east-1}"
PURGE_N=0
for arn in $(aws secretsmanager list-secrets --region "$REGION" \
  --include-planned-deletion \
  --query "SecretList[?starts_with(Name,'eap')].ARN" --output text 2>/dev/null); do
  aws secretsmanager delete-secret --secret-id "$arn" \
    --force-delete-without-recovery --region "$REGION" >/dev/null 2>&1 \
    && { echo "  purged ${arn##*:}"; PURGE_N=$((PURGE_N+1)); } \
    || echo "  (failed to purge ${arn##*:})"
done
[ "$PURGE_N" -eq 0 ] && echo "  (no eap secrets pending deletion)"

if [ -n "$WITH_BOOTSTRAP" ]; then
  echo ""; echo ">>> delete state bucket + lock table (AFTER the platform destroy)"
  BUCKET="eap-platform-state-${ACCOUNT}"
  # Purge THEN delete — done here (post-destroy), never in 98, so the state that
  # the platform destroy above depended on is only removed once it has run. The
  # bucket is versioned, so delete all object versions + delete-markers first.
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    V="$(aws s3api list-object-versions --bucket "$BUCKET" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo '{}')"
    [ "$V" != '{}' ] && echo "$V" | grep -q '"Key"' && aws s3api delete-objects --bucket "$BUCKET" --delete "$V" >/dev/null 2>&1 || true
    M="$(aws s3api list-object-versions --bucket "$BUCKET" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo '{}')"
    [ "$M" != '{}' ] && echo "$M" | grep -q '"Key"' && aws s3api delete-objects --bucket "$BUCKET" --delete "$M" >/dev/null 2>&1 || true
    aws s3api delete-bucket --bucket "$BUCKET" 2>/dev/null && echo "  deleted $BUCKET" || echo "  (could not delete $BUCKET — check for remaining versions)"
  else
    echo "  ($BUCKET not found — skip)"
  fi
  aws dynamodb delete-table --table-name eap-platform-locks --region "${AWS_REGION:-us-east-1}" 2>/dev/null && echo "  deleted lock table" || true
fi

echo ""
echo "Teardown complete."
