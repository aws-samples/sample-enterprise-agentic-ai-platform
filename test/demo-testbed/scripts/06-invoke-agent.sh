#!/usr/bin/env bash
# 06 — Headless agent smoke test: exercise every pipeline-deployed team-bu-1
# entrypoint through its REAL invoke path, and assert a successful response.
#
# DEMO note: agents run in-VPC (agent_network_mode default "VPC", same as
# enterprise). The invoke PATH is `invoke-agent-runtime` with the A2A envelope;
# the runtime's ENIs are attached to the platform VPC's private subnets. The
# Step-Functions apps + their invoke-bridge Lambda also run in the VPC.
#
# WHAT IT EXERCISES — one per architecture pattern (ADR-020):
#   1. Standalone (no application.yaml) — invoke the AgentCore runtime directly
#      via the A2A `message/send` JSON-RPC envelope.
#        * aws-architect-agent
#   2. Swarm / choreography (orchestration: a2a) — invoke the entry peer's
#      AgentCore runtime directly (same A2A envelope); the peer's LLM drives the
#      mesh from there.
#        * research-swarm (entry peer = researcher)
#   3. Step-Functions orchestration (orchestration: step-functions) — the state
#      machine IS the entrypoint (ADR-020: SFN is the driver; the orchestrator/
#      supervisor agent is a task inside it, NOT an invocable entry). We start
#      the execution with the `{"query": ...}` input the demo UIs use and poll
#      to a terminal state.
#        * data-pipeline-app, rrf-search-app
#
# HOW (verified against the live platform)
#   * AgentCore: A2A `message/send` envelope delivered via `fileb://` (the CLI
#     base64-encodes the file; a raw --payload string is rejected). Targets the
#     version-pinned NAMED endpoint "<name>_endpoint" (the DEFAULT qualifier is
#     not version-pinned and can 404 right after a redeploy).
#     PASS = HTTP 200 AND A2A result state "completed"/has `artifacts`, no error.
#   * Step Functions: `start-execution` with {"query": ...}, then poll
#     `describe-execution`. PASS = SUCCEEDED; FAIL = FAILED/TIMED_OUT/ABORTED;
#     still RUNNING after the poll budget => reported as a NOTE (these runs are
#     legitimately multi-minute), not a hard failure.
#   * Each AgentCore invoke uses a unique runtime-session-id (printed) so the
#     trace can be correlated in Langfuse. SFN executions surface an executionArn.
#
# Usage:
#   scripts/06-invoke-agent.sh            # exercise all patterns
#   scripts/06-invoke-agent.sh --yes      # (accepted for run-all symmetry; no prompt anyway)
#
# Env knobs:
#   SFN_POLL_ITERS (default 20)  SFN_POLL_SLEEP (default 15s)  => ~5 min budget/app
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo UNKNOWN)"
REPO="${DEMO_REPO:-team-bu-1}"

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
note() { printf '  \033[33mNOTE\033[0m %s\n' "$*"; }

echo "=== 06 — headless agent smoke test (standalone + swarm + step-functions) ==="
echo "    account: $ACCOUNT   region: $REGION   repo: $REPO   posture: in-VPC agents"

# BU/domain prefix used in deployed runtime names: team-bu-1 -> team_bu_1
DOMAIN_PREFIX="$(echo "$REPO" | tr '-' '_')"

# --- Directly-invokable AgentCore entrypoints. Format: "<runtime-name>|<prompt>".
TARGETS=(
  "${DOMAIN_PREFIX}_aws_architect_agent|In one sentence, what is an AWS VPC?"
  "${DOMAIN_PREFIX}_research_swarm_researcher|In one sentence, what is AWS Lambda?"
)

# Resolve a runtime name -> runtime id (empty if not deployed). We avoid JMESPath
# `| [0]` (text output can emit a stray "None" line alongside the real id) and
# instead pick the first non-empty, non-"None" line so a "runtime/None" ARN can
# never be built.
runtime_id() {
  aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
    --query "agentRuntimes[?agentRuntimeName=='$1'].agentRuntimeId" --output text 2>/dev/null \
    | tr '\t' '\n' | grep -viE '^(none)?$' | head -1
}

