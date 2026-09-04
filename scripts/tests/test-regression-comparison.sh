#!/usr/bin/env bash
# Unit tests for failure_key and the comparison baseline in
# scripts/regression-report.py.
#
# The run-over-run comparison never had a baseline on the hosted lane: it looks
# for a previous run *directory*, and that lane's workspace is fresh every run.
# Every scheduled run reported `not-compared`, so the
# "New failures: 0 / Resolved failures: 0" line in each auto-filed issue was
# structurally zero whatever had happened (jateeter/RealityEngine_CI#230).
#
# Turning it on has a trap. `compare_runs` diffs failure *strings*, and since
# #174 the universal-vectors line carries per-runtime source counts that
# legitimately move between runs — so a naive diff reports one ongoing failure
# as both new and resolved every night, noise shaped exactly like the churn the
# comparison exists to surface.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/regression-report.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cmp.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("rr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

STIM_A = ("event-1 parity mismatch: cpp-1+scala-1 | lsp-1 "
          "[stimulus DIFFERS — source counts {'cpp-1': 1, 'lsp-1': 2, 'scala-1': 1}]")
STIM_B = ("event-1 parity mismatch: cpp-1+scala-1 | lsp-1 "
          "[stimulus DIFFERS — source counts {'cpp-1': 3, 'lsp-1': 9, 'scala-1': 3}]")
OTHER  = "event-2 parity mismatch: cpp-1+lsp-1 | scala-1 [stimulus equal — same sources on every runtime]"

def cmp(cur, prev):
    return m.compare_runs(
        {"universalVectors": {"status": "failed", "failures": cur}},
        {"universalVectors": {"status": "failed", "failures": prev}},
        "prev-run")

what = sys.argv[2]
if what == "key-same":
    print("same" if m.failure_key(STIM_A) == m.failure_key(STIM_B) else "DIFFERENT")
elif what == "key-distinct":
    print("distinct" if m.failure_key(STIM_A) != m.failure_key(OTHER) else "COLLIDED")
elif what == "ongoing":
    r = cmp([STIM_B], [STIM_A])
    print(json.dumps({"new": len(r["newFailures"]), "resolved": len(r["resolvedFailures"])}))
elif what == "new":
    r = cmp([STIM_A, OTHER], [STIM_A])
    print(json.dumps({"new": len(r["newFailures"]), "resolved": len(r["resolvedFailures"])}))
elif what == "resolved":
    r = cmp([STIM_A], [STIM_A, OTHER])
    print(json.dumps({"new": len(r["newFailures"]), "resolved": len(r["resolvedFailures"])}))
elif what == "display-full":
    r = cmp([STIM_A, OTHER], [STIM_A])
    print(r["newFailures"][0]["failure"])
elif what == "no-baseline":
    r = m.compare_runs({"build": {"status": "failed", "failures": ["x"]}}, None, "")
    print(r["status"])
PYEOF
cmp() { python3 "$TMP/cmp.py" "$TOOL" "$1"; }

echo "== failure_key =="

# The trap, stated as a test: same failure, counts moved.
assert_eq "$(cmp key-same)" "same" \
  "one ongoing failure keeps its identity when source counts move"

assert_eq "$(cmp key-distinct)" "distinct" \
  "different events with different cluster shapes stay distinct"

echo
echo "== compare_runs =="

assert_eq "$(cmp ongoing)" '{"new": 0, "resolved": 0}' \
  "an ongoing failure is neither new nor resolved"

assert_eq "$(cmp new)" '{"new": 1, "resolved": 0}' \
  "a failure that appears is reported new, exactly once"

assert_eq "$(cmp resolved)" '{"new": 0, "resolved": 1}' \
  "a failure that clears is reported resolved, exactly once"

# Identity is normalised; the human-readable string is not.
assert_eq "$(cmp display-full)" \
  "event-2 parity mismatch: cpp-1+lsp-1 | scala-1 [stimulus equal — same sources on every runtime]" \
  "the reported failure keeps its full text, annotation included"

assert_eq "$(cmp no-baseline)" "not-compared" \
  "with no baseline the comparison says so rather than inventing one"

echo
echo "== baseline from a status file =="

# The hosted lane's path: no previous run directory, one carried-forward file.
mkdir -p "$TMP/hist/runs"
cat > "$TMP/baseline.json" <<'JSON'
{"runId": "gha-prev-1",
 "build": {"status": "passed", "failures": []},
 "universalVectors": {"status": "failed", "failures": ["event-1 parity mismatch: a | b"]}}
JSON

cat > "$TMP/base.py" <<'PYEOF'
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("rr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
prev, prev_id = m.load_baseline(Path(sys.argv[2]), "gha-now-1", "", Path(sys.argv[3]) if sys.argv[3] else None)
print(json.dumps({"found": prev is not None, "id": prev_id}))
PYEOF

assert_eq "$(python3 "$TMP/base.py" "$TOOL" "$TMP/hist" "$TMP/baseline.json")" \
  '{"found": true, "id": "gha-prev-1"}' \
  "a carried-forward status file is used as the baseline, and names its run"

assert_eq "$(python3 "$TMP/base.py" "$TOOL" "$TMP/hist" "$TMP/absent.json")" \
  '{"found": false, "id": ""}' \
  "an absent baseline file degrades to no comparison, not a crash"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
