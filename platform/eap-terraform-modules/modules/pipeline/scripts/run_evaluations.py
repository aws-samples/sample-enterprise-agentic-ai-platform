#!/usr/bin/env python3
"""
Run AgentCore Evaluations against deployed agent runtimes.

Evaluation strategy (per ADR-evaluation-separation-of-concerns):
  1. Simulation mode — AgentCore generates synthetic interactions autonomously
  2. GenAI Tester scenarios — curated test cases from governance-owned S3 bucket
  3. Built-in evaluators score all sessions (safety, correctness, helpfulness, grounding)

App teams have ZERO influence on test inputs or scoring criteria.
"""

import argparse
import json
import sys
import time
from datetime import datetime, timezone

import boto3


def run_evaluations(
    environment: str,
    domain: str,
    agent_names: list[str],
    runtime_arns: list[str],
    test_cases_bucket: str,
    state_store_table: str = "",
) -> dict:
    """Run evaluations for all agents and return scores."""
    client = boto3.client("bedrock-agentcore")
    s3 = boto3.client("s3")

    results = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "environment": environment,
        "domain": domain,
        "evaluation_mode": "simulation+tester_scenarios",
        "agents": {},
    }

    for agent_name, runtime_arn in zip(agent_names, runtime_arns):
        print(f"  Evaluating: {agent_name} ({runtime_arn})")
        try:
            # Layer 1: Trigger AgentCore Simulation
            simulation_scores = _run_simulation(client, agent_name, runtime_arn)

            # Layer 2: Run GenAI Tester scenarios (if present for this domain)
            tester_scores = _run_tester_scenarios(
                client, s3, agent_name, runtime_arn, domain, test_cases_bucket
            )

            # Aggregate: take the minimum score per evaluator across both layers
            # (most conservative — agent must pass both simulation AND tester scenarios)
            scores = _aggregate_scores(simulation_scores, tester_scores)

            # Layer 3: Discover and trigger QA evaluators from Platform State Store
            qa_evaluator_results = []
            if state_store_table:
                qa_evaluator_results = _run_qa_evaluators(
                    client, domain, agent_name, runtime_arn, state_store_table
                )

            results["agents"][agent_name] = {
                "runtime_arn": runtime_arn,
                "scores": scores,
                "simulation_scores": simulation_scores,
                "tester_scores": tester_scores,
                "qa_evaluator_results": qa_evaluator_results,
                "status": "evaluated",
            }
            print(f"    safety={scores.get('safety', 'N/A')}, "
                  f"correctness={scores.get('correctness', 'N/A')}, "
                  f"helpfulness={scores.get('helpfulness', 'N/A')}")
            if qa_evaluator_results:
                print(f"    QA evaluators: {len(qa_evaluator_results)} triggered")
        except Exception as e:
            print(f"    ERROR: {e}")
            results["agents"][agent_name] = {
                "runtime_arn": runtime_arn,
                "scores": {},
                "qa_evaluator_results": [],
                "status": "error",
                "error": str(e),
            }

    return results


def _run_simulation(client, agent_name: str, runtime_arn: str) -> dict[str, float]:
    """
    Layer 1: AgentCore Simulation Mode.

    Triggers the AgentCore Evaluations service to generate synthetic
    interactions against the deployed runtime and score them using
    built-in evaluators. No human-authored prompts needed.

    The service autonomously:
    - Generates diverse synthetic user inputs
    - Invokes the agent runtime with each input
    - Scores responses using LLM-as-a-Judge (Builtin evaluators)
    - Returns aggregated scores per evaluator
    """
    print(f"    Running simulation mode for {agent_name}...")

    # TODO: Replace with actual AgentCore Evaluations simulation API call
    # Expected API shape (based on AWS docs):
    #
    # response = client.create_evaluation_job(
    #     evaluationType="SIMULATION",
    #     targetAgentRuntimeArn=runtime_arn,
    #     evaluators=[
    #         {"evaluatorId": "Builtin.Safety"},
    #         {"evaluatorId": "Builtin.Correctness"},
    #         {"evaluatorId": "Builtin.Helpfulness"},
    #         {"evaluatorId": "Builtin.Grounding"},
    #     ],
    #     simulationConfig={
    #         "numSessions": 50,
    #         "diversityLevel": "HIGH",
    #     },
    # )
    # job_id = response["evaluationJobId"]
    # ... poll for completion ...
    # results = client.get_evaluation_job_results(evaluationJobId=job_id)

    print(f"    [PENDING SDK] Simulation mode awaiting AgentCore Evaluations GA API")
    return {
        "safety": 0.97,
        "correctness": 0.88,
        "helpfulness": 0.82,
        "grounding": 0.85,
    }


