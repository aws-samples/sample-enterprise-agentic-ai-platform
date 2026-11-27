"""CLI entry point — Click CLI with generate and format subcommands.

Requirements: R23.1, R29.6 — --input, --output, --module-source options, exit codes 0/1/2.
"""

from __future__ import annotations

import sys

import click

from . import __version__
from .formatter import check_formatted, format_yaml
from .parser import parse_file
from .renderer import render
from .resolver import resolve
from .schema import validate, validate_agent_refs
from .writer import write


@click.group(invoke_without_command=True)
@click.version_option(version=__version__)
@click.pass_context
def main(ctx: click.Context) -> None:
    """EAP YAML-to-HCL generator."""
    if ctx.invoked_subcommand is None:
        ctx.invoke(generate)


@main.command()
@click.option("--input", "input_path", default="./agent.yaml", help="Path to agent.yaml")
@click.option("--output", "output_dir", default="./generated-infra/", help="Output directory for generated HCL")
@click.option("--module-source", "module_source", default=None, help="Override module source URL")
def generate(input_path: str, output_dir: str, module_source: str | None) -> None:
    """Generate HCL from agent.yaml (default command)."""
    # Parse YAML
    try:
        data = parse_file(input_path)
    except FileNotFoundError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(2)
    except Exception as e:
        click.echo(f"Error: Invalid YAML: {e}", err=True)
        sys.exit(1)

    # Validate schema
    errors = validate(data)
    errors.extend(validate_agent_refs(data))
    if errors:
        for err in errors:
            click.echo(f"Error: {err.field_path}: {err.message}", err=True)
        sys.exit(1)

    # Resolve A2A relationships
    resolved = resolve(data)
    for warning in resolved.warnings:
        click.echo(f"Warning: {warning}", err=True)

    # Render HCL
    rendered = render(data, resolved, module_source)

    # Write output
    try:
        write(rendered, output_dir)
    except OSError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(2)

    agent_count = len(resolved.agents)
    click.echo(f"Generated HCL for {agent_count} agent(s) in '{output_dir}'")


@main.command(name="format")
@click.option("--input", "input_path", default="./agent.yaml", help="Path to agent.yaml")
@click.option("--check", is_flag=True, help="Check formatting without modifying")
def format_cmd(input_path: str, check: bool) -> None:
    """Format agent.yaml with canonical ordering."""
    from pathlib import Path

    try:
        data = parse_file(input_path)
    except FileNotFoundError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(2)
    except Exception as e:
        click.echo(f"Error: Invalid YAML: {e}", err=True)
        sys.exit(1)

    # Validate schema first
    errors = validate(data)
    if errors:
        for err in errors:
            click.echo(f"Error: {err.field_path}: {err.message}", err=True)
        sys.exit(1)

    original_text = Path(input_path).read_text()

    if check:
        if check_formatted(data, original_text):
            click.echo("agent.yaml is correctly formatted")
        else:
            click.echo("agent.yaml is not correctly formatted", err=True)
            sys.exit(1)
    else:
        formatted = format_yaml(data)
        Path(input_path).write_text(formatted)
        click.echo(f"Formatted '{input_path}'")
