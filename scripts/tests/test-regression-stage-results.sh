#!/usr/bin/env bash
# Unit tests for stage results in the regression report (RealityEngine_CI#350).
#
# summary.md listed nine fixed sections, while regression-test.sh runs about
# twenty stages. On 2026-10-01 export-parity and reset-contract failed; every
# listed section read `passed`, so the issue filer had no failing stage to name
# and filed the run as "Regression failure: unspecified", as it had every night
# since 2026-09-11.
#
# This drives the real run_stage, the real regression-report.py and the real
# issue-filer parser end to end over a fabricated run directory.
#
# run_stage is eval'd from regression-test.sh and calls stubs defined here.
# shellcheck disable=SC2034,SC2329
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT="$CI_DIR/scripts/regression-report.py"
FILER="$CI_DIR/scripts/lib/regression-issue-filer.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi; }

signature() {  # <summary.md> -> the issue filer's failure signature
  node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { parseFailingStages, failureSignature } from '$FILER';
    console.log(failureSignature(parseFailingStages(readFileSync('$1', 'utf8'))));"
}

# A run directory whose section reports all pass, as on 2026-10-01.
make_run() {
  local dir="$1"
  mkdir -p "$dir/reports" "$dir/responses/trajectory-parity" "$dir/responses/universal-vectors"
  echo '{"runId":"test-run","status":"failed","builds":[]}' > "$dir/manifest.json"
  echo '{"ok":true,"status":"passed","failures":[]}' > "$dir/reports/service-inventory.json"
  echo '{"ok":true,"status":"passed","failures":[]}' > "$dir/responses/trajectory-parity/trajectory-summary.json"
  echo '{"ok":true,"status":"passed","failures":[]}' > "$dir/responses/universal-vectors/summary.json"
  echo '{"ok":true,"status":"passed","failures":[]}' > "$dir/reports/mcp-smoke.json"
}
report() { python3 "$REPORT" --run-dir "$1" --history-dir "$TMP/history" >/dev/null; }

echo "run_stage records every outcome"
RUN_DIR="$TMP/run-stage"
eval "$(sed -n '/^run_stage() {/,/^}/p' "$CI_DIR/scripts/regression-test.sh")"
log() { :; }
STAGE_FAILURES=()
run_stage "export-parity" false
run_stage "trajectory-parity" true
check "$(cat "$RUN_DIR/reports/stage-results.tsv")" "$(printf 'export-parity\tfailed\t1\ntrajectory-parity\tpassed\t0')" \
  "one line per stage: name, status, exit"
check "${STAGE_FAILURES[*]}" "export-parity" "STAGE_FAILURES still collects the failure"

echo "the 2026-10-01 run"
make_run "$TMP/r1"
printf '%s\t%s\t%s\n' service-inventory passed 0 export-parity failed 1 trajectory-parity passed 0 \
  reset-contract failed 1 mcp passed 0 > "$TMP/r1/reports/stage-results.tsv"
report "$TMP/r1"
check "$(grep -c '^- export-parity: `failed`$' "$TMP/r1/summary.md")" 1 "export-parity has its own Results line"
check "$(grep -c '^- reset-contract: `failed`$' "$TMP/r1/summary.md")" 1 "reset-contract has its own Results line"
check "$(grep -c '^- trajectory-parity:' "$TMP/r1/summary.md")" 0 "a stage with a named section is not listed twice"
check "$(signature "$TMP/r1/summary.md")" "export-parity, reset-contract" "the filer names the stages, not 'unspecified'"
check "$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["failingSections"]))' "$TMP/r1/reports/regression-status.json")" \
  "export-parity,reset-contract" "regression-status.json failingSections agrees"

echo "a failed stage overrides its section's report"
make_run "$TMP/r2"
printf '%s\t%s\t%s\n' mcp failed 2 > "$TMP/r2/reports/stage-results.tsv"
report "$TMP/r2"
check "$(grep -c '^- MCP: `failed`$' "$TMP/r2/summary.md")" 1 "MCP reads failed when its stage exited non-zero"
check "$(signature "$TMP/r2/summary.md")" "mcp" "and keeps its existing signature"

echo "unchanged where nothing new is known"
make_run "$TMP/r3"
report "$TMP/r3"
check "$(sed -n '/^## Results/,/^## Comparison/p' "$TMP/r3/summary.md" | grep -c '^- ')" 9 \
  "a run with no stage-results.tsv shows the nine sections, as before"
make_run "$TMP/r4"
printf '%s\t%s\t%s\n' export-parity passed 0 mcp passed 0 > "$TMP/r4/reports/stage-results.tsv"
report "$TMP/r4"
check "$(signature "$TMP/r4/summary.md")" "unspecified" "all stages passing: no failing stage to name"

echo "comparison sees stage transitions"
CMP=$(python3 - "$REPORT" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("rr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cur  = {"stages": {"export-parity": {"status": "passed"}, "reset-contract": {"status": "failed"}}}
prev = {"stages": {"export-parity": {"status": "failed"}, "reset-contract": {"status": "failed"}}}
r = m.compare_runs(cur, prev, "prev")
print(json.dumps([[c["section"] for c in r["changes"]],
                  [f["failure"] for f in r["newFailures"]],
                  [f["failure"] for f in r["resolvedFailures"]]]))
PY
)
check "$CMP" '[["stage:export-parity"], [], ["export-parity"]]' "a fixed stage is a change and a resolved failure; an ongoing one is neither"

echo "the pr544-1639 run: arbiter passed, arbiter-sweep skipped"
make_run "$TMP/r5"
printf '%s\t%s\t%s\n' arbiter-sweep passed 0 arbiter passed 0 mqtt-yuma passed 0 > "$TMP/r5/reports/stage-results.tsv"
echo '{"status":"passed","failures":[],"lane":"local"}' > "$TMP/r5/reports/arbiter.json"
echo '{"status":"skipped","reason":"not requested; pass --arbiter-sweep"}' > "$TMP/r5/reports/arbiter-sweep-skipped.json"
report "$TMP/r5"
check "$(grep -c '^- Arbiter conformance: `passed`$' "$TMP/r5/summary.md")" 1 "Arbiter conformance reads arbiter.json, not not-run"
check "$(grep -c '^- arbiter-sweep: `skipped`$' "$TMP/r5/summary.md")" 1 "a stage that wrote <name>-skipped.json reads skipped, not passed"
check "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stages"]["arbiter-sweep"]["reason"])' "$TMP/r5/reports/regression-status.json")" \
  "not requested; pass --arbiter-sweep" "and keeps the skip reason"
check "$(signature "$TMP/r5/summary.md")" "unspecified" "a skip is not a failure to file"

echo "a skipped arbiter, and a failed stage that also wrote a skip report"
make_run "$TMP/r6"
printf '%s\t%s\t%s\n' arbiter passed 0 local-ai failed 1 > "$TMP/r6/reports/stage-results.tsv"
echo '{"status":"skipped","reason":"no contended cells"}' > "$TMP/r6/reports/arbiter-skipped.json"
echo '{"status":"skipped","reason":"hosted profile"}' > "$TMP/r6/reports/local-ai-skipped.json"
report "$TMP/r6"
check "$(grep -c '^- Arbiter conformance: `skipped`$' "$TMP/r6/summary.md")" 1 "a lane without contended cells reads skipped"
check "$(grep -c '^- local-ai: `failed`$' "$TMP/r6/summary.md")" 1 "a non-zero exit stays failed whatever report it left"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
