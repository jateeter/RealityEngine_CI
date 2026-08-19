#!/usr/bin/env bash
# Unit tests for scripts/regression-trajectory-parity.py (RealityEngine_CI#148).
#
# These pin the comparison, not the transport: the histories are fed in
# directly so the assertions are about what counts as divergence and where it
# is reported, which is the part that decides whether a real defect is found or
# buried.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

run_py() { python3 "$CI_DIR/scripts/tests/_trajectory_probe.py" "$@"; }

cat > "$CI_DIR/scripts/tests/_trajectory_probe.py" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "trajectory", Path(__file__).resolve().parent.parent / "regression-trajectory-parity.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def entry(step, length, cells):
    return {"stepNumber": step, "length": length,
            "nonZero": [{"index": i, "value": v} for i, v in sorted(cells.items())]}


case = sys.argv[1]

if case == "identical":
    h = [entry(0, 32, {0: 1.0}), entry(1, 32, {0: 1.0, 20: 1.0})]
    print(json.dumps(mod.first_divergence({"cpp": h, "lsp": list(h), "scala": list(h)})))

elif case == "value":
    a = [entry(0, 32, {0: 1.0}), entry(1, 32, {0: 1.0, 20: 1.0})]
    b = [entry(0, 32, {0: 1.0}), entry(1, 32, {0: 1.0, 20: 2.0})]
    print(json.dumps(mod.first_divergence({"cpp": a, "lsp": list(a), "scala": b})))

elif case == "first-only":
    # Divergence at step 1 and again at step 2. Only the first is the finding;
    # step 2 is downstream of it.
    a = [entry(0, 32, {0: 1.0}), entry(1, 32, {5: 1.0}), entry(2, 32, {6: 1.0})]
    b = [entry(0, 32, {0: 1.0}), entry(1, 32, {5: 9.0}), entry(2, 32, {6: 9.0})]
    print(json.dumps(mod.first_divergence({"cpp": a, "scala": b})))

elif case == "missing-cell":
    # An absent cell is zero, not "unknown": an engine that wrote nothing where
    # another wrote 1.0 has diverged, and reading absence as a wildcard would
    # hide exactly the case this stage exists to catch.
    a = [entry(0, 32, {0: 1.0, 20: 1.0})]
    b = [entry(0, 32, {0: 1.0})]
    print(json.dumps(mod.first_divergence({"cpp": a, "scala": b})))

elif case == "short-history":
    a = [entry(0, 32, {0: 1.0}), entry(1, 32, {0: 1.0})]
    b = [entry(0, 32, {0: 1.0})]
    print(json.dumps(mod.first_divergence({"cpp": a, "scala": b})))

elif case == "width":
    a = [entry(0, 32, {0: 1.0})]
    b = [entry(0, 64, {0: 1.0})]
    print(json.dumps(mod.first_divergence({"cpp": a, "scala": b})))

elif case == "clusters":
    print(json.dumps(mod.cluster({"cpp": 1.0, "lsp": 1.0, "scala": 2.0})))

elif case == "dense":
    print(json.dumps(mod.dense(entry(0, 32, {3: 1.5}))))
PY

echo "== first_divergence =="

assert_eq "$(run_py identical)" "null" \
  "three identical histories report no divergence"

D="$(run_py value)"
assert_eq "$(echo "$D" | python3 -c 'import json,sys; print(json.load(sys.stdin)["step"])')" "1" \
  "value divergence reports the step it happened on"
assert_eq "$(echo "$D" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cell"])')" "20" \
  "value divergence reports the cell"
assert_eq "$(echo "$D" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])')" "value" \
  "value divergence is labelled as such"
assert_eq "$(echo "$D" | python3 -c 'import json,sys; print(json.load(sys.stdin)["clusters"])')" \
  "[['cpp', 'lsp'], ['scala']]" \
  "agreement clusters name who agreed with whom, with no designated baseline"

assert_eq "$(run_py first-only | python3 -c 'import json,sys; print(json.load(sys.stdin)["step"])')" "1" \
  "only the first divergence is reported, not every downstream consequence"

assert_eq "$(run_py missing-cell | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["cell"], d["values"]["scala"])')" \
  "20 0.0" \
  "a cell absent from nonZero is zero, and disagrees with a written value"

S="$(run_py short-history)"
assert_eq "$(echo "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])')" "historyLength" \
  "an engine that stopped stepping is a length finding, not a value finding"
assert_eq "$(echo "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["step"])')" "1" \
  "the length finding names the step the shorter history ran out"

assert_eq "$(run_py width | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])')" "length" \
  "differing dense widths are reported before comparing cells"

echo
echo "== helpers =="

assert_eq "$(run_py clusters)" '[["cpp", "lsp"], ["scala"]]' \
  "clusters sort by size so the split is legible, not by engine name"
assert_eq "$(run_py dense)" '{"3": 1.5}' \
  "sparse entries expand to index -> value"

rm -f "$CI_DIR/scripts/tests/_trajectory_probe.py"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
