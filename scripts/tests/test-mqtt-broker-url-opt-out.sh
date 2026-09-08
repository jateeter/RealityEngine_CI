#!/usr/bin/env bash
# Unit tests for scripts/regression-test.sh's --mqtt-broker-url opt-out
# normalisation (RealityEngine_CI#311).
#
# Runs the real CLI in plan mode (no --execute, so no worktrees/build/start
# happen) and reads the "mqtt broker:" line the plan step prints, which is the
# resolved value the rest of the run would act on.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

resolved_broker() {
  bash "$CI_DIR/scripts/regression-test.sh" --profile hosted "$@" 2>&1 \
    | sed -n 's/^mqtt broker:  *//p' | head -n1
}

echo "== --mqtt-broker-url opt-out =="

assert_eq "$(resolved_broker)" "<not configured>" \
  "no flag at all leaves MQTT unconfigured in the plan"

assert_eq "$(resolved_broker --mqtt-broker-url none)" "<not configured>" \
  "'none' is normalised to unconfigured"
assert_eq "$(resolved_broker --mqtt-broker-url NONE)" "<not configured>" \
  "opt-out matching is case-insensitive (NONE)"
assert_eq "$(resolved_broker --mqtt-broker-url off)" "<not configured>" \
  "'off' is normalised to unconfigured"
assert_eq "$(resolved_broker --mqtt-broker-url Skip)" "<not configured>" \
  "'skip' is normalised to unconfigured, any case"

assert_eq "$(resolved_broker --mqtt-broker-url mqtt://127.0.0.1:1883)" "mqtt://127.0.0.1:1883" \
  "a real broker URL passes through unchanged"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
