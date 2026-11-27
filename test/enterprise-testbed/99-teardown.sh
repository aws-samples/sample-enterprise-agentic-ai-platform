#!/usr/bin/env bash
# 99 — Tear down the enterprise test bed. MANUAL ONLY. Never called by run-all.sh.
#
# Destroys in dependency order: platform -> iam-roles -> enterprise VPC.
# After the platform destroy it force-purges any Secrets Manager secrets left
# "scheduled for deletion" (name still reserved), so the next fresh deploy
# doesn't fail with "a secret with this name is already scheduled for deletion".
# Requires an explicit confirmation (type 'destroy'); pass --yes to skip.
# The Terraform STATE BUCKET (bootstrap) is left in place by default — pass
# --with-bootstrap to also empty+delete it.
#
# Usage:
#   ./99-teardown.sh                 # prompts, keeps state bucket
#   ./99-teardown.sh --yes           # no prompt
#   ./99-teardown.sh --with-bootstrap
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLATFORM="$REPO/platform/eap-platform"
TFVARS="configs/enterprise.testbed.tfvars"

AUTO=""
WITH_BOOTSTRAP=""
for a in "$@"; do
  [ "$a" = "--yes" ] && AUTO="yes"
  [ "$a" = "--with-bootstrap" ] && WITH_BOOTSTRAP="yes"
done

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
echo "==================================================================="
echo " ENTERPRISE TEST BED — TEARDOWN (account: $ACCOUNT)"
echo " Destroys: platform -> iam-roles -> enterprise VPC"
[ -n "$WITH_BOOTSTRAP" ] && echo " PLUS: empties + deletes the Terraform state bucket."
echo "==================================================================="
if [ "$AUTO" != "yes" ]; then
  read -r -p "This is destructive. [type 'destroy']: " ans
  [ "$ans" = "destroy" ] || { echo "aborted."; exit 1; }
fi

# Pre-destroy cleanup FIRST: delete pipeline-deployed agent runtimes (their VPC
# ENIs would otherwise block the VPC destroy) and empty the ECR repos (created
# without force_delete, so a non-empty repo blocks its own destroy). This runs
# unattended here (the outer confirmation already gates the whole teardown).
echo ""; echo ">>> pre-destroy cleanup (agents + ECR)"
PREDESTROY_ARGS=(--yes)
[ -n "$WITH_BOOTSTRAP" ] && PREDESTROY_ARGS+=(--with-bootstrap)
bash "$HERE/scripts/98-predestroy.sh" "${PREDESTROY_ARGS[@]}" || \
  echo "  (pre-destroy reported errors — review; terraform destroy may hit blocked resources)"

echo ""; echo ">>> destroy platform"
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
    echo "  (platform destroy reported errors — review; pipeline-created agent runtimes are NOT managed here)"
else
  echo "  no $TFVARS — skipping platform destroy (was it deployed?)"
fi

# ---------------------------------------------------------------------------
# Force-purge Secrets Manager secrets (POST platform-destroy).
# `terraform destroy` DELETES the Langfuse/platform secrets, but Secrets Manager
# only SCHEDULES deletion with a recovery window and keeps the NAME reserved, so
# a fresh apply fails: "a secret with this name is already scheduled for
# deletion." Force-purge them (no recovery window) so the next deploy can
# recreate them. --include-planned-deletion is required to list them.
# ---------------------------------------------------------------------------
echo ""; echo ">>> force-purge scheduled-for-deletion secrets (eap*)"
SEC_REGION="${AWS_REGION:-us-east-1}"
PURGE_N=0
for arn in $(aws secretsmanager list-secrets --region "$SEC_REGION" \
  --include-planned-deletion \
  --query "SecretList[?starts_with(Name,'eap')].ARN" --output text 2>/dev/null); do
  aws secretsmanager delete-secret --secret-id "$arn" \
    --force-delete-without-recovery --region "$SEC_REGION" >/dev/null 2>&1 \
    && { echo "  purged ${arn##*:}"; PURGE_N=$((PURGE_N+1)); } \
    || echo "  (failed to purge ${arn##*:})"
done
[ "$PURGE_N" -eq 0 ] && echo "  (no eap secrets pending deletion)"

echo ""; echo ">>> destroy iam-roles"
cd "$HERE/iam-roles" && terraform destroy -input=false -auto-approve || echo "  (iam-roles destroy reported errors — review)"

echo ""; echo ">>> destroy SSM jumphost (if created)"
if [ -f "$HERE/jumphost/terraform.tfstate" ]; then
  VPC_ID=$(cd "$HERE/enterprise-vpc" && terraform output -raw vpc_id 2>/dev/null || echo "")
  JUMP_SUBNET=$(cd "$HERE/enterprise-vpc" && terraform output -json private_subnet_ids 2>/dev/null | sed -E 's/^\["([^"]+)".*/\1/' || echo "")
  cd "$HERE/jumphost" && terraform destroy -input=false -auto-approve \
    -var "vpc_id=$VPC_ID" -var "subnet_id=$JUMP_SUBNET" || echo "  (jumphost destroy reported errors — review)"
else
  echo "  (no jumphost state — skipping)"
fi

echo ""; echo ">>> destroy enterprise VPC"
cd "$HERE/enterprise-vpc" && terraform destroy -input=false -auto-approve || echo "  (vpc destroy reported errors — check for lingering ENIs from the platform)"

if [ -n "$WITH_BOOTSTRAP" ]; then
  echo ""; echo ">>> delete state bucket + lock table (AFTER the platform destroy)"
  BUCKET="eap-platform-state-${ACCOUNT}"
  # Purge THEN delete — done here (post-destroy), never in 98, so the state the
  # platform destroy above relied on is only removed once it has run. The bucket
  # is versioned, so delete all object versions + delete-markers first.
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
echo "Teardown complete. Remove the generated $PLATFORM/$TFVARS if you want a clean tree."
