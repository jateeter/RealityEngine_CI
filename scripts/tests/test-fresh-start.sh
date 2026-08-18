#!/usr/bin/env bash
# Unit tests for scripts/lib/fresh-start.sh (RealityEngine_CI#144).
#
# --fresh used to remove a Docker volume matching *_perception_sources_data.
# No such volume exists on any host any more — the native multi-engine universe
# does not use it and localAIStack uses bind mounts — so the block found
# nothing, removed nothing, and printed "Perception volume cleared" anyway.
# Meanwhile the Scala PE restored its persisted sources on every start, because
# FRESH_START was never propagated to the engine launches.
#
# These pin what replaced it: the on-disk stores are found and removed, the
# count is honest, and ingested provider content is not touched unless asked.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}
assert_absent() {
  if [ ! -e "$1" ]; then echo "  PASS: $2"; PASS=$((PASS+1))
  else echo "  FAIL: $2 (still present: $1)"; FAIL=$((FAIL+1)); fi
}
assert_present() {
  if [ -e "$1" ]; then echo "  PASS: $2"; PASS=$((PASS+1))
  else echo "  FAIL: $2 (missing: $1)"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Helpers the lib expects from startUniverse.sh.
info() { :; }
ok()   { :; }
WARNS=()
add_warn() { WARNS+=("$*"); }

build_tree() {
  rm -rf "$TMP/tree"; mkdir -p "$TMP/tree"
  SCALA_DIR="$TMP/tree/RealityEngine_Scala"
  MGR_DIR="$TMP/tree/RealityEngine_Manager"
  CPP_DIR="$TMP/tree/RealityEngine_CPP"
  LSP_DIR="$TMP/tree/RealityEngine_LSP"
  LAS_DIR="$TMP/tree/localAIStack"
  # Scala persists per-instance and, when DATA_PATH is unset, to ./data.
  mkdir -p "$SCALA_DIR/data" "$SCALA_DIR/data-scala-1" "$SCALA_DIR/data-scala-2"
  echo '{"sources":[]}' > "$SCALA_DIR/data/perception-sources.json"
  echo '{"sources":[]}' > "$SCALA_DIR/data-scala-1/perception-sources.json"
  echo '{"sources":[]}' > "$SCALA_DIR/data-scala-2/perception-sources.json"
  mkdir -p "$MGR_DIR/perception-engine/backend/data"
  echo '{"sources":[]}' > "$MGR_DIR/perception-engine/backend/data/perception-sources.json"
  # C++ and LSP hold sources in memory; nothing on disk to find.
  mkdir -p "$CPP_DIR" "$LSP_DIR"
  mkdir -p "$LAS_DIR/volumes/redis" "$LAS_DIR/volumes/qdrant"
  echo 'appendonly' > "$LAS_DIR/volumes/redis/appendonly.aof"
  echo 'vectors'    > "$LAS_DIR/volumes/qdrant/segment.dat"
}

source "$CI_DIR/scripts/lib/fresh-start.sh"

echo "== _perception_state_paths =="

build_tree
FRESH_PROVIDER_CONTENT=false
assert_eq "$(_perception_state_paths | wc -l | tr -d ' ')" "4" \
  "finds every persisted PE store (scala x2 instances + scala default + manager)"

# The engine that persists is not necessarily the engine in --engines. A store
# whose engine is not running this time still has to go.
assert_eq "$(_perception_state_paths | grep -c 'data-scala-2')" "1" \
  "includes an instance store whose engine is not in this run"

rm -rf "$TMP/tree/RealityEngine_Scala/data-scala-1"
assert_eq "$(_perception_state_paths | wc -l | tr -d ' ')" "3" \
  "unmatched glob contributes nothing (no literal pattern leaks through)"

echo
echo "== clear_perception_state =="

build_tree
FRESH_PROVIDER_CONTENT=false
WARNS=()
clear_perception_state
assert_absent "$SCALA_DIR/data-scala-1/perception-sources.json" "scala instance store removed"
assert_absent "$SCALA_DIR/data/perception-sources.json"         "scala default store removed"
assert_absent "$MGR_DIR/perception-engine/backend/data/perception-sources.json" \
  "manager (TypeScript PE) store removed"
assert_eq "$(ls "$LAS_DIR/volumes/redis" | wc -l | tr -d ' ')" "0" "redis session state cleared"
assert_eq "${#WARNS[@]}" "0" "no warnings on a clean run"

# The line this replaced would have wiped the vector store as a side effect of
# asking for a fresh universe. Ingested documents are content, not run state.
assert_present "$LAS_DIR/volumes/qdrant/segment.dat" \
  "qdrant vector store survives --fresh"

echo
echo "== --fresh-provider-content =="

build_tree
FRESH_PROVIDER_CONTENT=true
WARNS=()
clear_perception_state
assert_eq "$(ls "$LAS_DIR/volumes/qdrant" | wc -l | tr -d ' ')" "0" \
  "qdrant cleared only when explicitly asked"

echo
echo "== nothing to clear =="

rm -rf "$TMP/tree"; mkdir -p "$TMP/tree"
SCALA_DIR="$TMP/tree/a"; MGR_DIR="$TMP/tree/b"; CPP_DIR="$TMP/tree/c"
LSP_DIR="$TMP/tree/d"; LAS_DIR="$TMP/tree/e"
FRESH_PROVIDER_CONTENT=false
WARNS=()
clear_perception_state
assert_eq "${#WARNS[@]}" "0" "an empty tree is not an error"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
