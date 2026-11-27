#!/usr/bin/env python3
"""
Placeholder Extraction and Cross-Validation

Extracts {placeholder_name} tokens from scoring rubric strings and
cross-validates that each test-cases.jsonl record's reference fields
are a subset of the declared placeholders.
"""

import re
from typing import Any


class ValidationError:
    """A structured validation error with a dotted path and message."""

    def __init__(self, path: str, message: str):
        self.path = path
        self.message = message

    def __str__(self):
        return f"  [{self.path}] {self.message}"


# Matches {placeholder_name} tokens in rubric strings
_PLACEHOLDER_PATTERN = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}")

# The input field is not a reference placeholder — it's the test input
_NON_REFERENCE_FIELDS = {"input"}


def extract_placeholders(scoring_rubric: str) -> set[str]:
    """Extract all {placeholder_name} tokens from a scoring rubric string.

    >>> sorted(extract_placeholders("Score: {expected_response} vs {assertions}"))
    ['assertions', 'expected_response']
    """
    return set(_PLACEHOLDER_PATTERN.findall(scoring_rubric))


def cross_validate_placeholders(
    declared_placeholders: set[str],
    jsonl_records: list[dict[str, Any]],
    context_path: str = "test-cases.jsonl",
) -> list[ValidationError]:
    """Validate that each JSONL record's reference fields are a subset of declared placeholders.

    A reference field is any key in the record that is NOT 'input'.

    Args:
        declared_placeholders: Set of placeholder names declared in evaluator.yaml.
        jsonl_records: List of parsed JSON objects from test-cases.jsonl.
        context_path: File path for error reporting.

    Returns:
        List of validation errors (empty means valid).
    """
    errors: list[ValidationError] = []

    for line_num, record in enumerate(jsonl_records, start=1):
        if not isinstance(record, dict):
            continue

        reference_fields = set(record.keys()) - _NON_REFERENCE_FIELDS
        undeclared = reference_fields - declared_placeholders

        for field in sorted(undeclared):
            errors.append(ValidationError(
                f"{context_path} line {line_num}",
                f"field '{field}' not declared in evaluator.yaml placeholders"
            ))

    return errors
