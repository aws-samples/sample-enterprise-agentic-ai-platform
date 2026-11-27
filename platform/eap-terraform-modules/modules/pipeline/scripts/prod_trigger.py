#!/usr/bin/env python3
"""
Prod Trigger

Triggers a production pipeline deployment for a specific semantic version.
Validates the version, verifies QA graduation, checks version ordering,
and resolves ECR image tags in the prod account before starting the pipeline.

Workflow:
    1. Validate --version is valid semver
    2. Query lifecycle store for a passing QA graduation report
    3. Reject if no passing QA graduation report exists for the version
    4. Query lifecycle store for currently deployed prod version
    5. Enforce version ordering (new > current), skip on first deploy
    6. Resolve version → ECR image tags in prod account
    7. Start prod pipeline with the validated version

Usage:
    python prod_trigger.py --version 1.3.0 --app-name rrf-search-app \
        --agents orchestrator,web-retriever --table lifecycle-table \
        --pipeline-name my-prod-pipeline [--region us-east-1]
"""

import argparse
import json
import sys
from typing import Dict, List, Optional

import boto3

from semver_utils import is_higher_version, is_valid_semver


class ProdTriggerError(Exception):
    pass


def resolve_ecr_image_tags(
    app_name: str, agents: List[str], version: str
) -> Dict[str, str]:
    """
    Resolve a semantic version to ECR image tags for all agents.

    Multi-agent naming convention: {app_name}_{agent_name}_{version}
    Standalone (single agent): {agent_name}_{version}

    Args:
        app_name: Application name (e.g., "rrf-search-app").
        agents: List of agent names in the application.
        version: Semantic version string.

    Returns:
        Dict mapping agent name to its ECR image tag.
    """
    tags = {}
    if len(agents) == 1:
        # Standalone agent
        tags[agents[0]] = f"{agents[0]}_{version}"
    else:
        # Multi-agent application
        for agent in agents:
            tags[agent] = f"{app_name}_{agent}_{version}"
    return tags


def get_graduation_report(
    table_name: str, agent_name: str, version: str, region: str = "us-east-1"
) -> Optional[dict]:
    """
    Query the lifecycle state store for a passing QA graduation report.

    Searches the agent's graduation_reports list for a report matching
    the specified version with environment="qa" and a passing status.

    Args:
        table_name: DynamoDB table name.
        agent_name: Agent identifier.
        version: Semantic version to look up.
        region: AWS region.

    Returns:
        The matching graduation report dict if found, None otherwise.
    """
    dynamodb = boto3.resource("dynamodb", region_name=region)
    table = dynamodb.Table(table_name)
    response = table.get_item(Key={"agent_name": agent_name})
    item = response.get("Item")

    if item is None:
        return None

    reports = item.get("graduation_reports", [])
    for report in reports:
        if (
            report.get("version") == version
            and report.get("environment") == "qa"
            and report.get("red_team_pass") is True
        ):
            return report

    return None


def get_current_prod_version(
    table_name: str, agent_name: str, region: str = "us-east-1"
) -> Optional[str]:
    """
    Query the lifecycle state store for the currently deployed prod version.

    Checks if the agent is currently in "production" state and returns
    its version field.

    Args:
        table_name: DynamoDB table name.
        agent_name: Agent identifier.
        region: AWS region.

    Returns:
        Current prod version string if deployed, None otherwise.
    """
    dynamodb = boto3.resource("dynamodb", region_name=region)
    table = dynamodb.Table(table_name)
    response = table.get_item(Key={"agent_name": agent_name})
    item = response.get("Item")

    if item is None:
        return None

    # Only return version if agent is in production state
    if item.get("current_state") == "production":
        return item.get("version")

    return None


def verify_ecr_images_exist(
    ecr_tags: Dict[str, str], registry: str, region: str = "us-east-1"
) -> None:
    """
    Verify that all resolved ECR image tags exist in the prod registry.

    Args:
        ecr_tags: Dict mapping agent name to ECR image tag.
        registry: ECR repository name/prefix.
        region: AWS region.

    Raises:
        ProdTriggerError: If any image tag is not found in ECR.
    """
    ecr_client = boto3.client("ecr", region_name=region)

    for agent_name, tag in ecr_tags.items():
        try:
            ecr_client.describe_images(
                repositoryName=registry,
                imageIds=[{"imageTag": tag}],
            )
        except ecr_client.exceptions.ImageNotFoundException:
            raise ProdTriggerError(
                f"No images found for version tag '{tag}' in prod repository '{registry}'. "
                f"Ensure ECR replication has completed for this version."
            )


def trigger_prod_pipeline(
    pipeline_name: str,
    version: str,
    ecr_tags: Dict[str, str],
    region: str = "us-east-1",
) -> str:
    """
    Start the prod pipeline execution with the specified version.

    Args:
        pipeline_name: CodePipeline name for prod.
        version: Validated semantic version.
        ecr_tags: Resolved ECR image tags.
        region: AWS region.

    Returns:
        Pipeline execution ID.
    """
    client = boto3.client("codepipeline", region_name=region)
    response = client.start_pipeline_execution(
        name=pipeline_name,
        variables=[
            {"name": "APP_VERSION", "value": version},
            {"name": "IMAGE_TAGS", "value": json.dumps(ecr_tags)},
        ],
    )
    return response["pipelineExecutionId"]


