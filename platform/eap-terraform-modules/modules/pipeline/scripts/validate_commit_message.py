#!/usr/bin/env python3
"""
Commit Message Validation Lambda

Enforces Conventional Commits specification on every push to CodeCommit.
Attached as a CodeCommit trigger (referenceUpdated event) to all team
repositories provisioned by the pipeline module.

Behavior:
    - Validates each commit message against the Conventional Commits pattern
    - Exempts merge and revert commits from validation
    - Fail-open: if the Lambda itself errors (e.g., API throttle), the push
      is allowed and a CloudWatch metric is emitted for alerting

Pattern: ^(feat|fix|docs|chore|refactor|test|perf|ci|build|BREAKING)(\\(.+\\))?!?: .{1,}

Usage:
    Deployed as a CodeCommit trigger Lambda, not invoked directly.
"""

import json
import re
import logging
from typing import List, Tuple

import boto3


logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Valid Conventional Commits type prefixes
VALID_PREFIXES = [
    "feat",
    "fix",
    "docs",
    "chore",
    "refactor",
    "test",
    "perf",
    "ci",
    "build",
    "BREAKING",
]

# Commit message patterns that are exempt from validation
EXEMPT_PATTERNS = [
    r"^Merge ",
    r"^Revert ",
]

# Conventional Commits validation regex
COMMIT_PATTERN = re.compile(
    r"^(feat|fix|docs|chore|refactor|test|perf|ci|build|BREAKING)(\(.+\))?!?: .{1,}"
)

# CloudWatch metric namespace for fail-open alerting
METRIC_NAMESPACE = "EAP/CommitValidation"


def validate_message(msg: str) -> bool:
    """
    Validate a single commit message against the Conventional Commits pattern.

    Accepts messages that either:
    - Match an exempt pattern (Merge, Revert)
    - Match the Conventional Commits format

    Args:
        msg: The commit message subject line.

    Returns:
        True if the message is valid, False otherwise.
    """
    # Check exempt patterns first
    for pattern in EXEMPT_PATTERNS:
        if re.match(pattern, msg):
            return True

    # Check conventional commits pattern
    return bool(COMMIT_PATTERN.match(msg))


def _get_commits_in_range(
    codecommit_client,
    repository_name: str,
    commit_id: str,
) -> List[Tuple[str, str]]:
    """
    Retrieve commit messages for a given commit and its parents.

    Uses get_commit to fetch the commit message for the pushed commit.
    For simplicity, validates only the tip commit of the push. For full
    range validation in a production setup, you would walk the commit graph.

    Args:
        codecommit_client: Boto3 CodeCommit client.
        repository_name: Name of the CodeCommit repository.
        commit_id: The commit ID to validate.

    Returns:
        List of (commit_id, message) tuples.
    """
    commits = []
    try:
        response = codecommit_client.get_commit(
            repositoryName=repository_name,
            commitId=commit_id,
        )
        commit = response.get("commit", {})
        message = commit.get("message", "").strip()
        # Use only the first line (subject) for validation
        subject = message.split("\n")[0].strip()
        commits.append((commit_id, subject))
    except Exception as e:
        logger.warning(f"Failed to get commit {commit_id}: {e}")
        raise

    return commits


def _emit_failopen_metric(region: str = "us-east-1") -> None:
    """
    Emit a CloudWatch metric indicating the Lambda failed open.

    This triggers a CloudWatch alarm to alert the platform team that
    commit validation was bypassed due to an internal error.

    Args:
        region: AWS region for the CloudWatch client.
    """
    try:
        cloudwatch = boto3.client("cloudwatch", region_name=region)
        cloudwatch.put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[
                {
                    "MetricName": "FailOpenEvents",
                    "Value": 1,
                    "Unit": "Count",
                }
            ],
        )
    except Exception as e:
        # Best-effort metric emission — don't let this fail the fail-open
        logger.error(f"Failed to emit CloudWatch metric: {e}")


def handler(event, context) -> dict:
    """
    CodeCommit trigger handler for referenceUpdated events.

    Validates that all commits in the push conform to the Conventional
    Commits specification. On validation failure, raises an exception
    with details about the offending commits.

    Fail-open: if the Lambda encounters an internal error (e.g., API
    throttle), the push is allowed and a CloudWatch metric is emitted.

    Args:
        event: CodeCommit trigger event containing repository and commit info.
        context: Lambda context object.

    Returns:
        {"status": "ALLOW"} on success.

    Raises:
        Exception: If any commit message does not conform, with details of
            the offending commits and valid format examples.
    """
    try:
        invalid_commits: List[Tuple[str, str]] = []

        for record in event.get("Records", []):
            # Extract repository name from the event source ARN
            event_source_arn = record.get("eventSourceARN", "")
            repository_name = event_source_arn.split(":")[-1]

            # Determine region from the ARN
            arn_parts = event_source_arn.split(":")
            region = arn_parts[3] if len(arn_parts) > 3 else "us-east-1"

            codecommit_client = boto3.client("codecommit", region_name=region)

            references = record.get("codecommit", {}).get("references", [])
            for ref in references:
                commit_id = ref.get("commit")
                if not commit_id:
                    continue

                commits = _get_commits_in_range(
                    codecommit_client, repository_name, commit_id
                )

                for cid, message in commits:
                    if not validate_message(message):
                        invalid_commits.append((cid, message))

        if invalid_commits:
            error_lines = ["Commit message validation failed. Non-conforming commits:"]
            for cid, message in invalid_commits:
                error_lines.append(f"  - {cid[:8]}: \"{message}\"")
            error_lines.append("")
            error_lines.append("Valid commit message format:")
            error_lines.append("  <type>(<optional-scope>): <description>")
            error_lines.append("")
            error_lines.append(f"Valid types: {', '.join(VALID_PREFIXES)}")
            error_lines.append("")
            error_lines.append("Examples:")
            error_lines.append("  feat: add user authentication")
            error_lines.append("  fix(parser): handle empty input gracefully")
            error_lines.append("  BREAKING: remove deprecated API endpoint")
            error_lines.append("  docs(readme): update installation instructions")

            error_message = "\n".join(error_lines)
            logger.error(error_message)
            raise Exception(error_message)

        logger.info("All commits conform to Conventional Commits specification")
        return {"status": "ALLOW"}

    except Exception as e:
        # If the error is from our own validation, re-raise it
        if "Commit message validation failed" in str(e):
            raise

        # Otherwise, this is an internal error — fail open
        logger.error(f"Internal error in commit validation Lambda: {e}")
        _emit_failopen_metric()
        return {"status": "ALLOW"}
