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
# `error` is null on this fixture and so is not an observation: a key present as
# null and a key absent say the same thing. C++ and Scala carry `error: null` on
# a success response where LSP omits it entirely, and treating that as different
# key sets reports a formatting choice as a contract divergence.
assert_eq "$(printf '%s' "$CPP" | probe response)" \
  '["dispatch", "globalStep", "step", "success", "timestamp"]' \
  "top-level keys include dispatch, and drop the null-valued error"

assert_eq "$(printf '%s' '{"success":true,"error":null,"step":{"a":1}}' | probe response)" \
  '["step", "success"]' \
  "a null-valued key is not an observation"

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
echo "== BOUNDARY_FILTERED =="

# SURFACE_SPEC.md, "The observable boundary": a runtime may carry more on its
# internal hop, and when that reaches an observable route the correct handling
# is to filter it there — not to require the others to implement it. An earlier
# revision of this gate reported these as divergences awaiting a fix, which is
# the reading that nearly had base64 bit-packing implemented in a third runtime
# to satisfy a field no consumer reads (#208).
cat > "$TMP/filtered.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("pesc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
what = sys.argv[2]
if what == "probes":
    print(json.dumps(sorted(m.BOUNDARY_FILTERED)))
elif what == "step-absent":
    print("clean" if "step" not in m.BOUNDARY_FILTERED else "STEP IS FILTERED")
else:
    print(json.dumps(sorted(m.BOUNDARY_FILTERED.get(what, []))))
PYEOF
filtered() { python3 "$TMP/filtered.py" "$TOOL" "$1"; }

assert_eq "$(filtered probes)" \
  '["response", "step.mergeBatch[]"]' \
  "filtering is scoped to the two probe points carrying internal augmentation"

assert_eq "$(filtered 'step.mergeBatch[]')" \
  '["valuesPacked"]' \
  "valuesPacked is filtered, per SURFACE_SPEC's already-settled instances"

assert_eq "$(filtered response)" \
  '["dispatch", "id"]' \
  "dispatch and scala's top-level id are filtered, as parity_identity already does"

# `step` is the one level SURFACE_SPEC pins and the gate has always enforced.
# Filtering anything there would silently retire the original contract check.
assert_eq "$(filtered step-absent)" \
  "clean" \
  "nothing is filtered at \`step\` — the spec pins that level"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
