"""YAML Validator tool — validates generated manifests against the platform schema.

Validates:
- agent.yaml: required fields, enum values, kebab-case names, nested memory/evaluations
- agent-card.yaml: required fields, semver version, kebab-case name
- application.yaml: required fields, enum values, kebab-case name, agent/step topology

Schema derived from docs/yaml-manifest-reference.md and design doc YAML_SCHEMA definitions.
"""

import re
from typing import Any

import yaml
from strands import tool

# Import the catalog browser so we can cross-check gateway_refs against the Gateway
# at validation time. See docs/adr/023-studio-mcp-catalog-scoping.md.
try:
    from agent.tools.mcp_catalog_browser import mcp_catalog_browser as _catalog_tool
except Exception:
    _catalog_tool = None

# ---------------------------------------------------------------------------
# Patterns
# ---------------------------------------------------------------------------
KEBAB_CASE_RE = re.compile(r"^[a-z][a-z0-9-]*$")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")

# ---------------------------------------------------------------------------
# Schema definitions — aligned with design doc YAML_SCHEMA constants
# ---------------------------------------------------------------------------

FRAMEWORK_VALUES = ["strands", "langgraph", "crewai", "claude-sdk", "custom"]
PROTOCOL_VALUES = ["a2a", "mcp"]
ROLE_VALUES = ["standalone", "orchestrator", "worker", "peer", "classifier", "handler"]
MEMORY_TYPE_VALUES = ["short-term", "long-term"]
MEMORY_RETENTION_VALUES = ["30d", "90d", "365d"]
EVALUATOR_VALUES = ["correctness", "helpfulness", "safety"]
ARCHITECTURE_VALUES = ["supervisor", "sequential-workflow", "parallel", "router", "swarm"]
ORCHESTRATION_VALUES = ["step-functions", "a2a", "none"]

AGENT_REQUIRED_FIELDS = ["name", "framework", "model_id", "protocols"]
AGENT_CARD_REQUIRED_FIELDS = ["name", "version", "description"]
APPLICATION_REQUIRED_FIELDS = ["name", "architecture", "description"]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _err(field: str, message: str, severity: str = "error") -> dict:
    return {"field": field, "message": message, "severity": severity}


def _check_kebab_case(value: Any, field: str) -> list[dict]:
    """Validate that a string value matches kebab-case pattern."""
    if not isinstance(value, str):
        return [_err(field, f"Expected string for {field}, got {type(value).__name__}")]
    if not KEBAB_CASE_RE.match(value):
        return [_err(field, f"Name must be kebab-case (lowercase, hyphens, start with letter): '{value}'")]
    return []


def _check_enum(value: Any, field: str, allowed: list[str]) -> list[dict]:
    """Validate that a value is one of the allowed enum values."""
    if not isinstance(value, str):
        return [_err(field, f"Expected string for {field}, got {type(value).__name__}")]
    if value not in allowed:
        return [_err(field, f"Invalid value '{value}' for {field}. Allowed: {allowed}")]
    return []


def _check_list_enum(value: Any, field: str, allowed: list[str]) -> list[dict]:
    """Validate that a list contains only allowed enum values."""
    if not isinstance(value, list):
        return [_err(field, f"Expected list for {field}, got {type(value).__name__}")]
    errors = []
    for i, item in enumerate(value):
        if not isinstance(item, str):
            errors.append(_err(f"{field}[{i}]", f"Expected string in {field}, got {type(item).__name__}"))
        elif item not in allowed:
            errors.append(_err(f"{field}[{i}]", f"Invalid value '{item}' in {field}. Allowed: {allowed}"))
    return errors


def _check_required(parsed: dict, required: list[str]) -> list[dict]:
    """Check that all required fields are present."""
    errors = []
    for field in required:
        if field not in parsed:
            errors.append(_err(field, f"Missing required field: {field}"))
    return errors


