#!/usr/bin/env python3
"""
Unconventional File Path Warning

Detects files in a QA evaluation repository that fall outside the known
directory conventions and emits warnings for each.

Known conventions:
  - evaluation.yaml                        (root binding file)
  - evaluations/{app}/evaluator.yaml       (evaluator definition)
  - evaluations/{app}/test-cases.jsonl     (ground truth dataset)
  - red-team/{category}.json               (domain red-team prompts)

Files outside these patterns receive a warning (not an error).
"""

import os
import re
from pathlib import Path


class ValidationWarning:
    """A structured validation warning."""

    def __init__(self, path: str, message: str):
        self.path = path
        self.message = message

    def __str__(self):
        return f"  [WARNING] {self.path}: {self.message}"


# Patterns that match known conventions (relative to repo root)
_KNOWN_PATTERNS = [
    re.compile(r"^evaluation\.yaml$"),
    re.compile(r"^evaluations/[^/]+/evaluator\.yaml$"),
    re.compile(r"^evaluations/[^/]+/test-cases\.jsonl$"),
    re.compile(r"^red-team/[^/]+\.json$"),
]

# Files/directories to always ignore (not part of convention warnings)
_IGNORED_PATTERNS = [
    re.compile(r"^\.git(/|$)"),
    re.compile(r"^\.gitignore$"),
    re.compile(r"^README\.md$"),
    re.compile(r"^LICENSE$"),
]


def is_conventional_path(rel_path: str) -> bool:
    """Check if a relative file path matches a known QA repo convention.

    >>> is_conventional_path("evaluation.yaml")
    True
    >>> is_conventional_path("evaluations/my-app/evaluator.yaml")
    True
    >>> is_conventional_path("random/file.txt")
    False
    """
    for pattern in _KNOWN_PATTERNS:
        if pattern.match(rel_path):
            return True
    return False


def is_ignored_path(rel_path: str) -> bool:
    """Check if a path should be ignored (e.g., .git, README).

    >>> is_ignored_path(".git/config")
    True
    >>> is_ignored_path("README.md")
    True
    """
    for pattern in _IGNORED_PATTERNS:
        if pattern.match(rel_path):
            return True
    return False


def find_unconventional_files(source_dir: Path) -> list[ValidationWarning]:
    """Walk the source directory and return warnings for unconventional file paths.

    Args:
        source_dir: Root directory of the QA repo.

    Returns:
        List of warnings for files outside known conventions.
    """
    warnings: list[ValidationWarning] = []

    for root, dirs, files in os.walk(source_dir):
        # Skip .git directory entirely
        if ".git" in dirs:
            dirs.remove(".git")

        for file_name in files:
            full_path = Path(root) / file_name
            rel_path = str(full_path.relative_to(source_dir))

            # Normalize path separators
            rel_path = rel_path.replace(os.sep, "/")

            if is_ignored_path(rel_path):
                continue

            if not is_conventional_path(rel_path):
                warnings.append(ValidationWarning(
                    rel_path,
                    "file is outside known QA repo conventions"
                ))

    return warnings
