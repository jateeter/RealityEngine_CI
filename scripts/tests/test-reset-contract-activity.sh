#!/usr/bin/env bash
# Unit tests for the registration-activity assertions in
# scripts/regression-reset-contract.py (RealityEngine_CI#358).
#
# The stage once passed while carrying a 2-1 activity split at registration, in
# one direction and then the other, because `compare_declared` compares
# membership only and `ingress_violations` skips everything but sensors. These
# pin the two assertions that close it:
#
#   - `compare_activity` reports a split on a test source as clusters, with the
#     verdict identical whichever runtime dissents (no reference member, #138);
#   - `registration_activity_violations` names the runtime the settled rule
#     disagrees with — test active iff its interned sequence is non-empty;
#   - sensor activity is left alone by both: it is earned by ingress, which is
#     not equal across runtimes on a lane with a live bridge.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/harness.py" <<'PYEOF'
import importlib.util, sys
from pathlib import Path

path = Path(sys.argv[1]) / "scripts" / "regression-reset-contract.py"
spec = importlib.util.spec_from_file_location("reset_contract_stage", path)
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)

def src(name, kind, active, inputs=None, last=None):
    source = {"name": name, "type": kind, "active": active,
              "region": {"offset": 10, "length": 4}, "machineName": name}
    if inputs is not None:
        source["inputs"] = inputs
    if last is not None:
        source["lastUpdated"] = last
    return source

def sets(per_runtime):
    return {rid: stage.source_map(sources) for rid, sources in per_runtime.items()}

mode = sys.argv[2]
armed = src("Fall Detection", "test", True, inputs=[[0, 1]])
paused = src("Fall Detection", "test", False, inputs=[[0, 1]])
empty = src("Empty Machine", "test", False, inputs=[])

if mode == "agree":
    s = sets({"cpp-1": [armed], "lsp-1": [armed], "scala-1": [armed]})
    print(len(stage.compare_activity(s)),
          sum(len(stage.registration_activity_violations(r, e)) for r, e in s.items()))
elif mode == "split-scala":
    s = sets({"cpp-1": [armed], "lsp-1": [armed], "scala-1": [paused]})
    print(stage.compare_activity(s)[0])
    print("|".join(r for r, e in s.items() if stage.registration_activity_violations(r, e)))
elif mode == "split-cpp":
    s = sets({"cpp-1": [paused], "lsp-1": [armed], "scala-1": [armed]})
    print(stage.compare_activity(s)[0])
elif mode == "empty-sequence":
    # Inactive is the right answer for a test source with nothing interned.
    s = sets({"cpp-1": [empty], "lsp-1": [empty], "scala-1": [empty]})
    print(sum(len(stage.registration_activity_violations(r, e)) for r, e in s.items()))
elif mode == "sensor-split":
    fed = src("mqtt:a/b", "sensor", True, last=1)
    unfed = src("mqtt:a/b", "sensor", False)
    s = sets({"cpp-1": [fed], "lsp-1": [unfed], "scala-1": [unfed]})
    print(len(stage.compare_activity(s)),
          sum(len(stage.registration_activity_violations(r, e)) for r, e in s.items()))
PYEOF

run() { python3 "$TMP/harness.py" "$CI_DIR" "$1"; }

echo "registration activity (#358)"
assert_eq "$(run agree)" "0 0" "three runtimes that agree with the rule report nothing"

out="$(run split-scala)"
assert_eq "$(sed -n 1p <<<"$out")" \
  "source 'Fall Detection::test::10::4' activity differs across runtimes: cpp-1+lsp-1=True | scala-1=False" \
  "a 2-1 split is reported as clusters carrying each value"
assert_eq "$(sed -n 2p <<<"$out")" "scala-1" "the rule names the runtime it disagrees with"

assert_eq "$(run split-cpp)" \
  "source 'Fall Detection::test::10::4' activity differs across runtimes: lsp-1+scala-1=True | cpp-1=False" \
  "the verdict has the same form whichever runtime dissents"

assert_eq "$(run empty-sequence)" "0" "a test source with an empty interned sequence is correctly inactive"
assert_eq "$(run sensor-split)" "0 0" "sensor activity is left to the ingress checks"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