# ---------------------------------------------------------------------------
# Per-manifest validators
# ---------------------------------------------------------------------------

def _validate_agent(parsed: dict) -> list[dict]:
    """Validate an agent.yaml manifest."""
    errors = _check_required(parsed, AGENT_REQUIRED_FIELDS)

    # name — kebab-case
    if "name" in parsed:
        errors.extend(_check_kebab_case(parsed["name"], "name"))

    # framework — enum
    if "framework" in parsed:
        errors.extend(_check_enum(parsed["framework"], "framework", FRAMEWORK_VALUES))

    # model_id — must be a non-empty string
    if "model_id" in parsed:
        if not isinstance(parsed["model_id"], str) or not parsed["model_id"].strip():
            errors.append(_err("model_id", "model_id must be a non-empty string"))

    # protocols — list of enum
    if "protocols" in parsed:
        errors.extend(_check_list_enum(parsed["protocols"], "protocols", PROTOCOL_VALUES))

    # role — optional enum
    if "role" in parsed:
        errors.extend(_check_enum(parsed["role"], "role", ROLE_VALUES))

    # description — optional string
    if "description" in parsed and not isinstance(parsed["description"], str):
        errors.append(_err("description", "description must be a string"))

    # memory — optional nested object
    if "memory" in parsed:
        mem = parsed["memory"]
        if not isinstance(mem, dict):
            errors.append(_err("memory", "memory must be a mapping"))
        else:
            if "type" in mem:
                errors.extend(_check_enum(mem["type"], "memory.type", MEMORY_TYPE_VALUES))
            if "retention" in mem:
                errors.extend(_check_enum(mem["retention"], "memory.retention", MEMORY_RETENTION_VALUES))

    # gateway_refs — optional list of objects with mcp_servers
    # Guardrail: every mcp_servers entry must exist in the Gateway catalog.
    # See docs/adr/023-studio-mcp-catalog-scoping.md.
    if "gateway_refs" in parsed:
        gw = parsed["gateway_refs"]
        if not isinstance(gw, list):
            errors.append(_err("gateway_refs", "gateway_refs must be a list"))
        else:
            # Fetch the current catalog once for this validation pass
            known_servers: set[str] | None = None
            if _catalog_tool is not None:
                try:
                    catalog = _catalog_tool("")  # workload identity fallback at validation time
                    if isinstance(catalog, dict) and "servers" in catalog and not catalog.get("error"):
                        known_servers = {s["name"] for s in catalog["servers"] if isinstance(s, dict) and "name" in s}
                except Exception:
                    known_servers = None  # Catalog unavailable; skip this check

            for i, ref in enumerate(gw):
                if not isinstance(ref, dict):
                    errors.append(_err(f"gateway_refs[{i}]", "Each gateway_ref must be a mapping"))
                elif "mcp_servers" in ref:
                    servers = ref["mcp_servers"]
                    if not isinstance(servers, list):
                        errors.append(_err(f"gateway_refs[{i}].mcp_servers", "mcp_servers must be a list"))
                    elif not all(isinstance(s, str) for s in servers):
                        errors.append(_err(f"gateway_refs[{i}].mcp_servers", "All mcp_servers entries must be strings"))
                    elif known_servers is not None:
                        for j, srv in enumerate(servers):
                            if srv not in known_servers:
                                errors.append(_err(
                                    f"gateway_refs[{i}].mcp_servers[{j}]",
                                    f"MCP server '{srv}' not found in platform Gateway catalog. "
                                    f"Call mcp_catalog_browser to see valid servers. "
                                    f"Available: {sorted(known_servers) if known_servers else '(catalog empty)'}",
                                ))

    # evaluations — optional nested object
    if "evaluations" in parsed:
        evals = parsed["evaluations"]
        if not isinstance(evals, dict):
            errors.append(_err("evaluations", "evaluations must be a mapping"))
        else:
            if "evaluators" in evals:
                errors.extend(_check_list_enum(evals["evaluators"], "evaluations.evaluators", EVALUATOR_VALUES))
            if "thresholds" in evals:
                thresholds = evals["thresholds"]
                if not isinstance(thresholds, dict):
                    errors.append(_err("evaluations.thresholds", "thresholds must be a mapping"))
                else:
                    for key, val in thresholds.items():
                        if not isinstance(val, (int, float)):
                            errors.append(_err(
                                f"evaluations.thresholds.{key}",
                                f"Threshold '{key}' must be a number, got {type(val).__name__}",
                            ))
                        elif not (0.0 <= float(val) <= 1.0):
                            errors.append(_err(
                                f"evaluations.thresholds.{key}",
                                f"Threshold '{key}' must be between 0.0 and 1.0, got {val}",
                            ))

    # calls — optional list of strings
    if "calls" in parsed:
        calls = parsed["calls"]
        if not isinstance(calls, list):
            errors.append(_err("calls", "calls must be a list"))
        elif not all(isinstance(c, str) for c in calls):
            errors.append(_err("calls", "All entries in calls must be strings"))

    return errors


