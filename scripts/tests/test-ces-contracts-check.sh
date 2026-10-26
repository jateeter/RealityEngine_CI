#!/usr/bin/env bash
# Unit tests for the --check half of scripts/record-ces-contracts.py: the
# comparison of one run with a recorded shard. No engines, no network.
#
# `--check --corpus NAME` compared the run with the per-domain shards and never
# read corpus-NAME.json, the artifact `--corpus NAME --write` produces. The
# regression corpus's localAIStack machines project a `localai` domain, which
# has no domain shard, so the check exited 1 on "no shard on disk" whatever the
# runtimes did, and the corpus shard was never compared with anything. These pin
# the two helpers the corpus path now uses:
#
#   compare_shard            a verdict or committed-output change is drift; a
#                            different stimulus is incomparable, never drift;
#                            a recorded machine the run did not commit is drift
#   corpus_membership_drift  a machine added to, removed from or edited in the
#                            corpus since recording names itself and says to
#                            re-record
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/record-ces-contracts.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/run.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("rc", sys.argv[1])
rc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)
case = json.load(sys.stdin)
if sys.argv[2] == "compare":
    n, drift, why = rc.compare_shard("corpus:t", case["doc"], case["machines"], case["stim"])
    print(json.dumps({"checked": n, "drift": drift, "incomparable": why}))
else:
    print(json.dumps(rc.corpus_membership_drift("corpus:t", case["doc"], case["now"])))
PYEOF
compare() { python3 "$TMP/run.py" "$TOOL" compare; }
members() { python3 "$TMP/run.py" "$TOOL" members; }
field()   { python3 -c "import json,sys; v=json.load(sys.stdin)$1; print(json.dumps(v) if not isinstance(v,(str,int)) or isinstance(v,bool) else v)"; }

A='{"verdict":"agreed","stream":[[1,0]]}'
A2='{"verdict":"agreed","stream":[[0,1]]}'
S='{"verdict":"agreed-silent"}'
STIM='{"residentMachines":2,"seedDepth":31,"steps":31}'
DOC="{\"stimulus\":$STIM,\"machines\":{\"M1\":$A,\"M2\":$S}}"

echo "== compare_shard =="

r="$(printf '{"doc":%s,"machines":{"M1":%s,"M2":%s},"stim":%s}' "$DOC" "$A" "$S" "$STIM" | compare)"
assert_eq "$(field '["drift"]' <<<"$r")" "[]" "an identical run is no drift"
assert_eq "$(field '["checked"]' <<<"$r")" "2" "and every machine is counted as checked"

r="$(printf '{"doc":%s,"machines":{"M1":%s,"M2":%s},"stim":%s}' "$DOC" "$S" "$S" "$STIM" | compare)"
assert_eq "$(field '["drift"][0]' <<<"$r")" "corpus:t/M1: verdict agreed -> agreed-silent" \
  "a changed verdict is drift, named by machine"

r="$(printf '{"doc":%s,"machines":{"M1":%s,"M2":%s},"stim":%s}' "$DOC" "$A2" "$S" "$STIM" | compare)"
assert_eq "$(field '["drift"][0]' <<<"$r")" "corpus:t/M1: same verdict (agreed) but the committed output changed" \
  "a changed committed output under the same verdict is drift"

r="$(printf '{"doc":%s,"machines":{"M1":%s},"stim":%s}' "$DOC" "$A" "$STIM" | compare)"
assert_eq "$(field '["drift"][0]' <<<"$r")" "corpus:t/M2: recorded but not committed by this run" \
  "a recorded machine the run did not commit is drift"

r="$(printf '{"doc":%s,"machines":{"M1":%s,"M2":%s,"M3":%s},"stim":%s}' "$DOC" "$A" "$S" "$A" "$STIM" | compare)"
assert_eq "$(field '["drift"][0]' <<<"$r")" "corpus:t/M3: not in the recorded shard" \
  "a committed machine the shard does not hold is drift"

r="$(printf '{"doc":%s,"machines":{"M1":%s,"M2":%s},"stim":{"residentMachines":2,"seedDepth":79,"steps":79}}' "$DOC" "$S" "$S" | compare)"
assert_eq "$(field '["drift"]' <<<"$r")" "[]" "a different stimulus is never drift, even with changed verdicts"
assert_eq "$(field '["checked"]' <<<"$r")" "0" "and nothing is counted as checked"
assert_eq "$(field '["incomparable"]' <<<"$r")" "corpus:t: recorded under a different stimulus (seedDepth 31 != 79; steps 31 != 79)" \
  "it is reported as incomparable, naming what differs"

echo "== corpus_membership_drift =="

WAS='{"corpusFingerprint":{"members":{"a.json":"h1","b.json":"h2"}}}'
r="$(printf '{"doc":%s,"now":{"members":{"a.json":"h1","b.json":"h2"}}}' "$WAS" | members)"
assert_eq "$r" "[]" "an unchanged corpus is no drift"

r="$(printf '{"doc":%s,"now":{"members":{"a.json":"h1","b.json":"h2","c.json":"h3"}}}' "$WAS" | members)"
assert_eq "$(field '[0]' <<<"$r")" "corpus:t: +c.json (not in the recorded corpus)" "an added machine is named"
assert_eq "$(field '[-1]' <<<"$r")" "corpus:t: re-record with --corpus t --write" "and the remedy is to re-record"

r="$(printf '{"doc":%s,"now":{"members":{"a.json":"h1"}}}' "$WAS" | members)"
assert_eq "$(field '[0]' <<<"$r")" "corpus:t: -b.json (recorded, no longer in the corpus)" "a removed machine is named"

r="$(printf '{"doc":%s,"now":{"members":{"a.json":"h1","b.json":"h9"}}}' "$WAS" | members)"
assert_eq "$(field '[0]' <<<"$r")" "corpus:t: ~b.json (changed since recorded)" "an edited machine is named"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
