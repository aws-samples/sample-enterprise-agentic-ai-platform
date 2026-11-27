#!/usr/bin/env python3
"""
Register QA Evaluators

Reads Terraform outputs (evaluator ARNs) and writes/updates Evaluator_Records
in the Platform State Store DynamoDB table. Also deletes records for evaluators
that have been removed from evaluation.yaml.

Called by the QA pipeline Apply stage after successful terraform apply.

Usage:
  python3 register_qa_evaluators.py \
      --table <dynamodb_table> \
      --domain <business_unit> \
      --repo <qa_repo_name> \
      --commit-sha <sha> \
      --ground-truth-bucket <bucket> \
      --region <aws_region>
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

import boto3
import yaml
from botocore.exceptions import ClientError


# ---------------------------------------------------------------------------
# Retry with exponential backoff
# ---------------------------------------------------------------------------

DEFAULT_MAX_RETRIES = 3
DEFAULT_BACKOFF_BASE = 1.0  # seconds


def retry_with_backoff(
    func,
    max_retries: int = DEFAULT_MAX_RETRIES,
    backoff_base: float = DEFAULT_BACKOFF_BASE,
):
    """
    Retry a callable with exponential backoff on DynamoDB service unavailability.

    Retries on:
      - ProvisionedThroughputExceededException
      - InternalServerError
      - ServiceUnavailable

    Raises the last exception if retries are exhausted.
    """
    retryable_codes = {
        "ProvisionedThroughputExceededException",
        "InternalServerError",
        "ServiceUnavailable",
    }

    last_exception = None
    for attempt in range(max_retries):
        try:
            return func()
        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            if error_code not in retryable_codes:
                raise
            last_exception = e
            if attempt < max_retries - 1:
                delay = backoff_base * (2 ** attempt)
                print(f"  ⚠ Retryable error ({error_code}), attempt {attempt + 1}/{max_retries}. "
                      f"Retrying in {delay:.1f}s...")
                time.sleep(delay)

    # Retries exhausted
    print(f"  ✗ Retries exhausted after {max_retries} attempts")
    raise last_exception


# ---------------------------------------------------------------------------
# Terraform output reader
# ---------------------------------------------------------------------------

def read_terraform_outputs() -> dict:
    """Read Terraform outputs from the current directory as JSON."""
    result = subprocess.run(
        ["terraform", "output", "-json"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: terraform output failed: {result.stderr}")
        sys.exit(1)
    return json.loads(result.stdout)


# ---------------------------------------------------------------------------
# State store operations
# ---------------------------------------------------------------------------

def write_evaluator_record(
    table,
    domain: str,
    app_name: str,
    evaluator_name: str,
    evaluator_arn: str,
    ground_truth_s3_uri: str,
    threshold: float,
    model_id: str,
    source_repo: str,
    commit_sha: str,
    max_retries: int = DEFAULT_MAX_RETRIES,
    backoff_base: float = DEFAULT_BACKOFF_BASE,
) -> None:
    """Write a single Evaluator_Record to the Platform State Store."""
    # High-level resource API: plain Python values, no DynamoDB type descriptors.
    put_item = {
        "PK": f"{domain}/{app_name}",
        "SK": f"evaluator/{evaluator_name}",
        "GSI1PK": domain,
        "GSI1SK": f"{app_name}#evaluator/{evaluator_name}",
        "evaluator_arn": evaluator_arn,
        "evaluator_name": evaluator_name,
        "ground_truth_s3_uri": ground_truth_s3_uri,
        "threshold": str(threshold),
        "model_id": model_id,
        "source_repo": source_repo,
        "business_unit": domain,
        "app_name": app_name,
        "commit_sha": commit_sha,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }

    def _write():
        table.put_item(Item=put_item)

    retry_with_backoff(_write, max_retries=max_retries, backoff_base=backoff_base)


def delete_evaluator_record(
    table,
    domain: str,
    app_name: str,
    evaluator_name: str,
    max_retries: int = DEFAULT_MAX_RETRIES,
    backoff_base: float = DEFAULT_BACKOFF_BASE,
) -> None:
    """Delete an Evaluator_Record from the Platform State Store."""
    def _delete():
        table.delete_item(
            Key={
                "PK": f"{domain}/{app_name}",
                "SK": f"evaluator/{evaluator_name}",
            }
        )

    retry_with_backoff(_delete, max_retries=max_retries, backoff_base=backoff_base)


def query_existing_evaluators(table, domain: str, app_name: str) -> list:
    """Query existing evaluator records for an app from the state store."""
    response = table.query(
        KeyConditionExpression="PK = :pk AND begins_with(SK, :sk_prefix)",
        ExpressionAttributeValues={
            ":pk": f"{domain}/{app_name}",
            ":sk_prefix": "evaluator/",
        },
    )
    return response.get("Items", [])


# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

def load_evaluation_yaml(source_dir: str = ".") -> dict:
    """Load and parse evaluation.yaml from the source directory."""
    eval_path = os.path.join(source_dir, "evaluation.yaml")
    if not os.path.exists(eval_path):
        print(f"ERROR: evaluation.yaml not found at {eval_path}")
        sys.exit(1)
    with open(eval_path, "r") as f:
        return yaml.safe_load(f)


def register_evaluators(
    table_name: str,
    domain: str,
    source_repo: str,
    commit_sha: str,
    ground_truth_bucket: str,
    region: str = "us-east-1",
    max_retries: int = DEFAULT_MAX_RETRIES,
    backoff_base: float = DEFAULT_BACKOFF_BASE,
) -> dict:
    """
    Register evaluators in the Platform State Store.

    1. Read Terraform outputs to get evaluator ARNs
    2. Read evaluation.yaml to get current bindings
    3. Write records for current bindings
    4. Delete records for removed bindings
    """
    # Read Terraform outputs
    tf_outputs = read_terraform_outputs()
    evaluator_arns = tf_outputs.get("evaluator_arns", {}).get("value", {})
    evaluator_names = tf_outputs.get("evaluator_names", {}).get("value", {})

    # Read evaluation.yaml for current bindings
    eval_config = load_evaluation_yaml()
    business_unit = eval_config.get("business_unit", domain)

    # Connect to DynamoDB
    dynamodb = boto3.resource("dynamodb", region_name=region)
    table = dynamodb.Table(table_name)

    # Track what we wrote
    written = []
    deleted = []

    # Build set of current binding app names and evaluator names
    current_bindings = {}
    for binding in eval_config.get("bindings", []):
        app_name = binding["app_name"]
        evaluator_path = binding["evaluators"][0]["path"]
        evaluator_yaml_path = os.path.join(evaluator_path, "evaluator.yaml")

        if os.path.exists(evaluator_yaml_path):
            with open(evaluator_yaml_path, "r") as f:
                evaluator_def = yaml.safe_load(f)
            evaluator_name = evaluator_def["name"]
            current_bindings.setdefault(app_name, set()).add(evaluator_name)

    # Write records for current bindings
    for binding in eval_config.get("bindings", []):
        app_name = binding["app_name"]
        evaluator_path = binding["evaluators"][0]["path"]
        evaluator_yaml_path = os.path.join(evaluator_path, "evaluator.yaml")

        if not os.path.exists(evaluator_yaml_path):
            print(f"  ⚠ Skipping {app_name}: evaluator.yaml not found at {evaluator_yaml_path}")
            continue

        with open(evaluator_yaml_path, "r") as f:
            evaluator_def = yaml.safe_load(f)

        evaluator_name = evaluator_def["name"]
        model_id = evaluator_def["model_id"]
        threshold = float(evaluator_def.get("threshold", 0.8))

        # Get ARN from Terraform output
        evaluator_arn = evaluator_arns.get(app_name, "")
        if not evaluator_arn:
            print(f"  ⚠ No ARN found for {app_name} in terraform outputs, using placeholder")
            evaluator_arn = f"arn:aws:bedrock-agentcore:{region}:evaluator/{evaluator_name}"

        ground_truth_s3_uri = (
            f"s3://{ground_truth_bucket}/ground-truth/{business_unit}/{app_name}/test-cases.jsonl"
        )

        print(f"  → Writing record: {domain}/{app_name} | evaluator/{evaluator_name}")
        write_evaluator_record(
            table=table,
            domain=domain,
            app_name=app_name,
            evaluator_name=evaluator_name,
            evaluator_arn=evaluator_arn,
            ground_truth_s3_uri=ground_truth_s3_uri,
            threshold=threshold,
            model_id=model_id,
            source_repo=source_repo,
            commit_sha=commit_sha,
            max_retries=max_retries,
            backoff_base=backoff_base,
        )
        written.append(f"{domain}/{app_name}#evaluator/{evaluator_name}")

    # Delete records for removed bindings
    all_app_names = set()
    for binding in eval_config.get("bindings", []):
        all_app_names.add(binding["app_name"])

    # Query each known app for existing records and delete stale ones
    for app_name in all_app_names:
        existing_records = query_existing_evaluators(table, domain, app_name)
        current_names = current_bindings.get(app_name, set())

        for record in existing_records:
            sk = record.get("SK", "")
            # SK format: "evaluator/{name}"
            existing_name = sk.replace("evaluator/", "") if sk.startswith("evaluator/") else ""
            if existing_name and existing_name not in current_names:
                print(f"  ← Deleting stale record: {domain}/{app_name} | evaluator/{existing_name}")
                delete_evaluator_record(
                    table=table,
                    domain=domain,
                    app_name=app_name,
                    evaluator_name=existing_name,
                    max_retries=max_retries,
                    backoff_base=backoff_base,
                )
                deleted.append(f"{domain}/{app_name}#evaluator/{existing_name}")

    return {"written": written, "deleted": deleted}


def main():
    parser = argparse.ArgumentParser(
        description="Register QA evaluators in Platform State Store"
    )
    parser.add_argument("--table", required=True, help="DynamoDB state store table name")
    parser.add_argument("--domain", required=True, help="Business unit domain")
    parser.add_argument("--repo", required=True, help="QA repo name")
    parser.add_argument("--commit-sha", required=True, help="Source commit SHA")
    parser.add_argument("--ground-truth-bucket", required=True, help="S3 bucket for ground truth")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    parser.add_argument("--max-retries", type=int, default=DEFAULT_MAX_RETRIES,
                        help="Max retry attempts for DynamoDB writes")
    parser.add_argument("--backoff-base", type=float, default=DEFAULT_BACKOFF_BASE,
                        help="Base delay in seconds for exponential backoff")
    args = parser.parse_args()

    print(f"=== Registering QA evaluators ===")
    print(f"  Table:  {args.table}")
    print(f"  Domain: {args.domain}")
    print(f"  Repo:   {args.repo}")
    print(f"  Commit: {args.commit_sha}")
    print(f"  Bucket: {args.ground_truth_bucket}")

    result = register_evaluators(
        table_name=args.table,
        domain=args.domain,
        source_repo=args.repo,
        commit_sha=args.commit_sha,
        ground_truth_bucket=args.ground_truth_bucket,
        region=args.region,
        max_retries=args.max_retries,
        backoff_base=args.backoff_base,
    )

    print(f"\n=== Summary ===")
    print(f"  Written: {len(result['written'])} records")
    print(f"  Deleted: {len(result['deleted'])} records")

    if result["written"]:
        print(f"\n  Records written:")
        for r in result["written"]:
            print(f"    ✓ {r}")

    if result["deleted"]:
        print(f"\n  Records deleted:")
        for r in result["deleted"]:
            print(f"    ✗ {r}")

    print(f"\n=== Registration complete ===")


if __name__ == "__main__":
    main()
