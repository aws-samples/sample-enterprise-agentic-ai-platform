"""HCL renderer — Jinja2 template rendering from YAML data + resolved A2A relationships.

Requirements: R27.1, R27.5 — syntactically valid HCL, deterministic generation.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, select_autoescape

from .resolver import ResolutionResult

_TEMPLATES_DIR = Path(__file__).parent / "templates"

DEFAULT_MODULE_SOURCE = "git::https://github.com/your-org/eap-modules.git"
DEFAULT_MODULE_VERSION = "v1.0.0"


@dataclass
class RenderedFiles:
    """All generated HCL files."""

    main_tf: str
    variables_tf: str
    versions_tf: str
    outputs_tf: str


def render(
    yaml_data: dict,
    resolved: ResolutionResult,
    module_source: str | None = None,
) -> RenderedFiles:
    """Render all HCL files from YAML data and resolved A2A relationships."""
    env = Environment(
        loader=FileSystemLoader(str(_TEMPLATES_DIR)),
        # Output is Terraform HCL, never HTML: HTML-escaping would corrupt it
        # (e.g. quotes in strings). Escape only templates with an HTML/XML
        # extension; none exist here, so the .tf.j2 templates render verbatim.
        autoescape=select_autoescape(
            enabled_extensions=("html", "htm", "xml"),
            default_for_string=False,
            default=False,
        ),
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
    )

    source = module_source or yaml_data.get("module_source", DEFAULT_MODULE_SOURCE)
    version = yaml_data.get("module_version", DEFAULT_MODULE_VERSION)

    context = {
        "domain": yaml_data["domain"],
        "framework": yaml_data["framework"],
        "model_id": yaml_data["model_id"],
        "module_source": source,
        "module_version": version,
        "agents": resolved.agents,
        "agent_names": [a.name for a in resolved.agents],
    }

    return RenderedFiles(
        main_tf=env.get_template("main.tf.j2").render(**context),
        variables_tf=env.get_template("variables.tf.j2").render(**context),
        versions_tf=env.get_template("versions.tf.j2").render(**context),
        outputs_tf=env.get_template("outputs.tf.j2").render(**context),
    )
