#!/usr/bin/env bash
# run-all — automate the DEMO test bed: 01 -> 06 in order, stop on first failure.
#
# ONE up-front confirmation (this creates billable AWS resources), then runs
# unattended. Pass --yes to skip the confirmation. Does NOT run teardown (99);
# teardown is always manual.
#
# Sequence:
#   01 check prereqs -> 00 seed images (clean-account bootstrap) ->
#   02 deploy platform (DEMO) -> 03 validate ->
#   04 seed repo (triggers deploy pipeline) -> 05 monitor pipeline ->
#   06 headless agent smoke test (all patterns) ->
#   07 console edge + hardening smoke test (ADR-037/038)
#
# Usage:
#   ./run-all.sh          # prompts once, then runs 01..07
#   ./run-all.sh --yes    # no prompt, fully unattended
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/scripts"
AUTO="${1:-}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
REGION="${AWS_REGION:-us-east-1}"

echo "==================================================================="
echo " DEMO TEST BED — full run (01 -> 07)"
echo "   account: $ACCOUNT    region: $REGION"
echo " DEMO posture: public console, agents IN-VPC, platform-created VPC"
echo " (hosts agents + observability), Cognito, self-hosted Langfuse."
echo " This CREATES BILLABLE AWS RESOURCES. Teardown is separate: 99-teardown.sh."
echo "==================================================================="
if [ "$AUTO" != "--yes" ]; then
  read -r -p "Proceed? [type 'yes']: " ans
  [ "$ans" = "yes" ] || { echo "aborted."; exit 1; }
fi

run() { echo ""; echo ">>> $1"; bash "$S/$1" --yes; }

bash "$S/01-check-prereqs.sh"
# Clean-account bootstrap: seed the base + ADE images so 02 can deploy
# Docker-free (idempotent — a no-op if the images already exist).
run "00-seed-images.sh"
run "02-deploy-platform.sh"
run "03-validate.sh"

# End-to-end CI/CD path: seed the app-team repo -> triggers the deploy pipeline
# -> builds each agent image and deploys the AgentCore runtimes + state machines.
bash "$S/04-seed-repos.sh" team-bu-1
bash "$S/05-monitor-pipeline.sh" team-bu-1-deploy-pipeline

# Headless smoke test of the deployed agents (all three patterns).
bash "$S/06-invoke-agent.sh" --yes

# Console edge + hardening smoke test (ADR-037/038): CloudFront reachability +
# ALB origin lockdown. Non-fatal to the overall run — a still-warming Langfuse
# can trip a transient check — so report but don't abort.
echo ""
echo ">>> 07-validate-console.sh"
bash "$S/07-validate-console.sh" || echo "  (07 reported issues — review above; not aborting the run)"

echo ""
echo "==================================================================="
echo " DEMO test bed run complete. Tear down with:  ./99-teardown.sh"
echo " Open the console CloudFront URL (script 02 printed it) and sign in."
echo " NOTE: the deploy pipeline created AGENT RUNTIMES that terraform destroy"
echo "       does NOT remove — 99 runs 98-predestroy.sh first to clean them up."
echo "==================================================================="
