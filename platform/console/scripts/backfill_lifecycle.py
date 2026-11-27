#!/usr/bin/env python3
"""
Backfill the agent-school-lifecycle DynamoDB table from live AgentCore runtimes.
Queries `aws bedrock-agentcore-control list-agent-runtimes` and writes each
runtime as a lifecycle record spread across stages: 50% dev, 30% UAT, 20% prod.
"""
import json
import subprocess
import sys
from datetime import datetime

import boto3

TABLE_NAME = "agent-school-lifecycle-team-bu-1-dev"
REGION = "us-east-1"


def get_runtimes():
    result = subprocess.run(
        ["aws", "bedrock-agentcore-control", "list-agent-runtimes",
         "--region", REGION, "--output", "json"],
        capture_output=True, text=True, check=True
    )
    data = json.loads(result.stdout)
    return data.get("agentRuntimes", [])


def backfill():
    runtimes = get_runtimes()
    total = len(runtimes)
    print(f"Found {total} agent runtimes. Writing to {TABLE_NAME}...")
    print(f"  Distribution: ~{int(total*0.5)} dev, ~{int(total*0.3)} validated (UAT), ~{int(total*0.2)} production")

    # Sort by name for deterministic assignment
    runtimes.sort(key=lambda r: r["agentRuntimeName"])

    # Assign stages: first 50% = enrolled (dev), next 30% = validated (UAT), last 20% = production
    prod_cutoff = int(total * 0.2)
    uat_cutoff = prod_cutoff + int(total * 0.3)
    # rest = dev

    dynamodb = boto3.resource("dynamodb", region_name=REGION)
    table = dynamodb.Table(TABLE_NAME)

    for i, rt in enumerate(runtimes):
        name = rt["agentRuntimeName"]

        if i < prod_cutoff:
            stage = "production"
        elif i < uat_cutoff:
            stage = "validated"
        else:
            stage = "enrolled"

        item = {
            "agent_name": name,
            "current_state": stage,
            "version": str(rt.get("agentRuntimeVersion", "1")),
            "commit_sha": "deployed",
            "last_transition": rt.get("lastUpdatedAt", datetime.utcnow().isoformat()),
            "runtime_id": rt.get("agentRuntimeId", ""),
            "runtime_arn": rt.get("agentRuntimeArn", ""),
            "description": rt.get("description", ""),
            "status": rt.get("status", "UNKNOWN"),
            "domain": "team-bu-1",
            "state_history": [],
            "graduation_reports": [],
        }

        # Add eval scores for UAT and prod agents
        if stage in ("validated", "production"):
            import random
            random.seed(hash(name))
            item["eval_score"] = str(round(random.uniform(0.75, 0.98), 2))  # nosec B311 - non-crypto random generating fake demo eval scores for backfilled test data.
            item["red_team_pass"] = True
            item["last_evaluated"] = rt.get("lastUpdatedAt", "")

        table.put_item(Item=item)
        print(f"  ✓ {name} → {stage} (v{item['version']})")

    print(f"\nDone. {total} agents written to {TABLE_NAME}.")


if __name__ == "__main__":
    backfill()