invoke_one() { # runtime-name  prompt   -> 0 pass / 1 fail
  local NAME="$1" PROMPT="$2"
  local RID; RID="$(runtime_id "$NAME")"
  if [ -z "$RID" ] || [ "$RID" = "None" ]; then
    bad "$NAME — not deployed (run scripts 04/05 to deploy the app-team agents)"
    return 1
  fi
  local ARN="arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:runtime/${RID}"
  # The platform pins a NAMED endpoint "<runtime-name>_endpoint" to the runtime's
  # current (immutable) version — the platform-sanctioned invoke target. The
  # CLI's default DEFAULT qualifier is not version-pinned and can 404 after a
  # redeploy, so we target the named endpoint explicitly.
  local QUALIFIER="${NAME}_endpoint"
  local MSG_ID="smoke-$(date +%s)-$RANDOM"
  local SID="demo-smoke-${NAME}-$(date +%s)-$RANDOM"
  local PJSON OUT; PJSON="$(mktemp)"; OUT="$(mktemp)"

  printf '{"jsonrpc":"2.0","method":"message/send","id":"%s","params":{"message":{"role":"user","parts":[{"kind":"text","text":"%s"}],"messageId":"%s"}}}' \
    "$MSG_ID" "$PROMPT" "$MSG_ID" > "$PJSON"

  echo ""
  echo "  --- $NAME ---"
  echo "      endpoint:   $QUALIFIER"
  echo "      session-id: $SID   (use this to find the trace in Langfuse)"

  aws bedrock-agentcore invoke-agent-runtime \
    --agent-runtime-arn "$ARN" \
    --qualifier "$QUALIFIER" \
    --runtime-session-id "$SID" \
    --payload "fileb://$PJSON" \
    --region "$REGION" \
    "$OUT" >"$OUT.meta" 2>&1
  local RC=$?

  local SC; SC="$(grep -oE '"statusCode": [0-9]+' "$OUT.meta" | grep -oE '[0-9]+' | head -1)"

  if [ $RC -ne 0 ]; then
    bad "$NAME — invoke failed: $(head -c 160 "$OUT.meta")"
    rm -f "$PJSON" "$OUT" "$OUT.meta"; return 1
  fi

  if grep -q '"state": *"completed"' "$OUT" || grep -q '"artifacts"' "$OUT"; then
    ok "$NAME — http=${SC:-?}, agent responded (state=completed)"
    python3 - "$OUT" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    arts = d.get("result", {}).get("artifacts", []) or []
    parts = arts[0].get("parts", []) if arts else []
    text = "".join(p.get("text", "") for p in parts if p.get("kind") == "text")
    if text:
        print("       reply:", (text[:200] + ("…" if len(text) > 200 else "")))
except Exception:
    pass
PY
    rm -f "$PJSON" "$OUT" "$OUT.meta"; return 0
  fi

  if grep -q '"error"' "$OUT"; then
    local CODE; CODE="$(grep -oE '"code": *-?[0-9]+' "$OUT" | grep -oE '\-?[0-9]+' | head -1)"
    bad "$NAME — http=${SC:-?}, JSON-RPC error code=${CODE:-?}: $(head -c 200 "$OUT")"
    rm -f "$PJSON" "$OUT" "$OUT.meta"; return 1
  fi

  bad "$NAME — http=${SC:-?}, unexpected response: $(head -c 200 "$OUT")"
  rm -f "$PJSON" "$OUT" "$OUT.meta"; return 1
}

SFN_POLL_ITERS="${SFN_POLL_ITERS:-20}"
SFN_POLL_SLEEP="${SFN_POLL_SLEEP:-15}"

