#!/bin/bash
# =============================================================================
# test-three-engine-full.sh
#
# Full 3-engine integration test orchestrator.
# Performs a clean teardown + restart of a scala:1,cpp:1,lsp:1 deployment,
# then runs the complete test suite against all three engine instances.
#
# Usage:
#   ./scripts/test-three-engine-full.sh [options]
#
# Options:
#   --mqtt-broker-url URL       MQTT broker (e.g. mqtt://yuma.lateraledge.cloud:1883)
#   --mqtt-mappings PATH        Path to MQTT mappings JSON (default: CPP sibling or PE example)
#   --mqtt-username USER        MQTT broker username (optional)
#   --mqtt-password PASS        MQTT broker password (optional)
#   --openclaw                  Enable OpenClaw ACP gateway
#   --no-openclaw               Skip OpenClaw (default: auto-detect)
#   --fresh                     Pass --fresh to startUniverse (wipe volumes, no-cache rebuild)
#   --skip-teardown             Skip the initial stopUniverse.sh --all step
#   --skip-unit                 Skip unit tests (faster iteration during e2e debugging)
#   --skip-e2e                  Skip e2e/deployment tests
#   --report-dir DIR            Directory for test report output (default: /tmp/re-test-reports)
#   --engines SPEC              Override engine spec (default: scala:1,cpp:1,lsp:1)
#   --prompt                    Force interactive prompts even if args supplied
#   --no-prompt                 Never prompt; fail fast if required values missing
#   --help                      Show this message
#
# Requires: bash 3.2+, curl, python3
# =============================================================================
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="/tmp/re-test-reports"
ENGINES_SPEC="scala:1,cpp:1,lsp:1"
REGISTRY_FILE="/tmp/re-registry/re-registry.json"

# ── Arg defaults ─────────────────────────────────────────────────────────────
MQTT_BROKER_URL=""
MQTT_MAPPINGS=""
MQTT_USERNAME=""
MQTT_PASSWORD=""
OPENCLAW_FLAG=""
FRESH_FLAG=""
SKIP_TEARDOWN=false
SKIP_UNIT=false
SKIP_E2E=false
FORCE_PROMPT=false
NO_PROMPT=false

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mqtt-broker-url=*) MQTT_BROKER_URL="${1#*=}"; shift ;;
    --mqtt-broker-url)   MQTT_BROKER_URL="$2"; shift 2 ;;
    --mqtt-mappings=*)   MQTT_MAPPINGS="${1#*=}"; shift ;;
    --mqtt-mappings)     MQTT_MAPPINGS="$2"; shift 2 ;;
    --mqtt-username=*)   MQTT_USERNAME="${1#*=}"; shift ;;
    --mqtt-username)     MQTT_USERNAME="$2"; shift 2 ;;
    --mqtt-password=*)   MQTT_PASSWORD="${1#*=}"; shift ;;
    --mqtt-password)     MQTT_PASSWORD="$2"; shift 2 ;;
    --openclaw)          OPENCLAW_FLAG="--openclaw"; shift ;;
    --no-openclaw)       OPENCLAW_FLAG="--no-openclaw"; shift ;;
    --fresh)             FRESH_FLAG="--fresh"; shift ;;
    --skip-teardown)     SKIP_TEARDOWN=true; shift ;;
    --skip-unit)         SKIP_UNIT=true; shift ;;
    --skip-e2e)          SKIP_E2E=true; shift ;;
    --engines=*)         ENGINES_SPEC="${1#*=}"; shift ;;
    --engines)           ENGINES_SPEC="$2"; shift 2 ;;
    --report-dir=*)      REPORT_DIR="${1#*=}"; shift ;;
    --report-dir)        REPORT_DIR="$2"; shift 2 ;;
    --prompt)            FORCE_PROMPT=true; shift ;;
    --no-prompt)         NO_PROMPT=true; shift ;;
    --help|-h)           grep '^#' "$SCRIPT" | sed 's/^# \{0,2\}//' | head -25; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BOLD='\033[1m'; RST='\033[0m'
