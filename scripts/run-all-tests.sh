#!/usr/bin/env bash
#
# run-all-tests.sh - unified test entry point across the RealityEngine repos.
#
# Usage:
#   scripts/run-all-tests.sh [--unit] [--e2e] [--all] [--deployment] [--list] [-h|--help]
#
#   --unit        Run offline build/unit/contract suites only (default).
#   --e2e         Run self-contained runtime e2e plus live-stack Playwright suites.
#   --all         Run both unit and e2e suites.
#   --deployment  Strict deployment gate: implies --all and treats skipped suites as failures.
#   --list        List the suites that would run and exit.
#
# Exit code is non-zero if any executed suite fails. Skipped suites are allowed
# for local non-deployment runs and fail the run in deployment mode.
set -uo pipefail

# -- Paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WS="$(cd "$CI_DIR/.." && pwd)"

SCALA_DIR="$WS/RealityEngine_Scala"
CPP_DIR="$WS/RealityEngine_CPP"
LSP_DIR="$WS/RealityEngine_LSP"
MGR_DIR="$WS/RealityEngine_Manager"
MACHINES_DIR="$WS/RealityEngine_Machines"
LOCALAI_DIR="$WS/localAIStack"
OPENCLAW_DIR="$WS/localOpenClawStack"

# -- Logging ---------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}ℹ${NC} $*"; }
warn() { echo -e "${RED}⚠${NC} $*"; }
hdr()  { echo -e "\n${CYAN}${BOLD}─── $* ───${NC}"; }

# -- Result accumulation ---------------------------------------------------
declare -a RESULTS=()        # "STATUS|label|note"
record() { RESULTS+=("$1|$2|${3:-}"); }

DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-false}"
MODE="unit"

have() { command -v "$1" >/dev/null 2>&1; }

version_at_least() {
    # version_at_least ACTUAL REQUIRED, numeric dot-separated versions.
    local actual="$1" required="$2" a_major a_minor a_patch r_major r_minor r_patch
    IFS=. read -r a_major a_minor a_patch _ <<< "$actual"
    IFS=. read -r r_major r_minor r_patch _ <<< "$required"
    a_major="${a_major:-0}"; a_minor="${a_minor:-0}"; a_patch="${a_patch:-0}"
    r_major="${r_major:-0}"; r_minor="${r_minor:-0}"; r_patch="${r_patch:-0}"
    [ "$a_major" -gt "$r_major" ] && return 0
    [ "$a_major" -lt "$r_major" ] && return 1
    [ "$a_minor" -gt "$r_minor" ] && return 0
    [ "$a_minor" -lt "$r_minor" ] && return 1
    [ "$a_patch" -ge "$r_patch" ]
}

NODE_VERSION=""
if have node; then NODE_VERSION="$(node -v 2>/dev/null | sed -E 's/^v//')"; fi
node_at_least() {
    [ -n "$NODE_VERSION" ] && version_at_least "$NODE_VERSION" "$1"
}

require_node() {
    local label="$1" min_version="$2"
    if ! have node; then
        skip_suite "$label" "node not found (need >=${min_version})"
        return 1
    fi
    if ! node_at_least "$min_version"; then
        skip_suite "$label" "Node ${NODE_VERSION} too old (need >=${min_version})"
        return 1
    fi
    return 0
}

resolve_sbt() {
    if have sbt; then echo "sbt"; return 0; fi
    for c in "$HOME/.sdkman/candidates/sbt/current/bin/sbt" /opt/homebrew/opt/sbt/bin/sbt; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

resolve_python() {
    local c
    for c in python3 python3.14 python3.13 python3.12 python3.11 python; do
        if have "$c" && "$c" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)' 2>/dev/null; then
            echo "$c"; return 0
        fi
    done
    return 1
}

run_suite() {
    local label="$1" workdir="$2"; shift 2
    local log; log="$(mktemp -t re-test.XXXXXX)"
    info "Running: $label"
    if ( cd "$workdir" && "$@" ) >"$log" 2>&1; then
        ok "$label - PASS"
        record PASS "$label"
    else
        warn "$label - FAIL (last 20 lines):"
        tail -20 "$log" | sed 's/^/    /'
        record FAIL "$label" "see output above"
    fi
    rm -f "$log"
}