start_sfn() { # state-machine-name  query   -> 0 pass / 1 fail / 2 still-running (soft)
  local SM="$1" QUERY="$2"
  local ARN; ARN="$(aws stepfunctions list-state-machines --region "$REGION" \
    --query "stateMachines[?name=='$SM'].stateMachineArn" --output text 2>/dev/null \
    | tr '\t' '\n' | grep -viE '^(none)?$' | head -1)"
  echo ""
  echo "  --- $SM ---"
  if [ -z "$ARN" ]; then
    bad "$SM — state machine not deployed (run scripts 04/05 to deploy the app)"
    return 1
  fi

  local INPUT QJSON
  QJSON="$(printf '%s' "$QUERY" | sed 's/"/\\"/g')"
  INPUT="{\"query\":\"${QJSON}\"}"
  local EXEC_NAME="demo-smoke-$(date +%s)-$RANDOM"

  local EXEC_ARN
  EXEC_ARN="$(aws stepfunctions start-execution --state-machine-arn "$ARN" \
    --name "$EXEC_NAME" --input "$INPUT" --region "$REGION" \
    --query 'executionArn' --output text 2>/dev/null)"
  if [ -z "$EXEC_ARN" ] || [ "$EXEC_ARN" = "None" ]; then
    bad "$SM — start-execution failed"
    return 1
  fi
  echo "      execution: ${EXEC_ARN##*:}"

  local i STATUS
  for i in $(seq 1 "$SFN_POLL_ITERS"); do
    STATUS="$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" \
      --region "$REGION" --query 'status' --output text 2>/dev/null || echo '?')"
    case "$STATUS" in
      SUCCEEDED)
        # SUCCEEDED only means the state machine finished. The invoke-bridge
        # returns an agent's JSON-RPC error as a normal payload, so a broken
        # agent still yields SUCCEEDED. Inspect the output for an error.
        local OUTPUT
        OUTPUT="$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" \
          --region "$REGION" --query 'output' --output text 2>/dev/null)"
        if printf '%s' "$OUTPUT" | grep -q -E '"error" *: *\{'; then
          bad "$SM — execution SUCCEEDED but an agent returned an error: $(printf '%s' "$OUTPUT" | grep -o -E '"error" *: *\{[^}]*\}' | head -1)"
          return 1
        fi
        ok "$SM — execution SUCCEEDED (no agent error in output)"
        return 0 ;;
      FAILED|TIMED_OUT|ABORTED)
        local CAUSE
        CAUSE="$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" \
          --region "$REGION" --query 'cause' --output text 2>/dev/null | head -c 200)"
        bad "$SM — execution $STATUS: ${CAUSE:-<no cause>}"
        return 1 ;;
    esac
    sleep "$SFN_POLL_SLEEP"
  done
  note "$SM — still RUNNING after $((SFN_POLL_ITERS*SFN_POLL_SLEEP))s (soft pass; multi-agent runs are long). Check: aws stepfunctions describe-execution --execution-arn $EXEC_ARN"
  return 2
}

FAILED=0
PASSED=0
SOFT=0

echo ""
echo "  [1/2] Directly-invokable AgentCore entrypoints (standalone + swarm)"
for entry in "${TARGETS[@]}"; do
  NAME="${entry%%|*}"
  PROMPT="${entry#*|}"
  if invoke_one "$NAME" "$PROMPT"; then PASSED=$((PASSED+1)); else FAILED=$((FAILED+1)); fi
done

# Format: "<state-machine-name>|<query>".
SFN_TARGETS=(
  "${DOMAIN_PREFIX}_data_pipeline_app_orchestration|Summarize the key benefits of serverless architecture."
  "${DOMAIN_PREFIX}_rrf_search_app_orchestration|Search for AWS Lambda best practices."
)

echo ""
echo "  [2/2] Step-Functions-orchestrated apps (state machine is the entrypoint)"
for entry in "${SFN_TARGETS[@]}"; do
  SM="${entry%%|*}"
  QUERY="${entry#*|}"
  start_sfn "$SM" "$QUERY"
  case $? in
    0) PASSED=$((PASSED+1)) ;;
    2) SOFT=$((SOFT+1)) ;;
    *) FAILED=$((FAILED+1)) ;;
  esac
done

echo ""
echo "=== summary: $PASSED passed, $FAILED failed, $SOFT still-running (soft) ==="
echo "    Traces flow to Langfuse (domain 'team-bu-1'); filter by the printed"
echo "    session-id / execution. Langfuse's ALB is internal even in demo, so its"
echo "    UI is reachable only from inside the VPC (jumphost/port-forward)."
[ "$FAILED" -eq 0 ] || exit 1
