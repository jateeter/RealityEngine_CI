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

# ── Start at the FLOOR, deliberately ─────────────────────────────────────────
# VECTOR_DIMENSION=7680 is the deployment floor (INTEGRATED_SPECIFICATION.md
# Phase 2), not the size of the space. Every engine is required to expand its
# perceptual space during machine ingestion — C++ add_machine -> grow_to, Scala
# addMachine -> growTo, LSP grow-perceptual-space, and the TS PE grows on demand.
#
# So this sweep starts at the floor ON PURPOSE. Pre-sizing the space to the
# corpus requirement would hand every engine a space large enough that it never
# has to grow, which makes an engine that silently drops out-of-range regions
# indistinguishable from one that expands correctly — it would mask exactly the
# defect this check exists to find. The corpus requires 16944 against a floor of
# 7680, so a runtime reporting the full count here has provably grown.
VECTOR_DIMENSION="${VECTOR_DIMENSION:-7680}"
export VECTOR_DIMENSION
REQUIRED_DIMENSION="$(python3 "$CI_DIR/scripts/lib/corpus-vector-dimension.py" "$MACHINES_DIR/machines")"
info "Starting every runtime at the floor: $VECTOR_DIMENSION (corpus needs $REQUIRED_DIMENSION)"

# ── The number on disk, which is the claim every runtime is measured against ──
DISK_COUNT="$(find "$MACHINES_DIR/machines" -name '*.json' -type f | wc -l | tr -d ' ')"
info "Corpus on disk: $DISK_COUNT machine files"
[ "$DISK_COUNT" -gt 0 ] || { bad "No machines found under $MACHINES_DIR/machines"; exit 1; }

# ── Start each runtime on the full corpus and ask what it loaded ─────────────
# Each runtime is started by its own start.sh, which is the same path the
# deployment lanes use — measuring a bespoke launch would answer a question
# nobody else asks.
#
# The ports are the universe's own (scala 5101, cpp 5301, lsp 5601), not
# off-band as this used to claim, so a local run collides with a running
# universe. FULL_CORPUS_PORT_OFFSET shifts all three; a hosted runner needs none.
PORT_OFFSET="${FULL_CORPUS_PORT_OFFSET:-0}"
declare -A RE_PORT=( [scala]=$((5101 + PORT_OFFSET)) [cpp]=$((5301 + PORT_OFFSET)) [lsp]=$((5601 + PORT_OFFSET)) )

# Per-runtime start.sh arguments. The C++ start.sh refuses to run without the
# unified Qdrant (it is shared with localAIStack), and this job starts none: a
# load count needs no vector store. Without the flag start.sh printed "Start
# localAIStack first" and exited 1 at once, cpp was never launched, and the loop
# below polled a dead port for 240s and recorded ERROR (#383). Scala and LSP
# have no such gate.
declare -A START_ARGS=( [scala]="" [cpp]="--allow-missing-qdrant" [lsp]="" )

engine_dir_for() {
    case "$1" in
        scala) echo "$CI_DIR/../RealityEngine_Scala" ;;
        cpp)   echo "$CI_DIR/../RealityEngine_CPP" ;;
        lsp)   echo "$CI_DIR/../RealityEngine_LSP" ;;
    esac
}

