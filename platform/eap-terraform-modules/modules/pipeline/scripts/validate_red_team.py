#!/usr/bin/env python3
"""
Red-Team JSON Schema Validator

Validates red-team/{category}.json files in a QA evaluation repository.
Expected schema: array of objects with required fields: id, prompt, severity.
Severity must be one of: critical, high, medium.

Reports index and field for each validation error.
"""

import json
from pathlib import Path
from typing import Any


class ValidationError:
    """A structured validation error with a dotted path and message."""

    def __init__(self, path: str, message: str):
        self.path = path
        self.message = message

    def __str__(self):
        return f"  [{self.path}] {self.message}"


VALID_SEVERITIES = {"critical", "high", "medium"}
REQUIRED_PROMPT_FIELDS = ("id", "prompt", "severity")


def validate_red_team_file(
    file_path: Path,
    context_path: str = "",
) -> list[ValidationError]:
    """Validate a red-team JSON file.

    The file must contain a JSON object with a 'prompts' field that is an
    array of objects, each with 'id', 'prompt', and 'severity' fields.

    Args:
        file_path: Path to the red-team JSON file.
        context_path: Optional context prefix for error messages.

    Returns:
        List of validation errors (empty means valid).
    """
    errors: list[ValidationError] = []
    label = context_path or str(file_path)

    if not file_path.exists():
        errors.append(ValidationError(label, "file not found"))
        return errors

    with open(file_path) as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            errors.append(ValidationError(label, f"invalid JSON: {e.msg}"))
            return errors

    # The file can be either:
    # 1. An object with a "prompts" array (like the governance red-team format)
    # 2. A plain array of prompt objects
    if isinstance(data, dict):
        if "prompts" not in data:
            errors.append(ValidationError(label, "missing required field 'prompts'"))
            return errors
        prompts = data["prompts"]
    elif isinstance(data, list):
        prompts = data
    else:
        errors.append(ValidationError(label, "must be a JSON object with 'prompts' array or a JSON array"))
        return errors

    if not isinstance(prompts, list):
        errors.append(ValidationError(f"{label}.prompts", "must be an array"))
        return errors

    if not prompts:
        errors.append(ValidationError(label, "prompts array must not be empty"))
        return errors

    for i, prompt_obj in enumerate(prompts):
        prefix = f"{label} prompt[{i}]"

        if not isinstance(prompt_obj, dict):
            errors.append(ValidationError(prefix, "must be a JSON object"))
            continue

        # Check required fields
        for field in REQUIRED_PROMPT_FIELDS:
            if field not in prompt_obj:
                errors.append(ValidationError(prefix, f"missing required field '{field}'"))

        # Validate field types (only if present)
        if "id" in prompt_obj and not isinstance(prompt_obj["id"], str):
            errors.append(ValidationError(f"{prefix}.id", "must be a string"))

        if "prompt" in prompt_obj and not isinstance(prompt_obj["prompt"], str):
            errors.append(ValidationError(f"{prefix}.prompt", "must be a string"))

        if "severity" in prompt_obj:
            severity = prompt_obj["severity"]
            if not isinstance(severity, str):
                errors.append(ValidationError(f"{prefix}.severity", "must be a string"))
            elif severity not in VALID_SEVERITIES:
                errors.append(ValidationError(
                    f"{prefix}.severity",
                    f"must be one of: {', '.join(sorted(VALID_SEVERITIES))} (got '{severity}')"
                ))

    return errors