hdr()  { echo -e "\n${BOLD}${BLU}═══ $* ═══${RST}"; }
ok()   { echo -e "  ${GRN}✅ $*${RST}"; }
fail() { echo -e "  ${RED}❌ $*${RST}"; }
warn() { echo -e "  ${YLW}⚠️  $*${RST}"; }
info() { echo -e "  ${CYN}ℹ  $*${RST}"; }

# ── Results accumulator ───────────────────────────────────────────────────────
RESULTS=()
record_pass() { RESULTS+=("PASS|$1|${2:-}"); }
record_fail() { RESULTS+=("FAIL|$1|${2:-}"); }
record_warn() { RESULTS+=("WARN|$1|${2:-}"); }
record_skip() { RESULTS+=("SKIP|$1|${2:-}"); }

PASS_COUNT=0; FAIL_COUNT=0; WARN_COUNT=0; SKIP_COUNT=0
START_TIME=$(date +%s)
RUN_ID="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/three-engine-report-${RUN_ID}.md"

# ── Engine registry (parallel indexed arrays — bash 3.2 compatible) ───────────
ENGINE_IDS=()
ENGINE_RE_URLS=()
ENGINE_PE_URLS=()

# Look up RE URL by engine ID
get_re_url() {
  local target="$1" i
  for i in "${!ENGINE_IDS[@]}"; do
    [[ "${ENGINE_IDS[$i]}" == "$target" ]] && { echo "${ENGINE_RE_URLS[$i]}"; return; }
  done
  echo ""
}

# Look up PE URL by engine ID
get_pe_url() {
  local target="$1" i
  for i in "${!ENGINE_IDS[@]}"; do
    [[ "${ENGINE_IDS[$i]}" == "$target" ]] && { echo "${ENGINE_PE_URLS[$i]}"; return; }
  done
  echo ""
}

# ── Interactive prompt helper ─────────────────────────────────────────────────
prompt_value() {
  local varname="$1" prompt_text="$2" default="${3:-}"
  local current
  eval current=\${$varname:-}
  if [[ -n "$current" ]] && [[ "$FORCE_PROMPT" == false ]]; then
    return 0
  fi
  if [[ "$NO_PROMPT" == true ]]; then
    return 0
  fi
  local display_default=""
  [[ -n "$default" ]] && display_default=" [${default}]"
  printf "${CYN}  ?  %s%s: ${RST}" "$prompt_text" "$display_default"
  local val
  read -r val
  if [[ -z "$val" ]] && [[ -n "$default" ]]; then
    val="$default"
  fi
  if [[ -n "$val" ]]; then
    eval "$varname"='"$val"'
  fi
}

# ── Report writer (defined early so it's callable from any phase) ─────────────
_write_report() {
  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$(( end_time - START_TIME ))

  local p=0 f=0 w=0 s=0 r
  for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do
    case "${r%%|*}" in
      PASS) (( p++ )) ;;
      FAIL) (( f++ )) ;;
      WARN) (( w++ )) ;;
      SKIP) (( s++ )) ;;
    esac
  done
  PASS_COUNT=$p; FAIL_COUNT=$f; WARN_COUNT=$w; SKIP_COUNT=$s

  local overall="PASS"
  [[ $FAIL_COUNT -gt 0 ]] && overall="FAIL"
  [[ $WARN_COUNT -gt 0 && "$overall" == "PASS" ]] && overall="WARN"

  cat > "$REPORT_FILE" <<REPORT
# RealityEngine 3-Engine Full Test Report

