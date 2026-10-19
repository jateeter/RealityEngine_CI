#!/usr/bin/env bash
# Unit tests for scripts/compare-lane-runs.py (ReleaseRoadmap E2) — two fake
# run directories, no universe.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/compare-lane-runs.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3 (expected $2, got $1)"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
A="$TMP/native-run"; B="$TMP/containerized-run"
mkdir -p "$A/reports" "$A/responses/x" "$B/reports" "$B/responses/x"

run() { set +e; OUT="$(python3 "$TOOL" "$A" "$B" 2>&1)"; RC=$?; set -e; }

echo "values that differ between any two runs are not differences"
cat > "$A/reports/p.json" <<'EOF'
{"generatedAt":"2026-10-19T06:00:00Z","instances":["cpp-1","lsp-1","scala-1"],
 "results":[{"instance":"cpp-1","outputs":167,"reUrl":"http://localhost:6301"},
            {"instance":"lsp-1","outputs":167,"reUrl":"http://localhost:6601"}],
 "sourceId":"seed-native-run-1792391816651","uuid":"0199f1aa-0000-7000-8000-000000000001"}
EOF
cat > "$B/reports/p.json" <<'EOF'
{"generatedAt":"2026-10-19T07:30:00Z","instances":["scala-1","cpp-1","lsp-1"],
 "results":[{"instance":"lsp-1","outputs":167,"reUrl":"http://localhost:51234"},
            {"instance":"cpp-1","outputs":167,"reUrl":"http://localhost:51236"}],
 "sourceId":"seed-containerized-run-1792389236390","uuid":"0199f1aa-0000-7000-8000-000000000002"}
EOF
echo '{"only":"in A"}' > "$A/responses/x/a-only.json"
run
assert_eq "$RC" 0 "timestamps, instance order, origins, run ids and UUIDs are masked"
case "$OUT" in *"1 identical after normalisation, 0 differ, of 1 shared"*) r=yes ;; *) r=no ;; esac
assert_eq "$r" yes "and a file in only one run is not compared"

echo "a measurement that differs is a difference"
sed -i.bak 's/"outputs":167,"reUrl":"http:\/\/localhost:51236"/"outputs":0,"reUrl":"http:\/\/localhost:51236"/' "$B/reports/p.json"
run
assert_eq "$RC" 1 "an engine that fired nothing in one lane fails the comparison"
case "$OUT" in *'$.results[0].outputs: 167 != 0'*) r=yes ;; *) r=no ;; esac
assert_eq "$r" yes "and names the path"
set +e; python3 "$TOOL" "$A" "$B" --report-only >/dev/null 2>&1; RC=$?; set -e
assert_eq "$RC" 0 "--report-only reports without failing"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