declare -A COUNTS=()
declare -A DIMS=()
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
    engine_dir="$(engine_dir_for "$runtime")"
    if [ ! -x "$engine_dir/start.sh" ]; then
        bad "$runtime: $engine_dir/start.sh missing or not executable"
        COUNTS[$runtime]="NO_START_SCRIPT"
        FAILED=1
        continue
    fi

    info "Starting $runtime on :$port with the full corpus..."
    read -r -a start_args <<<"${START_ARGS[$runtime]}"
    # Launched as a direct child (the subshell execs start.sh) so its exit
    # status can be collected. It used to run inside a detached subshell, so a
    # start.sh that failed was indistinguishable from one still starting.
    (
        cd "$engine_dir" || exit 1
        export REALITY_ENGINE_PORT="$port" PERCEPTION_ENGINE_PORT="$((port - 1))" \
               MACHINES_DIR="$MACHINES_DIR/machines" VECTOR_DIMENSION="$VECTOR_DIMENSION"
        exec nohup ./start.sh "${start_args[@]}"
    ) > "$REPORT_DIR/$runtime-start.log" 2>&1 &
    start_pid=$!
    echo "$start_pid" > "$REPORT_DIR/$runtime.pid"

    # Wait for health, but stop waiting the moment start.sh has exited
    # non-zero. Some start.sh scripts return once their engines are up (cpp),
    # others stay in the foreground; a clean exit is not a failure, a non-zero
    # one is, and it is reported with its reason, not as a 240s timeout.
    n=0
    start_rc=""
    until curl -sk --max-time 5 "https://127.0.0.1:$port/api/health" >/dev/null 2>&1 \
       || curl -s  --max-time 5 "http://127.0.0.1:$port/api/health"  >/dev/null 2>&1; do
        if [ -z "$start_rc" ] && ! kill -0 "$start_pid" 2>/dev/null; then
            start_rc=0; wait "$start_pid" || start_rc=$?
            [ "$start_rc" -ne 0 ] && break
        fi
        n=$((n+1)); [ "$n" -ge 120 ] && break; sleep 2
    done

    if [ -n "$start_rc" ] && [ "$start_rc" -ne 0 ]; then
        bad "$runtime: start.sh exited $start_rc before the engine answered. Its log ends:"
        tail -15 "$REPORT_DIR/$runtime-start.log" | sed 's/\x1b\[[0-9;]*m//g; s/^/    /'
        COUNTS[$runtime]="START_FAILED(exit $start_rc)"
        DIMS[$runtime]="?"
        FAILED=1
        continue
    fi

    scheme=https
    curl -sk --max-time 5 "https://127.0.0.1:$port/api/health" >/dev/null 2>&1 || scheme=http
    COUNTS[$runtime]="$(count_machines "$scheme://127.0.0.1:$port")"
    # What the engine SAYS its space is, after ingesting a corpus that needs
    # more than the floor. A runtime that grew internally but still reports the
    # startup value is reporting a space it is not using — recorded, not failed,
    # because the load count is the contract and this is the observable surface.
    DIMS[$runtime]="$(curl -sk --max-time 10 "$scheme://127.0.0.1:$port/api/config" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('eventDimension') or d.get('vectorDimension') or '?')" 2>/dev/null || echo '?')"
    info "  $runtime reports ${COUNTS[$runtime]} machines, eventDimension=${DIMS[$runtime]}"
done

# ── Compare ──────────────────────────────────────────────────────────────────
{
    echo "# Full corpus load parity"
    echo
    echo "disk: $DISK_COUNT"
    echo "floor: $VECTOR_DIMENSION   corpus requires: $REQUIRED_DIMENSION"
    for runtime in scala cpp lsp; do
        echo "$runtime: ${COUNTS[$runtime]:-UNMEASURED} machines, reported dimension ${DIMS[$runtime]:-?}"
    done
} > "$REPORT_DIR/load-parity.md"

for runtime in scala cpp lsp; do
    got="${COUNTS[$runtime]:-UNMEASURED}"
    if [ "$got" = "$DISK_COUNT" ]; then
        ok "$runtime loaded all $DISK_COUNT machines"
    elif [[ "$got" == START_FAILED* ]]; then
        bad "$runtime never started ($got), so no load count exists; see $runtime-start.log"
        FAILED=1
    else
        bad "$runtime loaded $got, disk has $DISK_COUNT — it did not expand past the $VECTOR_DIMENSION floor"
        FAILED=1
    fi
done

# Stop what we started — a scheduled sweep must not leave engines holding ports.
# Killing the start.sh PID is not enough: cpp's start.sh exits once its engines
# are up, so that PID is gone and the engines it launched kept running. Each
# engine's stop.sh stops only the PIDs its own start.sh recorded.
for runtime in scala cpp lsp; do
    pidfile="$REPORT_DIR/$runtime.pid"
    [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null || true
    engine_dir="$(engine_dir_for "$runtime")"
    [ -x "$engine_dir/stop.sh" ] && (cd "$engine_dir" && ./stop.sh >> "$REPORT_DIR/$runtime-start.log" 2>&1) || true
done

if [ "$FAILED" -ne 0 ]; then
    bad "Load-count parity FAILED — see $REPORT_DIR/load-parity.md"
    exit 1
fi
ok "All runtimes agree: $DISK_COUNT machines"
