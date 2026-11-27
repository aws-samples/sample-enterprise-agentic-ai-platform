#!/usr/bin/env python3
"""
Agent School Lifecycle State Machine

Manages agent lifecycle state transitions in DynamoDB.
Valid states: enrolled → training → validated → graduated → production
Regression: any state → training (on evaluation failure)

Used by pipeline stages to record state transitions.

Version tracking:
- New deployments use `version` (semver) and `commit_sha` as primary identifiers
- Legacy records with `image_tag` only are supported for backward compatibility
- The `image_tag` field is preserved read-only on existing records
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from typing import Optional

import boto3

from semver_utils import is_higher_version, is_valid_semver


# Valid states in order
STATES = ["enrolled", "training", "validated", "graduated", "production"]

# Valid forward transitions (from → to)
VALID_TRANSITIONS = {
    "enrolled": ["training"],
    "training": ["validated"],
    "validated": ["graduated"],
    "graduated": ["production"],
    "production": [],
}

# Regression: any state can go back to "training" on eval failure
REGRESSION_TARGET = "training"


class LifecycleError(Exception):
    pass


def validate_transition(current_state: str, target_state: str) -> bool:
    """Check if a state transition is valid."""
    # Regression to training is always valid (except from enrolled)
    if target_state == REGRESSION_TARGET and current_state != "enrolled":
        return True
    # Forward transitions
    return target_state in VALID_TRANSITIONS.get(current_state, [])


def transition_agent(
    table_name: str,
    agent_name: str,
    target_state: str,
    version: str,
    commit_sha: str,
    trigger: str,
    pipeline_execution_id: Optional[str] = None,
    region: str = "us-east-1",
    app_name: Optional[str] = None,
    is_entrypoint: Optional[bool] = None,
    deployed_by: str = "nocode-user",
) -> dict:
    """
    Transition an agent to a new lifecycle state.

    Args:
        table_name: DynamoDB table name.
        agent_name: Agent identifier.
        target_state: Target lifecycle state.
        version: Semantic version string (e.g., "1.2.0").
        commit_sha: Git commit SHA for traceability.
        trigger: What triggered this transition.
        pipeline_execution_id: Optional pipeline execution ID.
        region: AWS region.
        app_name: Application this agent belongs to. Groups sub-agents of a
            multi-agent app (e.g. all runtimes of a "research-assistant" app)
            under one application. Enables the app-index GSI so consumers can
            list an application's agents rather than a flat per-agent view.
            When omitted, standalone agents can be treated as their own app.
        is_entrypoint: Whether this agent is the application's main entrypoint
            (e.g. the orchestrator/supervisor that the UI should invoke).
            Sub-agents set this False. When omitted, left unset (see the
            recorded future enhancement for authoritative entrypoint detection).
        deployed_by: Who/what deployed the agent. Defaults to "nocode-user"
            (the Studio / no-code deploy path). Recorded for provenance.

    Returns:
        The updated record dict.

    Raises:
        LifecycleError: If transition is invalid or version is invalid.
    """
    # Validate version is valid semver
    if not is_valid_semver(version):
        raise LifecycleError(
            f"Invalid version format: '{version}'. Expected MAJOR.MINOR.PATCH (e.g., '1.2.0')"
        )

    dynamodb = boto3.resource("dynamodb", region_name=region)
    table = dynamodb.Table(table_name)

    # Get current state
    response = table.get_item(Key={"agent_name": agent_name})
    item = response.get("Item")

    if item is None:
        # First time — agent must be enrolled
        if target_state != "enrolled":
            raise LifecycleError(
                f"Agent '{agent_name}' not found. First transition must be to 'enrolled', got '{target_state}'"
            )
        current_state = None
    else:
        current_state = item.get("current_state", "enrolled")

    # Validate state transition
    if current_state and not validate_transition(current_state, target_state):
        raise LifecycleError(
            f"Invalid transition: {current_state} → {target_state}. "
            f"Valid targets from '{current_state}': {VALID_TRANSITIONS.get(current_state, [])} "
            f"(+ regression to 'training')"
        )

    # Version ordering validation
    # Skip if: (1) new agent, (2) legacy record without version field (first versioned deploy)
    if item is not None:
        current_version = item.get("version")
        if current_version:
            # Enforce version ordering: new version must be higher (except regression)
            if target_state != REGRESSION_TARGET and not is_higher_version(version, current_version):
                raise LifecycleError(
                    f"Version {version} must be higher than current {current_version}"
                )
        # else: legacy record with image_tag but no version — skip ordering on first versioned deploy

    # Build transition record
    now = datetime.now(timezone.utc).isoformat()
    transition = {
        "from_state": current_state or "(new)",
        "to_state": target_state,
        "timestamp": now,
        "trigger": trigger,
        "version": version,
        "commit_sha": commit_sha,
    }
    if pipeline_execution_id:
        transition["pipeline_execution_id"] = pipeline_execution_id

    # Update DynamoDB
    if item is None:
        # Create new record
        new_item = {
            "agent_name": agent_name,
            "current_state": target_state,
            "version": version,
            "commit_sha": commit_sha,
            "last_transition": now,
            "state_history": [transition],
            "graduation_reports": [],
            # Application-level hierarchy + provenance (now-achievable subset).
            # deployed_by is always recorded; app_name / is_entrypoint are set
            # when the caller can supply them.
            "deployed_by": deployed_by,
        }
        # app_name backs the app-index GSI, so only set it when non-empty
        # (DynamoDB GSI keys cannot be null/empty).
        if app_name:
            new_item["app_name"] = app_name
        if is_entrypoint is not None:
            new_item["is_entrypoint"] = is_entrypoint
        table.put_item(Item=new_item)
        return new_item
    else:
        # Update existing record
        history = item.get("state_history", [])
        history.append(transition)

        # Build update expression — preserve image_tag if it exists (read-only backward compat)
        update_expr = (
            "SET current_state = :state, version = :ver, commit_sha = :sha, "
            "last_transition = :ts, state_history = :history, deployed_by = :deployed_by"
        )
        expr_values = {
            ":state": target_state,
            ":ver": version,
            ":sha": commit_sha,
            ":ts": now,
            ":history": history,
            ":deployed_by": deployed_by,
        }
        # Only touch app_name / is_entrypoint when supplied, so a later
        # state-only transition never clears a previously recorded value.
        if app_name:
            update_expr += ", app_name = :app_name"
            expr_values[":app_name"] = app_name
        if is_entrypoint is not None:
            update_expr += ", is_entrypoint = :is_entrypoint"
            expr_values[":is_entrypoint"] = is_entrypoint

        table.update_item(
            Key={"agent_name": agent_name},
            UpdateExpression=update_expr,
            ExpressionAttributeValues=expr_values,
        )
        item["current_state"] = target_state
        item["version"] = version
        item["commit_sha"] = commit_sha
        item["last_transition"] = now
        item["state_history"] = history
        item["deployed_by"] = deployed_by
        if app_name:
            item["app_name"] = app_name
        if is_entrypoint is not None:
            item["is_entrypoint"] = is_entrypoint
        return item


def get_agent_state(table_name: str, agent_name: str, region: str = "us-east-1") -> Optional[dict]:
    """
    Get current lifecycle state for an agent.

    Returns version if available, falls back to image_tag for legacy records.
    """
    dynamodb = boto3.resource("dynamodb", region_name=region)
    table = dynamodb.Table(table_name)
    response = table.get_item(Key={"agent_name": agent_name})
    item = response.get("Item")
    if item is None:
        return None

    # Ensure the response includes a version identifier:
    # prefer `version`, fallback to `image_tag` for legacy records
    if "version" not in item and "image_tag" in item:
        item["_version_display"] = item["image_tag"]
    elif "version" in item:
        item["_version_display"] = item["version"]

    return item


def main():
    parser = argparse.ArgumentParser(description="Agent Lifecycle State Machine")
    subparsers = parser.add_subparsers(dest="command")

    # Transition command
    trans = subparsers.add_parser("transition", help="Transition agent to new state")
    trans.add_argument("--table", required=True, help="DynamoDB table name")
    trans.add_argument("--agent", required=True, help="Agent name")
    trans.add_argument("--state", required=True, choices=STATES, help="Target state")
    trans.add_argument("--version", required=True, help="Semantic version (e.g., 1.2.0)")
    trans.add_argument("--commit-sha", required=True, help="Git commit SHA")
    trans.add_argument("--trigger", required=True, help="What triggered this transition")
    trans.add_argument("--execution-id", default=None, help="Pipeline execution ID")
    trans.add_argument("--region", default="us-east-1")
    trans.add_argument("--app-name", default=None,
                       help="Application this agent belongs to (groups sub-agents under one app)")
    trans.add_argument("--entrypoint", action="store_true",
                       help="Mark this agent as the application's main entrypoint (orchestrator/supervisor)")
    trans.add_argument("--deployed-by", default="nocode-user",
                       help="Who/what deployed the agent (default: nocode-user)")

    # Query command
    query = subparsers.add_parser("query", help="Get agent lifecycle state")
    query.add_argument("--table", required=True, help="DynamoDB table name")
    query.add_argument("--agent", required=True, help="Agent name")
    query.add_argument("--region", default="us-east-1")

    args = parser.parse_args()

    if args.command == "transition":
        try:
            result = transition_agent(
                table_name=args.table,
                agent_name=args.agent,
                target_state=args.state,
                version=args.version,
                commit_sha=args.commit_sha,
                trigger=args.trigger,
                pipeline_execution_id=args.execution_id,
                region=args.region,
                app_name=args.app_name,
                is_entrypoint=True if args.entrypoint else None,
                deployed_by=args.deployed_by,
            )
            print(f"✓ {args.agent}: → {args.state} (v{args.version})")
            print(json.dumps(result, indent=2, default=str))
        except LifecycleError as e:
            print(f"✗ Transition rejected: {e}")
            sys.exit(1)

    elif args.command == "query":
        result = get_agent_state(args.table, args.agent, args.region)
        if result:
            print(json.dumps(result, indent=2, default=str))
        else:
            print(f"Agent '{args.agent}' not found in lifecycle store")
            sys.exit(1)

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