run_shell_suite() {
    local label="$1" workdir="$2" command="$3"
    local log; log="$(mktemp -t re-test.XXXXXX)"
    info "Running: $label"
    if ( cd "$workdir" && bash -lc "$command" ) >"$log" 2>&1; then
        ok "$label - PASS"
        record PASS "$label"
    else
        warn "$label - FAIL (last 20 lines):"
        tail -20 "$log" | sed 's/^/    /'
        record FAIL "$label" "see output above"
    fi
    rm -f "$log"
}

skip_suite() {
    if [ "$DEPLOYMENT_MODE" = "true" ]; then
        warn "FAIL: $1 - skipped in deployment mode: $2"
        record FAIL "$1" "skipped in deployment mode: $2"
    else
        warn "SKIP: $1 - $2"
        record SKIP "$1" "$2"
    fi
}

repo_present() {
    local label="$1" dir="$2"
    if [ ! -d "$dir" ]; then
        skip_suite "$label" "repo not found at $dir"
        return 1
    fi
    return 0
}

node_modules_present() {
    local label="$1" dir="$2"
    if [ ! -d "$dir/node_modules" ]; then
        skip_suite "$label" "node_modules missing - run 'npm ci' in $dir"
        return 1
    fi
    return 0
}

python_venv_env() {
    local dir="$1"
    if [ -d "$dir/.venv" ]; then
        echo "source .venv/bin/activate"
    else
        echo ":"
    fi
}

