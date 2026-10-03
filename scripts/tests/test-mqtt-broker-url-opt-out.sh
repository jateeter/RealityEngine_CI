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
  bash "$CI_DIR/scripts/regression-test.sh" --profile "${PROFILE:-hosted}" "$@" 2>&1 \
    | sed -n 's/^mqtt broker:  *//p' | head -n1
}

YUMA="mqtt://yuma.lateraledge.cloud:1883"

echo "== --mqtt-broker-url default and opt-out =="

# Regression MQTT testing uses the live Yuma broker on every lane (2026-10-03).
assert_eq "$(PROFILE=hosted resolved_broker)" "$YUMA" \
  "no flag on the hosted lane resolves to the Yuma broker"
assert_eq "$(PROFILE=local resolved_broker)" "$YUMA" \
  "no flag on the local lane resolves to the Yuma broker"
assert_eq "$(resolved_broker --mqtt-broker-url '')" "$YUMA" \
  "an empty flag is the default, not an opt-out"

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
