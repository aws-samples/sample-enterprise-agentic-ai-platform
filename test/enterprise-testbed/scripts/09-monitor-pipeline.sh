#!/usr/bin/env bash
# 09 — Monitor a deploy pipeline triggered by the repo seed (script 08).
# Polls the latest execution's stage states until it reaches a terminal state.
#
# Usage:
#   scripts/09-monitor-pipeline.sh                      # team-bu-1-deploy-pipeline
#   scripts/09-monitor-pipeline.sh <pipeline-name>
#   scripts/09-monitor-pipeline.sh <pipeline-name> 40   # max poll iterations
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PIPELINE="${1:-team-bu-1-deploy-pipeline}"
MAX_ITERS="${2:-60}"     # 60 * 15s = ~15 min
SLEEP=15

echo "=== 09 — monitor pipeline '$PIPELINE' (region $REGION) ==="

aws codepipeline get-pipeline --name "$PIPELINE" --region "$REGION" >/dev/null 2>&1 \
  || { echo "Pipeline '$PIPELINE' not found."; exit 1; }

for i in $(seq 1 "$MAX_ITERS"); do
  # Overall latest-execution status per stage.
  STATE=$(aws codepipeline get-pipeline-state --name "$PIPELINE" --region "$REGION" \
    --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output text 2>/dev/null || true)

  echo "--- poll $i/$MAX_ITERS ---"
  echo "$STATE" | awk '{printf "  %-12s %s\n", $1, $2}'

  # Terminal detection: any stage Failed => fail; all stages Succeeded => done.
  if echo "$STATE" | awk '{print $2}' | grep -q 'Failed'; then
    echo ""
    echo "PIPELINE FAILED. Inspect the failed stage/action:"
    echo "  aws codepipeline list-action-executions --pipeline-name $PIPELINE --region $REGION \\"
    echo "    --query 'actionExecutionDetails[?status==\`Failed\`].[stageName,actionName,output.executionResult.externalExecutionSummary]' --output text"
    exit 1
  fi
  # All stages present and all Succeeded (and none InProgress) => success.
  if [ -n "$STATE" ] && ! echo "$STATE" | awk '{print $2}' | grep -qE 'InProgress|Started|^$'; then
    if echo "$STATE" | awk '{print $2}' | grep -q 'Succeeded' && ! echo "$STATE" | awk '{print $2}' | grep -qvE 'Succeeded'; then
      echo ""
      echo "PIPELINE SUCCEEDED — agent(s) deployed. Verify runtimes:"
      echo "  aws bedrock-agentcore-control list-agent-runtimes --region $REGION --query 'agentRuntimes[].[agentRuntimeName,status]' --output text"
      exit 0
    fi
  fi

  sleep "$SLEEP"
done

echo ""
echo "Still running after $((MAX_ITERS*SLEEP))s — re-run to keep watching, or check the console."
