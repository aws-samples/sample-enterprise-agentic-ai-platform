#!/usr/bin/env bash
# 08 — Seed the app-team CodeCommit repo to trigger its deploy pipeline.
#
# Copies users/<repo> into a TEMP working dir, inits a fresh git repo there, and
# pushes to the platform-created CodeCommit repo. The source tree under users/
# is part of the outer platform repo and is NEVER git-init'd in place.
#
# AUTH: uses git-remote-codecommit (GRC) — `codecommit::<region>://<repo>`. GRC
# signs each request with SigV4 and is the reliable method for TEMPORARY /
# assumed-role credentials (e.g. SSO). The plain-HTTPS CodeCommit
# credential-helper does NOT work with STS session creds (returns 403 because
# the session-token-bearing username is mishandled), so GRC is used instead.
# Install: pip install git-remote-codecommit.
#
# Pushing to `main` triggers <repo>-deploy-pipeline (Source -> Build -> Deploy
# -> Verify), which builds the agent image and deploys the AgentCore runtime.
#
# Usage:
#   scripts/08-seed-repos.sh            # seeds team-bu-1 (default)
#   scripts/08-seed-repos.sh team-bu-1  # explicit repo
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
REPO="${1:-team-bu-1}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONOREPO="$(cd "$HERE/../.." && pwd)"
SRC="$MONOREPO/users/$REPO"
CC_URL="codecommit::${REGION}://${REPO}"

echo "=== 08 — seed CodeCommit repo '$REPO' from users/$REPO ==="

[ -d "$SRC" ] || { echo "Source dir not found: $SRC"; exit 1; }
command -v git-remote-codecommit >/dev/null 2>&1 \
  || { echo "git-remote-codecommit not found — install it: pip install git-remote-codecommit"; exit 1; }
aws codecommit get-repository --repository-name "$REPO" --region "$REGION" >/dev/null 2>&1 \
  || { echo "CodeCommit repo '$REPO' does not exist — deploy the platform first (script 05)."; exit 1; }

# Fresh temp working copy so we never touch the tracked source tree.
WORK="$(mktemp -d "/tmp/ent-seed-${REPO}.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
echo "  staging copy in $WORK"

# Copy source WITHOUT any nested .git; we create our own history.
( cd "$SRC" && tar --exclude='.git' -cf - . ) | ( cd "$WORK" && tar -xf - )

cd "$WORK"
git init -q
git checkout -q -b main
# Repo-scoped git identity (NOT global — this is a throwaway repo).
git config user.email "enterprise-testbed@eap.ai"
git config user.name  "enterprise-testbed"

git add -A
git commit -q -m "feat: seed $REPO agents (enterprise test bed)"

echo "  pushing to $CC_URL (branch main)..."
git remote add origin "$CC_URL"
# --force so re-runs overwrite a prior seed cleanly (throwaway repo).
git push --force -u origin main

echo ""
echo "Pushed. This triggers '${REPO}-deploy-pipeline'. Monitor with:"
echo "  scripts/09-monitor-pipeline.sh ${REPO}-deploy-pipeline"
