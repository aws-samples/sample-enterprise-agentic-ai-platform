#!/usr/bin/env bash
# run-all — automate the enterprise test bed: 01 -> 06 in order, stop on first failure.
#
# ONE up-front confirmation (this creates billable AWS resources), then runs
# unattended. Pass --yes to skip the confirmation. Does NOT run teardown (99);
# teardown is always manual.
#
# Usage:
#   ./run-all.sh          # prompts once, then runs 01..06
#   ./run-all.sh --yes    # no prompt, fully unattended
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/scripts"
AUTO="${1:-}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
REGION="${AWS_REGION:-us-east-1}"

echo "==================================================================="
echo " ENTERPRISE TEST BED — full run (01 -> 06)"
echo "   account: $ACCOUNT    region: $REGION"
echo " This CREATES BILLABLE AWS RESOURCES (VPC/NAT/endpoints, IAM, ECR,"
echo " AgentCore, Fargate/Langfuse). Teardown is separate: 99-teardown.sh."
echo "==================================================================="
if [ "$AUTO" != "--yes" ]; then
  read -r -p "Proceed? [type 'yes']: " ans
  [ "$ans" = "yes" ] || { echo "aborted."; exit 1; }
fi

run() { echo ""; echo ">>> $1"; bash "$S/$1" --yes; }

bash "$S/01-check-prereqs.sh"
run "02-create-vpc.sh"
run "03-create-iam.sh"
run "04-gen-tfvars.sh"
# Clean-account bootstrap: seed the base + ADE images so 05 can deploy
# Docker-free (idempotent — a no-op if the images already exist).
run "00-seed-images.sh"
run "05-deploy-platform.sh"
run "06-validate.sh"
run "07-jumphost.sh"

# End-to-end CI/CD path: seed the app-team repo -> triggers the deploy pipeline
# -> builds the agent image and deploys the AgentCore runtime. 08 pushes; 09
# polls the pipeline to a terminal state.
bash "$S/08-seed-repos.sh" team-bu-1
bash "$S/09-monitor-pipeline.sh" team-bu-1-deploy-pipeline

echo ""
echo "==================================================================="
echo " enterprise test bed run complete. Tear down with:  ./99-teardown.sh"
echo " Reach private Langfuse: see 07 output (SSM port-forward via jumphost)."
echo " NOTE: script 08 triggered a pipeline that deploys AGENT RUNTIMES which"
echo "       terraform destroy does NOT remove — see README teardown notes."
echo "==================================================================="
