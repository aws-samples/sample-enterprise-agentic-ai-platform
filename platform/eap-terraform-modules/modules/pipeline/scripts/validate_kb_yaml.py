#!/usr/bin/env python3
"""
KB Config Validator — validates kb.yaml schema

Required fields: name, description, embedding_model, chunking_strategy, sync_schedule
Optional sections: retrieval, access, tags

Exits 0 on valid, exits 1 on invalid with structured error output.
"""

import sys
from pathlib import Path
from typing import Any

# Add script directory to path for sibling imports
sys.path.insert(0, str(Path(__file__).parent))

from validate_sync_schedule import validate_sync_schedule


REQUIRED_FIELDS = ["name", "description", "embedding_model", "chunking_strategy", "sync_schedule"]
VALID_CHUNKING_TYPES = {"fixed_size", "semantic", "hierarchical", "none"}
VALID_SEARCH_TYPES = {"hybrid", "semantic", "keyword"}


def validate_kb_yaml(config: dict[str, Any]) -> list[str]:
    """Validate a parsed kb.yaml dict. Returns list of error messages (empty = valid)."""
    errors: list[str] = []

    # Check required fields
    for field in REQUIRED_FIELDS:
        if field not in config:
            errors.append(f"Required field missing: '{field}'")

    # If required fields are missing, can't validate further
    if errors:
        return errors

    # Validate name is a non-empty string
    if not isinstance(config["name"], str) or not config["name"].strip():
        errors.append("'name' must be a non-empty string")

    # Validate description is a non-empty string
    if not isinstance(config["description"], str) or not config["description"].strip():
        errors.append("'description' must be a non-empty string")

    # Validate embedding_model is a non-empty string
    if not isinstance(config["embedding_model"], str) or not config["embedding_model"].strip():
        errors.append("'embedding_model' must be a non-empty string")

    # Validate chunking_strategy
    chunking = config["chunking_strategy"]
    if not isinstance(chunking, dict):
        errors.append("'chunking_strategy' must be a mapping with at least a 'type' field")
    else:
        if "type" not in chunking:
            errors.append("'chunking_strategy.type' is required")
        elif chunking["type"] not in VALID_CHUNKING_TYPES:
            errors.append(
                f"'chunking_strategy.type' must be one of: {', '.join(sorted(VALID_CHUNKING_TYPES))} "
                f"(got '{chunking['type']}')"
            )

    # Validate sync_schedule
    schedule = config["sync_schedule"]
    if not isinstance(schedule, str):
        errors.append("'sync_schedule' must be a string")
    else:
        schedule_errors = validate_sync_schedule(schedule)
        for err in schedule_errors:
            errors.append(f"sync_schedule: {err}")

    # Validate optional 'retrieval' section
    if "retrieval" in config:
        retrieval = config["retrieval"]
        if not isinstance(retrieval, dict):
            errors.append("'retrieval' must be a mapping")
        else:
            if "search_type" in retrieval:
                if retrieval["search_type"] not in VALID_SEARCH_TYPES:
                    errors.append(
                        f"'retrieval.search_type' must be one of: {', '.join(sorted(VALID_SEARCH_TYPES))} "
                        f"(got '{retrieval['search_type']}')"
                    )
            if "max_results" in retrieval:
                max_r = retrieval["max_results"]
                if not isinstance(max_r, int) or max_r <= 0:
                    errors.append("'retrieval.max_results' must be a positive integer")

    # Validate optional 'access' section
    if "access" in config:
        access = config["access"]
        if not isinstance(access, dict):
            errors.append("'access' must be a mapping")
        else:
            if "allowed_domains" in access:
                if not isinstance(access["allowed_domains"], list):
                    errors.append("'access.allowed_domains' must be a list")
                elif not all(isinstance(d, str) for d in access["allowed_domains"]):
                    errors.append("'access.allowed_domains' must be a list of strings")
            if "allowed_agents" in access:
                if not isinstance(access["allowed_agents"], list):
                    errors.append("'access.allowed_agents' must be a list")
                elif not all(isinstance(a, str) for a in access["allowed_agents"]):
                    errors.append("'access.allowed_agents' must be a list of strings")

    # Validate optional 'tags' section
    if "tags" in config:
        if not isinstance(config["tags"], dict):
            errors.append("'tags' must be a mapping (dict)")

    return errors


def main():
    """CLI entry point for standalone validation."""
    if len(sys.argv) < 2:
        print("Usage: validate_kb_yaml.py <path-to-kb.yaml>")
        sys.exit(1)

    import yaml

    kb_yaml_path = Path(sys.argv[1])
    if not kb_yaml_path.exists():
        print(f"ERROR: File not found: {kb_yaml_path}")
        sys.exit(1)

    with open(kb_yaml_path) as f:
        try:
            config = yaml.safe_load(f)
        except Exception as e:
            print(f"ERROR: Invalid YAML: {e}")
            sys.exit(1)

    if not isinstance(config, dict):
        print("ERROR: kb.yaml must be a YAML mapping (dict)")
        sys.exit(1)

    errors = validate_kb_yaml(config)
    if errors:
        print(f"VALIDATION FAILED — {len(errors)} error(s):")
        for err in errors:
            print(f"  {err}")
        sys.exit(1)
    else:
        print("VALIDATION PASSED ✓")
        sys.exit(0)


if __name__ == "__main__":
    main()
