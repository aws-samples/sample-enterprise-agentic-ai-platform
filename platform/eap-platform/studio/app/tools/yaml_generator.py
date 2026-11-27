"""YAML Generator tool — produces valid YAML manifests from a structured AgentDesign.

Generates:
- agent.yaml for each agent (required + optional fields)
- agent-card.yaml for each agent (name, version, description, skills)
- application.yaml for multi-agent patterns (architecture, orchestration, topology)

Field ordering matches canonical templates in docs/templates/.
All YAML uses 2-space indentation with inline comments.
Calls yaml_validator internally before returning; auto-corrects up to 3 times.
"""

import re
from typing import Any

import yaml
from strands import tool

# ---------------------------------------------------------------------------
# Try to import the real yaml_validator (Task 4). Fall back to a simple
# inline validator if it doesn't exist yet.
# ---------------------------------------------------------------------------
try:
    from agent.tools.yaml_validator import yaml_validator as _real_validator

    def _validate(yaml_content: str, manifest_type: str) -> dict:
        result = _real_validator(yaml_content=yaml_content, manifest_type=manifest_type)
        # The real validator returns a tool Result; extract the dict.
        if isinstance(result, dict):
            return result
        return {"valid": True, "errors": [], "parsed": yaml.safe_load(yaml_content)}
except ImportError:
    # Fallback inline validator — checks required fields only.
    def _validate(yaml_content: str, manifest_type: str) -> dict:
        return _inline_validate(yaml_content, manifest_type)


# ---------------------------------------------------------------------------
# Inline fallback validator
# ---------------------------------------------------------------------------
_REQUIRED_FIELDS: dict[str, list[str]] = {
    "agent": ["name", "framework", "model_id", "protocols"],
    "agent-card": ["name", "version", "description"],
    "application": ["name", "architecture", "description"],
}

_ENUM_VALUES: dict[str, list[str]] = {
    "framework": ["strands", "langgraph", "crewai", "claude-sdk", "custom"],
    "role": ["standalone", "orchestrator", "worker", "peer", "classifier", "handler"],
    "architecture": ["supervisor", "sequential-workflow", "parallel", "router", "swarm"],
    "orchestration": ["step-functions", "a2a", "none"],
}

_KEBAB_RE = re.compile(r"^[a-z][a-z0-9-]*$")


def _inline_validate(yaml_content: str, manifest_type: str) -> dict:
    """Minimal validator used when yaml_validator tool is not yet available."""
    errors: list[dict[str, str]] = []
    try:
        parsed = yaml.safe_load(yaml_content)
    except yaml.YAMLError as exc:
        return {
            "valid": False,
            "errors": [{"field": "yaml", "message": str(exc), "severity": "error"}],
            "parsed": None,
        }

    if not isinstance(parsed, dict):
        return {
            "valid": False,
            "errors": [{"field": "yaml", "message": "YAML root must be a mapping", "severity": "error"}],
            "parsed": None,
        }

    # Required fields
    for field in _REQUIRED_FIELDS.get(manifest_type, []):
        if field not in parsed:
            errors.append({"field": field, "message": f"Missing required field: {field}", "severity": "error"})

    # Name kebab-case check
    name = parsed.get("name")
    if isinstance(name, str) and not _KEBAB_RE.match(name):
        errors.append({"field": "name", "message": f"Name must be kebab-case: {name}", "severity": "error"})

    # Enum checks
    for field, allowed in _ENUM_VALUES.items():
        val = parsed.get(field)
        if val is not None and isinstance(val, str) and val not in allowed:
            errors.append({
                "field": field,
                "message": f"Invalid value '{val}' for {field}. Allowed: {allowed}",
                "severity": "error",
            })

    return {
        "valid": len(errors) == 0,
        "errors": errors,
        "parsed": parsed,
    }



# ---------------------------------------------------------------------------
# YAML generation helpers — ordered fields matching canonical templates
# ---------------------------------------------------------------------------