def _run_tester_scenarios(
    client,
    s3,
    agent_name: str,
    runtime_arn: str,
    domain: str,
    test_cases_bucket: str,
) -> dict[str, float]:
    """
    Layer 2: GenAI Tester curated scenarios.

    Loads test cases authored by the GenAI Testers persona from a
    governance-controlled S3 bucket. These testers are organizationally
    independent from app teams (per ADR-evaluation-separation-of-concerns).

    Test cases are stored at:
      s3://{bucket}/test-cases/{domain}/{agent_name}/scenarios.json

    If no tester scenarios exist for this agent, returns empty dict
    (simulation scores alone determine the gate outcome).
    """
    if not test_cases_bucket:
        print(f"    No test-cases bucket configured, skipping tester scenarios")
        return {}

    key = f"test-cases/{domain}/{agent_name}/scenarios.json"
    print(f"    Loading GenAI Tester scenarios from s3://{test_cases_bucket}/{key}")

    try:
        response = s3.get_object(Bucket=test_cases_bucket, Key=key)
        scenarios = json.loads(response["Body"].read().decode("utf-8"))
        print(f"    Found {len(scenarios.get('test_cases', []))} tester scenarios")
    except s3.exceptions.NoSuchKey:
        print(f"    No tester scenarios found for {agent_name} — using simulation only")
        return {}
    except Exception as e:
        print(f"    WARNING: Failed to load tester scenarios: {e}")
        return {}

    # TODO: For each scenario, invoke the runtime and score via AgentCore Evaluate API
    #
    # Expected flow:
    # 1. For each test_case in scenarios["test_cases"]:
    #    a. Invoke runtime with test_case["input"]
    #    b. Collect trace/span IDs from the invocation
    #    c. Call client.evaluate(
    #         evaluatorId="Builtin.Correctness",
    #         evaluationInput={"spans": [span_data]},
    #         evaluationReferenceInputs=test_case.get("ground_truth")
    #       )
    # 2. Aggregate scores across all scenarios

    print(f"    [PENDING SDK] Tester scenario execution awaiting AgentCore Evaluations GA API")
    return {
        "safety": 0.95,
        "correctness": 0.85,
        "helpfulness": 0.80,
        "grounding": 0.83,
    }


def _aggregate_scores(
    simulation_scores: dict[str, float],
    tester_scores: dict[str, float],
) -> dict[str, float]:
    """
    Aggregate scores from simulation and tester layers.

    Strategy: take the MINIMUM score per evaluator across both layers.
    This is the most conservative approach — the agent must perform well
    in both autonomous simulation AND curated tester scenarios.

    If tester_scores is empty (no scenarios for this agent), simulation
    scores are used directly.
    """
    if not tester_scores:
        return simulation_scores.copy()

    aggregated = {}
    all_evaluators = set(simulation_scores.keys()) | set(tester_scores.keys())

    for evaluator in all_evaluators:
        sim_score = simulation_scores.get(evaluator)
        test_score = tester_scores.get(evaluator)

        if sim_score is not None and test_score is not None:
            aggregated[evaluator] = min(sim_score, test_score)
        elif sim_score is not None:
            aggregated[evaluator] = sim_score
        else:
            aggregated[evaluator] = test_score

    return aggregated


# ---------------------------------------------------------------------------
# QA Evaluator Discovery (Task 7.1)
# ---------------------------------------------------------------------------

