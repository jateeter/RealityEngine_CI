#!/usr/bin/env bash
# Lifecycle integration tests for startUniverse.sh / stopUniverse.sh.
#
# Prerequisites:
#   - Docker running
#   - All sibling repos present as siblings of RealityEngine_CI
#   - .env and certs already generated (or pass --setup)
#
# Usage:
#   bash scripts/tests/test-lifecycle.sh [--scenario=NAMES] [--setup]
#
# Scenarios (comma-separated, default: all):
#   dry-run              pre-flight + plan print, no services started
#   docker-roundtrip     full Docker start → stop → orphan check
#   multi-engine-start   --engines=scala:1 start → stop → orphan check
#   partial-instance     two instances → stop one → verify stamp → stop all
#
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$CI_DIR"

# ── Harness ───────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
SCENARIOS_RUN=()

_ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "  SKIP: $*"; SKIP=$((SKIP+1)); }
_hdr()  { echo ""; echo "── $* ──"; }

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then _ok "$label"
  else _fail "$label (expected '$expected', got '$actual')"; fi
}

assert_file_absent() {
  if [ ! -f "$1" ]; then _ok "absent: $1"
  else _fail "expected absent but exists: $1"; fi
}

assert_file_present() {
  if [ -f "$1" ]; then _ok "present: $1"
  else _fail "expected present but missing: $1"; fi
}

# Wall-clock timeout: fail if command takes longer than N seconds
with_timeout() {
  local max_s="$1"; shift
  local start; start=$(date +%s)
  "$@"
  local elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -gt "$max_s" ]; then
    _fail "exceeded ${max_s}s time limit (took ${elapsed}s): $*"
  fi
}

# Check no engine processes on the given ports remain after teardown
assert_no_orphans_on_ports() {
  local label="$1"; shift
  local found=""
  for port in "$@"; do
    if lsof -i ":$port" -sTCP:LISTEN >/dev/null 2>&1; then
      found="$found :$port"
    fi
  done
  if [ -z "$found" ]; then _ok "$label — no orphan listeners"
  else _fail "$label — orphan process(es) still listening on$found"; fi
}

# ── Flag parsing ──────────────────────────────────────────────────────────────
SELECTED_SCENARIOS="dry-run,docker-roundtrip,multi-engine-start,partial-instance"
DO_SETUP=false

for arg in "$@"; do
  case "$arg" in
    --scenario=*) SELECTED_SCENARIOS="${arg#*=}" ;;
    --setup)      DO_SETUP=true ;;
    --help|-h)
      grep '^#' "$0" | head -20 | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

_scenario_selected() {
  echo ",$SELECTED_SCENARIOS," | grep -q ",${1},"
}

# ── Optional setup ────────────────────────────────────────────────────────────
if [ "$DO_SETUP" = true ]; then
  [ -f .env ] || cp .env.example .env
  [ -f certs/server.crt ] || bash certs/generate-dev-certs.sh
fi

# ── SCENARIO: dry-run ─────────────────────────────────────────────────────────
if _scenario_selected "dry-run"; then
  SCENARIOS_RUN+=("dry-run")
  _hdr "Scenario: dry-run"

  stamp_file="$CI_DIR/.universe-engine-selection"
  stamp_before_present=false
  stamp_before=""
  if [ -f "$stamp_file" ]; then
    stamp_before_present=true
    stamp_before="$(cat "$stamp_file")"
  fi

  output=$(./startUniverse.sh --dry-run --no-openclaw 2>&1) && _exit=0 || _exit=$?
  assert_eq "$_exit" "0" "dry-run exits 0"
  echo "$output" | grep -q "Dry-Run Plan" \
    && _ok "output contains 'Dry-Run Plan'" \
    || _fail "output missing 'Dry-Run Plan'"
  echo "$output" | grep -q "Pre-flight: PASSED" \
    && _ok "output contains 'Pre-flight: PASSED'" \
    || _fail "output missing 'Pre-flight: PASSED'"
  if [ "$stamp_before_present" = true ]; then
    if [ -f "$stamp_file" ] && [ "$(cat "$stamp_file")" = "$stamp_before" ]; then
      _ok "dry-run leaves existing engine-selection stamp unchanged"
    else
      _fail "dry-run modified existing engine-selection stamp"
    fi
  else
    assert_file_absent "$stamp_file"
  fi

  # dry-run with --engines= should show instance plan
  output2=$(./startUniverse.sh --dry-run --engines=scala:2,cpp:1 --no-openclaw 2>&1) && true || true
  echo "$output2" | grep -q "scala-1\|cpp-1\|Instances that would spawn" \
    && _ok "multi-engine dry-run shows instance plan" \
    || _fail "multi-engine dry-run missing instance plan"
fi

