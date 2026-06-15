#!/usr/bin/env bash
#
# run-all-tests.sh — unified test entry point across the RealityEngine repos.
#
# Addresses the cross-repo testing findings:
#   * one command to run every suite (ScalaTest, C++, Lisp, Vitest, Playwright,
#     Python unittest) instead of remembering each repo's bespoke invocation;
#   * e2e suites are GATED on a live-stack health check, so they are skipped
#     with a clear message instead of failing with confusing connection errors
#     when the universe (startUniverse.sh) is not running.
#
# Usage:
#   scripts/run-all-tests.sh [--unit] [--e2e] [--all] [--list] [-h|--help]
#
#   --unit   Run unit/offline suites only (default).
#   --e2e    Run end-to-end suites only (requires a healthy live stack).
#   --all    Run both unit and e2e suites.
#   --list   List the suites that would run and exit.
#
# Exit code is non-zero if any executed suite fails. Skipped suites do not
# fail the run.
set -uo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WS="$(cd "$CI_DIR/.." && pwd)"

SCALA_DIR="$WS/RealityEngine_Scala"
CPP_DIR="$WS/RealityEngine_CPP"
LSP_DIR="$WS/RealityEngine_LSP"
MGR_DIR="$WS/RealityEngine_Manager"
MACHINES_DIR="$WS/RealityEngine_Machines"

# ── Logging (matches startUniverse.sh style) ────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}ℹ${NC} $*"; }
warn() { echo -e "${RED}⚠${NC} $*"; }
hdr()  { echo -e "\n${CYAN}${BOLD}─── $* ───${NC}"; }

# ── Result accumulation ─────────────────────────────────────────────────────
declare -a RESULTS=()        # "STATUS|label|note"
record() { RESULTS+=("$1|$2|${3:-}"); }

have() { command -v "$1" >/dev/null 2>&1; }

# node_ok — true if a usable Node (>=18) is on PATH. The npm/vitest/playwright
# toolchains crash cryptically on ancient Node (e.g. nvm-default v12), so we
# gate on this and skip with a clear message instead.
NODE_MAJOR=0
if have node; then NODE_MAJOR="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"; fi
node_ok() { [ "${NODE_MAJOR:-0}" -ge 18 ] 2>/dev/null; }

# Resolve sbt: PATH first, then SDKMAN, then Homebrew opt.
resolve_sbt() {
    if have sbt; then echo "sbt"; return 0; fi
    for c in "$HOME/.sdkman/candidates/sbt/current/bin/sbt" /opt/homebrew/opt/sbt/bin/sbt; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

# Resolve a Python >= 3.11. The Machines contract scripts (e.g.
# build-dispatch-envelope.py) use datetime.UTC, which is 3.11+. macOS ships
# /usr/bin/python3 as 3.9 (Command Line Tools), so bare `python3` is too old;
# prefer the default if new enough, else the newest versioned interpreter on
# PATH. Prints the interpreter name/path, or returns 1 if none qualifies.
resolve_python() {
    local c
    for c in python3 python3.14 python3.13 python3.12 python3.11 python; do
        if have "$c" && "$c" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)' 2>/dev/null; then
            echo "$c"; return 0
        fi
    done
    return 1
}

# run_suite <label> <workdir> <command...>
# Runs the command, captures output to a temp log, records PASS/FAIL.
run_suite() {
    local label="$1" workdir="$2"; shift 2
    local log; log="$(mktemp -t re-test.XXXXXX)"
    info "Running: $label"
    if ( cd "$workdir" && "$@" ) >"$log" 2>&1; then
        ok "$label — PASS"
        record PASS "$label"
    else
        warn "$label — FAIL (last 15 lines):"
        tail -15 "$log" | sed 's/^/    /'
        record FAIL "$label" "see output above"
    fi
    rm -f "$log"
}

skip_suite() { warn "SKIP: $1 — $2"; record SKIP "$1" "$2"; }

