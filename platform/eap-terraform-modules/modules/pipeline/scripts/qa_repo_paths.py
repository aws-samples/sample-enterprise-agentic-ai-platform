#!/usr/bin/env python3
"""
QA Repo Path Construction Utilities

Pure functions for computing canonical paths within a QA evaluation repository
and corresponding S3 keys. These ensure consistent path derivation across the
validate, plan, and apply stages.

Path conventions:
  - Evaluator directory:  evaluations/{app_name}/
  - S3 ground truth key:  ground-truth/{bu}/{app_name}/test-cases.jsonl
  - S3 red-team key:      red-team/{bu}/{category}.json
"""


def evaluator_dir(app_name: str) -> str:
    """Return the evaluator directory path within the QA repo for a given app.

    >>> evaluator_dir("rrf-search-app")
    'evaluations/rrf-search-app/'
    """
    return f"evaluations/{app_name}/"


def evaluator_yaml_path(app_name: str) -> str:
    """Return the evaluator.yaml path for a given app.

    >>> evaluator_yaml_path("rrf-search-app")
    'evaluations/rrf-search-app/evaluator.yaml'
    """
    return f"evaluations/{app_name}/evaluator.yaml"


def test_cases_path(app_name: str) -> str:
    """Return the test-cases.jsonl path for a given app.

    >>> test_cases_path("rrf-search-app")
    'evaluations/rrf-search-app/test-cases.jsonl'
    """
    return f"evaluations/{app_name}/test-cases.jsonl"


def s3_ground_truth_key(bu: str, app_name: str) -> str:
    """Return the S3 object key for the ground truth JSONL file.

    >>> s3_ground_truth_key("team-bu-1", "rrf-search-app")
    'ground-truth/team-bu-1/rrf-search-app/test-cases.jsonl'
    """
    return f"ground-truth/{bu}/{app_name}/test-cases.jsonl"


def s3_red_team_key(bu: str, category: str) -> str:
    """Return the S3 object key for a domain red-team prompt file.

    >>> s3_red_team_key("team-bu-1", "jailbreak")
    'red-team/team-bu-1/jailbreak.json'
    """
    return f"red-team/{bu}/{category}.json"