stack_healthy() {
    local registry_file="${RE_REGISTRY_FILE:-/tmp/re-registry/re-registry.json}"
    if [ -f "$registry_file" ]; then
        local ui=1 be=1 endpoints endpoint_count=0
        { curl -sk --max-time 3 https://localhost:5173/ >/dev/null 2>&1 || curl -s --max-time 3 http://localhost:5173/ >/dev/null 2>&1; } && ui=0
        { curl -sk --max-time 3 https://localhost:3001/health >/dev/null 2>&1 || curl -s --max-time 3 http://localhost:3001/health >/dev/null 2>&1; } && be=0
        endpoints="$(python3 - "$registry_file" <<'PYEOF' 2>/dev/null || true
import json
import sys

with open(sys.argv[1]) as f:
    instances = json.load(f).get("instances", [])
for inst in instances:
    re_url = inst.get("re_url")
    pe_url = inst.get("pe_url")
    if re_url:
        print(re_url.rstrip("/") + "/api/health")
    if pe_url:
        print(pe_url.rstrip("/") + "/api/health")
PYEOF
)"
        [ -n "$endpoints" ] || return 1
        while IFS= read -r endpoint; do
            [ -z "$endpoint" ] && continue
            endpoint_count=$((endpoint_count + 1))
            curl -sf --max-time 3 "$endpoint" >/dev/null 2>&1 || return 1
        done <<< "$endpoints"
        [ "$ui" -eq 0 ] && [ "$be" -eq 0 ] && [ "$endpoint_count" -gt 0 ]
        return
    fi

    local ui=1 be=1 pe=1 re=1
    { curl -sk --max-time 3 https://localhost:5173/ >/dev/null 2>&1 || curl -s --max-time 3 http://localhost:5173/ >/dev/null 2>&1; } && ui=0
    { curl -sk --max-time 3 https://localhost:3001/health >/dev/null 2>&1 || curl -s --max-time 3 http://localhost:3001/health >/dev/null 2>&1; } && be=0
    { curl -sk --max-time 3 https://localhost:3004/api/health >/dev/null 2>&1 || curl -s --max-time 3 http://localhost:3004/api/health >/dev/null 2>&1; } && pe=0
    { curl -sk --max-time 3 https://localhost:5001/api/health >/dev/null 2>&1 || curl -s --max-time 3 http://localhost:5001/api/health >/dev/null 2>&1; } && re=0
    [ "$ui" -eq 0 ] && [ "$be" -eq 0 ] && [ "$pe" -eq 0 ] && [ "$re" -eq 0 ]
}

run_openclaw_smoke() {
    local label="OpenClaw health/API smoke"
    repo_present "$label" "$OPENCLAW_DIR" || return

    local gateway_port="${OPENCLAW_GATEWAY_PORT:-18789}"
    local gateway_url="${OPENCLAW_GATEWAY_URL:-http://localhost:${gateway_port}}"

    if ! curl -sf --max-time 5 "$gateway_url/healthz" >/dev/null 2>&1; then
        skip_suite "$label" "OpenClaw gateway not reachable at $gateway_url/healthz"
        return
    fi

    local log; log="$(mktemp -t re-openclaw.XXXXXX)"
    info "Running: $label"
    local rc=1
    if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
        curl -sf --max-time 10 -H "Authorization: Bearer ${OPENCLAW_GATEWAY_TOKEN}" "$gateway_url/v1/models" >"$log" 2>&1
        rc=$?
    else
        curl -sf --max-time 10 "$gateway_url/v1/models" >"$log" 2>&1
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        ok "$label - PASS"
        record PASS "$label"
    else
        warn "$label - FAIL (last 20 lines):"
        tail -20 "$log" | sed 's/^/    /'
        record FAIL "$label" "health passed, /v1/models failed"
    fi
    rm -f "$log"
}

run_openclaw_integration_e2e() {
    local label="OpenClaw PE integration e2e"
    if [ ! -x "$CI_DIR/scripts/test-openclaw-integration.sh" ]; then
        skip_suite "$label" "test script missing or not executable"
        return
    fi

    require_node "$label" "25.5.0" || return

    local registry_file="${RE_REGISTRY_FILE:-/tmp/re-registry/re-registry.json}"
    if [ -f "$registry_file" ]; then
        local targets target_count=0 id pe_url
        targets="$(python3 - "$registry_file" <<'PYEOF' 2>/dev/null || true
import json
import sys

with open(sys.argv[1]) as f:
    instances = json.load(f).get("instances", [])
for inst in instances:
    iid = inst.get("id")
    pe_url = inst.get("pe_url")
    if iid and pe_url:
        print(f"{iid} {pe_url}")
PYEOF
)"
        [ -n "$targets" ] || { skip_suite "$label" "multi-engine registry has no PE URLs"; return; }
        while read -r id pe_url; do
            [ -z "$id" ] && continue
            target_count=$((target_count + 1))
            run_shell_suite "$label ($id)" "$CI_DIR" "PE_URL='$pe_url' ACP_COMPLETION_SOURCE_MAPPING_ID='${ACP_COMPLETION_SOURCE_MAPPING_ID:-acp-openclaw-completion}' '$CI_DIR/scripts/test-openclaw-integration.sh'"
        done <<< "$targets"
        [ "$target_count" -gt 0 ] || skip_suite "$label" "multi-engine registry has no PE URLs"
        return
    fi

    if ! { curl -sk --max-time 3 https://localhost:3004/api/health >/dev/null 2>&1 || curl -s --max-time 3 http://localhost:3004/api/health >/dev/null 2>&1; }; then
        skip_suite "$label" "PE not reachable at https://localhost:3004"
        return
    fi

    run_suite "$label" "$CI_DIR" "$CI_DIR/scripts/test-openclaw-integration.sh"
}

# -- Unit/build/contract suites -------------------------------------------
run_unit() {
    hdr "Build / unit / contract suites"

    if repo_present "C++ (make all)" "$CPP_DIR"; then
        if have make && { have c++ || have g++ || have clang++; }; then
            run_suite "C++ (make all)" "$CPP_DIR" make all
            run_suite "C++ (make test)" "$CPP_DIR" make test
        else
            skip_suite "C++" "make or C++ compiler not found"
        fi
    fi

    if repo_present "LSP (make build/test)" "$LSP_DIR"; then
        if ! have sbcl; then
            skip_suite "LSP" "sbcl not found (brew install sbcl)"
        elif [ -f "$LSP_DIR/quicklisp/setup.lisp" ] || [ -f "$HOME/quicklisp/setup.lisp" ]; then
            run_suite "LSP (make build)" "$LSP_DIR" make build
            run_suite "LSP (make test)" "$LSP_DIR" make test
        else
            skip_suite "LSP" "Quicklisp not found - install to ~/quicklisp"
        fi
    fi

    if repo_present "Scala (sbt test)" "$SCALA_DIR"; then
        local sbt
        if sbt="$(resolve_sbt)"; then
            run_suite "Scala root (sbt test)" "$SCALA_DIR" "$sbt" -batch -Dsbt.log.noformat=true test
            if [ -d "$SCALA_DIR/perception-engine" ]; then
                # The PE Makefile defaults SBT ?= sbt (bare), which is not on the
                # non-interactive PATH. Forward the resolved sbt so make can find it.
                run_suite "Scala PE (make compile)" "$SCALA_DIR/perception-engine" make compile SBT="$sbt"
                run_suite "Scala PE (make test)" "$SCALA_DIR/perception-engine" make test SBT="$sbt"
            else
                skip_suite "Scala PE" "perception-engine directory missing"
            fi
        else
            skip_suite "Scala" "sbt not found (install via sdkman or brew)"
        fi
    fi

    run_manager_builds_and_tests
    run_machines_offline
    run_openclaw_adapter_tests
    run_localai_tests
}

run_openclaw_adapter_tests() {
    local label="OpenClaw adapter unit/mock e2e"
    require_node "$label" "25.5.0" || return
    run_suite "$label" "$CI_DIR" npm run test:openclaw-adapter
}

run_manager_builds_and_tests() {
    local min_node="25.5.0"
    local modules=(
        "visualizer/backend|Manager visualizer backend"
        "visualizer/frontend|Manager visualizer frontend"
        "perception-engine/backend|Manager PE backend"
        "perception-engine/frontend|Manager PE frontend"
    )

    repo_present "Manager" "$MGR_DIR" || return
    require_node "Manager" "$min_node" || return

    local entry rel label dir
    for entry in "${modules[@]}"; do
        rel="${entry%%|*}"; label="${entry#*|}"; dir="$MGR_DIR/$rel"
        if [ ! -f "$dir/package.json" ]; then
            skip_suite "$label" "package.json missing at $dir"
            continue
        fi
        node_modules_present "$label build" "$dir" || continue
        run_suite "$label (npm run build)" "$dir" npm run build
        case "$rel" in
            visualizer/frontend)
                run_suite "$label (vitest)" "$dir" npx vitest run ;;
            perception-engine/backend)
                run_suite "$label (jest)" "$dir" npm test ;;
        esac
    done
}

run_machines_offline() {
    repo_present "Machines" "$MACHINES_DIR" || return
    require_node "Machines" "25.5.0" || return
    local py
    if py="$(resolve_python)"; then
        run_suite "Machines validate" "$MACHINES_DIR" npm run validate
        run_suite "Machines validate:strict" "$MACHINES_DIR" npm run validate:strict
        run_suite "Machines contracts" "$MACHINES_DIR" "$py" -m unittest discover -s tests/contracts -p '*_test.py'
    else
        skip_suite "Machines offline" "no Python >=3.11 found"
    fi
}

run_localai_tests() {
    local label="localAIStack pytest"
    repo_present "$label" "$LOCALAI_DIR" || return
    local py_env; py_env="$(python_venv_env "$LOCALAI_DIR")"
    if [ -d "$LOCALAI_DIR/.venv" ]; then
        run_shell_suite "$label" "$LOCALAI_DIR" "$py_env && python -m pytest services/api/tests"
    elif have pytest; then
        run_suite "$label" "$LOCALAI_DIR" pytest services/api/tests
    elif have python3 && python3 -m pytest --version >/dev/null 2>&1; then
        run_suite "$label" "$LOCALAI_DIR" python3 -m pytest services/api/tests
    else
        skip_suite "$label" "pytest not found - install services/api/requirements-dev.txt"
    fi
}

# -- E2E suites -------------------------------------------------------------
run_e2e() {
    hdr "Runtime e2e suites"

    if repo_present "C++ e2e" "$CPP_DIR"; then
        if have make && { have c++ || have g++ || have clang++; }; then
            run_suite "C++ (make e2e)" "$CPP_DIR" make e2e
        else
            skip_suite "C++ e2e" "make or C++ compiler not found"
        fi
    fi

    if repo_present "LSP e2e" "$LSP_DIR"; then
        if have sbcl && { [ -f "$LSP_DIR/quicklisp/setup.lisp" ] || [ -f "$HOME/quicklisp/setup.lisp" ]; }; then
            run_suite "LSP (make e2e-healthkit-spezi)" "$LSP_DIR" make e2e-healthkit-spezi
        else
            skip_suite "LSP e2e" "sbcl or Quicklisp missing"
        fi
    fi

    if repo_present "Scala PE e2e" "$SCALA_DIR/perception-engine"; then
        local sbt
        if sbt="$(resolve_sbt)"; then
            # PE Makefile (and its reality-assembly dep) shell out to bare sbt;
            # forward the resolved path so make can find it off the PATH.
            run_suite "Scala PE (make e2e-healthkit-spezi)" "$SCALA_DIR/perception-engine" make e2e-healthkit-spezi SBT="$sbt"
        else
            skip_suite "Scala PE e2e" "sbt not found"
        fi
    fi

    run_playwright_e2e
    run_openclaw_smoke
    run_openclaw_integration_e2e
}

run_playwright_e2e() {
    hdr "Live-stack Playwright suites"

    local registry_file="${RE_REGISTRY_FILE:-/tmp/re-registry/re-registry.json}"
    local registry_url="${RE_REGISTRY_URL:-http://127.0.0.1:5999/re-registry.json}"
    local multi_engine=false

    if ! stack_healthy; then
        warn "Live stack not reachable at https://localhost:5173 plus RE/PE/backend health endpoints"
        warn "Start it first: (cd $CI_DIR && ./startUniverse.sh)"
        skip_suite "CI e2e (Playwright)" "live stack down"
        skip_suite "Machines smoke (Playwright)" "live stack down"
        skip_suite "Machines integration (Playwright)" "live stack down"
        skip_suite "Machines e2e (Playwright)" "live stack down"
        skip_suite "Manager frontend e2e (Playwright)" "live stack down"
        return
    fi
    ok "Live stack reachable - reusing running services (REUSE_SERVICES=true)"
    export REUSE_SERVICES=true
    if [ -f "$registry_file" ]; then
        multi_engine=true
    fi

    require_node "Playwright e2e" "25.5.0" || return

    if [ -d "$CI_DIR/node_modules" ]; then
        if [ "$multi_engine" = "true" ]; then
            run_shell_suite "CI e2e (Playwright, multi-engine)" "$CI_DIR" \
                "REUSE_SERVICES=true MULTI_ENGINE_E2E=true PLAYWRIGHT_BASE_URL='${PLAYWRIGHT_BASE_URL:-http://localhost:5173}' CI=true npx playwright test e2e/tests/tree-to-pe-manager-equivalence.spec.ts --project=chromium --workers=1"
        else
            run_suite "CI e2e (Playwright)" "$CI_DIR" npx playwright test
        fi
    else
        skip_suite "CI e2e (Playwright)" "node_modules missing - run 'npm ci' in $CI_DIR"
    fi

    if [ -d "$MACHINES_DIR/node_modules" ]; then
        if [ "$multi_engine" = "true" ]; then
            local machines_env first_re_url first_pe_url
            first_re_url="$(python3 - "$registry_file" <<'PYEOF' 2>/dev/null || true
import json
import sys

with open(sys.argv[1]) as f:
    instances = json.load(f).get("instances", [])
print(instances[0].get("re_url", "") if instances else "")
PYEOF
)"
            first_pe_url="$(python3 - "$registry_file" <<'PYEOF' 2>/dev/null || true
import json
import sys

with open(sys.argv[1]) as f:
    instances = json.load(f).get("instances", [])
print(instances[0].get("pe_url", "") if instances else "")
PYEOF
)"
            machines_env="REUSE_SERVICES=true RE_REGISTRY_URL='$registry_url' RE_BASE_URL='${first_re_url:-http://localhost:5001}' PE_BASE_URL='${first_pe_url:-http://localhost:5000}' VIZ_BASE_URL='http://localhost:3001' VIZ_FRONTEND_URL='http://localhost:5173' LAS_BASE_URL='http://localhost:4000' QD_BASE_URL='http://localhost:4333' SKIP_GLOBAL_SETUP=true CI=true"
            run_shell_suite "Machines smoke (Playwright)" "$MACHINES_DIR" "$machines_env npm run test:smoke -- --project=chromium --workers=1"
            run_shell_suite "Machines integration (Playwright)" "$MACHINES_DIR" "$machines_env npm run test:integration -- --project=chromium --workers=1"
            run_shell_suite "Machines e2e (Playwright)" "$MACHINES_DIR" "$machines_env npm run test:e2e -- --project=chromium --workers=1"
        else
            run_suite "Machines smoke (Playwright)" "$MACHINES_DIR" npm run test:smoke
            run_suite "Machines integration (Playwright)" "$MACHINES_DIR" npm run test:integration
            run_suite "Machines e2e (Playwright)" "$MACHINES_DIR" npm run test:e2e
        fi
    else
        skip_suite "Machines Playwright" "node_modules missing - run 'npm ci' in $MACHINES_DIR"
    fi

    local fe="$MGR_DIR/visualizer/frontend"
    if [ -d "$fe/node_modules" ]; then
        run_shell_suite "Manager frontend e2e (Playwright)" "$fe" \
            "npx playwright test --project=chromium --workers=1"
    else
        skip_suite "Manager frontend e2e (Playwright)" "node_modules missing - run 'npm ci' in $fe"
    fi
}

summary() {
    hdr "Summary"
    local pass=0 fail=0 skip=0 entry status rest label note
    for entry in "${RESULTS[@]}"; do
        status="${entry%%|*}"; rest="${entry#*|}"; label="${rest%%|*}"; note="${rest#*|}"
        case "$status" in
            PASS) ok   "$label"; pass=$((pass+1));;
            FAIL) warn "$label  ($note)"; fail=$((fail+1));;
            SKIP) info "$label  - skipped: $note"; skip=$((skip+1));;
        esac
    done
    echo -e "\n${BOLD}Totals:${NC} ${GREEN}$pass passed${NC}, ${RED}$fail failed${NC}, ${YELLOW}$skip skipped${NC}"
    if [ "$DEPLOYMENT_MODE" = "true" ]; then
        echo -e "${BOLD}Deployment mode:${NC} skipped suites are recorded as failures"
    fi
    [ "$fail" -eq 0 ]
}

