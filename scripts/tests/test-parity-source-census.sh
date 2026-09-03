#!/usr/bin/env bash
# Unit tests for source_census and source_set_divergence in
# scripts/regression-universal-vectors.py.
#
# The stage recorded engine responses but nothing about the stimulus that
# produced them. jateeter/RealityEngine_CI#162 left 13 perceptual-space cells
# (0-4, 8-9, 16-21) where cpp read 0 and lsp/scala read 0.5, identically across
# all five events, with the other 14,375 cells agreeing — a signature that reads
# as a PE source-set inequality. Its *direction* was undeterminable after the
# fact, because nothing recorded what each PE was holding when the events were
# pushed (jateeter/RealityEngine_CI#174).
#
# These pin the two properties the census has to have to answer that question:
# it is keyed on machine name rather than runtime-minted id, and a difference in
# per-runtime bookkeeping is not a difference in stimulus.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/regression-universal-vectors.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Source lists arrive on stdin as {"instance": [source, ...]}. Prints the
# divergence verdict: "equal", or a compact description of what differed.
cat > "$TMP/census.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("uv", sys.argv[1])
uv = importlib.util.module_from_spec(spec); spec.loader.exec_module(uv)
by_instance = json.load(sys.stdin)
censuses = {inst: uv.source_census(srcs) for inst, srcs in by_instance.items()}
result = uv.source_set_divergence(censuses)
if result is None:
    print("equal")
else:
    print(json.dumps({"heldBySome": result["heldBySome"],
                      "describedDifferently": sorted(result["describedDifferently"]),
                      "counts": result["counts"]}, sort_keys=True))
PYEOF
divergence() { python3 "$TMP/census.py" "$TOOL"; }

# One corpus machine, held by both runtimes, described identically — but with
# the per-runtime bookkeeping that always differs.
BASE_CPP='{"id":"cpp-a","type":"test","name":"S1","machineName":"AGX001","active":true,"region":{"offset":40,"length":4},"lastValue":1,"lastUpdated":1000}'
BASE_LSP='{"id":"lsp-z","type":"test","name":"S1","machineName":"AGX001","active":true,"region":{"offset":40,"length":4},"lastValue":7,"lastUpdated":2000}'

echo "== source_set_divergence =="

# The property that makes the census usable at all. Ids are minted per runtime —
# the corpus declares none — so an id-keyed census splits three ways
# unconditionally and measures nothing (#146).
assert_eq "$(printf '{"cpp-1":[%s],"lsp-1":[%s]}' "$BASE_CPP" "$BASE_LSP" | divergence)" \
  "equal" \
  "same machine, different ids and lastValue -> equal stimulus"

# The #54 shape: one runtime holding runtime-registered localai/* sources the
# others never had.
EXTRA='{"id":"lsp-x","type":"test","name":"Extra","machineName":"localai/rag_corrective_cycle","active":true,"region":{"offset":7440,"length":8}}'
assert_eq "$(printf '{"cpp-1":[%s],"lsp-1":[%s,%s]}' "$BASE_CPP" "$BASE_LSP" "$EXTRA" | divergence)" \
  '{"counts": {"cpp-1": 1, "lsp-1": 2}, "describedDifferently": [], "heldBySome": {"localai/rag_corrective_cycle": ["lsp-1"]}}' \
  "source one runtime has and another does not -> reported as membership"

# Both hold the machine; one has it armed and the other does not. Same
# membership, different stimulus — and a different cause, so reported separately.
PAUSED='{"id":"lsp-z","type":"test","name":"S1","machineName":"AGX001","active":false,"region":{"offset":40,"length":4},"lastValue":7}'
assert_eq "$(printf '{"cpp-1":[%s],"lsp-1":[%s]}' "$BASE_CPP" "$PAUSED" | divergence)" \
  '{"counts": {"cpp-1": 1, "lsp-1": 1}, "describedDifferently": ["AGX001"], "heldBySome": {}}' \
  "same membership, one source inactive -> reported as description, not membership"

# A region difference is stimulus even when the name and activity match: the
# source writes somewhere else.
MOVED='{"id":"lsp-z","type":"test","name":"S1","machineName":"AGX001","active":true,"region":{"offset":44,"length":4}}'
assert_eq "$(printf '{"cpp-1":[%s],"lsp-1":[%s]}' "$BASE_CPP" "$MOVED" | divergence)" \
  '{"counts": {"cpp-1": 1, "lsp-1": 1}, "describedDifferently": ["AGX001"], "heldBySome": {}}' \
  "same name, different region -> stimulus differs"

# Three runtimes, two agreeing: the verdict is still just "not equal" — naming
# an outlier is the parity comparison's job, not the census's.
assert_eq "$(printf '{"cpp-1":[%s],"scala-1":[%s],"lsp-1":[%s,%s]}' "$BASE_CPP" "$BASE_CPP" "$BASE_LSP" "$EXTRA" | divergence)" \
  '{"counts": {"cpp-1": 1, "lsp-1": 2, "scala-1": 1}, "describedDifferently": [], "heldBySome": {"localai/rag_corrective_cycle": ["lsp-1"]}}' \
  "two agree, one holds an extra source -> membership names only the holder"

# Order is not stimulus. GET /api/sources makes no ordering guarantee across
# runtimes, and a census that inherited one would report every run as divergent.
SECOND='{"id":"q","type":"sensor","name":"S2","machineName":"AGX002","active":false,"region":{"offset":44,"length":4}}'
assert_eq "$(printf '{"cpp-1":[%s,%s],"lsp-1":[%s,%s]}' "$BASE_CPP" "$SECOND" "$SECOND" "$BASE_LSP" | divergence)" \
  "equal" \
  "same sources in a different order -> equal stimulus"

# Fewer than two runtimes cannot disagree.
assert_eq "$(printf '{"cpp-1":[%s]}' "$BASE_CPP" | divergence)" \
  "equal" \
  "single runtime -> nothing to compare"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
