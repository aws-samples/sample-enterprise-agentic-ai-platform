"""JSON Schema validation for agent.yaml.

Requirements: R22.6, R22.7, R29.1–R29.3 — validates against JSON Schema,
returns structured errors with field path and violation details.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import jsonschema


@dataclass
class ValidationError:
    """A single schema validation error."""

    field_path: str
    message: str
    value: object = None


_SCHEMA_PATH = Path(__file__).parent / "schema" / "agent-yaml-schema.json"
_cached_schema: dict | None = None


def load_schema() -> dict:
    """Load the JSON Schema from the package's schema/ directory."""
    global _cached_schema
    if _cached_schema is None:
        with _SCHEMA_PATH.open("r") as f:
            _cached_schema = json.load(f)
    return _cached_schema


def validate(yaml_data: dict) -> list[ValidationError]:
    """Validate parsed YAML against the JSON Schema.

    Returns empty list on success, list of ValidationError on failure.
    """
    schema = load_schema()
    validator = jsonschema.Draft7Validator(schema)
    errors: list[ValidationError] = []

    for err in sorted(validator.iter_errors(yaml_data), key=lambda e: list(e.absolute_path)):
        path = ".".join(str(p) for p in err.absolute_path) or "(root)"
        errors.append(
            ValidationError(
                field_path=path,
                message=err.message,
                value=err.instance,
            )
        )

    return errors


def validate_agent_refs(yaml_data: dict) -> list[ValidationError]:
    """Validate that calls/allowed_callers reference existing agent names.

    Requirement R22.7 — unresolved agent references are errors.
    """
    errors: list[ValidationError] = []
    agents = yaml_data.get("agents", {})
    agent_names = set(agents.keys())

    for name, block in agents.items():
        for field in ("calls", "allowed_callers"):
            for ref in block.get(field, []):
                if ref not in agent_names:
                    errors.append(
                        ValidationError(
                            field_path=f"agents.{name}.{field}",
                            message=f"Agent '{name}' references '{ref}' in '{field}' but no agent named '{ref}' exists",
                            value=ref,
                        )
                    )

    return errors
