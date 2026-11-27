#!/usr/bin/env python3
"""
evaluation.yaml Parser and Schema Validator

Validates the root evaluation.yaml file in a QA evaluation repository.
Checks:
  - Required top-level fields: version, business_unit, bindings
  - Each binding has app_name and evaluators[].path
  - Referenced evaluator directories exist in the source tree
"""

import os
from pathlib import Path
from typing import Any

import yaml


class ValidationError:
    """A structured validation error with a dotted path and message."""

    def __init__(self, path: str, message: str):
        self.path = path
        self.message = message

    def __str__(self):
        return f"  [{self.path}] {self.message}"


def parse_evaluation_yaml(file_path: Path) -> tuple[dict[str, Any] | None, list[ValidationError]]:
    """Parse evaluation.yaml and return (parsed_dict, errors).

    Returns (None, [error]) if the file cannot be parsed.
    Returns (dict, []) if parsing succeeds (schema validation is separate).
    """
    errors: list[ValidationError] = []

    if not file_path.exists():
        errors.append(ValidationError("evaluation.yaml", "file not found"))
        return None, errors

    with open(file_path) as f:
        try:
            data = yaml.safe_load(f)
        except yaml.YAMLError as e:
            errors.append(ValidationError("evaluation.yaml", f"invalid YAML: {e}"))
            return None, errors

    if not isinstance(data, dict):
        errors.append(ValidationError("evaluation.yaml", "must be a YAML mapping"))
        return None, errors

    return data, errors


def validate_evaluation_yaml(data: dict[str, Any], source_dir: Path) -> list[ValidationError]:
    """Validate the schema and cross-references of a parsed evaluation.yaml.

    Args:
        data: Parsed evaluation.yaml content.
        source_dir: Root directory of the QA repo (for directory existence checks).

    Returns:
        List of validation errors (empty means valid).
    """
    errors: list[ValidationError] = []

    # Required top-level fields
    if "version" not in data:
        errors.append(ValidationError("version", "required field missing"))
    if "business_unit" not in data:
        errors.append(ValidationError("business_unit", "required field missing"))
    if "bindings" not in data:
        errors.append(ValidationError("bindings", "required field missing"))
        return errors  # Cannot validate further without bindings

    bindings = data["bindings"]
    if not isinstance(bindings, list):
        errors.append(ValidationError("bindings", "must be a list"))
        return errors

    for i, binding in enumerate(bindings):
        prefix = f"bindings[{i}]"

        if not isinstance(binding, dict):
            errors.append(ValidationError(prefix, "each binding must be a mapping"))
            continue

        # app_name required
        if "app_name" not in binding:
            errors.append(ValidationError(f"{prefix}.app_name", "required field missing"))
        app_name = binding.get("app_name", "")

        # evaluators required
        if "evaluators" not in binding:
            errors.append(ValidationError(f"{prefix}.evaluators", "required field missing"))
            continue

        evaluators = binding["evaluators"]
        if not isinstance(evaluators, list):
            errors.append(ValidationError(f"{prefix}.evaluators", "must be a list"))
            continue

        for j, evaluator in enumerate(evaluators):
            eval_prefix = f"{prefix}.evaluators[{j}]"

            if not isinstance(evaluator, dict):
                errors.append(ValidationError(eval_prefix, "each evaluator must be a mapping"))
                continue

            if "path" not in evaluator:
                errors.append(ValidationError(f"{eval_prefix}.path", "required field missing"))
                continue

            # Cross-validate: referenced directory must exist
            eval_path = evaluator["path"]
            full_path = source_dir / eval_path
            if not full_path.is_dir():
                errors.append(ValidationError(
                    f"{eval_prefix}.path",
                    f"referenced directory does not exist: '{eval_path}'"
                ))

    return errors
