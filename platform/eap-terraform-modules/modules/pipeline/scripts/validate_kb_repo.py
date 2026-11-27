#!/usr/bin/env python3
"""
KB Repo Validator — Entry Point

Discovers KB directories (subdirectories containing kb.yaml), validates each one.
Aggregates errors and exits non-zero on failure.

Usage: python validate_kb_repo.py <repo-root-path>
"""

import sys
from pathlib import Path
from typing import Any

# Add script directory to path for sibling imports
sys.path.insert(0, str(Path(__file__).parent))

from validate_kb_yaml import validate_kb_yaml
from validate_data_sources_yaml import validate_data_sources_yaml


def discover_kb_directories(repo_root: Path) -> list[Path]:
    """Find all subdirectories containing a kb.yaml file."""
    kb_dirs = []
    for item in sorted(repo_root.iterdir()):
        if item.is_dir() and (item / "kb.yaml").exists():
            kb_dirs.append(item)
    return kb_dirs


def validate_kb_directory(kb_dir: Path) -> list[str]:
    """Validate a single KB directory. Returns list of error messages."""
    errors: list[str] = []
    kb_name = kb_dir.name

    # Validate kb.yaml
    kb_yaml_path = kb_dir / "kb.yaml"
    if not kb_yaml_path.exists():
        errors.append(f"[{kb_name}] Missing required file: kb.yaml")
        return errors

    try:
        import yaml
        with open(kb_yaml_path) as f:
            kb_config = yaml.safe_load(f)
    except Exception as e:
        errors.append(f"[{kb_name}] Invalid YAML in kb.yaml: {e}")
        return errors

    if not isinstance(kb_config, dict):
        errors.append(f"[{kb_name}] kb.yaml must be a YAML mapping (dict)")
        return errors

    kb_errors = validate_kb_yaml(kb_config)
    for err in kb_errors:
        errors.append(f"[{kb_name}/kb.yaml] {err}")

    # Validate data-sources.yaml
    ds_yaml_path = kb_dir / "data-sources.yaml"
    if not ds_yaml_path.exists():
        errors.append(f"[{kb_name}] Missing required file: data-sources.yaml")
        return errors

    try:
        with open(ds_yaml_path) as f:
            ds_config = yaml.safe_load(f)
    except Exception as e:
        errors.append(f"[{kb_name}] Invalid YAML in data-sources.yaml: {e}")
        return errors

    if not isinstance(ds_config, dict):
        errors.append(f"[{kb_name}] data-sources.yaml must be a YAML mapping (dict)")
        return errors

    ds_errors = validate_data_sources_yaml(ds_config)
    for err in ds_errors:
        errors.append(f"[{kb_name}/data-sources.yaml] {err}")

    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: validate_kb_repo.py <repo-root-path>")
        sys.exit(1)

    repo_root = Path(sys.argv[1])
    if not repo_root.exists():
        print(f"ERROR: Path not found: {repo_root}")
        sys.exit(1)

    kb_dirs = discover_kb_directories(repo_root)

    if not kb_dirs:
        print("WARNING: No KB directories found (no subdirectories with kb.yaml)")
        print("VALIDATION PASSED ✓ (nothing to validate)")
        sys.exit(0)

    all_errors: list[str] = []
    for kb_dir in kb_dirs:
        print(f"Validating: {kb_dir.name}/")
        errors = validate_kb_directory(kb_dir)
        all_errors.extend(errors)

    if all_errors:
        print(f"\nVALIDATION FAILED — {len(all_errors)} error(s):")
        for err in all_errors:
            print(f"  {err}")
        sys.exit(1)
    else:
        print(f"\nVALIDATION PASSED ✓ ({len(kb_dirs)} KB(s) validated)")
        sys.exit(0)


if __name__ == "__main__":
    main()
