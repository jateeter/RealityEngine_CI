#!/usr/bin/env bash
# Unit tests for scripts/lib/loki-driver.sh — no Docker; `docker` is stubbed.
#
# The probe it replaces captured an absent plugin as $'\n'missing, because
# `docker plugin inspect` prints an empty line before failing. That value
# matched no branch in startUniverse.sh, so the install was skipped silently
# (RealityEngine_CI#362). The stub reproduces that output exactly.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$(printf '%q' "$1")')"; FAIL=$((FAIL+1)); fi; }

# Stub: STUB_OUT is printed verbatim, STUB_RC is the exit status.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%b' "${STUB_OUT:-}"
exit "${STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

# shellcheck source=../lib/loki-driver.sh
source "$CI_DIR/scripts/lib/loki-driver.sh"

echo "loki-driver.sh: loki_driver_state"

# The #362 case: an empty line on stdout, then a non-zero exit.
check "$(STUB_OUT='\n' STUB_RC=1 loki_driver_state)" missing \
  "absent plugin (empty line, then failure) reads as missing"
check "$(STUB_OUT='' STUB_RC=1 loki_driver_state)" missing \
  "absent plugin (no output) reads as missing"
check "$(STUB_OUT='true\n' STUB_RC=0 loki_driver_state)" true "enabled reads as true"
check "$(STUB_OUT='false\n' STUB_RC=0 loki_driver_state)" false "disabled reads as false"
check "$(STUB_OUT='\ntrue\r\n' STUB_RC=0 loki_driver_state)" true "surrounding whitespace is ignored"
check "$(STUB_OUT='yes\n' STUB_RC=0 loki_driver_state)" "unknown:yes" \
  "an unrecognised value is reported, not mapped onto a known state"

# The old capture, kept as the regression it guards against.
old=$(STUB_OUT='\n' STUB_RC=1; export STUB_OUT STUB_RC; docker plugin inspect loki 2>/dev/null || echo "missing")
check "$([ "$old" = missing ] && echo matched || echo unmatched)" unmatched \
  "the pre-#362 capture does not equal 'missing' (why this library exists)"

# Every caller uses the library; none keeps its own capture.
check "$(grep -l "docker plugin inspect loki --format" "$CI_DIR/startUniverse.sh" "$CI_DIR/scripts/setup.sh" "$CI_DIR/scripts/deploy-validate-agent.sh" | wc -l | tr -d ' ')" 0 \
  "no caller probes the plugin directly"
check "$(grep -c "=\$(loki_driver_state)" "$CI_DIR/startUniverse.sh")" 1 "startUniverse.sh uses loki_driver_state"
check "$(grep -c "=\$(loki_driver_state)" "$CI_DIR/scripts/setup.sh")" 1 "setup.sh uses loki_driver_state"
check "$(grep -c "=\$(loki_driver_state)" "$CI_DIR/scripts/deploy-validate-agent.sh")" 1 "deploy-validate preflight uses loki_driver_state"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
