"""Pipeline Status tool — check the state of a running or completed pipeline execution.

Used after ``pipeline_trigger`` returns ``status: timeout`` so the Studio agent
can poll back periodically without holding the original tool call open past
AgentCore's 60s per-tool budget.

Accepts either an explicit ``execution_id`` (preferred, returned by
``pipeline_trigger``) or looks up the latest execution of the configured
pipeline when ``execution_id`` is omitted. On ``Succeeded`` it also resolves
the deployed runtime ARN via AgentCore so the caller can add it to the UI.
"""

import logging
import os

import boto3
from strands import tool

logger = logging.getLogger("studio.pipeline_status")


def _resolve_runtime_arn(agent_name: str, domain: str, region: str) -> dict:
    """Resolve the deployed agent's runtime ARN(s) from AgentCore.

    Returns one or more runtimes whose name matches {domain}_{agent_name}
    (standalone) or {domain}_{agent_name}_*  (multi-agent app).

    Handles both hyphen and underscore suffixes in runtime names:
      - Standalone: `{domain}_{name}-{random}`
      - Multi-agent: `{domain}_{app}_{agent}-{random}`
    """
    ac_client = boto3.client("bedrock-agentcore-control", region_name=region)
    runtime_prefix = f"{domain}_{agent_name}".replace("-", "_")
    endpoint_qualifier = f"{runtime_prefix}_endpoint"

    matches: list[dict] = []
    try:
        paginator = ac_client.get_paginator("list_agent_runtimes")
        for page in paginator.paginate():
            for rt in page.get("agentRuntimes", []):
                rt_name = rt.get("agentRuntimeName", "")
                if (
                    rt_name == runtime_prefix
                    or rt_name.startswith(f"{runtime_prefix}-")
                    or rt_name.startswith(f"{runtime_prefix}_")
                ):
                    matches.append({
                        "runtime_arn": rt.get("agentRuntimeArn", ""),
                        "runtime_name": rt_name,
                        "endpoint_qualifier": f"{rt_name.split('-')[0]}_endpoint"
                            if rt_name.startswith(f"{runtime_prefix}_")
                            else endpoint_qualifier,
                    })
    except Exception as e:
        logger.warning("Failed to resolve runtime ARN", extra={"error": str(e)})

    if not matches:
        return {"runtime_arn": "", "runtime_name": "", "endpoint_qualifier": "", "runtimes": []}

    # Primary ARN: first match (keeps backward-compat for standalone callers).
    # Full list returned under `runtimes` for multi-agent apps.
    return {
        "runtime_arn": matches[0]["runtime_arn"],
        "runtime_name": matches[0]["runtime_name"],
        "endpoint_qualifier": matches[0]["endpoint_qualifier"],
        "runtimes": matches,
    }


@tool
def pipeline_status(
    execution_id: str = "",
    app_name: str = "",
) -> dict:
    """Check the current status of a deploy pipeline execution.

    Call this after ``pipeline_trigger`` returns ``status: timeout`` (or at any
    time the user asks "is my deploy done?"). This is lightweight — one
    CodePipeline API call — and returns immediately.

    Args:
        execution_id: The pipeline execution ID returned by ``pipeline_trigger``.
            If empty, looks up the latest execution of the configured pipeline.
        app_name: (Optional) The agent/app name. When the pipeline has
            succeeded, used to resolve and return the deployed runtime ARN.

    Returns:
        Dict with:
          - execution_id: The execution ID that was checked
          - status: "in_progress" | "succeeded" | "failed" | "cancelled" | "stopped" | "unknown"
          - stage: The current stage name (if in progress) or last completed stage
          - runtime_arn: Populated when status==succeeded and app_name was provided
          - endpoint_qualifier: Endpoint qualifier for the runtime (if resolved)
          - error: Error message if the pipeline failed, else None
    """
    pipeline_name = os.environ.get("STUDIO_PIPELINE_NAME", "nocode-user-nocode-user-deploy-deploy")
    domain = os.environ.get("STUDIO_DEPLOY_DOMAIN", "nocode-user")
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

    cp_client = boto3.client("codepipeline", region_name=region)

    # If no explicit execution_id, grab the latest
    if not execution_id:
        try:
            resp = cp_client.list_pipeline_executions(
                pipelineName=pipeline_name,
                maxResults=1,
            )
            executions = resp.get("pipelineExecutionSummaries", [])
            if not executions:
                return {
                    "execution_id": "",
                    "status": "unknown",
                    "stage": "",
                    "runtime_arn": "",
                    "endpoint_qualifier": "",
                    "error": "No pipeline executions found",
                }
            execution_id = executions[0].get("pipelineExecutionId", "")
        except Exception as e:
            return {
                "execution_id": "",
                "status": "unknown",
                "stage": "",
                "runtime_arn": "",
                "endpoint_qualifier": "",
                "error": f"Failed to list executions: {e}",
            }

    # Get detailed status for the execution
    try:
        resp = cp_client.get_pipeline_execution(
            pipelineName=pipeline_name,
            pipelineExecutionId=execution_id,
        )
        execution = resp.get("pipelineExecution", {})
        aws_status = execution.get("status", "Unknown")
    except Exception as e:
        return {
            "execution_id": execution_id,
            "status": "unknown",
            "stage": "",
            "runtime_arn": "",
            "endpoint_qualifier": "",
            "error": f"Failed to get execution: {e}",
        }

    status_map = {
        "Succeeded": "succeeded",
        "Failed": "failed",
        "Cancelled": "cancelled",
        "Stopped": "stopped",
        "InProgress": "in_progress",
        "Superseded": "in_progress",
    }
    normalized = status_map.get(aws_status, "unknown")

    # Determine the current/last stage
    stage_name = ""
    try:
        state_resp = cp_client.get_pipeline_state(name=pipeline_name)
        for stage in state_resp.get("stageStates", []):
            latest_exec = stage.get("latestExecution", {})
            if latest_exec.get("pipelineExecutionId") == execution_id:
                if latest_exec.get("status") == "InProgress":
                    stage_name = stage.get("stageName", "")
                    break
                stage_name = stage.get("stageName", "")
    except Exception as e:
        logger.warning("Failed to get pipeline state", extra={"error": str(e)})

    result: dict = {
        "execution_id": execution_id,
        "status": normalized,
        "stage": stage_name,
        "runtime_arn": "",
        "endpoint_qualifier": "",
        "error": None,
    }

    if normalized == "succeeded" and app_name:
        arn_result = _resolve_runtime_arn(app_name, domain, region)
        result["runtime_arn"] = arn_result.get("runtime_arn", "")
        result["endpoint_qualifier"] = arn_result.get("endpoint_qualifier", "")
        result["runtimes"] = arn_result.get("runtimes", [])

    if normalized in ("failed", "cancelled", "stopped"):
        result["error"] = f"Pipeline {aws_status}"

    return result