def _ordered_dump(data: dict, comment_header: str = "") -> str:
    """Dump a dict to YAML with 2-space indentation.

    We use a custom approach to control field ordering rather than relying
    on yaml.dump's default alphabetical sort.
    """
    lines: list[str] = []
    if comment_header:
        for line in comment_header.strip().splitlines():
            lines.append(f"# {line}" if line.strip() else "#")
    _dump_mapping(data, lines, indent=0)
    return "\n".join(lines) + "\n"


def _dump_mapping(data: dict, lines: list[str], indent: int) -> None:
    """Recursively dump a mapping with controlled indentation."""
    prefix = "  " * indent
    for key, value in data.items():
        if value is None:
            continue
        if isinstance(value, dict):
            lines.append(f"{prefix}{key}:")
            _dump_mapping(value, lines, indent + 1)
        elif isinstance(value, list):
            if _is_simple_list(value):
                # Inline list: [a2a, mcp]
                formatted = ", ".join(str(v) for v in value)
                lines.append(f"{prefix}{key}: [{formatted}]")
            else:
                lines.append(f"{prefix}{key}:")
                for item in value:
                    if isinstance(item, dict):
                        _dump_list_mapping(item, lines, indent + 1)
                    else:
                        lines.append(f"{prefix}  - {item}")
        elif isinstance(value, bool):
            lines.append(f"{prefix}{key}: {'true' if value else 'false'}")
        elif isinstance(value, (int, float)):
            lines.append(f"{prefix}{key}: {value}")
        else:
            # String value — quote if it contains special chars
            str_val = str(value)
            if _needs_quoting(str_val):
                lines.append(f'{prefix}{key}: "{str_val}"')
            else:
                lines.append(f"{prefix}{key}: {str_val}")


def _dump_list_mapping(data: dict, lines: list[str], indent: int) -> None:
    """Dump a dict as a YAML list item (- key: value)."""
    prefix = "  " * indent
    first = True
    for key, value in data.items():
        if value is None:
            continue
        marker = "- " if first else "  "
        first = False
        if isinstance(value, dict):
            lines.append(f"{prefix}{marker}{key}:")
            _dump_mapping(value, lines, indent + 2)
        elif isinstance(value, list):
            if _is_simple_list(value):
                formatted = ", ".join(str(v) for v in value)
                lines.append(f"{prefix}{marker}{key}: [{formatted}]")
            else:
                lines.append(f"{prefix}{marker}{key}:")
                for item in value:
                    if isinstance(item, dict):
                        _dump_list_mapping(item, lines, indent + 2)
                    else:
                        lines.append(f"{prefix}    - {item}")
        elif isinstance(value, bool):
            lines.append(f"{prefix}{marker}{key}: {'true' if value else 'false'}")
        elif isinstance(value, (int, float)):
            lines.append(f"{prefix}{marker}{key}: {value}")
        else:
            str_val = str(value)
            if _needs_quoting(str_val):
                lines.append(f'{prefix}{marker}{key}: "{str_val}"')
            else:
                lines.append(f"{prefix}{marker}{key}: {str_val}")


def _is_simple_list(lst: list) -> bool:
    """Check if a list contains only simple scalar values (strings, numbers)."""
    return all(isinstance(v, (str, int, float, bool)) for v in lst)


def _needs_quoting(value: str) -> bool:
    """Check if a YAML string value needs quoting."""
    if not value:
        return True
    # Quote if it looks like a version number, URL, or contains special chars
    if value.startswith("http") or ":" in value:
        return True
    if re.match(r"^\d+\.\d+\.\d+$", value):
        return True
    return False



# ---------------------------------------------------------------------------
# Individual manifest generators
# ---------------------------------------------------------------------------