def run_prod_trigger(
    version: str,
    app_name: str,
    agents: List[str],
    table_name: str,
    pipeline_name: str,
    ecr_registry: str = "",
    region: str = "us-east-1",
    skip_ecr_check: bool = False,
) -> dict:
    """
    Execute the full prod trigger workflow.

    Args:
        version: Semantic version to deploy.
        app_name: Application name.
        agents: List of agent names.
        table_name: DynamoDB lifecycle table name.
        pipeline_name: Prod pipeline name.
        ecr_registry: ECR repository name in prod account (optional).
        region: AWS region.
        skip_ecr_check: Skip ECR image existence verification.

    Returns:
        Dict with trigger result.

    Raises:
        ProdTriggerError: On validation or trigger failure.
    """
    # 1. Validate version format
    if not is_valid_semver(version):
        raise ProdTriggerError(
            f"Invalid version format: '{version}'. Expected MAJOR.MINOR.PATCH (e.g., '1.2.0')"
        )

    # 2. Verify QA graduation report exists for this version
    agent_key = f"{app_name}/{agents[0]}" if len(agents) > 1 else agents[0]
    graduation_report = get_graduation_report(table_name, agent_key, version, region)

    if graduation_report is None:
        raise ProdTriggerError(
            f"Version {version} has not graduated QA. "
            f"No passing graduation report found for '{agent_key}' at version {version}. "
            f"Deploy to QA and pass all evaluation gates before promoting to production."
        )
    print(f"✓ QA graduation verified for version {version}")

    # 3. Check version ordering against currently deployed prod version
    current_version = get_current_prod_version(table_name, agent_key, region)

    if current_version:
        if not is_higher_version(version, current_version):
            raise ProdTriggerError(
                f"Version {version} must be higher than currently deployed prod version "
                f"{current_version}. Downgrades are not permitted via the normal deployment path."
            )
        print(f"✓ Version {version} > current prod {current_version}")
    else:
        # First prod deployment — accept any valid semver
        print(f"✓ No current prod version deployed. Accepting {version} as initial deployment.")

    # 4. Resolve version → ECR image tags
    ecr_tags = resolve_ecr_image_tags(app_name, agents, version)
    print(f"✓ Resolved ECR tags: {json.dumps(ecr_tags, indent=2)}")

    # 5. Verify images exist in prod ECR (optional)
    if ecr_registry and not skip_ecr_check:
        verify_ecr_images_exist(ecr_tags, ecr_registry, region)
        print("✓ All ECR images verified in prod account")

    # 6. Trigger prod pipeline
    execution_id = trigger_prod_pipeline(pipeline_name, version, ecr_tags, region)
    print(f"✓ Prod pipeline started: {execution_id}")

    return {
        "status": "triggered",
        "version": version,
        "pipeline_execution_id": execution_id,
        "ecr_tags": ecr_tags,
        "graduation_report": graduation_report,
    }


def main():
    """CLI entry point for prod trigger."""
    parser = argparse.ArgumentParser(
        description="Trigger prod deployment for a semantic version (requires QA graduation)"
    )
    parser.add_argument(
        "--version",
        required=True,
        help="Semantic version to deploy (e.g., '1.3.0')",
    )
    parser.add_argument(
        "--app-name",
        required=True,
        help="Application name (e.g., 'rrf-search-app')",
    )
    parser.add_argument(
        "--agents",
        required=True,
        help="Comma-separated list of agent names (e.g., 'orchestrator,web-retriever')",
    )
    parser.add_argument(
        "--table",
        required=True,
        help="DynamoDB lifecycle state table name",
    )
    parser.add_argument(
        "--pipeline-name",
        required=True,
        help="Prod CodePipeline name to trigger",
    )
    parser.add_argument(
        "--ecr-registry",
        default="",
        help="ECR repository name in prod account for image verification (optional)",
    )
    parser.add_argument(
        "--region",
        default="us-east-1",
        help="AWS region (default: us-east-1)",
    )
    parser.add_argument(
        "--skip-ecr-check",
        action="store_true",
        help="Skip ECR image existence verification",
    )
    args = parser.parse_args()

    agents = [a.strip() for a in args.agents.split(",")]

    try:
        result = run_prod_trigger(
            version=args.version,
            app_name=args.app_name,
            agents=agents,
            table_name=args.table,
            pipeline_name=args.pipeline_name,
            ecr_registry=args.ecr_registry,
            region=args.region,
            skip_ecr_check=args.skip_ecr_check,
        )
        print(json.dumps(result, indent=2))
    except ProdTriggerError as e:
        print(f"✗ Prod trigger rejected: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