# ── Live-stack health gate (Finding: e2e depend on a running universe) ──────
# Returns 0 only if BOTH the Visualizer UI (Playwright baseURL, :5173) and the
# Visualizer backend (:3001/health) respond. Requiring the backend prevents a
# stale, leftover Vite dev server from falsely greenlighting the e2e suites.
stack_healthy() {
    local ui=1 be=1
    curl -sk --max-time 3 https://localhost:5173/ >/dev/null 2>&1 \
        || curl -s --max-time 3 http://localhost:5173/ >/dev/null 2>&1 && ui=0
    curl -sk --max-time 3 https://localhost:3001/health >/dev/null 2>&1 \
        || curl -s --max-time 3 http://localhost:3001/health >/dev/null 2>&1 && be=0
    [ "$ui" -eq 0 ] && [ "$be" -eq 0 ]
}

# ── Unit suites ─────────────────────────────────────────────────────────────
run_unit() {
    hdr "Unit / offline suites"

    # Scala — ScalaTest via sbt
    if [ -d "$SCALA_DIR" ]; then
        local sbt; if sbt="$(resolve_sbt)"; then
            run_suite "Scala (ScalaTest)" "$SCALA_DIR" "$sbt" -batch -Dsbt.log.noformat=true test
        else
            skip_suite "Scala (ScalaTest)" "sbt not found (install via sdkman or brew)"
        fi
    fi

    # C++ — make test (builds + runs unit binaries)
    if [ -d "$CPP_DIR" ]; then
        if have make && { have c++ || have g++ || have clang++; }; then
            run_suite "C++ (make test)" "$CPP_DIR" make test
        else
            skip_suite "C++ (make test)" "make or C++ compiler not found"
        fi
    fi

    # Lisp — `make test` (loads Quicklisp, provisions ASDF deps, runs core-tests).
    # Running sbcl + asdf:test-system directly would skip Quicklisp and fail to
    # resolve dependencies (alexandria, hunchentoot, …); the Makefile target is
    # the canonical path. Gate on Quicklisp so a missing copy SKIPs cleanly
    # instead of failing — the Makefile resolves it repo-local first, then $HOME.
    if [ -d "$LSP_DIR" ]; then
        if ! have sbcl; then
            skip_suite "Lisp (core-tests)" "sbcl not found (brew install sbcl)"
        elif [ -f "$LSP_DIR/quicklisp/setup.lisp" ] || [ -f "$HOME/quicklisp/setup.lisp" ]; then
            run_suite "Lisp (core-tests)" "$LSP_DIR" make test
        else
            skip_suite "Lisp (core-tests)" "Quicklisp not found — install to ~/quicklisp (see RealityEngine_LSP/README.md)"
        fi
    fi

    # Manager — Visualizer frontend (Vitest)
    local fe="$MGR_DIR/visualizer/frontend"
    if [ -d "$fe" ]; then
        if ! node_ok; then
            skip_suite "Manager frontend (Vitest)" "Node ${NODE_MAJOR} too old (need >=18) — 'nvm use 20' or newer"
        elif [ ! -d "$fe/node_modules" ]; then
            skip_suite "Manager frontend (Vitest)" "node_modules missing — run 'npm ci' in $fe"
        else
            run_suite "Manager frontend (Vitest)" "$fe" npx vitest run
        fi
    fi

    # Manager — Perception-engine backend (orphaned: 211 tests, no runner)
    local pe="$MGR_DIR/perception-engine/backend"
    if [ -d "$pe" ]; then
        if ! grep -q '"test"' "$pe/package.json" 2>/dev/null \
           || ! grep -qiE '"(jest|vitest|mocha)"' "$pe/package.json" 2>/dev/null; then
            skip_suite "Manager PE backend (15 files)" "no test runner configured in package.json"
        elif ! node_ok; then
            skip_suite "Manager PE backend (15 files)" "Node ${NODE_MAJOR} too old (need >=18) — 'nvm use 25.5.0'"
        elif [ ! -d "$pe/node_modules" ]; then
            skip_suite "Manager PE backend (15 files)" "node_modules missing — run 'npm ci' in $pe"
        else
            run_suite "Manager PE backend (Jest)" "$pe" npm test
        fi
    fi

    # Machines — Python agent-contract tests (require Python >= 3.11)
    if [ -d "$MACHINES_DIR" ]; then
        local py
        if py="$(resolve_python)"; then
            run_suite "Machines contracts (unittest)" "$MACHINES_DIR" \
                "$py" -m unittest discover -s tests/contracts -p '*_test.py'
        else
            skip_suite "Machines contracts (unittest)" "no Python >=3.11 found (scripts use datetime.UTC — brew install python@3.13)"
        fi
    fi
}