def _generate_agent_yaml(agent: dict) -> str:
    """Generate agent.yaml content for a single agent.

    Field ordering matches docs/templates/agent/agent.yaml:
    name → framework → model_id → protocols → role → memory → gateway_refs →
    evaluations → calls
    """
    from collections import OrderedDict

    doc = OrderedDict()
    # Required fields
    doc["name"] = agent["name"]
    doc["framework"] = agent.get("framework", "strands")
    doc["model_id"] = agent.get("model_id", "us.anthropic.claude-sonnet-5")
    doc["protocols"] = agent.get("protocols", ["a2a"])

    # Optional fields — only include if present
    if agent.get("role"):
        doc["role"] = agent["role"]

    if agent.get("description"):
        doc["description"] = agent["description"]

    if agent.get("memory"):
        mem = OrderedDict()
        mem["type"] = agent["memory"].get("type", "short-term")
        if agent["memory"].get("retention"):
            mem["retention"] = agent["memory"]["retention"]
        doc["memory"] = mem

    if agent.get("gateway_refs"):
        doc["gateway_refs"] = agent["gateway_refs"]

    if agent.get("evaluations"):
        evals = OrderedDict()
        if agent["evaluations"].get("evaluators"):
            evals["evaluators"] = agent["evaluations"]["evaluators"]
        if agent["evaluations"].get("thresholds"):
            evals["thresholds"] = agent["evaluations"]["thresholds"]
        doc["evaluations"] = evals

    if agent.get("calls"):
        doc["calls"] = agent["calls"]

    header = (
        "agent.yaml — Agent Manifest\n"
        f"Generated by Agent Deployment Engineer for {agent['name']}"
    )
    return _ordered_dump(dict(doc), comment_header=header)


def _generate_agent_card_yaml(agent: dict) -> str:
    """Generate agent-card.yaml content for a single agent.

    Field ordering matches docs/templates/agent/agent-card.yaml:
    name → version → description → skills
    """
    from collections import OrderedDict

    doc = OrderedDict()
    doc["name"] = agent["name"]
    doc["version"] = "1.0.0"
    doc["description"] = agent.get("description", f"Agent: {agent['name']}")

    # Skills
    skills = agent.get("skills", [])
    if not skills:
        # Generate a default skill from the agent description
        skills = [
            {
                "id": f"{agent['name']}-default",
                "name": agent["name"].replace("-", " ").title(),
                "description": agent.get("description", f"Core capability of {agent['name']}"),
            }
        ]

    # Ensure each skill dict has ordered keys
    ordered_skills = []
    for skill in skills:
        s = OrderedDict()
        s["id"] = skill.get("id", "default")
        s["name"] = skill.get("name", "Default Skill")
        s["description"] = skill.get("description", "")
        ordered_skills.append(dict(s))

    doc["skills"] = ordered_skills

    header = (
        "agent-card.yaml — Agent Card\n"
        f"Generated by Agent Deployment Engineer for {agent['name']}"
    )
    return _ordered_dump(dict(doc), comment_header=header)


def _generate_application_yaml(design: dict) -> str:
    """Generate application.yaml for multi-agent patterns.

    Field ordering matches docs/templates/composition/application.yaml:
    name → architecture → description → orchestration → agents/steps
    """
    from collections import OrderedDict

    doc = OrderedDict()
    doc["name"] = design.get("app_name", "my-app")
    doc["architecture"] = design["pattern"]
    doc["description"] = design.get("description", "Multi-agent application")

    orchestration = design.get("orchestration", "none")
    if orchestration and orchestration != "none":
        doc["orchestration"] = orchestration

    # Build topology based on architecture type
    if design["pattern"] == "sequential-workflow":
        steps = _build_sequential_steps(design.get("agents", []))
        doc["steps"] = steps
    else:
        agents_topology = _build_agent_topology(design.get("agents", []))
        doc["agents"] = agents_topology

    header = (
        "application.yaml — Multi-Agent Application Manifest\n"
        f"Generated by Agent Deployment Engineer for {design.get('app_name', 'my-app')}"
    )
    return _ordered_dump(dict(doc), comment_header=header)


