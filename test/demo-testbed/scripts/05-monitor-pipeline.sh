#!/usr/bin/env bash
# 05 — Monitor the deploy pipeline triggered by the repo seed (script 04).
# Tracks the LATEST pipeline execution by id (so downstream stages' stale
# statuses from a previous run cannot cause a false FAILED), and polls each
# action to a terminal state.
#
# Usage:
#   scripts/05-monitor-pipeline.sh                      # team-bu-1-deploy-pipeline
#   scripts/05-monitor-pipeline.sh <pipeline-name>
#   scripts/05-monitor-pipeline.sh <pipeline-name> 60   # max poll iterations
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PIPELINE="${1:-team-bu-1-deploy-pipeline}"
MAX_ITERS="${2:-60}"     # 60 * 15s = ~15 min
SLEEP=15

echo "=== 05 — monitor pipeline '$PIPELINE' (region $REGION) ==="

aws codepipeline get-pipeline --name "$PIPELINE" --region "$REGION" >/dev/null 2>&1 \
  || { echo "Pipeline '$PIPELINE' not found."; exit 1; }

# Resolve the most recent execution id so we scope status to THIS run only.
sleep 3
EID="$(aws codepipeline list-pipeline-executions --pipeline-name "$PIPELINE" --region "$REGION" \
  --max-items 1 --query 'pipelineExecutionSummaries[0].pipelineExecutionId' --output text 2>/dev/null \
  | tr '\t' '\n' | grep -viE '^(none)?$' | head -1)"
[ -z "$EID" ] && { echo "No pipeline execution found yet — did script 04 push?"; exit 1; }
echo "  tracking execution: $EID"

for i in $(seq 1 "$MAX_ITERS"); do
  # Per-action status for THIS execution only.
  ROWS="$(aws codepipeline list-action-executions --pipeline-name "$PIPELINE" --region "$REGION" \
    --filter pipelineExecutionId="$EID" \
    --query 'actionExecutionDetails[].{stage:stageName,action:actionName,status:status}' \
    --output text 2>/dev/null | sort -u || true)"

  echo "--- poll $i/$MAX_ITERS ($(date +%H:%M:%S)) ---"
  echo "$ROWS" | awk 'NF{printf "  %-10s %-18s %s\n", $1, $2, $3}'

  # Any Failed action => fail.
  if echo "$ROWS" | awk '{print $NF}' | grep -q 'Failed'; then
    echo ""
    echo "PIPELINE FAILED. Inspect the failed action's CodeBuild log:"
    echo "  aws codepipeline list-action-executions --pipeline-name $PIPELINE --region $REGION \\"
    echo "    --filter pipelineExecutionId=$EID \\"
    echo "    --query 'actionExecutionDetails[?status==\`Failed\`].[stageName,actionName,output.executionResult.externalExecutionId]' --output text"
    exit 1
  fi

  # Overall execution status.
  ST="$(aws codepipeline list-pipeline-executions --pipeline-name "$PIPELINE" --region "$REGION" \
    --query "pipelineExecutionSummaries[?pipelineExecutionId=='$EID'].status | [0]" --output text 2>/dev/null || echo '?')"
  case "$ST" in
    Succeeded)
      echo ""
      echo "PIPELINE SUCCEEDED — agent(s) deployed. Verify runtimes:"
      echo "  aws bedrock-agentcore-control list-agent-runtimes --region $REGION --query 'agentRuntimes[].[agentRuntimeName,status]' --output text"
      exit 0 ;;
    Failed|Stopped|Superseded)
      echo ""; echo "PIPELINE $ST."; exit 1 ;;
  esac

  sleep "$SLEEP"
done

echo ""
echo "Still running after $((MAX_ITERS*SLEEP))s — re-run to keep watching, or check the console."
