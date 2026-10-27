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
echo "== content measures =="

# The status comparison cannot see a change of corpus: two passing runs on
# different corpora compare as identical. The measures are what can.
cat > "$TMP/meas.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("rr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
PASSING = {"build": {"status": "passed", "failures": []}}
def run(measures):
    return dict(PASSING, measures=measures)
three = lambda n: {"cpp-1": n, "lsp-1": n, "scala-1": n}
what = sys.argv[2]
if what == "corpus-grew":
    r = m.compare_runs(run({"machines": three(44)}), run({"machines": three(41)}), "prev")
    print(json.dumps({"sections": len(r["changes"]), "measures": [c["measure"] for c in r["measureChanges"]]}))
elif what == "same":
    r = m.compare_runs(run({"machines": three(44)}), run({"machines": three(44)}), "prev")
    print(len(r["measureChanges"]))
elif what == "old-baseline":
    r = m.compare_runs(run({"machines": three(44), "openclaw.agents": 18}), dict(PASSING), "prev")
    print(len(r["measureChanges"]))
elif what == "new-measure":
    r = m.compare_runs(run({"machines": three(44), "openclaw.agents": 18}), run({"machines": three(44)}), "prev")
    print(len(r["measureChanges"]))
elif what == "describe-agree":
    print(m.describe_change({"measure": "machines", "previous": three(41), "current": three(44)}))
elif what == "describe-split":
    print(m.describe_change({"measure": "machines", "previous": three(41),
                             "current": {"cpp-1": 44, "lsp-1": 43, "scala-1": 44}}))
elif what == "describe-list":
    print(m.describe_change({"measure": "escalation.machines", "previous": ["a"], "current": ["a", "b"]}))
elif what == "summary":
    r = m.compare_runs(run({"machines": three(44)}), run({"machines": three(41)}), "prev")
    print(m.summary_markdown(__import__("pathlib").Path("."), {"manifest": {}}, r))
PYEOF
meas() { python3 "$TMP/meas.py" "$TOOL" "$1"; }

assert_eq "$(meas corpus-grew)" '{"sections": 0, "measures": ["machines"]}' \
  "a passing run on a larger corpus changes no section but changes a measure"
assert_eq "$(meas same)" "0" "an unchanged measure is not reported"
assert_eq "$(meas old-baseline)" "0" \
  "a baseline written before measures existed reports no measure as changed"
assert_eq "$(meas new-measure)" "0" "a measure only the current run carries is not a change"
assert_eq "$(meas describe-agree)" "machines: 41 on every instance -> 44 on every instance" \
  "instances that agree collapse to one value"
assert_eq "$(meas describe-split)" \
  'machines: 41 on every instance -> {"cpp-1": 44, "lsp-1": 43, "scala-1": 44}' \
  "instances that disagree keep every instance's value"
assert_eq "$(meas describe-list)" "escalation.machines: +b" "a list measure names what was added"
assert_eq "$(meas summary | grep -c -- '- Changed measures: `1`')" "1" "the summary counts the changed measures"
assert_eq "$(meas summary | grep -c -- '  - machines: 41 on every instance -> 44 on every instance')" "1" \
  "and lists each one under the count"

echo
echo "== measures from a run directory =="

R="$TMP/run"; mkdir -p "$R/reports" "$R/logs" "$R/responses/trajectory-parity"
printf '{"counts":{"cpp-1":44,"lsp-1":44,"scala-1":44},"failures":[]}' > "$R/reports/machine-set-parity.json"
printf '{"internedTestSources":{"cpp-1":26},"seedSteps":31,"arbiterConfig":{"cpp-1":{"registryEntries":2837}}}' \
  > "$R/responses/trajectory-parity/trajectory-summary.json"
printf '{"stack":{"body":{"services":{"pe":{"sensor_count":67},"re":{"machine_count":44}}}}}' > "$R/reports/local-ai.json"
printf 'checked 18 agent(s) derived from x\nagent specs are current\n' > "$R/logs/agent-corpus-current.log"
printf '{"escalations":{"cpp-1":{"RED":5}},"escalatingMachines":{"cpp-1":{"m2":{},"m1":{}}}}' \
  > "$R/reports/escalation-dispatch.json"
cat > "$TMP/collect.py" <<'PYEOF'
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("rr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.collect_measures(Path(sys.argv[2])), sort_keys=True))
PYEOF
got="$(python3 "$TMP/collect.py" "$TOOL" "$R")"
assert_eq "$got" '{"escalation.dispatches": {"cpp-1": {"RED": 5}}, "escalation.machines": {"cpp-1": ["m1", "m2"]}, "localAi.peSensors": 67, "localAi.reMachines": 44, "machines": {"cpp-1": 44, "lsp-1": 44, "scala-1": 44}, "openclaw.agents": 18, "trajectory.contendedCells": {"cpp-1": 2837}, "trajectory.internedTestSources": {"cpp-1": 26}, "trajectory.seedSteps": 31}' \
  "every measure is read from the report that holds it"
assert_eq "$(python3 "$TMP/collect.py" "$TOOL" "$TMP/absent")" "{}" \
  "a run that produced no reports has no measures, not zeros"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
