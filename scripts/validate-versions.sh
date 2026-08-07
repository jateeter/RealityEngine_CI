#!/bin/bash
# =============================================================================
# validate-versions.sh — check sibling repos are on compatible refs
#
# Reads the version compatibility table from VERSION-COMPAT.md and verifies
# that each sibling repo's current HEAD commit or branch matches a pinned ref.
# Exits 0 when all repos are compatible; non-zero otherwise.
#
# Usage:  bash scripts/validate-versions.sh [--warn-only]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$SCRIPT_DIR/.."
COMPAT_FILE="$CI_DIR/VERSION-COMPAT.md"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; }

WARN_ONLY=false
for arg in "$@"; do
    [ "$arg" = "--warn-only" ] && WARN_ONLY=true
done

if [ ! -f "$COMPAT_FILE" ]; then
    warn "VERSION-COMPAT.md not found — skipping version validation"
    exit 0
fi

echo "Checking sibling repo version compatibility..."
echo ""

# Parse VERSION-COMPAT.md table: lines like | RealityEngine_Scala | v1.2.3 | main |
# Columns: | Repo | Version/Tag | Branch |
ERRORS=0
while IFS='|' read -r _ repo version branch _; do
    repo="${repo// /}"
    version="${version// /}"
    branch="${branch// /}"
    # Skip header/separator lines
    [[ "$repo" =~ ^-+$ || "$repo" == "Repo" || -z "$repo" ]] && continue

    REPO_DIR="$CI_DIR/../$repo"
    # -e, not -d: in a git worktree .git is a file holding a gitdir: pointer,
    # not a directory. With -d every repo in a worktree layout was "not found
    # (skipping)", every repo was skipped, ERRORS stayed 0, and the script
    # printed "All sibling repos on compatible refs" — reporting success
    # precisely because it had checked nothing. The regression suite builds
    # cold-start worktrees for every run, so that is the one context where
    # this check has never once run.
    if [ ! -e "$REPO_DIR/.git" ]; then
        warn "$repo — not found at $REPO_DIR (skipping)"
        continue
    fi

    CURRENT_BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    CURRENT_REF=$(git -C "$REPO_DIR" describe --tags --exact-match HEAD 2>/dev/null || \
                  git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

    BRANCH_OK=true
    VERSION_OK=true
    if [ -n "$branch" ] && [ "$CURRENT_BRANCH" != "$branch" ]; then
        # A regression run checks each repo out on its own run-local branch
        # created from origin/<branch>, so the name differs while the commit is
        # exactly the expected one. Compatibility is about the commit, not the
        # label, so only call it a mismatch when the commit differs too.
        EXPECTED_SHA=$(git -C "$REPO_DIR" rev-parse --verify -q "origin/$branch" 2>/dev/null || \
                       git -C "$REPO_DIR" rev-parse --verify -q "$branch" 2>/dev/null || echo "")
        HEAD_SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "-")
        if [ -n "$EXPECTED_SHA" ] && [ "$HEAD_SHA" = "$EXPECTED_SHA" ]; then
            CURRENT_BRANCH="$CURRENT_BRANCH (at $branch)"
        else
            BRANCH_OK=false
        fi
    fi
    [ -n "$version" ] && [ "$version" != "any" ] && [ "$CURRENT_REF" != "$version" ] && VERSION_OK=false

    if [ "$BRANCH_OK" = true ] && [ "$VERSION_OK" = true ]; then
        ok "$repo  ($CURRENT_BRANCH @ $CURRENT_REF)"
    elif [ "$BRANCH_OK" = false ]; then
        fail "$repo — on branch '$CURRENT_BRANCH', expected '$branch'"
        ERRORS=$((ERRORS+1))
    else
        warn "$repo — at ref '$CURRENT_REF', expected '$version' (branch OK: $CURRENT_BRANCH)"
        ERRORS=$((ERRORS+1))
    fi
done < "$COMPAT_FILE"

echo ""
if [ "$ERRORS" -gt 0 ]; then
    if [ "$WARN_ONLY" = true ]; then
        warn "$ERRORS version mismatch(es) — proceeding anyway (--warn-only)"
        exit 0
    else
        fail "$ERRORS version mismatch(es) — run with --warn-only to proceed anyway"
        exit 1
    fi
else
    ok "All sibling repos on compatible refs"
fi
