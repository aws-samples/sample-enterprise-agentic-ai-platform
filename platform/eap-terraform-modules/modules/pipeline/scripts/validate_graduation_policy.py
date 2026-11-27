#!/usr/bin/env python3
"""
Graduation Policy Validator

Validates a graduation-policy.yaml file against the platform schema.
Used by:
  1. The governance pipeline (on push to governance repo)
  2. The gate buildspec (sanity check before applying thresholds)

Exits 0 on valid, exits 1 on invalid with structured error output.
"""

import json
import sys
from pathlib import Path
from typing import Any

import yaml


PLATFORM_SAFETY_MINIMUM = 0.90
VALID_ENVIRONMENTS = {"dev", "qa", "uat", "prod"}
VALID_EVALUATORS = {"safety", "correctness", "helpfulness", "grounding"}


class ValidationError:
    def __init__(self, path: str, message: str):
        self.path = path
        self.message = message

    def __str__(self):
        return f"  [{self.path}] {self.message}"


def validate_graduation_policy(policy: dict[str, Any]) -> list[ValidationError]:
    """Validate a parsed graduation policy dict. Returns list of errors (empty = valid)."""
    errors: list[ValidationError] = []

    # Required top-level keys
    if "version" not in policy:
        errors.append(ValidationError("version", "required field missing"))
    if "platform_minimums" not in policy:
        errors.append(ValidationError("platform_minimums", "required field missing"))
    if "environments" not in policy:
        errors.append(ValidationError("environments", "required field missing"))
        return errors  # Can't validate further without environments

    # Platform minimums
    minimums = policy.get("platform_minimums", {})
    if "safety" not in minimums:
        errors.append(ValidationError("platform_minimums.safety", "required field missing"))
    elif not isinstance(minimums["safety"], (int, float)):
        errors.append(ValidationError("platform_minimums.safety", "must be a number"))
    elif minimums["safety"] < PLATFORM_SAFETY_MINIMUM:
        errors.append(ValidationError(
            "platform_minimums.safety",
            f"cannot be below {PLATFORM_SAFETY_MINIMUM} (got {minimums['safety']})"
        ))

    # Environments
    environments = policy.get("environments", {})
    for env_name, env_config in environments.items():
        if env_name not in VALID_ENVIRONMENTS:
            errors.append(ValidationError(
                f"environments.{env_name}",
                f"invalid environment (must be one of: {', '.join(sorted(VALID_ENVIRONMENTS))})"
            ))
            continue

        errors.extend(_validate_environment_config(env_name, env_config, minimums))

    # Domain overrides
    domain_overrides = policy.get("domain_overrides", {})
    for domain, overrides in domain_overrides.items():
        for env_name, override_config in overrides.items():
            if env_name not in VALID_ENVIRONMENTS:
                errors.append(ValidationError(
                    f"domain_overrides.{domain}.{env_name}",
                    f"invalid environment"
                ))
                continue

            # Validate override thresholds
            override_thresholds = override_config.get("thresholds", {})
            errors.extend(_validate_thresholds(
                f"domain_overrides.{domain}.{env_name}.thresholds",
                override_thresholds,
                minimums,
            ))

            # Verify overrides are stricter than environment defaults
            env_defaults = environments.get(env_name, {}).get("thresholds", {})
            for evaluator, value in override_thresholds.items():
                default_value = env_defaults.get(evaluator)
                if default_value is not None and value < default_value:
                    errors.append(ValidationError(
                        f"domain_overrides.{domain}.{env_name}.thresholds.{evaluator}",
                        f"domain override ({value}) cannot be lower than environment default ({default_value})"
                    ))

    # Custom evaluators
    custom_evaluators = policy.get("custom_evaluators", {})
    for domain, evaluators in custom_evaluators.items():
        if not isinstance(evaluators, list):
            errors.append(ValidationError(
                f"custom_evaluators.{domain}",
                "must be a list of evaluator definitions"
            ))
            continue
        for i, evaluator in enumerate(evaluators):
            prefix = f"custom_evaluators.{domain}[{i}]"
            if "name" not in evaluator:
                errors.append(ValidationError(f"{prefix}.name", "required"))
            if "lambda_arn" not in evaluator:
                errors.append(ValidationError(f"{prefix}.lambda_arn", "required"))
            if "threshold" not in evaluator:
                errors.append(ValidationError(f"{prefix}.threshold", "required"))
            elif not isinstance(evaluator["threshold"], (int, float)):
                errors.append(ValidationError(f"{prefix}.threshold", "must be a number"))
            elif not (0.0 <= evaluator["threshold"] <= 1.0):
                errors.append(ValidationError(
                    f"{prefix}.threshold",
                    f"must be between 0.0 and 1.0 (got {evaluator['threshold']})"
                ))

    return errors


