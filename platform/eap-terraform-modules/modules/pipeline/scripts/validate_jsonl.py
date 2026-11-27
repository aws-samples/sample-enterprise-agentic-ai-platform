#!/usr/bin/env python3
"""
JSONL Validation with Line-Level Error Reporting

Validates test-cases.jsonl files:
  - Each line must be valid JSON
  - Each line must have an 'input' field
  - Each line must have at least one reference field (not 'input')
  - Empty files (0 lines) are rejected

Reports line number and parse error for malformed lines.
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


# The input field is required but not counted as a reference field
_NON_REFERENCE_FIELDS = {"input"}


def validate_jsonl(
    file_path: Path,
    context_path: str = "",
) -> tuple[list[dict[str, Any]], list[ValidationError]]:
    """Validate a test-cases.jsonl file and return (parsed_records, errors).

    Args:
        file_path: Path to the JSONL file on disk.
        context_path: Optional context prefix for error messages.

    Returns:
        Tuple of (valid_records, errors). Records are returned even if some
        lines fail, to support downstream cross-validation on valid lines.
    """
    errors: list[ValidationError] = []
    records: list[dict[str, Any]] = []
    label = context_path or str(file_path)

    if not file_path.exists():
        errors.append(ValidationError(label, "file not found"))
        return records, errors

    with open(file_path) as f:
        lines = f.readlines()

    # Reject empty files
    non_empty_lines = [line for line in lines if line.strip()]
    if not non_empty_lines:
        errors.append(ValidationError(label, "must contain at least one test case"))
        return records, errors

    for line_num, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped:
            continue  # Skip blank lines

        # Parse JSON
        try:
            record = json.loads(stripped)
        except json.JSONDecodeError as e:
            errors.append(ValidationError(
                f"{label} line {line_num}",
                f"{e.msg}"
            ))
            continue

        # Must be a JSON object
        if not isinstance(record, dict):
            errors.append(ValidationError(
                f"{label} line {line_num}",
                "must be a JSON object"
            ))
            continue

        # Must have 'input' field
        if "input" not in record:
            errors.append(ValidationError(
                f"{label} line {line_num}",
                "missing required field 'input'"
            ))
            continue

        # Must have at least one reference field
        reference_fields = set(record.keys()) - _NON_REFERENCE_FIELDS
        if not reference_fields:
            errors.append(ValidationError(
                f"{label} line {line_num}",
                "must have at least one reference field (e.g., 'expected_response', 'assertions')"
            ))
            continue

        records.append(record)

    return records, errors
