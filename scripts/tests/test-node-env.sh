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
# Every pin in this repo names the same minor as establish_node.
check "$(cat "$CI_DIR/.nvmrc")" "$RE_NODE_VERSION" ".nvmrc pins $RE_NODE_VERSION"
check "$(grep -hoE "node-version: '[^']+'" "$CI_DIR"/.github/workflows/*.yml | sort -u)" "node-version: '$RE_NODE_VERSION'" \
  "every workflow pins node-version $RE_NODE_VERSION"
check "$(git -C "$CI_DIR" grep -hoE '^FROM node:[^ ]+' -- '*Dockerfile*' | sort -u)" "FROM node:$RE_NODE_VERSION-alpine" \
  "every Dockerfile builds on node:$RE_NODE_VERSION-alpine"
case $- in *u*) u=on ;; *) u=off ;; esac
check "$u" on "the caller's set -u survives sourcing nvm"
check "$(NVM_DIR=/nonexistent bash -c "source '$CI_DIR/scripts/lib/node-env.sh'; establish_node 2>/dev/null; echo \$?")" 1 \
  "no nvm is a stated failure, not a silent fall back to PATH"
for f in startUniverse.sh scripts/run-all-tests.sh scripts/deploy-validate-agent.sh; do
  check "$(grep -c '^establish_node' "$CI_DIR/$f")" 1 "$f establishes Node"
done
echo ""; echo "  $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