def _validate_agent_card(parsed: dict) -> list[dict]:
    """Validate an agent-card.yaml manifest."""
    errors = _check_required(parsed, AGENT_CARD_REQUIRED_FIELDS)

    # name — kebab-case
    if "name" in parsed:
        errors.extend(_check_kebab_case(parsed["name"], "name"))

    # version — semver pattern
    if "version" in parsed:
        v = parsed["version"]
        if not isinstance(v, str):
            errors.append(_err("version", f"version must be a string, got {type(v).__name__}"))
        elif not SEMVER_RE.match(v):
            errors.append(_err("version", f"version must be semver (e.g. 1.0.0), got '{v}'"))

    # description — non-empty string
    if "description" in parsed:
        if not isinstance(parsed["description"], str) or not parsed["description"].strip():
            errors.append(_err("description", "description must be a non-empty string"))

    # skills — optional list of skill objects
    if "skills" in parsed:
        skills = parsed["skills"]
        if not isinstance(skills, list):
            errors.append(_err("skills", "skills must be a list"))
        else:
            for i, skill in enumerate(skills):
                if not isinstance(skill, dict):
                    errors.append(_err(f"skills[{i}]", "Each skill must be a mapping"))
                else:
                    for sf in ("id", "name", "description"):
                        if sf not in skill:
                            errors.append(_err(f"skills[{i}].{sf}", f"Missing required skill field: {sf}"))
                        elif not isinstance(skill[sf], str):
                            errors.append(_err(f"skills[{i}].{sf}", f"Skill {sf} must be a string"))

    return errors