# ── E2E suites (gated) ──────────────────────────────────────────────────────
run_e2e() {
    hdr "End-to-end suites (live-stack gated)"

    if ! stack_healthy; then
        warn "Live stack not reachable at https://localhost:5173"
        warn "Start it first:  (cd $CI_DIR && ./startUniverse.sh)"
        skip_suite "CI e2e (Playwright)"            "live stack down"
        skip_suite "Machines e2e (Playwright)"      "live stack down"
        skip_suite "Manager frontend e2e (Playwright)" "live stack down"
        return
    fi
    ok "Live stack reachable — reusing running services (REUSE_SERVICES=true)"
    export REUSE_SERVICES=true

    if ! node_ok; then
        skip_suite "CI e2e (Playwright)"               "Node ${NODE_MAJOR} too old (need >=18)"
        skip_suite "Machines e2e (Playwright)"         "Node ${NODE_MAJOR} too old (need >=18)"
        skip_suite "Manager frontend e2e (Playwright)" "Node ${NODE_MAJOR} too old (need >=18)"
        return
    fi

    if [ -d "$CI_DIR/node_modules" ]; then
        run_suite "CI e2e (Playwright)" "$CI_DIR" npx playwright test
    else
        skip_suite "CI e2e (Playwright)" "node_modules missing — run 'npm ci' in $CI_DIR"
    fi

    if [ -d "$MACHINES_DIR/node_modules" ]; then
        run_suite "Machines e2e (Playwright)" "$MACHINES_DIR" npm run test:e2e
    else
        skip_suite "Machines e2e (Playwright)" "node_modules missing — run 'npm ci' in $MACHINES_DIR"
    fi

    local fe="$MGR_DIR/visualizer/frontend"
    if [ -d "$fe/node_modules" ]; then
        run_suite "Manager frontend e2e (Playwright)" "$fe" npm run test:e2e
    else
        skip_suite "Manager frontend e2e (Playwright)" "node_modules missing — run 'npm ci' in $fe"
    fi
}

# ── Summary ─────────────────────────────────────────────────────────────────
summary() {
    hdr "Summary"
    local pass=0 fail=0 skip=0 entry status label note
    for entry in "${RESULTS[@]}"; do
        status="${entry%%|*}"; rest="${entry#*|}"; label="${rest%%|*}"; note="${rest#*|}"
        case "$status" in
            PASS) ok   "$label"; pass=$((pass+1));;
            FAIL) warn "$label  ($note)"; fail=$((fail+1));;
            SKIP) info "$label  — skipped: $note"; skip=$((skip+1));;
        esac
    done
    echo -e "\n${BOLD}Totals:${NC} ${GREEN}$pass passed${NC}, ${RED}$fail failed${NC}, ${YELLOW}$skip skipped${NC}"
    [ "$fail" -eq 0 ]
}

# ── Main ────────────────────────────────────────────────────────────────────
MODE="unit"
case "${1:-}" in
    --unit|"") MODE="unit";;
    --e2e)     MODE="e2e";;
    --all)     MODE="all";;
    --list)    MODE="list";;
    -h|--help)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 0;;
    *) warn "Unknown option: $1"; echo "Try --help"; exit 2;;
esac

echo -e "${BOLD}RealityEngine — unified test runner${NC}  (workspace: $WS)"

if [ "$MODE" = "list" ]; then
    cat <<EOF

Unit:  Scala (ScalaTest) · C++ (make test) · Lisp (core-tests) ·
       Manager frontend (Vitest) · Manager PE backend [orphaned] ·
       Machines contracts (unittest)
E2E:   CI · Machines · Manager frontend  (Playwright; require live stack)
EOF
    exit 0
fi

case "$MODE" in
    unit) run_unit;;
    e2e)  run_e2e;;
    all)  run_unit; run_e2e;;
esac

summary
