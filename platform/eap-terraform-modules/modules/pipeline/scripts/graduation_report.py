#!/usr/bin/env python3
"""
Graduation Report Generation

Generates and persists graduation reports for agents that pass all
evaluation gates in a given environment. The report uses the semantic
version as the primary human-facing identifier rather than ECR image tags.

A graduation report captures:
    - version: semantic version (primary identifier)
    - commit_sha: git commit for traceability
    - environment: which environment the agent graduated from (qa/prod)
    - scores: evaluation scores (safety, correctness, helpfulness)
    - red_team_pass: whether the red team suite passed
    - timestamp: ISO 8601 timestamp of graduation
    - approver: who/what approved the graduation

Reports are written to S3 for archival and recorded in the lifecycle
state store for prod promotion checks.

Usage:
    python graduation_report.py --version 1.3.0 --commit-sha a1b2c3d4 \
        --environment qa --agent rrf-search-app/orchestrator \
        --table lifecycle-table --bucket graduation-reports \
        --scores '{"safety":0.95,"correctness":0.88,"helpfulness":0.82}' \
        --red-team-pass --approver "pipeline:automated"
"""

import argparse
import json
import sys
import uuid
from datetime import datetime, timezone
from typing import Dict, Optional

import boto3

from semver_utils import is_valid_semver


class GraduationReportError(Exception):
    pass


def generate_graduation_report(
    version: str,
    commit_sha: str,
    environment: str,
    scores: Dict[str, float],
    red_team_pass: bool,
    approver: str,
    qa_evaluator_results: Optional[list] = None,
) -> dict:
    """
    Generate a graduation report with version as primary identifier.

    The report captures all evaluation results and metadata needed for
    audit trails and prod promotion validation. Includes individual QA
    evaluator results (score, threshold, pass/fail) when present.

    Args:
        version: Semantic version string (primary identifier).
        commit_sha: Git commit SHA for traceability.
        environment: Environment graduated from ("qa" or "prod").
        scores: Evaluation scores dict (keys: safety, correctness, helpfulness).
        red_team_pass: Whether the red team suite passed.
        approver: Identity of approver (e.g., "pipeline:automated").
        qa_evaluator_results: Optional list of QA evaluator results, each
            containing evaluator_name, score, threshold, and passed status.

    Returns:
        Complete graduation report dict.

    Raises:
        GraduationReportError: If inputs are invalid.
    """
    # Validate version
    if not is_valid_semver(version):
        raise GraduationReportError(
            f"Invalid version format: '{version}'. Expected MAJOR.MINOR.PATCH (e.g., '1.2.0')"
        )

    # Validate environment
    if environment not in ("qa", "prod"):
        raise GraduationReportError(
            f"Invalid environment: '{environment}'. Expected 'qa' or 'prod'."
        )

    # Validate scores contain required keys
    required_score_keys = {"safety", "correctness", "helpfulness"}
    missing_keys = required_score_keys - set(scores.keys())
    if missing_keys:
        raise GraduationReportError(
            f"Missing required score keys: {missing_keys}. "
            f"Required: {required_score_keys}"
        )

    report_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    report = {
        "report_id": report_id,
        "version": version,
        "commit_sha": commit_sha,
        "environment": environment,
        "timestamp": now,
        "scores": scores,
        "red_team_pass": red_team_pass,
        "approver": approver,
    }

    # Include QA evaluator results if present (Task 7.6)
    if qa_evaluator_results is not None:
        report["qa_evaluator_results"] = [
            {
                "evaluator_name": r.get("evaluator_name", ""),
                "score": r.get("score", 0.0),
                "threshold": r.get("threshold", 0.0),
                "passed": r.get("passed", False),
                "source": r.get("source", "qa_repo"),
            }
            for r in qa_evaluator_results
        ]
        # Summary: did all QA evaluators pass?
        qa_all_passed = all(r.get("passed", False) for r in qa_evaluator_results)
        report["qa_evaluators_pass"] = qa_all_passed
        report["qa_evaluators_count"] = len(qa_evaluator_results)
    else:
        report["qa_evaluator_results"] = []
        report["qa_evaluators_pass"] = True
        report["qa_evaluators_count"] = 0

    return report


def write_report_to_s3(
    report: dict,
    bucket: str,
    agent_name: str,
    region: str = "us-east-1",
) -> str:
    """
    Write the graduation report to S3 for archival.

    Reports are stored at:
        s3://{bucket}/{agent_name}/{version}/{report_id}.json

    Args:
        report: The graduation report dict.
        bucket: S3 bucket name.
        agent_name: Agent identifier.
        region: AWS region.

    Returns:
        The S3 key where the report was stored.
    """
    s3 = boto3.client("s3", region_name=region)
    version = report["version"]
    report_id = report["report_id"]

    key = f"{agent_name}/{version}/{report_id}.json"
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(report, indent=2),
        ContentType="application/json",
    )

    return key


