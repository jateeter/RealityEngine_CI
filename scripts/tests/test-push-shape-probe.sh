#!/usr/bin/env bash
# Unit tests for shape_probe in scripts/regression-pe-step-contract.py.
#
# The gate read `set(step.keys())` and stopped — one level deep. Two places the
# runtimes actually diverge sit outside it, so the stage whose entire job is
# catching payload-shape divergence could not see them
# (jateeter/RealityEngine_CI#231):
#
#   * the response top level, where `dispatch` lives — emitted by C++, absent
#     from LSP and Scala
#   * inside `mergeBatch`, where LSP's `valuesPacked` split the runtimes, was
#     fixed, and regressed with no gate looking at that depth
#     (jateeter/RealityEngine_CI#208, closed COMPLETED then reproduced five days
#     later)
#
# These pin the probe points, and the distinction between a runtime disagreeing
# with its peers and a runtime disagreeing with itself.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/regression-pe-step-contract.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A push response arrives on stdin. Prints either the probe points, one probe
# point's key set, or the intra-runtime problems, per argv[2].
cat > "$TMP/probe.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("pesc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
shape, problems = m.shape_probe(json.load(sys.stdin))
what = sys.argv[2]
if what == "probes":     print(json.dumps(sorted(shape)))
elif what == "problems": print(json.dumps(problems))
else:                    print(json.dumps(shape.get(what, "<absent>")))
PYEOF
probe() { python3 "$TMP/probe.py" "$TOOL" "$1"; }

# The shape the three runtimes actually produced in run 33739002606.
CPP='{"success":true,"timestamp":1,"globalStep":12,"error":null,"dispatch":{"dispatchRecordsCreated":2},
      "step":{"stepNumber":1,"mergeBatch":[{"machineId":"m","values":[1],"region":{},"provenance":[],"governance":{},"sequenceIds":[]}]}}'
LSP='{"success":true,"timestamp":1,"globalStep":17,
      "step":{"stepNumber":1,"mergeBatch":[{"machineId":"m","values":[1],"region":{},"provenance":[],"governance":{},"sequenceIds":[],"valuesPacked":{"bitsPerElement":8}}]}}'

echo "== shape_probe =="

assert_eq "$(printf '%s' "$CPP" | probe probes)" \
  '["response", "step", "step.mergeBatch[]"]' \
  "probes the response top level, step, and inside mergeBatch"

# The divergence that was invisible: dispatch is a sibling of step, so a gate
# reading step.keys() can never see it.
assert_eq "$(printf '%s' "$CPP" | probe response)" \
  '["dispatch", "error", "globalStep", "step", "success", "timestamp"]' \
  "top-level keys include dispatch on the runtime that emits it"

assert_eq "$(printf '%s' "$LSP" | probe response)" \
  '["globalStep", "step", "success", "timestamp"]' \
  "top-level keys omit dispatch on a runtime that does not emit it"

# #208, at the depth no gate was looking.
assert_eq "$(printf '%s' "$LSP" | probe 'step.mergeBatch[]')" \
  '["governance", "machineId", "provenance", "region", "sequenceIds", "values", "valuesPacked"]' \
  "mergeBatch element keys include valuesPacked where it is emitted"

assert_eq "$(printf '%s' "$CPP" | probe 'step.mergeBatch[]')" \
  '["governance", "machineId", "provenance", "region", "sequenceIds", "values"]' \
  "mergeBatch element keys omit it where it is not"

# Union rather than element 0: a runtime whose own elements disagree would
# otherwise be represented by whichever element happened to come first.
MIXED='{"success":true,"step":{"mergeBatch":[{"a":1},{"a":1,"b":2}]}}'
assert_eq "$(printf '%s' "$MIXED" | probe 'step.mergeBatch[]')" \
  '["a", "b"]' \
  "mergeBatch elements are unioned, not sampled"

# ...and that self-disagreement is reported as a local defect, separately from
# cross-runtime divergence, because it has a different cause.
assert_eq "$(printf '%s' "$MIXED" | probe problems)" \
  '["mergeBatch elements disagree with each other: [[\"a\"], [\"a\", \"b\"]]"]' \
  "a runtime disagreeing with itself is reported as its own problem"

CONSISTENT='{"success":true,"step":{"mergeBatch":[{"a":1},{"a":2}]}}'
assert_eq "$(printf '%s' "$CONSISTENT" | probe problems)" \
  '[]' \
  "elements with equal key sets and different values are not a problem"

# Degenerate shapes must not crash the gate or silently report agreement.
assert_eq "$(printf '%s' '{"success":true}' | probe probes)" \
  '["response"]' \
  "a response with no step yields the top level only"

assert_eq "$(printf '%s' '{"success":true,"step":{"mergeBatch":[]}}' | probe probes)" \
  '["response", "step"]' \
  "an empty mergeBatch contributes no element probe point"

assert_eq "$(printf '%s' '[1,2,3]' | probe problems)" \
  '["response was not an object"]' \
  "a non-object response is a problem, not an empty shape"

echo
echo "== KNOWN_SHAPE_DIVERGENCE register =="

# The register is what keeps the gate honest without turning a green stage red
# on defects the same change is not fixing. It only works if entries are
# scoped to probe points that genuinely diverge today, and if removing one
# tightens the gate with no other edit.
cat > "$TMP/register.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("pesc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(sorted(m.KNOWN_SHAPE_DIVERGENCE)))
PYEOF

assert_eq "$(python3 "$TMP/register.py" "$TOOL")" \
  '["response", "step.mergeBatch[]"]' \
  "register covers exactly the two probe points diverging today"

# `step` must never be registered: it is the one level the spec pins and the
# gate has always enforced. Registering it would silently retire the original
# contract check.
cat > "$TMP/step-not-registered.py" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pesc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("clean" if "step" not in m.KNOWN_SHAPE_DIVERGENCE else "STEP IS REGISTERED")
PYEOF

assert_eq "$(python3 "$TMP/step-not-registered.py" "$TOOL")" \
  "clean" \
  "\`step\` is never registered — the spec pins it and the gate enforces it"

# Every entry has to name the issue that will retire it, or the register
# becomes a list of divergences with no owner.
cat > "$TMP/register-cited.py" <<'PYEOF'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("pesc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
uncited = [k for k, v in m.KNOWN_SHAPE_DIVERGENCE.items() if not re.search(r"#\d+", str(v))]
print("cited" if not uncited else f"UNCITED: {uncited}")
PYEOF

assert_eq "$(python3 "$TMP/register-cited.py" "$TOOL")" \
  "cited" \
  "every register entry cites the issue that retires it"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
