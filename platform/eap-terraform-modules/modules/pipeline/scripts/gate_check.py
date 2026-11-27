#!/usr/bin/env python3
"""
Graduation Gate Check

Compares evaluation scores against graduation policy thresholds.
Generates a graduation report with PASS/FAIL result.

The gate passes if and only if:
1. All evaluation scores meet or exceed their corresponding thresholds
2. Red-team failures do not exceed the configured maximum (if required)

Effective thresholds are resolved as:
  max(environment_default, domain_override)
Domain overrides can only make thresholds stricter, never more lenient.
"""

import argparse
import json
import sys
import uuid
from datetime import datetime, timezone

import boto3
import yaml


def load_policy(policy_path: str) -> dict:
    """Load and return the graduation policy."""
    with open(policy_path) as f:
        return yaml.safe_load(f)


def load_scores(scores_path: str) -> dict:
    """Load evaluation scores JSON."""
    with open(scores_path) as f:
        return json.load(f)


def load_red_team(red_team_path: str) -> dict:
    """Load red-team results JSON."""
    with open(red_team_path) as f:
        return json.load(f)


def resolve_effective_thresholds(
    policy: dict,
    environment: str,
    domain: str,
    developer_thresholds: dict[str, float] | None = None,
) -> dict[str, float]:
    """
    Resolve effective thresholds for a given environment + domain.

    Resolution order (most restrictive wins):
      1. Environment defaults from graduation policy
      2. Domain overrides (governance-set, can only be stricter)
      3. Developer-declared thresholds (from agent.yaml, can only raise)

    Effective = max(environment_default, domain_override, developer_declared)
    per evaluator. This ensures:
      - Governance thresholds can never be lowered by any party
      - Domain admins can only tighten governance
      - Developers can only tighten domain/governance
    """
    env_config = policy.get("environments", {}).get(environment, {})
    env_thresholds = env_config.get("thresholds", {})

    # Layer 1: environment defaults
    effective = dict(env_thresholds)

    # Layer 2: domain overrides (can only be stricter)
    domain_overrides = policy.get("domain_overrides", {}).get(domain, {})
    domain_env = domain_overrides.get(environment, {})
    domain_thresholds = domain_env.get("thresholds", {})

    for evaluator, override_value in domain_thresholds.items():
        current = effective.get(evaluator, 0.0)
        effective[evaluator] = max(current, override_value)

    # Layer 3: developer-declared thresholds (can only raise, never lower)
    if developer_thresholds:
        for evaluator, dev_value in developer_thresholds.items():
            current = effective.get(evaluator, 0.0)
            # Developer can only make it stricter — max() ensures they can't lower
            effective[evaluator] = max(current, dev_value)

    return effective


def check_gate(
    policy: dict,
    scores: dict,
    red_team: dict,
    environment: str,
    domain: str,
) -> dict:
    """
    Run the graduation gate check.
    Returns a graduation report dict with result: PASS or FAIL.
    """
    env_config = policy.get("environments", {}).get(environment, {})

    # Extract developer-declared thresholds if present in scores metadata
    developer_thresholds = scores.get("developer_thresholds")

    effective_thresholds = resolve_effective_thresholds(
        policy, environment, domain, developer_thresholds
    )

    failures: list[str] = []
    all_agent_scores: dict[str, dict] = {}

    # Check evaluation scores for each agent
    agents = scores.get("agents", {})
    for agent_name, agent_data in agents.items():
        agent_scores = agent_data.get("scores", {})
        all_agent_scores[agent_name] = agent_scores

        if agent_data.get("status") == "error":
            failures.append(f"{agent_name}: evaluation failed with error: {agent_data.get('error', 'unknown')}")
            continue

        for evaluator, threshold in effective_thresholds.items():
            score = agent_scores.get(evaluator)
            if score is None:
                # Evaluator not scored — only fail if threshold is > 0
                if threshold > 0:
                    failures.append(
                        f"{agent_name}.{evaluator}: not scored (threshold requires >= {threshold})"
                    )
            elif score < threshold:
                failures.append(
                    f"{agent_name}.{evaluator}: {score:.3f} < {threshold:.3f} (below threshold by {threshold - score:.3f})"
                )

    # Check red-team results
    red_team_required = env_config.get("red_team_required", False)
    red_team_max_failures = env_config.get("red_team_max_failures", 0)

    if red_team_required and not red_team.get("skipped", False):
        red_team_failures = red_team.get("failed", 0)
        if red_team_failures > red_team_max_failures:
            failures.append(
                f"red-team: {red_team_failures} failures (max allowed: {red_team_max_failures})"
            )

    # Build graduation report
    result = "PASS" if not failures else "FAIL"

    report = {
        "report_id": str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "environment": environment,
        "domain": domain,
        "result": result,
        "thresholds_applied": effective_thresholds,
        "evaluation_scores": all_agent_scores,
        "red_team_results": {
            "required": red_team_required,
            "total_tests": red_team.get("total_tests", 0),
            "passed": red_team.get("passed", 0),
            "failed": red_team.get("failed", 0),
        },
        "failure_reasons": failures if failures else None,
    }

    return report


