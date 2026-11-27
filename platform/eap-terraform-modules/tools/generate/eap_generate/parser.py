"""YAML parser with round-trip fidelity using ruamel.yaml.

Requirements: R26.1 — preserves key ordering and supports YAML 1.2 scalar types.
"""

from __future__ import annotations

from pathlib import Path

from ruamel.yaml import YAML


def _make_yaml() -> YAML:
    """Create a ruamel.yaml instance configured for round-trip parsing."""
    y = YAML()
    y.preserve_quotes = True
    y.default_flow_style = False
    y.width = 120
    y.indent(mapping=2, sequence=4, offset=2)
    return y


def parse_file(path: str | Path) -> dict:
    """Parse an agent.yaml file and return a plain dict.

    Raises:
        FileNotFoundError: If the file does not exist.
        ruamel.yaml.YAMLError: If the YAML is malformed (includes line/col info).
    """
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Input file '{p}' not found")
    yaml = _make_yaml()
    with p.open("r") as f:
        data = yaml.load(f)
    # Convert CommentedMap to plain dict for downstream consumers
    return _to_plain(data)


def parse_string(text: str) -> dict:
    """Parse a YAML string and return a plain dict."""
    from io import StringIO

    yaml = _make_yaml()
    data = yaml.load(StringIO(text))
    return _to_plain(data)


def dump_string(data: dict) -> str:
    """Dump a dict back to a YAML string (round-trip safe)."""
    from io import StringIO

    yaml = _make_yaml()
    buf = StringIO()
    yaml.dump(data, buf)
    return buf.getvalue()


def _to_plain(obj):
    """Recursively convert ruamel CommentedMap/Seq to plain dict/list."""
    if isinstance(obj, dict):
        return {k: _to_plain(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_to_plain(v) for v in obj]
    return obj
