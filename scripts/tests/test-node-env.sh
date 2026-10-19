#!/usr/bin/env bash
# Unit tests for scripts/lib/node-env.sh: Node is established, never inherited
# from the terminal (RealityEngine_Machines#126). Skips where nvm is absent.
set -euo pipefail
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then echo "  SKIP: nvm not installed here"; exit 0; fi
PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }
echo "node-env.sh"
# shellcheck source=../lib/node-env.sh
source "$CI_DIR/scripts/lib/node-env.sh"
establish_node
check "$(node -v | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')" "$RE_NODE_VERSION" "establish_node selects Node $RE_NODE_VERSION, the minor, not just the major"
# One minor everywhere, held in .nvmrc. Workflows read it; what cannot read a
# file (image tags, a strict engines range) names it. scripts/advance-node.sh
# moves them all; a Dependabot node-image PR fails here until it has run.
V="$RE_NODE_VERSION"
check "$(tr -d '[:space:]' < "$CI_DIR/.nvmrc")" "$V" ".nvmrc pins $V"
check "$(cat "$CI_DIR"/.github/workflows/*.yml | grep -cE '^[[:space:]]+node-version:' || true)" 0 \
  "no workflow names a node-version literal"
check "$(cat "$CI_DIR"/.github/workflows/*.yml | grep -cE '^[[:space:]]+uses: actions/setup-node@' || true)" \
  "$(cat "$CI_DIR"/.github/workflows/*.yml | grep -cE '^[[:space:]]+node-version-file: ([^ ]+/)?\.nvmrc$' || true)" \
  "every setup-node step reads node-version-file from an .nvmrc"
check "$(git -C "$CI_DIR" grep -hoE '^FROM node:[^ ]+' -- '*Dockerfile*' | sort -u)" "FROM node:$V-alpine" \
  "every Dockerfile builds on node:$V-alpine"
check "$(grep -oE '"node:[^"]+"' "$CI_DIR/release/images.json" | sort -u)" "\"node:$V-bookworm-slim\"" \
  "release/images.json builds OpenClaw on node:$V-bookworm-slim"
# The sibling repos pin the same minor, where they are checked out next to CI.
for repo in RealityEngine_Manager RealityEngine_Machines localAIStack localOpenClawStack OpenCommons-Health---Personal-Information-Management; do
  dir="$CI_DIR/../$repo"; [ -e "$dir/.git" ] || continue
  check "$(git -C "$dir" ls-files '.nvmrc' '*/.nvmrc' | while read -r f; do tr -d '[:space:]' < "$dir/$f"; echo; done | grep -v "^$V\$" | sort -u)" "" \
    "$repo: every .nvmrc pins $V"
  check "$(git -C "$dir" grep -hoE 'node:[0-9]+\.[0-9]+-' -- ':!*.md' | sort -u | grep -vxF "node:$V-" || true)" "" \
    "$repo: every node image names $V"
done
[ "$FAIL" -eq 0 ] || echo "  Node pins disagree: run scripts/advance-node.sh to move every repo to one minor."
case $- in *u*) u=on ;; *) u=off ;; esac
check "$u" on "the caller's set -u survives sourcing nvm"
check "$(NVM_DIR=/nonexistent bash -c "source '$CI_DIR/scripts/lib/node-env.sh'; establish_node 2>/dev/null; echo \$?")" 1 \
  "no nvm is a stated failure, not a silent fall back to PATH"
for f in startUniverse.sh scripts/run-all-tests.sh scripts/deploy-validate-agent.sh; do
  check "$(grep -c '^establish_node' "$CI_DIR/$f")" 1 "$f establishes Node"
done
echo ""; echo "  $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