def main():
    parser = argparse.ArgumentParser(description="Graduation Gate Check")
    parser.add_argument("--policy", required=True, help="Path to graduation-policy.yaml")
    parser.add_argument("--scores", required=True, help="Path to evaluation-scores.json")
    parser.add_argument("--red-team", required=True, help="Path to red-team-results.json")
    parser.add_argument("--environment", required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--output", required=True, help="Output graduation-report.json path")
    parser.add_argument("--image-tag", default="", help="Image tag being evaluated")
    parser.add_argument("--reports-bucket", default="", help="S3 bucket for graduation reports")
    parser.add_argument("--lifecycle-table", default="", help="DynamoDB lifecycle table name")
    parser.add_argument("--region", default="us-east-1")
    args = parser.parse_args()

    policy = load_policy(args.policy)
    scores = load_scores(args.scores)
    red_team = load_red_team(args.red_team)

    report = check_gate(policy, scores, red_team, args.environment, args.domain)

    # Enrich report with image tag
    if args.image_tag:
        report["image_tag"] = args.image_tag

    # Write report locally (for pipeline artifact)
    with open(args.output, "w") as f:
        json.dump(report, f, indent=2)

    # If gate passed, store report to S3 and update lifecycle
    if report["result"] == "PASS":
        if args.reports_bucket:
            store_graduation_report(report, args.reports_bucket, args.region)
        if args.lifecycle_table:
            record_graduation_in_lifecycle(
                report, args.lifecycle_table, args.domain, args.region
            )

    # Print summary
    print(f"Gate result: {report['result']}")
    if report["failure_reasons"]:
        print(f"Failures ({len(report['failure_reasons'])}):")
        for reason in report["failure_reasons"]:
            print(f"  ✗ {reason}")
    else:
        print("All thresholds met ✓")


def store_graduation_report(report: dict, bucket: str, region: str) -> None:
    """Upload graduation report to S3 for audit and lifecycle tracking."""
    s3 = boto3.client("s3", region_name=region)
    report_id = report["report_id"]
    domain = report["domain"]
    environment = report["environment"]

    key = f"graduation-reports/{domain}/{environment}/{report_id}.json"
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(report, indent=2),
        ContentType="application/json",
    )
    print(f"  Graduation report stored: s3://{bucket}/{key}")


def record_graduation_in_lifecycle(
    report: dict, table_name: str, domain: str, region: str
) -> None:
    """Record graduation report ID in the agent lifecycle DynamoDB records."""
    dynamodb = boto3.resource("dynamodb", region_name=region)
    table = dynamodb.Table(table_name)

    report_id = report["report_id"]
    timestamp = report["timestamp"]
    environment = report["environment"]
    agents = report.get("evaluation_scores", {})

    for agent_name in agents:
        try:
            response = table.get_item(Key={"agent_name": agent_name})
            item = response.get("Item")
            if item is None:
                continue

            graduation_reports = item.get("graduation_reports", [])
            graduation_reports.append({
                "report_id": report_id,
                "environment": environment,
                "timestamp": timestamp,
                "image_tag": report.get("image_tag", ""),
            })

            table.update_item(
                Key={"agent_name": agent_name},
                UpdateExpression="SET graduation_reports = :reports",
                ExpressionAttributeValues={":reports": graduation_reports},
            )
            print(f"  Lifecycle updated for {agent_name}: report_id={report_id}")
        except Exception as e:
            print(f"  WARNING: Failed to update lifecycle for {agent_name}: {e}")


if __name__ == "__main__":
    main()
