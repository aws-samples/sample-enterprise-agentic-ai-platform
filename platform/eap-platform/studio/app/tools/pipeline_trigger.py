"""Pipeline Trigger tool — commits generated files to CodeCommit and triggers deployment.

Uses the boto3 CodeCommit API to create a commit in the target repo
(configured via STUDIO_TARGET_REPO env var, defaults to "nocode-user").
The deploy pipeline triggers automatically on push (CodePipeline watches the repo).

After commit, polls the pipeline to completion and resolves the deployed
agent's runtime ARN from AgentCore — enabling the UI to auto-add the agent
to the "My Deployed Agents" tab for immediate testing.

Pattern-to-folder mapping:
  standalone          → standalone
  supervisor          → orchestration/supervisor
  sequential-workflow → orchestration/sequential
  router              → orchestration/router
  swarm               → choreography/swarm
"""

import logging
import os
import time

import boto3
from strands import tool

logger = logging.getLogger("studio.pipeline_trigger")

# ---------------------------------------------------------------------------
# Pattern → directory mapping
# ---------------------------------------------------------------------------

_PATTERN_FOLDER_MAP: dict[str, str] = {
    "standalone": "standalone",
    "supervisor": "orchestration/supervisor",
    "sequential-workflow": "orchestration/sequential",
    "router": "orchestration/router",
    "swarm": "choreography/swarm",
}


def _resolve_pattern_folder(pattern_folder: str) -> str:
    """Map a pattern name to its repo directory path.

    If *pattern_folder* is already a path (contains "/"), it is returned as-is
    so callers can pass pre-resolved paths.
    """
    if "/" in pattern_folder:
        return pattern_folder
    return _PATTERN_FOLDER_MAP.get(pattern_folder, pattern_folder)


def _build_put_file_entries(
    pattern_folder: str,
    app_name: str,
    files: dict[str, str],
) -> list[dict]:
    """Build the ``putFiles`` list for the CodeCommit ``create_commit`` API.

    Each file path follows the convention:
        {pattern_folder}/{app_name}/{relative_path}

    where *relative_path* is the key from the *files* dict (e.g.
    ``my-agent/main.py``, ``my-agent/agent.yaml``).
    """
    resolved_folder = _resolve_pattern_folder(pattern_folder)
    entries: list[dict] = []
    for relative_path, content in files.items():
        file_path = f"{resolved_folder}/{app_name}/{relative_path}"
        entries.append(
            {
                "filePath": file_path,
                "fileMode": "NORMAL",
                "fileContent": content.encode("utf-8"),
            }
        )
    return entries


# ---------------------------------------------------------------------------
# Pipeline polling + ARN resolution
# ---------------------------------------------------------------------------

PIPELINE_LOOKUP_WAIT = 8   # brief wait so CodePipeline picks up the commit
PIPELINE_RETRY_WAIT = 5    # gap between follow-up lookups
PIPELINE_LOOKUP_TRIES = 3  # quick retries while waiting for execution to appear


def _lookup_delay(attempt: int) -> int:
    """Seconds to wait before lookup attempt N (0-based).

    The first attempt waits a grace period for CodePipeline to register the
    commit; later attempts use a shorter retry gap.
    """
    return PIPELINE_LOOKUP_WAIT if attempt == 0 else PIPELINE_RETRY_WAIT


def _find_latest_execution(pipeline_name: str, region: str, start_after: float) -> dict:
    """Find the execution that was triggered by our just-made commit.

    Does NOT wait for it to complete — the UI polls /api/deployment-status.

    Returns dict with execution_id. Empty string if none found in the short
    lookup window (rare; CodePipeline usually picks up a commit in <10s).
    """
    cp_client = boto3.client("codepipeline", region_name=region)

    for attempt in range(PIPELINE_LOOKUP_TRIES):
        time.sleep(_lookup_delay(attempt))
        try:
            resp = cp_client.list_pipeline_executions(
                pipelineName=pipeline_name,
                maxResults=5,
            )
            for e in resp.get("pipelineExecutionSummaries", []):
                et = e.get("startTime")
                if et and et.timestamp() >= start_after - 5:
                    return {"execution_id": e.get("pipelineExecutionId", "")}
        except Exception as err:
            logger.warning("list_pipeline_executions failed", extra={"error": str(err)})

    return {"execution_id": ""}


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

    return {
        "runtime_arn": matches[0]["runtime_arn"],
        "runtime_name": matches[0]["runtime_name"],
        "endpoint_qualifier": matches[0]["endpoint_qualifier"],
        "runtimes": matches,
    }


# ---------------------------------------------------------------------------
# Main tool
# ---------------------------------------------------------------------------