def record_report_in_lifecycle_store(
    report: dict,
    table_name: str,
    agent_name: str,
    region: str = "us-east-1",
) -> None:
    """
    Record the graduation report ID in the lifecycle state store.

    Appends the report to the agent's graduation_reports list in DynamoDB.

    Args:
        report: The graduation report dict.
        table_name: DynamoDB table name.
        agent_name: Agent identifier.
        region: AWS region.

    Raises:
        GraduationReportError: If the agent record doesn't exist.
    """
    dynamodb = boto3.resource("dynamodb", region_name=region)
    table = dynamodb.Table(table_name)

    # Get current record
    response = table.get_item(Key={"agent_name": agent_name})
    item = response.get("Item")

    if item is None:
        raise GraduationReportError(
            f"Agent '{agent_name}' not found in lifecycle store. "
            f"Cannot record graduation report."
        )

    # Append report to graduation_reports list
    reports = item.get("graduation_reports", [])
    reports.append(report)

    table.update_item(
        Key={"agent_name": agent_name},
        UpdateExpression="SET graduation_reports = :reports",
        ExpressionAttributeValues={":reports": reports},
    )


def run_graduation_report(
    version: str,
    commit_sha: str,
    environment: str,
    agent_name: str,
    table_name: str,
    bucket: str,
    scores: Dict[str, float],
    red_team_pass: bool,
    approver: str,
    region: str = "us-east-1",
    qa_evaluator_results: Optional[list] = None,
) -> dict:
    """
    Generate, persist, and record a graduation report.

    Args:
        version: Semantic version string.
        commit_sha: Git commit SHA.
        environment: Environment ("qa" or "prod").
        agent_name: Agent identifier.
        table_name: DynamoDB lifecycle table.
        bucket: S3 bucket for report archival.
        scores: Evaluation scores dict.
        red_team_pass: Whether red team suite passed.
        approver: Approver identity.
        region: AWS region.
        qa_evaluator_results: Optional list of QA evaluator results.

    Returns:
        Dict with report details and storage locations.

    Raises:
        GraduationReportError: On validation or persistence failure.
    """
    # 1. Generate report
    report = generate_graduation_report(
        version=version,
        commit_sha=commit_sha,
        environment=environment,
        scores=scores,
        red_team_pass=red_team_pass,
        approver=approver,
        qa_evaluator_results=qa_evaluator_results,
    )
    print(f"✓ Generated graduation report: {report['report_id']}")

    # 2. Write to S3
    s3_key = write_report_to_s3(report, bucket, agent_name, region)
    print(f"✓ Report archived to s3://{bucket}/{s3_key}")

    # 3. Record in lifecycle store
    record_report_in_lifecycle_store(report, table_name, agent_name, region)
    print(f"✓ Report recorded in lifecycle store for '{agent_name}'")

    return {
        "status": "recorded",
        "report_id": report["report_id"],
        "version": version,
        "environment": environment,
        "s3_key": s3_key,
        "report": report,
    }


def main():
    """CLI entry point for graduation report generation."""
    parser = argparse.ArgumentParser(
        description="Generate and persist a graduation report for an agent version"
    )
    parser.add_argument(
        "--version",
        required=True,
        help="Semantic version (e.g., '1.3.0')",
    )
    parser.add_argument(
        "--commit-sha",
        required=True,
        help="Git commit SHA for traceability",
    )
    parser.add_argument(
        "--environment",
        required=True,
        choices=["qa", "prod"],
        help="Environment the agent graduated from",
    )
    parser.add_argument(
        "--agent",
        required=True,
        help="Agent name (e.g., 'rrf-search-app/orchestrator')",
    )
    parser.add_argument(
        "--table",
        required=True,
        help="DynamoDB lifecycle state table name",
    )
    parser.add_argument(
        "--bucket",
        required=True,
        help="S3 bucket for graduation report archival",
    )
    parser.add_argument(
        "--scores",
        required=True,
        help='Evaluation scores as JSON (e.g., \'{"safety":0.95,"correctness":0.88,"helpfulness":0.82}\')',
    )
    parser.add_argument(
        "--red-team-pass",
        action="store_true",
        help="Flag indicating red team suite passed",
    )
    parser.add_argument(
        "--approver",
        default="pipeline:automated",
        help="Approver identity (default: pipeline:automated)",
    )
    parser.add_argument(
        "--qa-evaluator-results",
        default="",
        help='QA evaluator results as JSON array (e.g., \'[{"evaluator_name":"x","score":0.9,"threshold":0.8,"passed":true}]\')',
    )
    parser.add_argument(
        "--region",
        default="us-east-1",
        help="AWS region (default: us-east-1)",
    )
    args = parser.parse_args()

    # Parse scores JSON
    try:
        scores = json.loads(args.scores)
    except json.JSONDecodeError as e:
        print(f"✗ Invalid scores JSON: {e}")
        sys.exit(1)

    # Parse QA evaluator results JSON (optional)
    qa_evaluator_results = None
    if args.qa_evaluator_results:
        try:
            qa_evaluator_results = json.loads(args.qa_evaluator_results)
        except json.JSONDecodeError as e:
            print(f"✗ Invalid qa-evaluator-results JSON: {e}")
            sys.exit(1)

    try:
        result = run_graduation_report(
            version=args.version,
            commit_sha=args.commit_sha,
            environment=args.environment,
            agent_name=args.agent,
            table_name=args.table,
            bucket=args.bucket,
            scores=scores,
            red_team_pass=args.red_team_pass,
            approver=args.approver,
            region=args.region,
            qa_evaluator_results=qa_evaluator_results,
        )
        print(json.dumps(result, indent=2))
    except GraduationReportError as e:
        print(f"✗ Graduation report failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
