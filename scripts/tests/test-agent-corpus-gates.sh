#!/usr/bin/env bash
# Tests for the two agent-corpus staleness gates (RealityEngine_CI#467).
#
#   item 2  regression-test.sh run_agent_corpus_current: every run, the 15
#           regression agents against the corpus (materialize_agents.py --check)
#   item 3  check-corpus-exit-criteria.py §3.7(4): the agent index records its
#           provenance, and --require-current-digest holds it to today's corpus
#
# Nothing detected a stale agent corpus before these: agents/ sat five weeks
# behind the machine corpus with every gate green.
#
# Item 3 runs against the real corpus and agent corpus, so it needs
# RealityEngine_Machines and localOpenClawStack beside this repo (or MACHINES /
# OPENCLAW set); it skips that half otherwise. The materializer's own negative
# test lives in localOpenClawStack (tests/run_materialize_check_tests.py).
#
# run_agent_corpus_current is eval'd and calls stubs defined here.
# shellcheck disable=SC2034,SC2329
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACHINES="${MACHINES:-$CI_DIR/../RealityEngine_Machines}"
OPENCLAW="${OPENCLAW:-$CI_DIR/../localOpenClawStack}"
CHECK="$CI_DIR/scripts/check-corpus-exit-criteria.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }

echo "item 2: run_agent_corpus_current"
eval "$(sed -n '/^run_agent_corpus_current() {/,/^}/p' "$CI_DIR/scripts/regression-test.sh")"
step() { :; }; log() { :; }
SKIPPED=""; CMD=""
write_skip_report() { SKIPPED="$1"; }
run_cmd() { shift; CMD="$*"; }
repo_root() { echo "/ws/$1"; }
repo_present() { [ "$PRESENT" = yes ]; }
PRESENT=yes; run_agent_corpus_current
check "$CMD" "env MACHINES_DIR=/ws/RealityEngine_Machines/machines python3 /ws/localOpenClawStack/machine-behaviors/materialize_agents.py --check --manifest /ws/RealityEngine_CI/config/regression-corpus.txt" \
  "runs the materializer's --check, scoped to the regression corpus, against the run's trees"
PRESENT=no; CMD=""; run_agent_corpus_current
check "$SKIPPED|$CMD" "agent-corpus-current-skipped.json|" "without localOpenClawStack it records a skip and runs nothing"
check "$(grep -c '^run_stage "agent-corpus-current" run_agent_corpus_current$' "$CI_DIR/scripts/regression-test.sh")" 1 \
  "it is a run_stage, so a stale agent fails the run"

echo "item 3: §3.7(4) provenance"
INDEX="$OPENCLAW/machine-behaviors/agents/INDEX.json"
if [ ! -f "$INDEX" ] || [ ! -d "$MACHINES/machines" ]; then
  echo "  skip: needs RealityEngine_Machines and localOpenClawStack (MACHINES=$MACHINES OPENCLAW=$OPENCLAW)"
else
  gate() {  # <index> [flags...] -> exit status
    local idx="$1"; shift
    set +e; python3 "$CHECK" --machines "$MACHINES" --openclaw "$OPENCLAW" --index "$idx" "$@" > "$TMP/out" 2>&1; local rc=$?; set -e
    echo "$rc"
  }
  python3 - "$INDEX" "$TMP" <<'PY'
import json, sys
src, tmp = sys.argv[1], sys.argv[2]
d = json.load(open(src))
stale = json.loads(json.dumps(d)); stale["provenance"]["corpus"]["digest"] = "sha256:" + "0" * 64
json.dump(stale, open(f"{tmp}/stale.json", "w"))
bare = {k: v for k, v in d.items() if k != "provenance"}
json.dump(bare, open(f"{tmp}/bare.json", "w"))
PY
  check "$(gate "$TMP/bare.json")" 1 "an index with no provenance fails"
  check "$(grep -c 'FAIL §3.7(4) agent index records its provenance' "$TMP/out")" 1 "and names §3.7(4)"
  check "$(gate "$TMP/stale.json")" 0 "a stale digest passes without --require-current-digest (per-run is item 2's job)"
  check "$(gate "$TMP/stale.json" --require-current-digest)" 1 "a stale digest fails with --require-current-digest"
  check "$(grep -c 'FAIL §3.7(4) provenance names the current corpus' "$TMP/out")" 1 "and says which corpus it names"
  rc=$(gate "$INDEX" --require-current-digest)
  if [ "$rc" = 0 ]; then
    check "$rc" 0 "the committed index names the current corpus"
  else
    echo "  note: the committed index is stale against this corpus checkout; the weekly job would file drift:"
    grep '§3.7(4)' "$TMP/out" | sed 's/^/        /'
  fi
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