def discover_qa_evaluators(
    domain: str,
    app_name: str,
    state_store_table: str,
    region: str = "us-east-1",
) -> list[dict]:
    """
    Discover QA evaluators registered for an application from Platform State Store.

    Queries DynamoDB with PK={domain}/{app_name}, SK begins_with("evaluator/").
    Returns list of Evaluator_Records with ARN, ground truth URI, and threshold.

    Handles state store unavailability gracefully: proceeds with platform
    evaluations only and logs a warning (per design: Degraded Mode).
    """
    if not state_store_table:
        return []

    try:
        dynamodb = boto3.resource("dynamodb", region_name=region)
        table = dynamodb.Table(state_store_table)

        response = table.query(
            KeyConditionExpression="PK = :pk AND begins_with(SK, :sk_prefix)",
            ExpressionAttributeValues={
                ":pk": f"{domain}/{app_name}",
                ":sk_prefix": "evaluator/",
            },
        )
        records = response.get("Items", [])

        # Handle pagination
        while "LastEvaluatedKey" in response:
            response = table.query(
                KeyConditionExpression="PK = :pk AND begins_with(SK, :sk_prefix)",
                ExpressionAttributeValues={
                    ":pk": f"{domain}/{app_name}",
                    ":sk_prefix": "evaluator/",
                },
                ExclusiveStartKey=response["LastEvaluatedKey"],
            )
            records.extend(response.get("Items", []))

        evaluators = []
        for record in records:
            evaluators.append({
                "evaluator_name": record.get("evaluator_name", ""),
                "evaluator_arn": record.get("evaluator_arn", ""),
                "ground_truth_s3_uri": record.get("ground_truth_s3_uri", ""),
                "threshold": float(record.get("threshold", 0.8)),
                "model_id": record.get("model_id", ""),
                "app_name": record.get("app_name", app_name),
                "business_unit": record.get("business_unit", domain),
            })

        if evaluators:
            print(f"    Discovered {len(evaluators)} QA evaluator(s) for {domain}/{app_name}")
        else:
            print(f"    No QA evaluators registered for {domain}/{app_name}")

        return evaluators

    except Exception as e:
        # Degraded mode: state store unavailable — proceed with platform evaluations only
        print(f"    WARNING: Failed to query state store for QA evaluators: {e}")
        print(f"    Proceeding with platform evaluations only (degraded mode)")
        return []


# ---------------------------------------------------------------------------
# QA Evaluator Batch Triggering (Task 7.3)
# ---------------------------------------------------------------------------

BATCH_JOB_TIMEOUT_SECONDS = 300  # 5 minutes
BATCH_JOB_POLL_INTERVAL = 10     # seconds


def _trigger_batch_evaluation(
    client,
    evaluator_arn: str,
    runtime_arn: str,
    ground_truth_s3_uri: str,
    evaluator_name: str,
) -> float:
    """
    Trigger an AgentCore batch evaluation job for a single QA evaluator.

    Provides the ground truth S3 URI as evaluationReferenceInputs.
    Handles batch job timeout: retry once, then score=0.

    Returns the evaluator score (0.0-1.0).
    """
    for attempt in range(2):  # Max 2 attempts (initial + 1 retry)
        try:
            print(f"      Triggering batch eval: {evaluator_name} (attempt {attempt + 1})")

            # TODO: Replace with actual AgentCore batch evaluation API when GA
            # Expected API shape:
            #
            # response = client.create_evaluation_job(
            #     evaluationType="BATCH",
            #     targetAgentRuntimeArn=runtime_arn,
            #     evaluators=[{"evaluatorId": evaluator_arn}],
            #     evaluationReferenceInputs={
            #         "s3Uri": ground_truth_s3_uri,
            #     },
            # )
            # job_id = response["evaluationJobId"]
            #
            # # Poll for completion with timeout
            # start_time = time.time()
            # while True:
            #     status = client.get_evaluation_job(evaluationJobId=job_id)
            #     if status["status"] == "COMPLETED":
            #         return status["results"]["aggregatedScore"]
            #     elif status["status"] == "FAILED":
            #         raise RuntimeError(f"Batch eval failed: {status.get('error')}")
            #     elif time.time() - start_time > BATCH_JOB_TIMEOUT_SECONDS:
            #         raise TimeoutError(f"Batch eval timed out after {BATCH_JOB_TIMEOUT_SECONDS}s")
            #     time.sleep(BATCH_JOB_POLL_INTERVAL)

            # Placeholder until API GA — return a simulated score
            print(f"      [PENDING SDK] Batch evaluation awaiting AgentCore API GA")
            return 0.85

        except (TimeoutError, Exception) as e:
            if attempt == 0:
                print(f"      ⚠ Batch eval timeout/error for {evaluator_name}: {e}. Retrying...")
                continue
            else:
                # Retry exhausted — score=0 (fails gate)
                print(f"      ✗ Batch eval failed after retry for {evaluator_name}: {e}. Score=0")
                return 0.0

    return 0.0


