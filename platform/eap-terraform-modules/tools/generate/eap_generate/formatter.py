"""YAML pretty-printer — canonical formatting with sorted keys.

Requirements: R26.2–R26.4 — 2-space indent, sorted top-level keys,
sorted agent names, round-trip fidelity.
"""

from __future__ import annotations

from io import StringIO

from ruamel.yaml import YAML

# Canonical key ordering for top-level fields
_TOP_LEVEL_ORDER = ["domain", "framework", "model_id", "module_source", "module_version", "agents"]


def format_yaml(data: dict) -> str:
    """Format an agent.yaml dict with canonical ordering.

    - 2-space indentation
    - Sorted top-level keys (domain, framework, model_id, module_source, module_version, agents)
    - Sorted agent names within the agents block
    """
    ordered = _sort_top_level(data)
    yaml = YAML()
    yaml.default_flow_style = False
    yaml.width = 120
    yaml.indent(mapping=2, sequence=4, offset=2)
    buf = StringIO()
    yaml.dump(ordered, buf)
    return buf.getvalue()


def check_formatted(data: dict, original_text: str) -> bool:
    """Check if the original text matches canonical formatting.

    Returns True if already formatted, False otherwise.
    """
    canonical = format_yaml(data)
    return canonical.strip() == original_text.strip()


def _sort_top_level(data: dict) -> dict:
    """Sort top-level keys and agent names."""
    result = {}

    # Add keys in canonical order
    for key in _TOP_LEVEL_ORDER:
        if key in data:
            if key == "agents":
                # Sort agent names alphabetically
                result["agents"] = dict(sorted(data["agents"].items()))
            else:
                result[key] = data[key]

    # Add any unknown keys at the end (future-proofing)
    for key in data:
        if key not in result:
            result[key] = data[key]

    return result