# ── SCENARIO: docker-roundtrip ────────────────────────────────────────────────
if _scenario_selected "docker-roundtrip"; then
  SCENARIOS_RUN+=("docker-roundtrip")
  _hdr "Scenario: docker-roundtrip"

  if ! docker info >/dev/null 2>&1; then
    _skip "docker-roundtrip — Docker not available"
  else
    _teardown_docker() {
      ./stopUniverse.sh 2>/dev/null || true
    }
    trap _teardown_docker EXIT

    _start=$(date +%s)
    ./startUniverse.sh --no-openclaw --skip-seed 2>&1 | tail -5
    _elapsed=$(( $(date +%s) - _start ))
    [ "$_elapsed" -lt 300 ] \
      && _ok "docker start completed in ${_elapsed}s (< 300s)" \
      || _fail "docker start took ${_elapsed}s — exceeds 300s limit"

    assert_file_present "$CI_DIR/.universe-engine-selection"

    # Verify key containers are running
    for cname in reality-engine-app reality-engine-loki; do
      if docker ps --format "{{.Names}}" | grep -q "$cname"; then
        _ok "container running: $cname"
      else
        _fail "container not running: $cname"
      fi
    done

    # Stop and verify clean teardown
    ./stopUniverse.sh 2>&1 | tail -3
    trap - EXIT

    assert_file_absent "$CI_DIR/.universe-engine-selection"

    # No RE containers remain
    _remaining=$(docker ps -a --format "{{.Names}}" | grep -c "reality-engine-" || echo 0)
    assert_eq "$_remaining" "0" "all RE containers removed after stop"

    assert_no_orphans_on_ports "docker teardown" 3000 3001 3004 5173
  fi
fi

# ── SCENARIO: multi-engine-start ─────────────────────────────────────────────
if _scenario_selected "multi-engine-start"; then
  SCENARIOS_RUN+=("multi-engine-start")
  _hdr "Scenario: multi-engine-start"

  SCALA_START="$CI_DIR/../RealityEngine_Scala/start.sh"
  if [ ! -x "$SCALA_START" ]; then
    _skip "multi-engine-start — $SCALA_START not found or not executable"
  elif ! docker info >/dev/null 2>&1; then
    _skip "multi-engine-start — Docker not available"
  else
    _teardown_me() { ./stopUniverse.sh --engines-only 2>/dev/null || true; }
    trap _teardown_me EXIT

    _start=$(date +%s)
    ./startUniverse.sh --no-openclaw --skip-seed --engines=scala:1 2>&1 | tail -5
    _elapsed=$(( $(date +%s) - _start ))
    [ "$_elapsed" -lt 300 ] \
      && _ok "multi-engine start completed in ${_elapsed}s" \
      || _fail "multi-engine start took ${_elapsed}s — exceeds 300s"

    assert_file_present "/tmp/re-registry/re-registry.json"
    _inst_count=$(python3 -c "import json; d=json.load(open('/tmp/re-registry/re-registry.json')); print(len(d['instances']))" 2>/dev/null || echo 0)
    assert_eq "$_inst_count" "1" "registry has 1 instance after --engines=scala:1"

    # Health check the registered RE
    _re_url=$(python3 -c "import json; d=json.load(open('/tmp/re-registry/re-registry.json')); print(d['instances'][0]['re_url'])" 2>/dev/null || echo "")
    if [ -n "$_re_url" ] && curl -sf --max-time 5 "$_re_url/api/health" >/dev/null 2>&1; then
      _ok "registered RE instance responds to /api/health"
    else
      _fail "registered RE instance did not respond at $_re_url/api/health"
    fi

    ./stopUniverse.sh --engines-only 2>&1 | tail -3
    trap - EXIT

    assert_file_absent "/tmp/re-registry/re-registry.json"
    assert_file_absent "$CI_DIR/.universe-engine-selection"
    assert_no_orphans_on_ports "multi-engine teardown" 5001 5000
  fi
fi

# ── SCENARIO: partial-instance ────────────────────────────────────────────────
if _scenario_selected "partial-instance"; then
  SCENARIOS_RUN+=("partial-instance")
  _hdr "Scenario: partial-instance"

  SCALA_START="$CI_DIR/../RealityEngine_Scala/start.sh"
  if [ ! -x "$SCALA_START" ]; then
    _skip "partial-instance — $SCALA_START not found or not executable"
  elif ! docker info >/dev/null 2>&1; then
    _skip "partial-instance — Docker not available"
  else
    _teardown_pi() { ./stopUniverse.sh --all 2>/dev/null || true; }
    trap _teardown_pi EXIT

    ./startUniverse.sh --no-openclaw --skip-seed --engines=scala:2 2>&1 | tail -5

    _inst_count=$(python3 -c "import json; d=json.load(open('/tmp/re-registry/re-registry.json')); print(len(d['instances']))" 2>/dev/null || echo 0)
    assert_eq "$_inst_count" "2" "registry has 2 instances before partial stop"

    # Stop only scala-1
    ./stopUniverse.sh --instance=scala-1 2>&1 | tail -3

    # Stamp must still exist (scala-2 still running)
    assert_file_present "$CI_DIR/.universe-engine-selection"

    _remaining=$(python3 -c "import json; d=json.load(open('/tmp/re-registry/re-registry.json')); print(len(d['instances']))" 2>/dev/null || echo 0)
    assert_eq "$_remaining" "1" "registry has 1 instance after stopping scala-1"

    # scala-1 port must be free
    assert_no_orphans_on_ports "scala-1 stopped" 5001

    # Stop remaining
    ./stopUniverse.sh --engines-only 2>&1 | tail -3
    trap - EXIT

    assert_file_absent "$CI_DIR/.universe-engine-selection"
    assert_file_absent "/tmp/re-registry/re-registry.json"
    assert_no_orphans_on_ports "full teardown" 5001 5101 5000 5100
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Lifecycle tests: $PASS passed, $FAIL failed, $SKIP skipped"
echo "  Scenarios run: ${SCENARIOS_RUN[*]:-none}"
echo "════════════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