@tool
def pipeline_trigger(
    pattern_folder: str,
    app_name: str,
    files: dict,
) -> dict:
    """Commit generated files to the nocode-user CodeCommit repo, trigger the deploy
    pipeline, wait for completion, and return the deployed agent's runtime ARN.

    The Studio always commits to the dedicated nocode-user repo (not team-bu-1),
    ensuring Studio-generated agents are isolated from developer-managed agents.

    Args:
        pattern_folder: Pattern name or directory path (e.g. "standalone",
            "supervisor", "orchestration/supervisor").
        app_name: Application or agent name (kebab-case).
        files: Dict mapping relative file paths to file content strings.
            Keys are paths relative to the app directory, e.g.
            {"my-agent/main.py": "...", "my-agent/agent.yaml": "..."}.

    Returns:
        Dict with:
          - commit_id: The CodeCommit commit hash
          - pipeline_execution_id: The pipeline execution ID
          - status: "started" | "commit_failed"
          - pattern_folder: Resolved directory path (e.g. "orchestration/supervisor")
          - app_name: The app/agent name you committed
          - repo: The CodeCommit repo name (usually "nocode-user")
          - runtime_arn: Always empty — the UI resolves ARNs after pipeline success
          - endpoint_qualifier: Always empty — same as above
          - runtimes: Always empty — same as above
          - message: Human-readable summary for the agent to pass through
          - error: Error message if any step failed, else None

        The tool returns as soon as the commit is made and the pipeline
        execution ID is known (~10-15 seconds). It does NOT wait for the
        pipeline to finish. When you reply to the user, include:
          - the ``pipeline_execution_id`` (so the UI can poll for status)
          - the ``app_name``
          - the ``pattern_folder`` path
        The UI uses all three to resolve the final ARNs and pattern, and to
        render the right pattern-specific view once the pipeline succeeds.
    """
    repo_name = os.environ.get("STUDIO_TARGET_REPO", "nocode-user")
    pipeline_name = os.environ.get("STUDIO_PIPELINE_NAME", "nocode-user-nocode-user-deploy-deploy")
    domain = os.environ.get("STUDIO_DEPLOY_DOMAIN", "nocode-user")
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

    # Step 1: Commit files to CodeCommit
    try:
        cc_client = boto3.client("codecommit", region_name=region)

        branch_name = "main"
        try:
            branch_resp = cc_client.get_branch(repositoryName=repo_name, branchName=branch_name)
            parent_commit_id = branch_resp["branch"]["commitId"]
        except cc_client.exceptions.BranchDoesNotExistException:
            parent_commit_id = None

        put_files = _build_put_file_entries(pattern_folder, app_name, files)

        commit_kwargs: dict = {
            "repositoryName": repo_name,
            "branchName": branch_name,
            "putFiles": put_files,
            "authorName": "Agent Deployment Engineer",
            "email": "studio@eap-platform.internal",
            "commitMessage": f"Deploy {app_name} ({pattern_folder}) via Agent Deployment Engineer",
        }
        if parent_commit_id:
            commit_kwargs["parentCommitId"] = parent_commit_id

        commit_resp = cc_client.create_commit(**commit_kwargs)
        commit_id = commit_resp.get("commitId", "")
        logger.info("Committed to CodeCommit", extra={"commit_id": commit_id, "repo": repo_name})

    except Exception as exc:
        return {
            "commit_id": "",
            "pipeline_execution_id": "",
            "status": "commit_failed",
            "runtime_arn": "",
            "endpoint_qualifier": "",
            "error": str(exc),
        }

    # Step 2: Don't poll — return immediately with the pipeline execution ID.
    # The UI polls /api/deployment-status in the browser; the Studio container
    # stays free to keep talking to the user instead of blocking on a long loop.
    commit_time = time.time()
    pipeline_result = _find_latest_execution(pipeline_name, region, start_after=commit_time)

    return {
        "commit_id": commit_id,
        "pipeline_execution_id": pipeline_result.get("execution_id", ""),
        "status": "started",
        "runtime_arn": "",
        "endpoint_qualifier": "",
        "runtimes": [],
        # Echo path info so the UI can read application.yaml to determine the
        # real pattern (supervisor / sequential-workflow / router / swarm /
        # standalone) after the pipeline succeeds.
        "pattern_folder": _resolve_pattern_folder(pattern_folder),
        "app_name": app_name,
        "repo": repo_name,
        "error": None,
        "message": (
            "Deployment started. The pipeline waits at its Approve stage until "
            "a reviewer approves the commit in the CodePipeline console "
            f"(pipeline {pipeline_name}); nothing is deployed before that. The "
            "UI shows progress and adds the agent to My Deployed Agents once "
            "the pipeline succeeds."
        ),
    }