def _validate_environment_config(
    env_name: str,
    config: dict[str, Any],
    minimums: dict[str, float],
) -> list[ValidationError]:
    """Validate a single environment configuration block."""
    errors: list[ValidationError] = []
    prefix = f"environments.{env_name}"

    if "thresholds" not in config:
        errors.append(ValidationError(f"{prefix}.thresholds", "required field missing"))
        return errors

    errors.extend(_validate_thresholds(f"{prefix}.thresholds", config["thresholds"], minimums))

    # red_team_max_failures must be non-negative integer if present
    if "red_team_max_failures" in config:
        val = config["red_team_max_failures"]
        if not isinstance(val, int) or val < 0:
            errors.append(ValidationError(
                f"{prefix}.red_team_max_failures",
                "must be a non-negative integer"
            ))

    return errors


def _validate_thresholds(
    prefix: str,
    thresholds: dict[str, Any],
    minimums: dict[str, float],
) -> list[ValidationError]:
    """Validate a thresholds block — all values in [0.0, 1.0], safety >= platform minimum."""
    errors: list[ValidationError] = []

    for evaluator, value in thresholds.items():
        if evaluator not in VALID_EVALUATORS:
            errors.append(ValidationError(
                f"{prefix}.{evaluator}",
                f"unknown evaluator (valid: {', '.join(sorted(VALID_EVALUATORS))})"
            ))
            continue

        if not isinstance(value, (int, float)):
            errors.append(ValidationError(f"{prefix}.{evaluator}", "must be a number"))
            continue

        if not (0.0 <= value <= 1.0):
            errors.append(ValidationError(
                f"{prefix}.{evaluator}",
                f"must be between 0.0 and 1.0 (got {value})"
            ))

        # Safety cannot be below platform minimum
        if evaluator == "safety":
            min_safety = minimums.get("safety", PLATFORM_SAFETY_MINIMUM)
            if value < min_safety:
                errors.append(ValidationError(
                    f"{prefix}.safety",
                    f"cannot be below platform minimum {min_safety} (got {value})"
                ))

    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: validate_graduation_policy.py <path-to-graduation-policy.yaml>")
        sys.exit(1)

    policy_path = Path(sys.argv[1])
    if not policy_path.exists():
        print(f"ERROR: File not found: {policy_path}")
        sys.exit(1)

    with open(policy_path) as f:
        try:
            policy = yaml.safe_load(f)
        except yaml.YAMLError as e:
            print(f"ERROR: Invalid YAML: {e}")
            sys.exit(1)

    if not isinstance(policy, dict):
        print("ERROR: Policy must be a YAML mapping (dict)")
        sys.exit(1)

    errors = validate_graduation_policy(policy)

    if errors:
        print(f"VALIDATION FAILED — {len(errors)} error(s):")
        for err in errors:
            print(str(err))
        # Output as JSON for programmatic consumption
        print("\n--- JSON ---")
        print(json.dumps([{"path": e.path, "message": e.message} for e in errors], indent=2))
        sys.exit(1)
    else:
        print("VALIDATION PASSED ✓")
        sys.exit(0)


if __name__ == "__main__":
    main()
