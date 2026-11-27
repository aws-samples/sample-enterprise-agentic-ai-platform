#!/usr/bin/env bash
# 04 — Seed the app-team CodeCommit repo to trigger its deploy pipeline.
# (Identical CI/CD path to the enterprise bed — demo vs enterprise only differs in the platform
# posture, not in how agent code is pushed/built/deployed.)
#
# Copies users/<repo> into a TEMP working dir, inits a fresh git repo there, and
# pushes to the platform-created CodeCommit repo. The source tree under users/ is
# part of the outer platform repo and is NEVER git-init'd in place.
#
# AUTH: uses git-remote-codecommit (GRC) — `codecommit::<region>://<repo>`. GRC
# SigV4-signs each request and is the reliable method for TEMPORARY / assumed-role
# credentials (e.g. SSO). The plain-HTTPS CodeCommit credential-helper does
# NOT work with STS session creds (403). Install: pip install git-remote-codecommit.
#
# Pushing to `main` triggers <repo>-deploy-pipeline (Source -> Build -> Deploy ->
# Verify), which builds each agent image and deploys the AgentCore runtimes.
#
# Usage:
#   scripts/04-seed-repos.sh            # seeds team-bu-1 (default)
#   scripts/04-seed-repos.sh team-bu-1  # explicit repo
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
REPO="${1:-team-bu-1}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONOREPO="$(cd "$HERE/../.." && pwd)"
SRC="$MONOREPO/users/$REPO"
CC_URL="codecommit::${REGION}://${REPO}"

echo "=== 04 — seed CodeCommit repo '$REPO' from users/$REPO ==="

[ -d "$SRC" ] || { echo "Source dir not found: $SRC"; exit 1; }
command -v git-remote-codecommit >/dev/null 2>&1 \
  || { echo "git-remote-codecommit not found — install it: pip install git-remote-codecommit"; exit 1; }
aws codecommit get-repository --repository-name "$REPO" --region "$REGION" >/dev/null 2>&1 \
  || { echo "CodeCommit repo '$REPO' does not exist — deploy the platform first (script 02)."; exit 1; }

# Fresh temp working copy so we never touch the tracked source tree.
WORK="$(mktemp -d "/tmp/demo-seed-${REPO}.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
echo "  staging copy in $WORK"

# Copy source WITHOUT any nested .git; we create our own history.
( cd "$SRC" && tar --exclude='.git' -cf - . ) | ( cd "$WORK" && tar -xf - )

cd "$WORK"
git init -q
git checkout -q -b main
# Repo-scoped git identity (NOT global — this is a throwaway repo).
git config user.email "demo-testbed@eap.ai"
git config user.name  "demo-testbed"

git add -A
git commit -q -m "feat: seed $REPO agents (demo test bed)"

echo "  pushing to $CC_URL (branch main)..."
git remote add origin "$CC_URL"
# --force so re-runs overwrite a prior seed cleanly (throwaway repo).
git push --force -u origin main

echo ""
echo "Pushed. This triggers '${REPO}-deploy-pipeline'. Monitor with:"
echo "  scripts/05-monitor-pipeline.sh ${REPO}-deploy-pipeline"
