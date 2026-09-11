#!/usr/bin/env bash
# Unit tests for the quorum classification in scripts/regression-ces-contracts.py.
#
# This stage replaces a recorder that replayed the corpus through one nominated
# engine, which made that engine unfalsifiable: regenerating made it pass by
# construction, so the gate could never find a defect in the thing it was
# judged against (RealityEngine_CI#327).
#
# What replaced it is 3-of-3 agreement, and these pin the properties that
# matter if that replacement is to be worth anything:
#
#   - a 2-1 split records as a disagreement carrying every party's stream, not
#     as a contract with a noted outlier;
#   - unanimous silence records as "no runtime emits", not as a contract with
#     an empty stream;
#   - a runtime that could not be driven is neither silence nor agreement;
#   - the verdict does not depend on which runtime dissents.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/regression-ces-contracts.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/drive.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("cc", sys.argv[1])
cc = importlib.util.module_from_spec(spec); spec.loader.exec_module(cc)
results = json.load(sys.stdin)
chain = {"id": "M.json::seq::term", "machineFile": "M.json", "machineName": "M",
         "sequenceId": "seq", "terminalEventId": "term",
         "inputRegion": {"offset": 0, "length": 2}, "inputs": [[1, 0]]}
v = cc.classify(chain, results, sys.argv[2:])
print(json.dumps(v, sort_keys=True))
PYEOF
classify() { python3 "$TMP/drive.py" "$TOOL" "$@"; }
verdict()  { classify "$@" | python3 -c "import json,sys;print(json.load(sys.stdin)['verdict'])"; }

# One step emitting a value; the shape run_chain produces.
FIRED='{"stream":[{"step":0,"mergeBatch":[{"region":{"offset":8,"length":2},"values":[1,0]}],"eventBus":[]}]}'
OTHER='{"stream":[{"step":0,"mergeBatch":[{"region":{"offset":8,"length":2},"values":[0,1]}],"eventBus":[]}]}'
QUIET='{"stream":[{"step":0,"mergeBatch":[],"eventBus":[]}]}'
BROKEN='{"error":"push step 0 HTTP 500"}'

echo "== classify =="

A="{\"cpp-1\":$FIRED,\"lsp-1\":$FIRED,\"scala-1\":$FIRED}"
assert_eq "$(printf '%s' "$A" | verdict cpp-1 lsp-1 scala-1)" "agreed" \
  "all three emit the same stream -> agreed"

# The case the whole redesign exists for. Two agree, one does not. Under the
# replaced tool the nominated engine simply defined the answer.
B="{\"cpp-1\":$OTHER,\"lsp-1\":$FIRED,\"scala-1\":$FIRED}"
assert_eq "$(printf '%s' "$B" | verdict cpp-1 lsp-1 scala-1)" "disagreement" \
  "2-1 split -> disagreement, not a contract with an outlier"

assert_eq "$(printf '%s' "$B" | classify cpp-1 lsp-1 scala-1 \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d['clusters']),all('outputStream' in c for c in d['clusters']))")" \
  "2 True" \
  "a disagreement carries every cluster's stream"

# Symmetry: a designated baseline is exactly what breaks this.
C="{\"cpp-1\":$FIRED,\"lsp-1\":$FIRED,\"scala-1\":$OTHER}"
assert_eq "$(printf '%s' "$C" | verdict cpp-1 lsp-1 scala-1)" \
          "$(printf '%s' "$B" | verdict cpp-1 lsp-1 scala-1)" \
  "the verdict does not depend on which runtime dissents"

D="{\"cpp-1\":$QUIET,\"lsp-1\":$QUIET,\"scala-1\":$QUIET}"
assert_eq "$(printf '%s' "$D" | verdict cpp-1 lsp-1 scala-1)" "no-runtime-emits" \
  "unanimous silence -> no-runtime-emits, not an empty contract"

# An undriveable lane has produced no evidence either way. Counting it as
# silence would manufacture a "nobody implements this" finding out of a 500.
E="{\"cpp-1\":$BROKEN,\"lsp-1\":$QUIET,\"scala-1\":$QUIET}"
assert_eq "$(printf '%s' "$E" | verdict cpp-1 lsp-1 scala-1)" "unmeasurable" \
  "one runtime undriveable + two silent -> unmeasurable, not silence"

F="{\"cpp-1\":$BROKEN,\"lsp-1\":$FIRED,\"scala-1\":$FIRED}"
assert_eq "$(printf '%s' "$F" | verdict cpp-1 lsp-1 scala-1)" "unmeasurable" \
  "one runtime undriveable + two agreeing -> unmeasurable, not agreed"

echo
echo "== the recorded artifact =="

cat > "$TMP/payload.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("cc", sys.argv[1])
cc = importlib.util.module_from_spec(spec); spec.loader.exec_module(cc)
verdicts = [{"verdict": v, "chain": f"c{i}"} for i, v in enumerate(
    ["agreed", "agreed", "disagreement", "no-runtime-emits", "unmeasurable"])]
q = cc.quorum_composition([{"runtime": r} for r in ("cpp", "lsp", "scala")])
p = cc.build_payload(verdicts, q, [{"runtime": r} for r in ("cpp", "lsp", "scala")], 1)
print(json.dumps(p, sort_keys=True))
PYEOF
PAYLOAD="$(python3 "$TMP/payload.py" "$TOOL")"
field() { printf '%s' "$PAYLOAD" | python3 -c "import json,sys;print($1)" ; }

assert_eq "$(field "json.load(sys.stdin)['counts']['agreed']")" "2" \
  "only agreed chains are counted as contracts"
assert_eq "$(field "len(json.load(sys.stdin)['contracts'])")" "2" \
  "contracts holds the agreed chains and nothing else"

# Enumerated, not counted. The whole point of §3.
for k in disagreements noRuntimeEmits unmeasurable; do
  assert_eq "$(field "len(json.load(sys.stdin)['$k'])")" "1" \
    "$k is enumerated in the artifact, not just counted"
done

assert_eq "$(field "json.load(sys.stdin)['derivedFrom']")" \
  "3-of-3 agreement across the cpp, lsp and scala runtimes" \
  "the artifact states what it was derived from"

# No nominated engine anywhere in the artifact or the tool.
assert_eq "$(printf '%s' "$PAYLOAD" | grep -ci 'ENGINE_DIST\|replay engine\|baseline engine' || true)" "0" \
  "the artifact names no nominated engine"

echo "== quorum_composition =="
cat > "$TMP/q.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("cc", sys.argv[1])
cc = importlib.util.module_from_spec(spec); spec.loader.exec_module(cc)
q = cc.quorum_composition([{"runtime": r} for r in sys.argv[2:]])
print(json.dumps([q["formed"], q["missing"]]))
PYEOF
assert_eq "$(python3 "$TMP/q.py" "$TOOL" cpp lsp scala)" '[true, []]' \
  "all three present -> quorum formed"
assert_eq "$(python3 "$TMP/q.py" "$TOOL" cpp scala)" '[false, ["lsp"]]' \
  "a runtime absent -> not formed, and it is named"
assert_eq "$(python3 "$TMP/q.py" "$TOOL" cpp scala ts)" '[false, ["lsp"]]' \
  "ts does not substitute for a missing native runtime"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
