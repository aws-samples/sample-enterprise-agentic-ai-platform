#!/usr/bin/env python3
"""
Sync Schedule Validator

Validates sync schedule values:
  - Predefined intervals: daily, weekly, monthly
  - Valid 6-field AWS cron expressions: cron(min hour dom month dow year)

Returns list of errors (empty = valid).
"""

import re
import sys
from pathlib import Path
from typing import Any


PREDEFINED_INTERVALS = {"daily", "weekly", "monthly"}

# Predefined interval to cron expression mapping
INTERVAL_TO_CRON = {
    "daily": "cron(0 0 * * ? *)",
    "weekly": "cron(0 0 ? * SUN *)",
    "monthly": "cron(0 0 1 * ? *)",
}

# AWS cron format: cron(min hour dom month dow year)
# Each field can contain: numbers, *, ?, -, /, L, W, #, or comma-separated values
CRON_PATTERN = re.compile(
    r'^cron\(\s*'
    r'([0-9\*\?\-\/\,LW#]+)\s+'   # minute
    r'([0-9\*\?\-\/\,LW#]+)\s+'   # hour
    r'([0-9\*\?\-\/\,LW#]+)\s+'   # day-of-month
    r'([0-9\*\?\-\/\,LW#A-Za-z]+)\s+'  # month (can have JAN-DEC)
    r'([0-9\*\?\-\/\,LW#A-Za-z]+)\s+'  # day-of-week (can have SUN-SAT)
    r'([0-9\*\?\-\/\,]+)'         # year
    r'\s*\)$'
)


def validate_sync_schedule(schedule: str) -> list[str]:
    """
    Validate a sync schedule string.
    Returns list of error messages (empty = valid).
    """
    errors: list[str] = []

    if not isinstance(schedule, str) or not schedule.strip():
        errors.append("sync_schedule must be a non-empty string")
        return errors

    schedule = schedule.strip()

    # Check predefined intervals
    if schedule in PREDEFINED_INTERVALS:
        return []

    # Check cron expression format
    if schedule.startswith("cron(") and schedule.endswith(")"):
        if not CRON_PATTERN.match(schedule):
            errors.append(
                f"Invalid cron expression: '{schedule}'. "
                f"Expected format: cron(minute hour day-of-month month day-of-week year)"
            )
        return errors

    # Neither predefined nor cron
    errors.append(
        f"Invalid sync_schedule: '{schedule}'. "
        f"Must be a predefined interval ({', '.join(sorted(PREDEFINED_INTERVALS))}) "
        f"or a valid cron expression (e.g., 'cron(0 6 * * ? *)')"
    )
    return errors


def translate_schedule_to_cron(schedule: str) -> str:
    """
    Translate a sync schedule to a cron expression.
    If it's already a cron expression, return as-is.
    If it's a predefined interval, return the corresponding cron.
    """
    schedule = schedule.strip()
    if schedule in INTERVAL_TO_CRON:
        return INTERVAL_TO_CRON[schedule]
    return schedule


def main():
    """CLI entry point for standalone validation."""
    if len(sys.argv) < 2:
        print("Usage: validate_sync_schedule.py <schedule-string>")
        sys.exit(1)

    schedule = sys.argv[1]
    errors = validate_sync_schedule(schedule)

    if errors:
        print(f"VALIDATION FAILED:")
        for err in errors:
            print(f"  {err}")
        sys.exit(1)
    else:
        cron = translate_schedule_to_cron(schedule)
        print(f"VALIDATION PASSED ✓ (resolved cron: {cron})")
        sys.exit(0)


if __name__ == "__main__":
    main()
