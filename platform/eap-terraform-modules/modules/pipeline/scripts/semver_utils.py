#!/usr/bin/env python3
"""
Semantic Version Utilities

Centralized semver parsing, comparison, and validation for Agent School.
Used by QA/Prod triggers, pipeline lifecycle hooks, and build stages
to enforce version ordering and validate version strings.

Version format: MAJOR.MINOR.PATCH (e.g., "1.2.0")
- No leading zeros allowed (e.g., "01.2.0" is invalid)
- All components must be non-negative integers
"""

import re
import sys
from typing import Tuple


# Strict semver pattern: three non-negative integers, no leading zeros
_SEMVER_PATTERN = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")


def parse_version(version_str: str) -> Tuple[int, int, int]:
    """
    Parse 'MAJOR.MINOR.PATCH' into a tuple of integers.

    Args:
        version_str: Version string in MAJOR.MINOR.PATCH format.

    Returns:
        Tuple of (major, minor, patch) integers.

    Raises:
        ValueError: If the string is not valid semver format.
    """
    if not is_valid_semver(version_str):
        raise ValueError(
            f"Invalid version format: '{version_str}'. Expected MAJOR.MINOR.PATCH "
            f"(e.g., '1.2.0') with no leading zeros."
        )
    parts = version_str.split(".")
    return (int(parts[0]), int(parts[1]), int(parts[2]))


def is_valid_semver(version_str: str) -> bool:
    """
    Return True if string is valid MAJOR.MINOR.PATCH format.

    Validates:
    - Exactly three dot-separated components
    - Each component is a non-negative integer
    - No leading zeros (e.g., "01.2.0" is invalid, "0.2.0" is valid)

    Args:
        version_str: String to validate.

    Returns:
        True if valid semver, False otherwise.
    """
    if not isinstance(version_str, str):
        return False
    return _SEMVER_PATTERN.match(version_str) is not None


def compare_versions(v1: str, v2: str) -> int:
    """
    Compare two semantic version strings.

    Comparison follows standard semver precedence:
    MAJOR has highest precedence, then MINOR, then PATCH.

    Args:
        v1: First version string.
        v2: Second version string.

    Returns:
        -1 if v1 < v2, 0 if v1 == v2, 1 if v1 > v2.

    Raises:
        ValueError: If either version string is invalid.
    """
    parsed_v1 = parse_version(v1)
    parsed_v2 = parse_version(v2)

    if parsed_v1 < parsed_v2:
        return -1
    elif parsed_v1 > parsed_v2:
        return 1
    else:
        return 0


def is_higher_version(new_version: str, current_version: str) -> bool:
    """
    Return True if new_version is strictly greater than current_version.

    Uses standard semantic versioning precedence for comparison.

    Args:
        new_version: The candidate version to deploy.
        current_version: The currently deployed version.

    Returns:
        True if new_version > current_version, False otherwise.

    Raises:
        ValueError: If either version string is invalid.
    """
    return compare_versions(new_version, current_version) == 1


def main():
    """CLI interface for version validation and comparison."""
    if len(sys.argv) < 3:
        print("Usage:")
        print("  python semver_utils.py validate <version>")
        print("  python semver_utils.py compare <v1> <v2>")
        sys.exit(1)

    command = sys.argv[1]

    if command == "validate":
        version = sys.argv[2]
        if is_valid_semver(version):
            major, minor, patch = parse_version(version)
            print(f"✓ Valid semver: {version} (major={major}, minor={minor}, patch={patch})")
        else:
            print(f"✗ Invalid semver: '{version}'")
            sys.exit(1)

    elif command == "compare":
        if len(sys.argv) < 4:
            print("Usage: python semver_utils.py compare <v1> <v2>")
            sys.exit(1)
        v1 = sys.argv[2]
        v2 = sys.argv[3]
        try:
            result = compare_versions(v1, v2)
            if result == -1:
                print(f"{v1} < {v2}")
            elif result == 0:
                print(f"{v1} == {v2}")
            else:
                print(f"{v1} > {v2}")
        except ValueError as e:
            print(f"✗ {e}")
            sys.exit(1)

    else:
        print(f"Unknown command: {command}")
        print("Valid commands: validate, compare")
        sys.exit(1)


if __name__ == "__main__":
    main()