**Run ID:** ${RUN_ID}
**Date:** $(date -u "+%Y-%m-%d %H:%M:%S UTC")
**Engine spec:** \`${ENGINES_SPEC}\`
**Duration:** ${elapsed}s
**Overall:** ${overall}

## Summary

| Outcome | Count |
|---------|-------|
| ✅ PASS | ${PASS_COUNT} |
| ❌ FAIL | ${FAIL_COUNT} |
| ⚠️  WARN | ${WARN_COUNT} |
| ⏭  SKIP | ${SKIP_COUNT} |

## Configuration

| Setting | Value |
|---------|-------|
| MQTT broker | ${MQTT_BROKER_URL:-<disabled>} |
| MQTT mappings | ${MQTT_MAPPINGS:-<auto>} |
| OpenClaw | ${OPENCLAW_FLAG:-<auto-detect>} |
| Fresh start | ${FRESH_FLAG:-no} |
| Teardown skipped | ${SKIP_TEARDOWN} |

## Registered Engines

REPORT

  local i
  if [[ ${#ENGINE_IDS[@]} -eq 0 ]]; then
    echo "_No engines found in registry_" >> "$REPORT_FILE"
  else
    for i in "${!ENGINE_IDS[@]}"; do
      echo "- **[${ENGINE_IDS[$i]}]** RE: \`${ENGINE_RE_URLS[$i]:-?}\`  PE: \`${ENGINE_PE_URLS[$i]:-?}\`" >> "$REPORT_FILE"
    done
  fi

  cat >> "$REPORT_FILE" <<REPORT

## Phase Results

| Status | Test | Notes |
|--------|------|-------|
REPORT

  for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do
    local status label note icon
    IFS="|" read -r status label note <<< "$r"
    case "$status" in
      PASS) icon="✅" ;;
      FAIL) icon="❌" ;;
      WARN) icon="⚠️ " ;;
      SKIP) icon="⏭ " ;;
      *) icon="  " ;;
    esac
    echo "| ${icon} ${status} | ${label} | ${note:-} |" >> "$REPORT_FILE"
  done

  cat >> "$REPORT_FILE" <<REPORT

## Logs

| Log | Path |
|-----|------|
| Startup | \`${REPORT_DIR}/startup-${RUN_ID}.log\` |
| Teardown | \`${REPORT_DIR}/teardown-${RUN_ID}.log\` |
| Unit tests | \`${REPORT_DIR}/unit-${RUN_ID}.log\` |
| E2E tests | \`${REPORT_DIR}/e2e-${RUN_ID}.log\` |
REPORT

  for id in "${ENGINE_IDS[@]+"${ENGINE_IDS[@]}"}"; do
    echo "| MQTT [$id] | \`${REPORT_DIR}/mqtt-${id}-${RUN_ID}.log\` |" >> "$REPORT_FILE"
  done

  echo "" >> "$REPORT_FILE"
  echo "_Generated by \`test-three-engine-full.sh\`_" >> "$REPORT_FILE"
}

# ── Gather config interactively if needed ─────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BOLD}║    RealityEngine 3-Engine Full Integration Test              ║${RST}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RST}"
echo ""
echo -e "  Engine spec:  ${BOLD}${ENGINES_SPEC}${RST}"
echo -e "  CI dir:       ${CI_DIR}"
echo -e "  Report dir:   ${REPORT_DIR}"
echo ""

if [[ "$NO_PROMPT" == false ]]; then
  hdr "Configuration"
  prompt_value MQTT_BROKER_URL \
    "MQTT broker URL (blank to skip MQTT)" \
    "mqtt://yuma.lateraledge.cloud:1883"
  if [[ -n "$MQTT_BROKER_URL" ]]; then
    prompt_value MQTT_MAPPINGS \
      "MQTT mappings JSON path (blank = use CPP sibling or PE example)" ""
    prompt_value MQTT_USERNAME "MQTT username (blank if none)" ""
    prompt_value MQTT_PASSWORD "MQTT password (blank if none)" ""
  fi
  if [[ -z "$OPENCLAW_FLAG" ]]; then
    printf "${CYN}  ?  Enable OpenClaw? [y/N]: ${RST}"
    read -r oc_ans
    case "$oc_ans" in y|Y|yes|YES) OPENCLAW_FLAG="--openclaw" ;; *) OPENCLAW_FLAG="--no-openclaw" ;; esac
  fi
  if [[ -z "$FRESH_FLAG" ]]; then
    printf "${CYN}  ?  Fresh start (wipe volumes, rebuild images)? [y/N]: ${RST}"
    read -r fr_ans
    case "$fr_ans" in y|Y|yes|YES) FRESH_FLAG="--fresh" ;; esac
  fi
fi

echo ""
info "Resolved configuration:"
info "  MQTT broker:  ${MQTT_BROKER_URL:-<disabled>}"
info "  MQTT mappings:${MQTT_MAPPINGS:-<auto>}"
info "  OpenClaw:     ${OPENCLAW_FLAG:-<auto-detect>}"
info "  Fresh:        ${FRESH_FLAG:-no}"
info "  Skip teardown:${SKIP_TEARDOWN}"
info "  Skip unit:    ${SKIP_UNIT}"
info "  Skip e2e:     ${SKIP_E2E}"
echo ""

# ── Phase 0: Teardown ─────────────────────────────────────────────────────────
hdr "Phase 0 · Teardown"
if [[ "$SKIP_TEARDOWN" == true ]]; then
  warn "Skipping teardown (--skip-teardown)"
  record_skip "Teardown" "skipped by --skip-teardown"
else
  info "Running stopUniverse.sh --all (Docker containers left running) ..."
  TEARDOWN_LOG="$REPORT_DIR/teardown-${RUN_ID}.log"
  set +e
  bash "$CI_DIR/stopUniverse.sh" --all > "$TEARDOWN_LOG" 2>&1
  TEARDOWN_RC=$?
  set -e
  if [[ $TEARDOWN_RC -eq 0 ]]; then
    ok "Teardown complete"
    record_pass "Teardown" "stopUniverse.sh --all exited 0"
  else
    warn "stopUniverse.sh --all exited $TEARDOWN_RC (may be normal if nothing was running)"
    record_warn "Teardown" "exit $TEARDOWN_RC — check $TEARDOWN_LOG"
  fi
  sleep 3
fi

# ── Phase 1: Clean 3-engine start ────────────────────────────────────────────
hdr "Phase 1 · Start 3-Engine Universe"

START_ARGS=(
  "--engines=${ENGINES_SPEC}"
  "--machine-load=runtime"
  "--pe-source-bootstrap=auto"
)
[[ -n "$FRESH_FLAG" ]]      && START_ARGS+=("$FRESH_FLAG")
[[ -n "$OPENCLAW_FLAG" ]]   && START_ARGS+=("$OPENCLAW_FLAG")
[[ -n "$MQTT_BROKER_URL" ]] && START_ARGS+=("--mqtt-broker-url=${MQTT_BROKER_URL}")
[[ -n "$MQTT_MAPPINGS" ]]   && START_ARGS+=("--mqtt-mappings=${MQTT_MAPPINGS}")

info "startUniverse.sh ${START_ARGS[*]}"
echo ""

STARTUP_LOG="$REPORT_DIR/startup-${RUN_ID}.log"
set +e
MQTT_USERNAME="$MQTT_USERNAME" MQTT_PASSWORD="$MQTT_PASSWORD" \
  bash "$CI_DIR/startUniverse.sh" "${START_ARGS[@]}" 2>&1 | tee "$STARTUP_LOG"
START_RC=${PIPESTATUS[0]}
set -e

if [[ $START_RC -eq 0 ]]; then
  ok "Universe started (exit 0)"
  record_pass "Universe startup" "3-engine universe started successfully"
else
  fail "startUniverse.sh exited $START_RC"
  record_fail "Universe startup" "startUniverse.sh exited $START_RC — see $STARTUP_LOG"
  echo ""
  echo -e "${RED}Fatal: universe startup failed. Cannot continue.${RST}"
  echo "  Log: $STARTUP_LOG"
  _write_report
  exit 1
fi

# ── Phase 2: Verify registry ──────────────────────────────────────────────────
hdr "Phase 2 · Verify Engine Registry"

wait_registry() {
  local attempts=0
  while [[ $attempts -lt 30 ]]; do
    if [[ -f "$REGISTRY_FILE" ]]; then
      local count
      count=$(python3 -c "import json; print(len(json.load(open('$REGISTRY_FILE')).get('instances',[])))" 2>/dev/null || echo "0")
      if [[ "$count" -gt 0 ]]; then
        echo "$count"
        return 0
      fi
    fi
    sleep 2
    (( attempts++ ))
  done
  echo "0"
  return 1
}

info "Waiting for registry at $REGISTRY_FILE ..."
ENGINE_COUNT=$(wait_registry || true)
if [[ "$ENGINE_COUNT" -eq 0 ]]; then
  fail "Registry empty or missing after 60s"
  record_fail "Registry check" "no instances in $REGISTRY_FILE"
else
  ok "Registry has $ENGINE_COUNT instance(s)"
  record_pass "Registry check" "$ENGINE_COUNT engines registered"
fi

# Extract engine list into parallel arrays
if [[ -f "$REGISTRY_FILE" ]]; then
  while IFS="|" read -r _id _re _pe; do
    [[ -z "$_id" ]] && continue
    ENGINE_IDS+=("$_id")
    ENGINE_RE_URLS+=("$_re")
    ENGINE_PE_URLS+=("$_pe")
  done < <(python3 - "$REGISTRY_FILE" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
for inst in data.get("instances", []):
    iid = inst.get("id", "")
    re  = inst.get("re_url", "")
    pe  = inst.get("pe_url", "")
    print(f"{iid}|{re}|{pe}")
PYEOF
)
fi

info "Registered engines:"
local_i=0
for id in "${ENGINE_IDS[@]+"${ENGINE_IDS[@]}"}"; do
  info "  [$id]  RE=${ENGINE_RE_URLS[$local_i]:-?}  PE=${ENGINE_PE_URLS[$local_i]:-?}"
  (( local_i++ ))
done

# ── Phase 3: Per-engine smoke tests ──────────────────────────────────────────
hdr "Phase 3 · Per-Engine Smoke Tests"

smoke_check() {
  local id="$1" re_url="$2" pe_url="$3"
  local label_prefix="[$id]"

  # RE health
  local re_health re_status
  re_health=$(curl -sk --max-time 8 "$re_url/api/health" 2>/dev/null || true)
  re_status=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status','?'))" <<< "$re_health" 2>/dev/null || echo "?")
  if [[ "$re_status" == "ok" || "$re_status" == "healthy" ]]; then
    ok "$label_prefix RE health: $re_status"
    record_pass "$label_prefix RE health" "$re_url"
  else
    fail "$label_prefix RE health: got '$re_status'"
    record_fail "$label_prefix RE health" "status=$re_status from $re_url/api/health"
  fi

  # PE health
  local pe_health pe_status
  pe_health=$(curl -sk --max-time 8 "$pe_url/api/health" 2>/dev/null || true)
  pe_status=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status','?'))" <<< "$pe_health" 2>/dev/null || echo "?")
  if [[ "$pe_status" == "ok" || "$pe_status" == "healthy" ]]; then
    ok "$label_prefix PE health: $pe_status"
    record_pass "$label_prefix PE health" "$pe_url"
  else
    fail "$label_prefix PE health: got '$pe_status'"
    record_fail "$label_prefix PE health" "status=$pe_status from $pe_url/api/health"
  fi

  # RE /api/machines
  local machines_resp machine_count
  machines_resp=$(curl -sk --max-time 8 "$re_url/api/machines" 2>/dev/null || true)
  machine_count=$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
m=d.get('machines',d) if isinstance(d,dict) else d
print(len(m) if isinstance(m,list) else '?')
" <<< "$machines_resp" 2>/dev/null || echo "?")
  if [[ "$machine_count" =~ ^[0-9]+$ ]] && [[ "$machine_count" -gt 0 ]]; then
    ok "$label_prefix RE machines: $machine_count loaded"
    record_pass "$label_prefix RE machines" "$machine_count machines"
  else
    warn "$label_prefix RE machines: count='$machine_count'"
    record_warn "$label_prefix RE machines" "count=$machine_count"
  fi

  # PE sources
  local sources_resp source_count
  sources_resp=$(curl -sk --max-time 8 "$pe_url/api/sources" 2>/dev/null || true)
  source_count=$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
s=d.get('sources',d) if isinstance(d,dict) else d
print(len(s) if isinstance(s,list) else '?')
" <<< "$sources_resp" 2>/dev/null || echo "?")
  if [[ "$source_count" =~ ^[0-9]+$ ]] && [[ "$source_count" -gt 0 ]]; then
    ok "$label_prefix PE sources: $source_count"
    record_pass "$label_prefix PE sources" "$source_count sources"
  else
    warn "$label_prefix PE sources: count='$source_count'"
    record_warn "$label_prefix PE sources" "count=$source_count"
  fi

  # PE push smoke
  local push_resp push_ok
  push_resp=$(curl -sk --max-time 10 -X POST "$pe_url/api/push" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || true)
  push_ok=$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
print('ok' if d.get('success') or d.get('pushed') or 'stepCount' in d else 'fail')
" <<< "$push_resp" 2>/dev/null || echo "fail")
  if [[ "$push_ok" == "ok" ]]; then
    ok "$label_prefix PE push: success"
    record_pass "$label_prefix PE push" ""
  else
    warn "$label_prefix PE push: $push_resp"
    record_warn "$label_prefix PE push" "response: $push_resp"
  fi
}

if [[ ${#ENGINE_IDS[@]} -eq 0 ]]; then
  warn "No engines in registry — running smoke tests against default ports"
  smoke_check "scala" "http://localhost:5001" "http://localhost:5000"
  smoke_check "cpp"   "http://localhost:5301" "http://localhost:5300"
  smoke_check "lsp"   "http://localhost:5601" "http://localhost:5600"
else
  local_i=0
  for id in "${ENGINE_IDS[@]}"; do
    smoke_check "$id" "${ENGINE_RE_URLS[$local_i]}" "${ENGINE_PE_URLS[$local_i]}"
    (( local_i++ ))
  done
fi

# ── Phase 4: MQTT per-engine validation ───────────────────────────────────────
hdr "Phase 4 · MQTT Validation"

if [[ -z "$MQTT_BROKER_URL" ]]; then
  warn "MQTT broker URL not set — skipping MQTT phase"
  record_skip "MQTT validation" "no --mqtt-broker-url provided"
else
  MQTT_TEST_SCRIPT="$CI_DIR/scripts/test-mqtt-yuma.sh"
  if [[ ! -x "$MQTT_TEST_SCRIPT" ]]; then
    warn "test-mqtt-yuma.sh not found or not executable at $MQTT_TEST_SCRIPT"
    record_skip "MQTT validation" "test script missing"
  else
    MQTT_ARGS=(
      "--broker-url=$MQTT_BROKER_URL"
      "--skip-enable"
    )
    [[ -n "$MQTT_MAPPINGS" ]] && MQTT_ARGS+=("--mappings=$MQTT_MAPPINGS")
    [[ -n "$MQTT_USERNAME" ]] && MQTT_ARGS+=("--username=$MQTT_USERNAME")
    [[ -n "$MQTT_PASSWORD" ]] && MQTT_ARGS+=("--password=$MQTT_PASSWORD")

    if [[ ${#ENGINE_IDS[@]} -eq 0 ]]; then
      # Fall back to default PE ports
      local_i=0
      for id in scala cpp lsp; do
        local default_pe
        case "$id" in
          scala) default_pe="http://localhost:5000" ;;
          cpp)   default_pe="http://localhost:5300" ;;
          lsp)   default_pe="http://localhost:5600" ;;
        esac
        info "Testing MQTT on [$id] PE=$default_pe ..."
        MQTT_LOG="$REPORT_DIR/mqtt-${id}-${RUN_ID}.log"
        set +e
        bash "$MQTT_TEST_SCRIPT" --pe-url="$default_pe" "${MQTT_ARGS[@]}" > "$MQTT_LOG" 2>&1
        MQTT_RC=$?
        set -e
        if [[ $MQTT_RC -eq 0 ]]; then
          ok "[$id] MQTT Yuma test: PASS"
          record_pass "[$id] MQTT Yuma" "broker=$MQTT_BROKER_URL"
        else
          fail "[$id] MQTT Yuma test: FAIL (exit $MQTT_RC)"
          record_fail "[$id] MQTT Yuma" "exit $MQTT_RC — see $MQTT_LOG"
          tail -5 "$MQTT_LOG" | sed 's/^/    /'
        fi
      done
    else
      local_i=0
      for id in "${ENGINE_IDS[@]}"; do
        pe_url="${ENGINE_PE_URLS[$local_i]}"
        info "Testing MQTT on [$id] PE=$pe_url ..."
        MQTT_LOG="$REPORT_DIR/mqtt-${id}-${RUN_ID}.log"
        set +e
        bash "$MQTT_TEST_SCRIPT" --pe-url="$pe_url" "${MQTT_ARGS[@]}" > "$MQTT_LOG" 2>&1
        MQTT_RC=$?
        set -e
        if [[ $MQTT_RC -eq 0 ]]; then
          ok "[$id] MQTT Yuma test: PASS"
          record_pass "[$id] MQTT Yuma" "broker=$MQTT_BROKER_URL"
        else
          fail "[$id] MQTT Yuma test: FAIL (exit $MQTT_RC)"
          record_fail "[$id] MQTT Yuma" "exit $MQTT_RC — see $MQTT_LOG"
          tail -5 "$MQTT_LOG" | sed 's/^/    /'
        fi
        (( local_i++ ))
      done
    fi
  fi
fi

# ── Phase 5: Unit tests ───────────────────────────────────────────────────────
hdr "Phase 5 · Unit Tests"

if [[ "$SKIP_UNIT" == true ]]; then
  warn "Skipping unit tests (--skip-unit)"
  record_skip "Unit tests" "skipped by --skip-unit"
elif [[ -x "$CI_DIR/scripts/run-all-tests.sh" ]]; then
  UNIT_LOG="$REPORT_DIR/unit-${RUN_ID}.log"
  info "Running run-all-tests.sh --unit ..."
  set +e
  bash "$CI_DIR/scripts/run-all-tests.sh" --unit 2>&1 | tee "$UNIT_LOG"
  UNIT_RC=${PIPESTATUS[0]}
  set -e
  if [[ $UNIT_RC -eq 0 ]]; then
    ok "Unit tests: PASS"
    record_pass "Unit tests" "run-all-tests.sh --unit"
  else
    fail "Unit tests: FAIL (exit $UNIT_RC)"
    record_fail "Unit tests" "exit $UNIT_RC — see $UNIT_LOG"
  fi
else
  warn "run-all-tests.sh not found — skipping unit tests"
  record_skip "Unit tests" "run-all-tests.sh not found"
fi

# ── Phase 6: E2E/Deployment tests ─────────────────────────────────────────────
hdr "Phase 6 · E2E + Deployment Tests"

if [[ "$SKIP_E2E" == true ]]; then
  warn "Skipping e2e/deployment tests (--skip-e2e)"
  record_skip "E2E tests" "skipped by --skip-e2e"
elif [[ -x "$CI_DIR/scripts/run-all-tests.sh" ]]; then
  E2E_LOG="$REPORT_DIR/e2e-${RUN_ID}.log"
  info "Running run-all-tests.sh --e2e --deployment ..."
  set +e
  RE_REGISTRY_FILE="$REGISTRY_FILE" \
    bash "$CI_DIR/scripts/run-all-tests.sh" --e2e --deployment 2>&1 | tee "$E2E_LOG"
  E2E_RC=${PIPESTATUS[0]}
  set -e
  if [[ $E2E_RC -eq 0 ]]; then
    ok "E2E + deployment tests: PASS"
    record_pass "E2E + deployment tests" "run-all-tests.sh --e2e --deployment"
  else
    fail "E2E + deployment tests: FAIL (exit $E2E_RC)"
    record_fail "E2E + deployment tests" "exit $E2E_RC — see $E2E_LOG"
  fi
else
  warn "run-all-tests.sh not found — skipping e2e/deployment tests"
  record_skip "E2E tests" "run-all-tests.sh not found"
fi

# ── Phase 7: Cross-engine perceptual coherence check ─────────────────────────
hdr "Phase 7 · Cross-Engine Coherence"

if [[ ${#ENGINE_IDS[@]} -lt 2 ]]; then
  warn "Fewer than 2 engines registered — skipping cross-engine coherence check"
  record_skip "Cross-engine coherence" "< 2 engines"
else
  info "Comparing perceptual simulation state across engines ..."
  STATES_MATCH=true
  ENGINE_DIMS=()
  first_dim=""

  local_i=0
  for id in "${ENGINE_IDS[@]}"; do
    re_url="${ENGINE_RE_URLS[$local_i]}"
    state_resp=$(curl -sk --max-time 8 "$re_url/api/perceptual-simulation/state" 2>/dev/null || true)
    dim=$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
print(d.get('dimensionality',d.get('totalDimension','?')))
" <<< "$state_resp" 2>/dev/null || echo "?")
    ENGINE_DIMS+=("$dim")
    info "  [$id] perceptual dimensionality: $dim"

    if [[ -z "$first_dim" ]]; then
      first_dim="$dim"
    elif [[ "$dim" != "$first_dim" && "$dim" != "?" && "$first_dim" != "?" ]]; then
      fail "Dimensionality mismatch: first engine=$first_dim, [$id]=$dim"
      record_fail "Cross-engine coherence" "dimensionality mismatch: $first_dim vs $dim"
      STATES_MATCH=false
    fi
    (( local_i++ ))
  done

  if [[ "$STATES_MATCH" == true ]]; then
    ok "All engines report consistent perceptual dimensionality ($first_dim)"
    record_pass "Cross-engine coherence" "dimensionality=$first_dim across all engines"
  fi
fi

# ── Finalize results & write report ──────────────────────────────────────────
_write_report

# ── Final console summary ─────────────────────────────────────────────────────
hdr "Test Summary"

for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do
  IFS="|" read -r status label note <<< "$r"
  case "$status" in
    PASS) ok "${label}${note:+  ($note)}" ;;
    FAIL) fail "${label}${note:+  ($note)}" ;;
    WARN) warn "${label}${note:+  ($note)}" ;;
    SKIP) info "SKIP: ${label}${note:+  ($note)}" ;;
  esac
done

echo ""
echo -e "  ${BOLD}Results: ${GRN}${PASS_COUNT} passed${RST}  ${RED}${FAIL_COUNT} failed${RST}  ${YLW}${WARN_COUNT} warnings${RST}  ${CYN}${SKIP_COUNT} skipped${RST}"
echo ""
echo -e "  Report: ${BOLD}${REPORT_FILE}${RST}"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo -e "${RED}${BOLD}OVERALL: FAIL${RST}"
  exit 1
elif [[ $WARN_COUNT -gt 0 ]]; then
  echo -e "${YLW}${BOLD}OVERALL: PASS (with warnings)${RST}"
  exit 0
else
  echo -e "${GRN}${BOLD}OVERALL: PASS${RST}"
  exit 0
fi
