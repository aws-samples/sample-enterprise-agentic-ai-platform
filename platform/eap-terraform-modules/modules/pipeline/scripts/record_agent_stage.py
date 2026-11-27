#!/usr/bin/env python3
"""
Record Agent Stage

Records an agent's lifecycle stage transition in the DynamoDB lifecycle store.
Called by pipeline buildspecs at key moments to track graduation progress.

Pipeline events → Agent stages:
  - agent.yaml commit detected   → enrolled
  - Deploy stage starts          → training
  - Dev gate pass                → validated
  - QA gate pass                 → graduated
  - Prod deploy success          → production
  - Any eval failure             → training (regression)

Usage:
  python3 record_agent_stage.py training --table <table> --agent <name> \
      --version <semver> --commit-sha <sha> [--execution-id <id>] [--region <region>]
"""

import argparse
import json
import sys
from datetime import datetime, timezone

# Import the lifecycle state machine
from lifecycle_state import transition_agent, get_agent_state, LifecycleError


# Stage command → target lifecycle state mapping
HOOK_TRANSITIONS = {
    "enrolled": "enrolled",
    "training": "training",
    "validated": "validated",
    "graduated": "graduated",
    "production": "production",
    "regress": "training",  # regression on eval failure
}


def run_hook(
    hook_name: str,
    table_name: str,
    agent_name: str,
    version: str,
    commit_sha: str,
    execution_id: str = "",
    region: str = "us-east-1",
    app_name: str = "",
    is_entrypoint: bool = False,
    deployed_by: str = "nocode-user",
) -> dict:
    """Execute a lifecycle hook, transitioning the agent's state."""
    target_state = HOOK_TRANSITIONS.get(hook_name)
    if target_state is None:
        raise ValueError(f"Unknown hook: '{hook_name}'. Valid: {list(HOOK_TRANSITIONS.keys())}")

    trigger = f"pipeline:{hook_name}"

    try:
        result = transition_agent(
            table_name=table_name,
            agent_name=agent_name,
            target_state=target_state,
            version=version,
            commit_sha=commit_sha,
            trigger=trigger,
            pipeline_execution_id=execution_id or None,
            region=region,
            app_name=app_name or None,
            is_entrypoint=True if is_entrypoint else None,
            deployed_by=deployed_by,
        )
        print(f"✓ [{hook_name}] {agent_name} → {target_state} (v{version})")
        return result
    except LifecycleError as e:
        # For regression, log but don't fail the pipeline
        if hook_name == "regress":
            print(f"⚠ [{hook_name}] Regression failed for {agent_name}: {e}")
            return {"error": str(e)}
        raise


def main():
    parser = argparse.ArgumentParser(description="Record agent lifecycle stage in DynamoDB")
    parser.add_argument("stage", choices=list(HOOK_TRANSITIONS.keys()),
                        help="Stage to record")
    parser.add_argument("--table", required=True, help="DynamoDB lifecycle table")
    parser.add_argument("--agent", required=True, help="Agent name")
    parser.add_argument("--version", required=True, help="Semantic version (e.g., 1.2.0)")
    parser.add_argument("--commit-sha", required=True, help="Git commit SHA")
    parser.add_argument("--execution-id", default="", help="Pipeline execution ID")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--app-name", default="",
                        help="Application this agent belongs to (groups sub-agents under one app)")
    parser.add_argument("--entrypoint", action="store_true",
                        help="Mark this agent as the application's main entrypoint (orchestrator/supervisor)")
    parser.add_argument("--deployed-by", default="nocode-user",
                        help="Who/what deployed the agent (default: nocode-user)")
    args = parser.parse_args()

    result = run_hook(
        hook_name=args.stage,
        table_name=args.table,
        agent_name=args.agent,
        version=args.version,
        commit_sha=args.commit_sha,
        execution_id=args.execution_id,
        region=args.region,
        app_name=args.app_name,
        is_entrypoint=args.entrypoint,
        deployed_by=args.deployed_by,
    )

    print(json.dumps(result, indent=2, default=str))


if __name__ == "__main__":
    main()
