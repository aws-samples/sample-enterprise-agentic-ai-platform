#!/usr/bin/env python3
"""
Version Computation Module

Derives the next semantic version from git history using Conventional Commits.
Scans commits since the last application-scoped git tag, determines the bump
level (MAJOR/MINOR/PATCH), and creates an annotated tag.

Algorithm:
    1. Find latest tag matching `{app_path}/v*`
    2. If no tag exists, start at 0.1.0
    3. Parse commits since tag
    4. Determine bump: BREAKING → MAJOR, feat → MINOR, else → PATCH
    5. Compute next version, create annotated tag, push

Usage:
    python compute_version.py --app-path orchestration/supervisor/rrf-search-app
    python compute_version.py --app-path standalone/aws-architect --dry-run
"""

import argparse
import re
import subprocess
import sys
from typing import List, Optional

from semver_utils import is_valid_semver, parse_version


# Initial version when no prior tag exists
INITIAL_VERSION = "0.1.0"

# Application tags look like "{app_path}/vMAJOR.MINOR.PATCH",
# e.g. "orchestration/supervisor/rrf-search-app/v1.2.0".
_TAG_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]*/v\d+\.\d+\.\d+")


def determine_bump(commit_messages: List[str]) -> str:
    """
    Determine the version bump level from a list of commit messages.

    Inspects commit messages for Conventional Commits signals:
    - BREAKING or `!:` in any commit → "major"
    - `feat:` in any commit (no BREAKING) → "minor"
    - All others → "patch"

    Args:
        commit_messages: List of commit subject lines.

    Returns:
        One of "major", "minor", or "patch".
    """
    has_feat = False

    for msg in commit_messages:
        # Check for BREAKING changes
        if "BREAKING" in msg or "!:" in msg:
            return "major"
        # Check for feature commits
        if msg.startswith("feat:") or msg.startswith("feat("):
            has_feat = True

    if has_feat:
        return "minor"

    return "patch"


def compute_next_version(current_version: str, commit_messages: List[str]) -> str:
    """
    Apply the determined bump to the current version.

    Args:
        current_version: The current semantic version string (e.g., "1.2.3").
        commit_messages: List of commit subject lines since the last tag.

    Returns:
        The next semantic version string.

    Raises:
        ValueError: If current_version is not valid semver.
    """
    major, minor, patch = parse_version(current_version)
    bump = determine_bump(commit_messages)

    if bump == "major":
        return f"{major + 1}.0.0"
    elif bump == "minor":
        return f"{major}.{minor + 1}.0"
    else:
        return f"{major}.{minor}.{patch + 1}"


def get_latest_tag(app_path: str) -> Optional[str]:
    """
    Query git for the latest tag in the application's namespace.

    Runs: git tag --list "{app_path}/v*" --sort=-v:refname

    Args:
        app_path: Application path (e.g., "orchestration/supervisor/rrf-search-app").

    Returns:
        The latest tag string (e.g., "orchestration/supervisor/rrf-search-app/v1.2.0"),
        or None if no tags exist for this application.
    """
    try:
        result = subprocess.run(
            ["git", "tag", "--list", f"{app_path}/v*", "--sort=-v:refname"],
            capture_output=True,
            text=True,
            check=True,
        )
        tags = result.stdout.strip().splitlines()
        if tags:
            return tags[0]
        return None
    except subprocess.CalledProcessError:
        return None


def create_version_tag(app_path: str, version: str) -> None:
    """
    Create an annotated git tag and push it to the remote.

    Creates tag in format: {app_path}/v{version}
    Example: orchestration/supervisor/rrf-search-app/v1.3.0

    Args:
        app_path: Application path.
        version: Semantic version string (e.g., "1.3.0").

    Raises:
        subprocess.CalledProcessError: If git tag or push fails.
    """
    tag_name = f"{app_path}/v{version}"

    # Create annotated tag
    subprocess.run(
        ["git", "tag", "-a", tag_name, "-m", f"Release {version}"],
        check=True,
    )

    # Push tag to remote
    subprocess.run(
        ["git", "push", "origin", tag_name],
        check=True,
    )


def _extract_version_from_tag(tag: str, app_path: str) -> str:
    """
    Extract the version string from a tag name.

    Args:
        tag: Full tag string (e.g., "orchestration/supervisor/rrf-search-app/v1.2.0").
        app_path: Application path prefix.

    Returns:
        Version string (e.g., "1.2.0").
    """
    prefix = f"{app_path}/v"
    if tag.startswith(prefix):
        return tag[len(prefix):]
    raise ValueError(f"Tag '{tag}' does not match expected format '{prefix}X.Y.Z'")


def _get_commits_since_tag(tag: Optional[str]) -> List[str]:
    """
    Get commit messages since a given tag (or all commits if no tag).

    Args:
        tag: The git tag to diff from, or None for all commits.

    Returns:
        List of commit subject lines.
    """
    if tag:
        # The tag comes from `git tag --list`, but validate it anyway so it can
        # never be read as a git option (leading "-") or carry a ref expression.
        if not _TAG_RE.fullmatch(tag):
            raise ValueError(f"Refusing unexpected tag format: {tag!r}")
        result = subprocess.run(
            ["git", "log", f"{tag}..HEAD", "--format=%s"],
            capture_output=True,
            text=True,
            check=True,
        )
    else:
        result = subprocess.run(
            ["git", "log", "--format=%s"],
            capture_output=True,
            text=True,
            check=True,
        )
    messages = result.stdout.strip().splitlines()
    return [m for m in messages if m]  # Filter empty lines


def main():
    """CLI entry point for version computation."""
    parser = argparse.ArgumentParser(
        description="Compute next semantic version from Conventional Commits"
    )
    parser.add_argument(
        "--app-path",
        required=True,
        help="Application path (e.g., 'orchestration/supervisor/rrf-search-app')",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Compute version without creating/pushing tag",
    )
    args = parser.parse_args()

    app_path = args.app_path

    # 1. Find latest tag
    latest_tag = get_latest_tag(app_path)

    if latest_tag:
        current_version = _extract_version_from_tag(latest_tag, app_path)
        print(f"Latest tag: {latest_tag} (version {current_version})")
    else:
        current_version = None
        print(f"No prior tag found for '{app_path}', starting at {INITIAL_VERSION}")

    # 2. Get commits since tag
    commits = _get_commits_since_tag(latest_tag)

    if not commits:
        print("No new commits since last tag. Nothing to do.")
        sys.exit(0)

    print(f"Found {len(commits)} commit(s) since last tag")

    # 3. Compute next version
    if current_version:
        next_version = compute_next_version(current_version, commits)
    else:
        next_version = INITIAL_VERSION

    print(f"Computed next version: {next_version}")

    # 4. Create tag and push (unless dry-run)
    if not args.dry_run:
        create_version_tag(app_path, next_version)
        print(f"✓ Created and pushed tag: {app_path}/v{next_version}")
    else:
        print(f"[dry-run] Would create tag: {app_path}/v{next_version}")

    # 5. Write VERSION file
    with open("VERSION", "w") as f:
        f.write(next_version)
    print(f"✓ Wrote VERSION file: {next_version}")

    # 6. Print version (for capture by build scripts)
    print(next_version)


if __name__ == "__main__":
    main()
