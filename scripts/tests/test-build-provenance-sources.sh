#!/usr/bin/env bash
# Which sources each artifact is held against — scripts/verify-build-provenance.py.
#
# The gate compares every declared artifact against the newest file matching its
# source globs. Get the globs wrong and it reports a staleness that does not
# exist, and its stated remedy ("rebuild") cannot clear it.
#
# That has happened twice:
#
#   #195  every artifact was compared against HEAD, so a docs-only merge marked
#         all three engines stale.
#   #354  both C++ servers carried `include/**/*.hpp`, which also matches
#         `include/reality/generated/` — 1329 of this repo's 1338 headers,
#         emitted by cesgen from the machine corpus and linked by neither
#         server. A corpus regeneration marked both stale; `make all` correctly
#         rebuilt nothing, because make follows real dependencies; and the gate
#         still failed. The only ways out were `touch`, `make -B`, or
#         RE_SKIP_PROVENANCE=1 — the override the gate exists to discourage.
#
# These pin the property both fixes share: an artifact is held against the files
# it is actually built from, and nothing else.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/verify-build-provenance.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A miniature RealityEngine_CPP: the nine real headers, a generated tree, and
# the two server binaries. Mtimes are set so the binaries are NEWER than every
# real source and OLDER than the generated headers — exactly #354's shape.
REPO="$TMP/RealityEngine_CPP"
mkdir -p "$REPO/src" "$REPO/include/reality/generated" "$REPO/bin"
for h in reality arbiter http json sta_checker mqtt_client mqtt_mapping mqtt_bridge vector_aggregator; do
  echo "// $h" > "$REPO/include/reality/$h.hpp"
done
for f in reality arbiter http sta_checker mqtt_client mqtt_mapping mqtt_bridge \
         reality_engine_server perception_engine_server; do
  echo "// $f" > "$REPO/src/$f.cpp"
done
for i in $(seq 1 40); do echo "// gen$i" > "$REPO/include/reality/generated/M$i.hpp"; done
echo "bin" > "$REPO/bin/reality_engine_server"
echo "bin" > "$REPO/bin/perception_engine_server"

touch -t 202601010000 "$REPO"/src/*.cpp "$REPO"/include/reality/*.hpp   # sources: oldest
touch -t 202601020000 "$REPO"/bin/*                                      # binaries: built after
touch -t 202601030000 "$REPO"/include/reality/generated/*.hpp            # corpus regenerated after

cat > "$TMP/probe.py" <<'PYEOF'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("vbp", sys.argv[1])
vbp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vbp)
repo = Path(sys.argv[2]); artifact = sys.argv[3]
cfg = vbp.TARGETS["cpp"]
globs = cfg.get("artifact_sources", {}).get(artifact) or cfg["sources"]
newest, where = vbp.newest_source(repo, globs)
built = (repo / artifact).stat().st_mtime
print("STALE" if newest > built else "CURRENT", where.name if where else "-")
PYEOF

echo "== the sources each C++ server is held against =="

for artifact in bin/reality_engine_server bin/perception_engine_server; do
  out="$(python3 "$TMP/probe.py" "$TOOL" "$REPO" "$artifact")"
  assert_eq "${out%% *}" "CURRENT" \
    "$artifact is not marked stale by a corpus regeneration it does not link (#354)"
done

# The property the gate exists for must survive the narrowing: a real source
# edit still moves the deadline. This is the 2026-08-22 incident.
touch -t 202601040000 "$REPO/src/reality.cpp"
for artifact in bin/reality_engine_server bin/perception_engine_server; do
  out="$(python3 "$TMP/probe.py" "$TOOL" "$REPO" "$artifact")"
  assert_eq "$out" "STALE reality.cpp" \
    "$artifact is still marked stale by an edit to a source it does link"
done

# #195: the PE server's own TU must not age the RE binary.
touch -t 202601010000 "$REPO/src/reality.cpp"
touch -t 202601050000 "$REPO/src/perception_engine_server.cpp"
assert_eq "$(python3 "$TMP/probe.py" "$TOOL" "$REPO" bin/reality_engine_server | cut -d' ' -f1)" "CURRENT" \
  "an edit to perception_engine_server.cpp does not age the RE binary (#195)"
assert_eq "$(python3 "$TMP/probe.py" "$TOOL" "$REPO" bin/perception_engine_server)" "STALE perception_engine_server.cpp" \
  "but it does age the PE binary"

echo
echo "== the globs themselves =="
cat > "$TMP/globs.py" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vbp", sys.argv[1])
vbp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vbp)
cfg = vbp.TARGETS["cpp"]
allg = list(cfg["sources"])
for v in cfg.get("artifact_sources", {}).values():
    allg += v
print("yes" if any("include/**" in g for g in allg) else "no")
PYEOF
assert_eq "$(python3 "$TMP/globs.py" "$TOOL")" "no" \
  "no cpp glob uses include/** — it would match the generated tree again"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
