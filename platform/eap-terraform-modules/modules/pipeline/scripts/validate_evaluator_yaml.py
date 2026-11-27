#!/usr/bin/env python3
"""
evaluator.yaml Schema Validator

Validates an evaluator definition YAML file within a QA evaluation repository.
Required fields: name, model_id, scoring_rubric
Optional fields: description, score_range, threshold, placeholders

Emits a specific error for each missing required field.
"""

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


REQUIRED_FIELDS = ("name", "model_id", "scoring_rubric")
OPTIONAL_FIELDS = ("description", "score_range", "threshold", "placeholders")


def parse_evaluator_yaml(file_path: Path) -> tuple[dict[str, Any] | None, list[ValidationError]]:
    """Parse evaluator.yaml and return (parsed_dict, errors).

    Returns (None, [error]) if the file cannot be parsed.
    """
    errors: list[ValidationError] = []

    if not file_path.exists():
        errors.append(ValidationError("evaluator.yaml", "file not found"))
        return None, errors

    with open(file_path) as f:
        try:
            data = yaml.safe_load(f)
        except yaml.YAMLError as e:
            errors.append(ValidationError("evaluator.yaml", f"invalid YAML: {e}"))
            return None, errors

    if not isinstance(data, dict):
        errors.append(ValidationError("evaluator.yaml", "must be a YAML mapping"))
        return None, errors

    return data, errors


def validate_evaluator_yaml(data: dict[str, Any], context_path: str = "") -> list[ValidationError]:
    """Validate evaluator.yaml schema.

    Args:
        data: Parsed evaluator.yaml content.
        context_path: Optional prefix for error paths (e.g., "evaluations/my-app/evaluator.yaml").

    Returns:
        List of validation errors (empty means valid).
    """
    errors: list[ValidationError] = []
    prefix = f"{context_path}: " if context_path else ""

    # Check required fields — emit one error per missing field
    for field in REQUIRED_FIELDS:
        if field not in data:
            errors.append(ValidationError(
                f"{prefix}{field}",
                f"missing required field '{field}'"
            ))

    # If required fields are missing, skip optional field validation
    if errors:
        return errors

    # Validate types of required fields
    if not isinstance(data["name"], str) or not data["name"].strip():
        errors.append(ValidationError(f"{prefix}name", "must be a non-empty string"))

    if not isinstance(data["model_id"], str) or not data["model_id"].strip():
        errors.append(ValidationError(f"{prefix}model_id", "must be a non-empty string"))

    if not isinstance(data["scoring_rubric"], str) or not data["scoring_rubric"].strip():
        errors.append(ValidationError(f"{prefix}scoring_rubric", "must be a non-empty string"))

    # Validate optional fields (only if present)
    if "description" in data:
        if not isinstance(data["description"], str):
            errors.append(ValidationError(f"{prefix}description", "must be a string"))

    if "score_range" in data:
        score_range = data["score_range"]
        if not isinstance(score_range, dict):
            errors.append(ValidationError(f"{prefix}score_range", "must be a mapping with 'min' and 'max'"))
        else:
            if "min" not in score_range:
                errors.append(ValidationError(f"{prefix}score_range.min", "required when score_range is specified"))
            elif not isinstance(score_range["min"], (int, float)):
                errors.append(ValidationError(f"{prefix}score_range.min", "must be a number"))

            if "max" not in score_range:
                errors.append(ValidationError(f"{prefix}score_range.max", "required when score_range is specified"))
            elif not isinstance(score_range["max"], (int, float)):
                errors.append(ValidationError(f"{prefix}score_range.max", "must be a number"))

            if ("min" in score_range and "max" in score_range
                    and isinstance(score_range["min"], (int, float))
                    and isinstance(score_range["max"], (int, float))):
                if score_range["min"] >= score_range["max"]:
                    errors.append(ValidationError(
                        f"{prefix}score_range",
                        f"min ({score_range['min']}) must be less than max ({score_range['max']})"
                    ))

    if "threshold" in data:
        if not isinstance(data["threshold"], (int, float)):
            errors.append(ValidationError(f"{prefix}threshold", "must be a number"))
        elif not (0.0 <= data["threshold"] <= 1.0):
            errors.append(ValidationError(
                f"{prefix}threshold",
                f"must be between 0.0 and 1.0 (got {data['threshold']})"
            ))

    if "placeholders" in data:
        if not isinstance(data["placeholders"], list):
            errors.append(ValidationError(f"{prefix}placeholders", "must be a list of strings"))
        else:
            for i, p in enumerate(data["placeholders"]):
                if not isinstance(p, str):
                    errors.append(ValidationError(
                        f"{prefix}placeholders[{i}]", "must be a string"
                    ))

    return errors
