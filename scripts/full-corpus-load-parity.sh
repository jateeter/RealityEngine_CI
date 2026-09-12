#!/usr/bin/env bash
# full-corpus-load-parity — every runtime loads the WHOLE corpus, and agrees.
#
# WHY THIS EXISTS
# ---------------
# Nothing raises when an engine silently fails to read part of the corpus. A
# machine whose shape a loader mishandles is not reported as an error; it is
# simply absent, and an engine holding 1,327 of 1,328 machines answers every
# request it is asked about perfectly well. The only check that catches it is
# whether the runtimes agree with each other and with the file count on disk.
#
# That is not hypothetical:
#   * The Reality Event rename (RealityEngine_CI#220) turned on exactly this
#     hazard — a missed corpus read raises nothing, so four-runtime load-count
#     parity was the only gate that would have caught it.
#   * RealityEngine_CI#356: scala held 1344 machines to cpp/lsp's 1338 and no
#     wired gate asserted the difference, so it went unnoticed.
#
# The per-PR lanes boot the 20-machine regression selection, which cannot see
# this: a shape that only appears in one of the other 1,308 machines has no
# opportunity to diverge. Hence the scheduled full-corpus cycle.
#
# Exit 1 on any disagreement. A runtime that fails to start is a failure, not a
# skip — "could not be measured" and "measured equal" must not look alike.

set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACHINES_DIR="${MACHINES_DIR:-$CI_DIR/../RealityEngine_Machines}"
REPORT_DIR="$CI_DIR/.full-corpus"
mkdir -p "$REPORT_DIR"

# shellcheck source=scripts/registry.sh
source "$CI_DIR/scripts/registry.sh"

info() { printf '\033[1;33mℹ\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '\033[0;31m⚠\033[0m %s\n' "$*"; }

# ── Perceptual space the FULL corpus needs ───────────────────────────────────
# The engines default to 7680; the full corpus maps to 16944. Starting
# under-provisioned makes machines fail to map, and the resulting short load
# count looks exactly like a parity defect. It is not — it is a capacity class,
# and scripts/claude.md is explicit that the two must never be conflated. So the
# requirement is computed from the corpus and floored at the engine default,
# which is what test-corpus-parity-loop.sh does for the same reason.
VECTOR_DIMENSION="${VECTOR_DIMENSION:-$(python3 "$CI_DIR/scripts/lib/corpus-vector-dimension.py" "$MACHINES_DIR/machines")}"
export VECTOR_DIMENSION
info "Perceptual space required by the full corpus: $VECTOR_DIMENSION"

# ── The number on disk, which is the claim every runtime is measured against ──
DISK_COUNT="$(find "$MACHINES_DIR/machines" -name '*.json' -type f | wc -l | tr -d ' ')"
info "Corpus on disk: $DISK_COUNT machine files"
[ "$DISK_COUNT" -gt 0 ] || { bad "No machines found under $MACHINES_DIR/machines"; exit 1; }

# ── Start each runtime on the full corpus and ask what it loaded ─────────────
# Ports are off-band so this can run beside anything already up. Each runtime is
# started by its own start.sh, which is the same path the deployment lanes use —
# measuring a bespoke launch would answer a question nobody else asks.
declare -A RE_PORT=( [scala]=5101 [cpp]=5301 [lsp]=5601 )
declare -A COUNTS=()
FAILED=0

count_machines() {
    local url="$1"
    curl -sk --max-time 30 "$url/api/machines" 2>/dev/null \
        | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('machines',[])))" 2>/dev/null \
        || echo "ERROR"
}

for runtime in scala cpp lsp; do
    port="${RE_PORT[$runtime]}"
    # Each engine's own start.sh, the same entry point the deployment lanes
    # use. REALITY_ENGINE_PORT / MACHINES_DIR is the contract all three share.
    case "$runtime" in
        scala) engine_dir="$CI_DIR/../RealityEngine_Scala" ;;
        cpp)   engine_dir="$CI_DIR/../RealityEngine_CPP" ;;
        lsp)   engine_dir="$CI_DIR/../RealityEngine_LSP" ;;
    esac
    if [ ! -x "$engine_dir/start.sh" ]; then
        bad "$runtime: $engine_dir/start.sh missing or not executable"
        COUNTS[$runtime]="NO_START_SCRIPT"
        FAILED=1
        continue
    fi

    info "Starting $runtime on :$port with the full corpus..."
    (
        cd "$engine_dir" || exit 1
        REALITY_ENGINE_PORT="$port" \
        PERCEPTION_ENGINE_PORT="$((port - 1))" \
        MACHINES_DIR="$MACHINES_DIR/machines" \
        VECTOR_DIMENSION="$VECTOR_DIMENSION" \
            nohup ./start.sh > "$REPORT_DIR/$runtime-start.log" 2>&1 &
        echo $! > "$REPORT_DIR/$runtime.pid"
    )

    n=0
    until curl -sk --max-time 5 "https://127.0.0.1:$port/api/health" >/dev/null 2>&1 \
       || curl -s  --max-time 5 "http://127.0.0.1:$port/api/health"  >/dev/null 2>&1; do
        n=$((n+1)); [ "$n" -ge 120 ] && break; sleep 2
    done

    scheme=https
    curl -sk --max-time 5 "https://127.0.0.1:$port/api/health" >/dev/null 2>&1 || scheme=http
    COUNTS[$runtime]="$(count_machines "$scheme://127.0.0.1:$port")"
    info "  $runtime reports ${COUNTS[$runtime]} machines"
done

# ── Compare ──────────────────────────────────────────────────────────────────
{
    echo "# Full corpus load parity"
    echo
    echo "disk: $DISK_COUNT"
    for runtime in scala cpp lsp; do echo "$runtime: ${COUNTS[$runtime]:-UNMEASURED}"; done
} > "$REPORT_DIR/load-parity.md"

for runtime in scala cpp lsp; do
    got="${COUNTS[$runtime]:-UNMEASURED}"
    if [ "$got" = "$DISK_COUNT" ]; then
        ok "$runtime loaded all $DISK_COUNT machines"
    else
        bad "$runtime loaded $got, disk has $DISK_COUNT"
        FAILED=1
    fi
done

# Stop what we started — a scheduled sweep must not leave engines holding ports.
for runtime in scala cpp lsp; do
    pidfile="$REPORT_DIR/$runtime.pid"
    [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null || true
done

if [ "$FAILED" -ne 0 ]; then
    bad "Load-count parity FAILED — see $REPORT_DIR/load-parity.md"
    exit 1
fi
ok "All runtimes agree: $DISK_COUNT machines"
