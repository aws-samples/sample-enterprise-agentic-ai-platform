#!/usr/bin/env python3
"""
QA Evaluation Repo Validator — Entrypoint

Runs all validation checks against a QA evaluation repository source directory:
  1. Parse and validate evaluation.yaml (schema + cross-refs)
  2. Validate each evaluator.yaml (required fields, types)
  3. Validate each test-cases.jsonl (JSONL format, required fields)
  4. Cross-validate placeholders (rubric placeholders vs JSONL fields)
  5. Validate red-team/*.json schema
  6. Warn on unconventional file paths

Usage:
  python3 validate_qa_repo.py <source-directory>

Exits 0 on valid (with optional warnings printed to stderr).
Exits 1 on any validation error.
"""

import json
import sys
from pathlib import Path

from validate_evaluation_yaml import parse_evaluation_yaml, validate_evaluation_yaml
from validate_evaluator_yaml import parse_evaluator_yaml, validate_evaluator_yaml
from validate_jsonl import validate_jsonl
from validate_placeholders import extract_placeholders, cross_validate_placeholders
from validate_red_team import validate_red_team_file
from validate_conventions import find_unconventional_files


def main():
    if len(sys.argv) < 2:
        print("Usage: validate_qa_repo.py <source-directory>")
        sys.exit(1)

    source_dir = Path(sys.argv[1])
    if not source_dir.is_dir():
        print(f"ERROR: Not a directory: {source_dir}")
        sys.exit(1)

    all_errors: list = []
    all_warnings: list = []

    # --- 1. Parse and validate evaluation.yaml ---
    eval_yaml_path = source_dir / "evaluation.yaml"
    data, parse_errors = parse_evaluation_yaml(eval_yaml_path)
    all_errors.extend(parse_errors)

    bindings: list = []
    if data is not None:
        schema_errors = validate_evaluation_yaml(data, source_dir)
        all_errors.extend(schema_errors)

        if not schema_errors:
            bindings = data.get("bindings", [])

    # --- 2 & 3 & 4. For each binding, validate evaluator + test-cases + placeholders ---
    for binding in bindings:
        if not isinstance(binding, dict):
            continue

        app_name = binding.get("app_name", "")
        evaluators = binding.get("evaluators", [])

        for evaluator_ref in evaluators:
            if not isinstance(evaluator_ref, dict):
                continue

            eval_dir = evaluator_ref.get("path", "")
            if not eval_dir:
                continue

            evaluator_yaml_path = source_dir / eval_dir / "evaluator.yaml"
            test_cases_path = source_dir / eval_dir / "test-cases.jsonl"
            context_prefix = f"{eval_dir}"

            # Validate evaluator.yaml
            evaluator_data, eval_parse_errors = parse_evaluator_yaml(evaluator_yaml_path)
            all_errors.extend(eval_parse_errors)

            declared_placeholders: set = set()
            if evaluator_data is not None:
                eval_schema_errors = validate_evaluator_yaml(
                    evaluator_data, context_path=f"{context_prefix}/evaluator.yaml"
                )
                all_errors.extend(eval_schema_errors)

                # Extract placeholders from rubric (for cross-validation)
                if not eval_schema_errors and "scoring_rubric" in evaluator_data:
                    declared_placeholders = extract_placeholders(evaluator_data["scoring_rubric"])

                    # If explicit placeholders declared, use those instead
                    if "placeholders" in evaluator_data and isinstance(evaluator_data["placeholders"], list):
                        declared_placeholders = set(evaluator_data["placeholders"])

            # Validate test-cases.jsonl
            records, jsonl_errors = validate_jsonl(
                test_cases_path, context_path=f"{context_prefix}/test-cases.jsonl"
            )
            all_errors.extend(jsonl_errors)

            # Cross-validate placeholders
            if declared_placeholders and records:
                placeholder_errors = cross_validate_placeholders(
                    declared_placeholders, records,
                    context_path=f"{context_prefix}/test-cases.jsonl"
                )
                all_errors.extend(placeholder_errors)

    # --- 5. Validate red-team/*.json ---
    red_team_dir = source_dir / "red-team"
    if red_team_dir.is_dir():
        for rt_file in sorted(red_team_dir.glob("*.json")):
            rt_errors = validate_red_team_file(
                rt_file, context_path=f"red-team/{rt_file.name}"
            )
            all_errors.extend(rt_errors)

    # --- 6. Warn on unconventional file paths ---
    all_warnings = find_unconventional_files(source_dir)

    # --- Output results ---
    if all_warnings:
        print(f"WARNINGS — {len(all_warnings)} file(s) outside conventions:", file=sys.stderr)
        for w in all_warnings:
            print(str(w), file=sys.stderr)

    if all_errors:
        print(f"VALIDATION FAILED — {len(all_errors)} error(s):")
        for err in all_errors:
            print(str(err))
        # JSON output for programmatic consumption
        print("\n--- JSON ---")
        print(json.dumps(
            [{"path": e.path, "message": e.message} for e in all_errors],
            indent=2
        ))
        sys.exit(1)
    else:
        print("VALIDATION PASSED ✓")
        if all_warnings:
            print(f"  ({len(all_warnings)} warning(s) — see stderr)")
        sys.exit(0)


if __name__ == "__main__":
    main()