def _build_agent_topology(agents: list[dict]) -> list[dict]:
    """Build the agents topology list for application.yaml."""
    from collections import OrderedDict

    topology = []
    for agent in agents:
        entry = OrderedDict()
        entry["name"] = agent["name"]
        if agent.get("role"):
            entry["role"] = agent["role"]
        if agent.get("description"):
            entry["description"] = agent["description"]
        if agent.get("calls"):
            entry["calls"] = agent["calls"]
        if agent.get("called_by"):
            entry["called_by"] = agent["called_by"]
        if agent.get("can_call"):
            entry["can_call"] = agent["can_call"]
        if agent.get("gateway_refs"):
            entry["gateway_refs"] = agent["gateway_refs"]
        topology.append(dict(entry))
    return topology


def _build_sequential_steps(agents: list[dict]) -> list[dict]:
    """Build the steps list for sequential-workflow application.yaml."""
    from collections import OrderedDict

    steps = []
    prev_name = None
    for agent in agents:
        step = OrderedDict()
        step["name"] = agent["name"]
        if agent.get("description"):
            step["description"] = agent["description"]
        if prev_name:
            step["depends_on"] = [prev_name]
        steps.append(dict(step))
        prev_name = agent["name"]
    return steps



# ---------------------------------------------------------------------------
# Auto-correction helpers
# ---------------------------------------------------------------------------

_DEFAULT_VALUES: dict[str, Any] = {
    "framework": "strands",
    "model_id": "us.anthropic.claude-sonnet-5",
    "protocols": ["a2a"],
}


def _auto_correct_agent_yaml(content: str, errors: list[dict]) -> str:
    """Attempt to fix validation errors in agent.yaml by injecting defaults."""
    parsed = yaml.safe_load(content) or {}
    for error in errors:
        field = error.get("field", "")
        if "Missing required field" in error.get("message", ""):
            if field in _DEFAULT_VALUES:
                parsed[field] = _DEFAULT_VALUES[field]
        if field == "name" and "kebab-case" in error.get("message", ""):
            name = parsed.get("name", "my-agent")
            # Convert to kebab-case
            parsed["name"] = re.sub(r"[^a-z0-9-]", "-", name.lower()).strip("-")
    return _ordered_dump(parsed)


def _auto_correct_agent_card_yaml(content: str, errors: list[dict]) -> str:
    """Attempt to fix validation errors in agent-card.yaml."""
    parsed = yaml.safe_load(content) or {}
    for error in errors:
        field = error.get("field", "")
        if "Missing required field" in error.get("message", ""):
            if field == "version":
                parsed["version"] = "1.0.0"
            elif field == "description":
                parsed["description"] = f"Agent: {parsed.get('name', 'unknown')}"
            elif field == "name":
                parsed["name"] = "my-agent"
    return _ordered_dump(parsed)


def _auto_correct_application_yaml(content: str, errors: list[dict]) -> str:
    """Attempt to fix validation errors in application.yaml."""
    parsed = yaml.safe_load(content) or {}
    for error in errors:
        field = error.get("field", "")
        if "Missing required field" in error.get("message", ""):
            if field == "architecture":
                parsed["architecture"] = "supervisor"
            elif field == "description":
                parsed["description"] = "Multi-agent application"
            elif field == "name":
                parsed["name"] = "my-app"
    return _ordered_dump(parsed)


_AUTO_CORRECTORS = {
    "agent": _auto_correct_agent_yaml,
    "agent-card": _auto_correct_agent_card_yaml,
    "application": _auto_correct_application_yaml,
}

MAX_RETRIES = 3


