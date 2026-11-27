#!/usr/bin/env python3
"""
Data Sources Config Validator — validates data-sources.yaml schema

Validates that data_sources is a non-empty list with type-specific required fields:
  - s3: bucket_name OR create_bucket
  - web_crawl: seed_urls + scope
  - confluence: host_url + credential_arn
  - sharepoint: site_url + credential_arn
  - salesforce: instance_url + credential_arn

Exits 0 on valid, exits 1 on invalid with structured error output.
"""

import sys
from pathlib import Path
from typing import Any


VALID_TYPES = {"s3", "web_crawl", "confluence", "sharepoint", "salesforce", "custom"}

# Type-specific required fields
TYPE_REQUIREMENTS: dict[str, list[list[str]]] = {
    "s3": [["bucket_name", "create_bucket"]],  # At least one of these
    "web_crawl": [["seed_urls"], ["scope"]],
    "confluence": [["host_url"], ["credential_arn"]],
    "sharepoint": [["site_url"], ["credential_arn"]],
    "salesforce": [["instance_url"], ["credential_arn"]],
    "custom": [],
}

VALID_SCOPES = {"host_only", "subdomain", "domain"}


def validate_data_sources_yaml(config: dict[str, Any]) -> list[str]:
    """Validate a parsed data-sources.yaml dict. Returns list of error messages."""
    errors: list[str] = []

    if "data_sources" not in config:
        errors.append("Required field missing: 'data_sources'")
        return errors

    data_sources = config["data_sources"]
    if not isinstance(data_sources, list):
        errors.append("'data_sources' must be a list")
        return errors

    if len(data_sources) == 0:
        errors.append("'data_sources' must contain at least one entry")
        return errors

    for i, ds in enumerate(data_sources):
        ds_name = ds.get("name", f"entry[{i}]")
        prefix = f"data_sources[{i}] ({ds_name})"

        if not isinstance(ds, dict):
            errors.append(f"{prefix}: must be a mapping")
            continue

        # name is recommended but not strictly required for validation
        if "type" not in ds:
            errors.append(f"{prefix}: required field 'type' missing")
            continue

        ds_type = ds["type"]
        if ds_type not in VALID_TYPES:
            errors.append(
                f"{prefix}: invalid type '{ds_type}' "
                f"(must be one of: {', '.join(sorted(VALID_TYPES))})"
            )
            continue

        # Check type-specific required fields
        requirements = TYPE_REQUIREMENTS.get(ds_type, [])
        for field_group in requirements:
            if len(field_group) == 1:
                # Single required field
                if field_group[0] not in ds:
                    errors.append(f"{prefix}: required field '{field_group[0]}' missing for type '{ds_type}'")
            else:
                # At least one of the fields must be present
                if not any(f in ds for f in field_group):
                    errors.append(
                        f"{prefix}: at least one of {field_group} is required for type '{ds_type}'"
                    )

        # Type-specific extra validation
        if ds_type == "s3":
            # create_bucket and bucket_name conflict check
            if ds.get("create_bucket") and ds.get("bucket_name"):
                errors.append(
                    f"{prefix}: 'create_bucket: true' and 'bucket_name' cannot both be specified"
                )

        if ds_type == "web_crawl":
            if "seed_urls" in ds:
                if not isinstance(ds["seed_urls"], list) or len(ds["seed_urls"]) == 0:
                    errors.append(f"{prefix}: 'seed_urls' must be a non-empty list")
            if "scope" in ds:
                if ds["scope"] not in VALID_SCOPES:
                    errors.append(
                        f"{prefix}: 'scope' must be one of: {', '.join(sorted(VALID_SCOPES))} "
                        f"(got '{ds['scope']}')"
                    )

    return errors


def main():
    """CLI entry point for standalone validation."""
    if len(sys.argv) < 2:
        print("Usage: validate_data_sources_yaml.py <path-to-data-sources.yaml>")
        sys.exit(1)

    import yaml

    ds_yaml_path = Path(sys.argv[1])
    if not ds_yaml_path.exists():
        print(f"ERROR: File not found: {ds_yaml_path}")
        sys.exit(1)

    with open(ds_yaml_path) as f:
        try:
            config = yaml.safe_load(f)
        except Exception as e:
            print(f"ERROR: Invalid YAML: {e}")
            sys.exit(1)

    if not isinstance(config, dict):
        print("ERROR: data-sources.yaml must be a YAML mapping (dict)")
        sys.exit(1)

    errors = validate_data_sources_yaml(config)
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
