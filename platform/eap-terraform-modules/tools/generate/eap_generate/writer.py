"""File writer — writes rendered HCL to output directory.

Requirements: R29.5 — overwrite existing files with warning, no partial output on error.
"""

from __future__ import annotations

import sys
from pathlib import Path

from .renderer import RenderedFiles


def write(rendered: RenderedFiles, output_dir: str | Path) -> None:
    """Write all rendered HCL files to the output directory.

    Creates the directory if it doesn't exist. Overwrites existing files
    with a warning to stderr. Writes all files or none (no partial output).
    """
    out = Path(output_dir)

    # Check if output dir has existing files
    if out.exists() and any(out.iterdir()):
        print(f"Warning: Overwriting existing files in '{out}'", file=sys.stderr)

    try:
        out.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        raise OSError(f"Cannot write to '{out}': {e}") from e

    files = {
        "main.tf": rendered.main_tf,
        "variables.tf": rendered.variables_tf,
        "versions.tf": rendered.versions_tf,
        "outputs.tf": rendered.outputs_tf,
    }

    # Write to temp files first, then rename (atomic-ish) for no partial output
    written: list[Path] = []
    try:
        for name, content in files.items():
            target = out / name
            tmp = out / f".{name}.tmp"
            tmp.write_text(content)
            written.append(tmp)

        # All writes succeeded — rename temps to final
        for name in files:
            tmp = out / f".{name}.tmp"
            final = out / name
            tmp.rename(final)
    except OSError as e:
        # Clean up any temp files on failure
        for tmp in written:
            tmp.unlink(missing_ok=True)
        raise OSError(f"Cannot write to '{out}': {e}") from e