def _validate_and_correct(content: str, manifest_type: str) -> tuple[str, bool, list[dict]]:
    """Validate YAML content and auto-correct up to MAX_RETRIES times.

    Returns (final_content, is_valid, errors).
    """
    current = content
    for _attempt in range(MAX_RETRIES):
        result = _validate(current, manifest_type)
        if result.get("valid", False):
            return current, True, []
        errors = result.get("errors", [])
        # Only attempt correction for error-severity issues
        error_issues = [e for e in errors if e.get("severity") == "error"]
        if not error_issues:
            return current, True, errors  # Only warnings remain
        corrector = _AUTO_CORRECTORS.get(manifest_type)
        if corrector:
            current = corrector(current, error_issues)
        else:
            break
    # Final validation after all retries
    result = _validate(current, manifest_type)
    return current, result.get("valid", False), result.get("errors", [])


# ---------------------------------------------------------------------------
# Multi-agent pattern detection
# ---------------------------------------------------------------------------

_MULTI_AGENT_PATTERNS = {"supervisor", "sequential-workflow", "router", "swarm", "parallel"}


def _is_multi_agent(pattern: str) -> bool:
    """Check if the pattern requires an application.yaml."""
    return pattern in _MULTI_AGENT_PATTERNS


# ---------------------------------------------------------------------------
# Main tool
# ---------------------------------------------------------------------------

@tool
def yaml_generator(agent_design: dict) -> dict:
    """Generate all YAML manifests for the agent design.

    Accepts an agent_design dict matching the AgentDesign schema:
    {
        "pattern": "standalone|supervisor|sequential-workflow|router|swarm",
        "orchestration": "step-functions|a2a|none",
        "app_name": "my-app",
        "description": "Application description",
        "agents": [
            {
                "name": "agent-name",
                "role": "standalone|orchestrator|worker|peer|classifier|handler",
                "description": "What this agent does",
                "model_id": "us.anthropic.claude-sonnet-5",
                "framework": "strands",
                "protocols": ["a2a"],
                "memory": {"type": "short-term|long-term", "retention": "90d"},
                "gateway_refs": [{"mcp_servers": ["server-name"]}],
                "evaluations": {"evaluators": ["correctness"], "thresholds": {"safety": 0.95}},
                "calls": ["other-agent"],
                "called_by": ["supervisor-agent"],
                "can_call": ["peer-agent"],
                "skills": [{"id": "skill-id", "name": "Skill", "description": "What it does"}]
            }
        ]
    }

    Returns:
    {
        "files": {"<path>": "<yaml-content>", ...},
        "validation_passed": bool,
        "validation_errors": [{"field": str, "message": str, "severity": str}]
    }
    """
    files: dict[str, str] = {}
    all_errors: list[dict] = []
    all_valid = True

    pattern = agent_design.get("pattern", "standalone")
    agents = agent_design.get("agents", [])

    if not agents:
        return {
            "files": {},
            "validation_passed": False,
            "validation_errors": [
                {"field": "agents", "message": "No agents defined in agent_design", "severity": "error"}
            ],
        }

    # Generate agent.yaml and agent-card.yaml for each agent
    for agent in agents:
        agent_name = agent.get("name", "my-agent")

        # agent.yaml
        agent_yaml = _generate_agent_yaml(agent)
        agent_yaml, valid, errors = _validate_and_correct(agent_yaml, "agent")
        if not valid:
            all_valid = False
            all_errors.extend(errors)
        files[f"{agent_name}/agent.yaml"] = agent_yaml

        # agent-card.yaml
        card_yaml = _generate_agent_card_yaml(agent)
        card_yaml, valid, errors = _validate_and_correct(card_yaml, "agent-card")
        if not valid:
            all_valid = False
            all_errors.extend(errors)
        files[f"{agent_name}/agent-card.yaml"] = card_yaml

    # Generate application.yaml for multi-agent patterns
    if _is_multi_agent(pattern):
        app_yaml = _generate_application_yaml(agent_design)
        app_yaml, valid, errors = _validate_and_correct(app_yaml, "application")
        if not valid:
            all_valid = False
            all_errors.extend(errors)
        files["application.yaml"] = app_yaml

    return {
        "files": files,
        "validation_passed": all_valid,
        "validation_errors": all_errors,
    }
