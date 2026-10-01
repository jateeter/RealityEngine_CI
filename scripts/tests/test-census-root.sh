#!/usr/bin/env bash
# Unit tests for where scripts/census-legacy-event-keys.py looks, and what it
# does when a repository is not there (RealityEngine_CI#491).
#
# It used to read a hardcoded developer workspace path and only note a missing
# repository on stderr, so on the hosted runner it scanned nothing and passed.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CENSUS="$CI_DIR/scripts/census-legacy-event-keys.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected $2, got $1)"; FAIL=$((FAIL+1)); fi; }

REPOS=(RealityEngine_CI RealityEngine_Manager RealityEngine_Machines RealityEngine_CPP
       RealityEngine_LSP RealityEngine_Scala localAIStack localOpenClawStack localHealthkitBridge)

echo "census-legacy-event-keys.py: root and missing repositories"

# An empty root: nothing scanned must not read as nothing found.
mkdir -p "$TMP/empty"
set +e; python3 "$CENSUS" --root "$TMP/empty" >"$TMP/out" 2>&1; rc=$?; set -e
check "$rc" 1 "an empty root fails rather than passing having scanned nothing"
check "$(grep -c 'not scanned' "$TMP/out")" 1 "the failure names the repositories it could not read"

# Every repository present and clean.
for r in "${REPOS[@]}"; do mkdir -p "$TMP/full/$r"; done
echo '{"events": []}' > "$TMP/full/RealityEngine_CPP/fixture.json"
set +e; python3 "$CENSUS" --root "$TMP/full" >"$TMP/out" 2>&1; rc=$?; set -e
check "$rc" 0 "all nine present with no legacy key passes"

# One repository missing.
rm -rf "$TMP/full/localHealthkitBridge"
set +e; python3 "$CENSUS" --root "$TMP/full" >"$TMP/out" 2>&1; rc=$?; set -e
check "$rc" 1 "one missing repository fails"
check "$(grep -c 'localHealthkitBridge' "$TMP/out")" 2 "and is named (stderr note plus the failure)"

# A legacy key is still caught under an explicit root.
mkdir -p "$TMP/full/localHealthkitBridge"
echo '{"sequences": [{"vectors": []}]}' > "$TMP/full/RealityEngine_CPP/fixture.json"
set +e; python3 "$CENSUS" --root "$TMP/full" >"$TMP/out" 2>&1; rc=$?; set -e
check "$rc" 1 "a legacy key under --root is still a failure"

# The default root is the directory containing this repository.
check "$(python3 -c "import importlib.util as u; s=u.spec_from_file_location('c','$CENSUS'); m=u.module_from_spec(s); s.loader.exec_module(m); print(m.ROOT)")" \
      "$(cd "$CI_DIR/.." && pwd -P)" "the default root is the parent of RealityEngine_CI"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
