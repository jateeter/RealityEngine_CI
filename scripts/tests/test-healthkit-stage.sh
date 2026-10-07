#!/usr/bin/env bash
# Unit tests for regression-test.sh run_healthkit_bridge: the real HealthKitBridge
# app on a real iPhone, never the simulator (owner decision 2026-10-06).
#
# run_healthkit_bridge is extracted from regression-test.sh and run with stubs:
# xcrun (devicectl reports a connected iPhone or none), xcodegen, and the
# harness helpers it calls (repo_root, registry_instance_lines, run_cmd, ...).
# Nothing is built, installed or launched.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

CI_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }

FN="$(sed -n '/^run_healthkit_bridge() {/,/^}/p' "$CI_DIR_REAL/scripts/regression-test.sh")"
check "$([ -n "$FN" ] && echo found)" found "run_healthkit_bridge extracted from regression-test.sh"

mkdir -p "$TMP/bin" "$TMP/bridge/scripts" "$TMP/ci"
for s in e2e_device.sh e2e_simulator.sh; do printf '#!/usr/bin/env bash\n' > "$TMP/bridge/scripts/$s"; chmod +x "$TMP/bridge/scripts/$s"; done
# devicectl writes its device list to --json-output; STUB_IPHONE names a connected
# iPhone, empty means only a disconnected one.
cat > "$TMP/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "--json-output" ] && out="$2"; shift; done
if [ -n "${STUB_IPHONE:-}" ]; then state=connected; name="$STUB_IPHONE"; else state=unavailable; name="Old iPhone"; fi
printf '{"result":{"devices":[{"hardwareProperties":{"deviceType":"iPhone"},"connectionProperties":{"tunnelState":"%s"},"deviceProperties":{"name":"%s"}}]}}' "$state" "$name" > "$out"
STUB
printf '#!/usr/bin/env bash\n' > "$TMP/bin/xcodegen"
chmod +x "$TMP/bin/xcrun" "$TMP/bin/xcodegen"

stage() {  # [env assignments...] -> "skip:<reason>" or "run:<args>"
  rm -f "$TMP/skip" "$TMP/run"
  env PATH="$TMP/bin:$PATH" "$@" CI_DIR="$TMP/ci" PROFILE=local BRIDGE="$TMP/bridge" OUTDIR="$TMP" \
    HEALTHKIT_BRIDGE_TOKEN=tok bash -c '
      step() { :; }; log() { :; }
      write_skip_report() { printf "%s" "$2" > "$OUTDIR/skip"; }
      repo_root() { echo "$BRIDGE"; }
      registry_instance_lines() { echo "cpp-1|cpp|http://192.168.1.20:58590"; }
      run_cmd() { printf "%s " "$@" > "$OUTDIR/run"; }
      '"$FN"'
      run_healthkit_bridge'
  if [ -f "$TMP/run" ]; then echo "run:$(cat "$TMP/run")"; elif [ -f "$TMP/skip" ]; then echo "skip:$(cat "$TMP/skip")"; else echo none; fi
}

echo "no simulator, ever"
check "$(grep -c 'e2e_simulator' <<<"$FN")" 0 "the stage never names e2e_simulator.sh"

echo "no iPhone connected"
: > "$TMP/ci/.env"
r="$(stage STUB_IPHONE= DEVELOPMENT_TEAM=TEAM123)"
check "${r%%:*}" skip "records a skip, does not run"
check "$(grep -c 'no connected iPhone' <<<"$r")" 1 "and says no iPhone is connected"
check "$(grep -c 'simulator is not used' <<<"$r")" 1 "and that the simulator is not used"

echo "an iPhone connected"
r="$(stage STUB_IPHONE="Test iPhone" DEVELOPMENT_TEAM=TEAM123)"
check "${r%%:*}" run "runs the device leg"
check "$(grep -c 'e2e_device.sh' <<<"$r")" 1 "with e2e_device.sh"
check "$(grep -c 'DEVELOPMENT_TEAM=TEAM123' <<<"$r")" 1 "signing with the team from the environment"
check "$(grep -c 'PE_BASE_URL=http://192.168.1.20:58590' <<<"$r")" 1 "against the instance registry's PE"
check "$(grep -c 'HEALTHKIT_BRIDGE_TOKEN=tok' <<<"$r")" 1 "with the bridge token"

echo "the team"
printf 'DEVELOPMENT_TEAM=FROMENV9\n' > "$TMP/ci/.env"
r="$(stage STUB_IPHONE="Test iPhone" DEVELOPMENT_TEAM=)"
check "$(grep -c 'DEVELOPMENT_TEAM=FROMENV9' <<<"$r")" 1 "falls back to RealityEngine_CI/.env"
: > "$TMP/ci/.env"
r="$(stage STUB_IPHONE="Test iPhone" DEVELOPMENT_TEAM=)"
check "${r%%:*}" skip "unset everywhere: records a skip"
check "$(grep -c 'DEVELOPMENT_TEAM unset' <<<"$r")" 1 "and names what to set"

echo ""
echo "healthkit-stage: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