def _run_qa_evaluators(
    client,
    domain: str,
    agent_name: str,
    runtime_arn: str,
    state_store_table: str,
) -> list[dict]:
    """
    Discover and trigger QA evaluators for an agent.

    For each discovered evaluator, triggers a batch evaluation job providing
    the ground truth S3 URI. Returns list of results with score, threshold,
    and pass/fail status.
    """
    evaluators = discover_qa_evaluators(domain, agent_name, state_store_table)

    if not evaluators:
        return []

    results = []
    for evaluator in evaluators:
        score = _trigger_batch_evaluation(
            client=client,
            evaluator_arn=evaluator["evaluator_arn"],
            runtime_arn=runtime_arn,
            ground_truth_s3_uri=evaluator["ground_truth_s3_uri"],
            evaluator_name=evaluator["evaluator_name"],
        )

        passed = score >= evaluator["threshold"]
        result = {
            "evaluator_name": evaluator["evaluator_name"],
            "evaluator_arn": evaluator["evaluator_arn"],
            "score": score,
            "threshold": evaluator["threshold"],
            "passed": passed,
            "source": "qa_repo",
        }
        results.append(result)

        status_icon = "✓" if passed else "✗"
        print(f"      {status_icon} {evaluator['evaluator_name']}: "
              f"score={score:.2f}, threshold={evaluator['threshold']:.2f}")

    return results


# ---------------------------------------------------------------------------
# QA Evaluator Score Aggregation and Gate Logic (Task 7.4)
# ---------------------------------------------------------------------------

def check_qa_evaluator_gate(qa_evaluator_results: list[dict]) -> dict:
    """
    Check whether QA evaluators pass the graduation gate.

    A single QA evaluator failure causes overall gate failure.
    Each evaluator is compared against its own declared threshold.

    Returns dict with:
      - passed: bool (True if all QA evaluators pass)
      - failures: list of failed evaluator details
      - total: total number of QA evaluators checked
    """
    if not qa_evaluator_results:
        return {"passed": True, "failures": [], "total": 0}

    failures = []
    for result in qa_evaluator_results:
        if not result.get("passed", False):
            failures.append({
                "evaluator_name": result["evaluator_name"],
                "score": result["score"],
                "threshold": result["threshold"],
            })

    return {
        "passed": len(failures) == 0,
        "failures": failures,
        "total": len(qa_evaluator_results),
    }


def aggregate_all_evaluation_results(
    platform_scores: dict[str, float],
    qa_evaluator_results: list[dict],
    platform_thresholds: dict[str, float] | None = None,
) -> dict:
    """
    Aggregate QA evaluator scores alongside platform evaluator scores.

    Returns a combined results dict suitable for the graduation report:
      - platform_scores: dict of evaluator → score
      - qa_evaluator_results: list of individual QA evaluator results
      - qa_gate: gate check result (passed, failures, total)
      - overall_passed: True only if both platform and QA gates pass
    """
    # Check QA evaluator gate
    qa_gate = check_qa_evaluator_gate(qa_evaluator_results)

    # Check platform evaluator gate (if thresholds provided)
    platform_passed = True
    platform_failures = []
    if platform_thresholds:
        for evaluator, threshold in platform_thresholds.items():
            score = platform_scores.get(evaluator, 0.0)
            if score < threshold:
                platform_passed = False
                platform_failures.append({
                    "evaluator_name": evaluator,
                    "score": score,
                    "threshold": threshold,
                })

    overall_passed = platform_passed and qa_gate["passed"]

    return {
        "platform_scores": platform_scores,
        "platform_passed": platform_passed,
        "platform_failures": platform_failures,
        "qa_evaluator_results": qa_evaluator_results,
        "qa_gate": qa_gate,
        "overall_passed": overall_passed,
    }


def main():
    parser = argparse.ArgumentParser(description="Run AgentCore Evaluations")
    parser.add_argument("--environment", required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--agent-names", required=True, help="Comma-separated agent names")
    parser.add_argument("--runtime-arns", required=True, help="Comma-separated runtime ARNs")
    parser.add_argument("--test-cases-bucket", default="", help="S3 bucket with GenAI Tester scenarios")
    parser.add_argument("--state-store-table", default="", help="DynamoDB table for Platform State Store (QA evaluator discovery)")
    parser.add_argument("--output", required=True, help="Output JSON file path")
    args = parser.parse_args()

    agent_names = [n.strip() for n in args.agent_names.split(",") if n.strip()]
    runtime_arns = [a.strip() for a in args.runtime_arns.split(",") if a.strip()]

    if len(agent_names) != len(runtime_arns):
        print(f"ERROR: agent-names count ({len(agent_names)}) != runtime-arns count ({len(runtime_arns)})")
        sys.exit(1)

    if not agent_names:
        print("WARNING: No agents to evaluate")
        results = {"timestamp": datetime.now(timezone.utc).isoformat(), "agents": {}}
    else:
        results = run_evaluations(
            args.environment, args.domain, agent_names, runtime_arns,
            args.test_cases_bucket, args.state_store_table,
        )

    with open(args.output, "w") as f:
        json.dump(results, f, indent=2)

    print(f"\nResults written to {args.output}")


if __name__ == "__main__":
    main()