print_list() {
    cat <<EOF

Unit/build/offline:
  _CPP       make all; make test
  _LSP       make build; make test
  _Scala     sbt test; perception-engine make compile; make test
  _Manager   npm run build for visualizer/backend, visualizer/frontend,
             perception-engine/backend, perception-engine/frontend; plus frontend Vitest and PE backend Jest
  _Machines  validate; validate:strict; contracts
  localAIStack pytest services/api/tests

E2E:
  _CPP       make e2e
  _LSP       make e2e-healthkit-spezi
  _Scala     perception-engine make e2e-healthkit-spezi
  _CI        Playwright e2e against live stack
  _Machines  smoke, integration, e2e Playwright against live stack
  _Manager   visualizer frontend Playwright against live stack
  OpenClaw   healthz + /v1/models smoke when gateway is running
  OpenClaw   PE integration e2e when a PE is running at https://localhost:3004

Modes:
  --unit (default), --e2e, --all, --deployment (strict --all), --list
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --unit) MODE="unit" ;;
        --e2e) MODE="e2e" ;;
        --all) MODE="all" ;;
        --deployment) MODE="all"; DEPLOYMENT_MODE="true" ;;
        --list) MODE="list" ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) warn "Unknown option: $1"; echo "Try --help"; exit 2 ;;
    esac
    shift
done

[ "$DEPLOYMENT_MODE" = "1" ] && DEPLOYMENT_MODE="true"

if [ "$MODE" = "list" ]; then
    echo -e "${BOLD}RealityEngine - unified test runner${NC}  (workspace: $WS)"
    print_list
    exit 0
fi

echo -e "${BOLD}RealityEngine - unified test runner${NC}  (workspace: $WS)"
[ "$DEPLOYMENT_MODE" = "true" ] && info "Deployment mode enabled: skipped suites fail the run"

case "$MODE" in
    unit) run_unit ;;
    e2e)  run_e2e ;;
    all)  run_unit; run_e2e ;;
esac

summary