def _validate_application(parsed: dict) -> list[dict]:
    """Validate an application.yaml manifest."""
    errors = _check_required(parsed, APPLICATION_REQUIRED_FIELDS)

    # name — kebab-case
    if "name" in parsed:
        errors.extend(_check_kebab_case(parsed["name"], "name"))

    # architecture — enum
    if "architecture" in parsed:
        errors.extend(_check_enum(parsed["architecture"], "architecture", ARCHITECTURE_VALUES))

    # description — non-empty string
    if "description" in parsed:
        if not isinstance(parsed["description"], str) or not parsed["description"].strip():
            errors.append(_err("description", "description must be a non-empty string"))

    # orchestration — optional enum
    if "orchestration" in parsed:
        errors.extend(_check_enum(parsed["orchestration"], "orchestration", ORCHESTRATION_VALUES))

    # agents — optional list of agent topology entries
    if "agents" in parsed:
        agents = parsed["agents"]
        if not isinstance(agents, list):
            errors.append(_err("agents", "agents must be a list"))
        else:
            for i, agent in enumerate(agents):
                if not isinstance(agent, dict):
                    errors.append(_err(f"agents[{i}]", "Each agent entry must be a mapping"))
                    continue
                if "name" not in agent:
                    errors.append(_err(f"agents[{i}].name", "Missing required field: name"))
                elif isinstance(agent["name"], str):
                    errors.extend(_check_kebab_case(agent["name"], f"agents[{i}].name"))
                if "role" in agent:
                    errors.extend(_check_enum(agent["role"], f"agents[{i}].role", ROLE_VALUES))
                for list_field in ("calls", "called_by", "can_call"):
                    if list_field in agent:
                        lf = agent[list_field]
                        if not isinstance(lf, list):
                            errors.append(_err(f"agents[{i}].{list_field}", f"{list_field} must be a list"))
                        elif not all(isinstance(x, str) for x in lf):
                            errors.append(_err(f"agents[{i}].{list_field}", f"All entries in {list_field} must be strings"))

    # steps — optional list of step entries (sequential-workflow)
    if "steps" in parsed:
        steps = parsed["steps"]
        if not isinstance(steps, list):
            errors.append(_err("steps", "steps must be a list"))
        else:
            for i, step in enumerate(steps):
                if not isinstance(step, dict):
                    errors.append(_err(f"steps[{i}]", "Each step must be a mapping"))
                    continue
                if "name" not in step:
                    errors.append(_err(f"steps[{i}].name", "Missing required field: name"))
                elif isinstance(step["name"], str):
                    errors.extend(_check_kebab_case(step["name"], f"steps[{i}].name"))
                if "depends_on" in step:
                    deps = step["depends_on"]
                    if not isinstance(deps, list):
                        errors.append(_err(f"steps[{i}].depends_on", "depends_on must be a list"))
                    elif not all(isinstance(d, str) for d in deps):
                        errors.append(_err(f"steps[{i}].depends_on", "All entries in depends_on must be strings"))

    return errors


# ---------------------------------------------------------------------------
# Manifest type dispatcher
# ---------------------------------------------------------------------------

_VALIDATORS = {
    "agent": _validate_agent,
    "agent-card": _validate_agent_card,
    "application": _validate_application,
}

SUPPORTED_MANIFEST_TYPES = list(_VALIDATORS.keys())


# ---------------------------------------------------------------------------
# Main tool
# ---------------------------------------------------------------------------

@tool
def yaml_validator(yaml_content: str, manifest_type: str) -> dict:
    """Validate a YAML manifest against the platform schema.

    Args:
        yaml_content: The YAML string to validate.
        manifest_type: One of "agent", "agent-card", "application".

    Returns:
        {
            "valid": bool,
            "errors": [{"field": str, "message": str, "severity": "error"|"warning"}],
            "parsed": dict | None  # The parsed YAML as a dict (for round-trip verification)
        }
    """
    # Validate manifest_type
    if manifest_type not in _VALIDATORS:
        return {
            "valid": False,
            "errors": [_err(
                "manifest_type",
                f"Unsupported manifest_type '{manifest_type}'. Must be one of: {SUPPORTED_MANIFEST_TYPES}",
            )],
            "parsed": None,
        }

    # Parse YAML
    try:
        parsed = yaml.safe_load(yaml_content)
    except yaml.YAMLError as exc:
        return {
            "valid": False,
            "errors": [_err("yaml", f"YAML parse error: {exc}")],
            "parsed": None,
        }

    # Handle empty or non-mapping YAML
    if parsed is None:
        return {
            "valid": False,
            "errors": [_err("yaml", "YAML document is empty")],
            "parsed": None,
        }

    if not isinstance(parsed, dict):
        return {
            "valid": False,
            "errors": [_err("yaml", f"YAML root must be a mapping, got {type(parsed).__name__}")],
            "parsed": None,
        }

    # Run manifest-specific validation
    errors = _VALIDATORS[manifest_type](parsed)

    return {
        "valid": len(errors) == 0,
        "errors": errors,
        "parsed": parsed,
    }
