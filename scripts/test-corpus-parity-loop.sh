#!/bin/bash
# =============================================================================
# test-corpus-parity-loop.sh
#
# Incremental corpus parity across the C++, LSP and Scala RE/PE pairs.
#
# Brings up a scala:1,cpp:1,lsp:1 universe holding a single machine, validates
# sequential-operation parity across the three pairs, then loads the next corpus
# machine through the RE/PE APIs and re-validates — one machine per iteration
# until the whole corpus has been verified.
#
# The universe is started once. Machines are added over the live APIs, so the
# corpus grows through every state between one machine and 1328 without a
# restart, and the first machine whose presence splits the runtimes is named.
#
# Usage:
#   ./scripts/test-corpus-parity-loop.sh [options]
#
# Options:
#   --seed-machine PATH     Corpus-relative machine the universe boots with
#                           (default: domains/digital-logic/DLX011_req-ack-handshake.json)
#   --mode MODE             cumulative (default) — corpus grows one machine per
#                           iteration; isolated — each machine is removed before
#                           the next is loaded, validating machines one at a time
#   --limit N               Stop after N iterations (default: whole corpus)
#   --start-index N         Skip the first N corpus entries (sorted order)
#   --steps N               Pushes per iteration (default: 0 = walk the longest
#                           interned sequence right through)
#   --settle-ms N           Delay after each push (default: 250)
#   --stop-on-fail          Halt at the first machine that breaks parity
#   --resume                Reuse the running universe and append to existing
#                           results, skipping iterations already recorded
#   --skip-start            Do not start a universe; use the one already running
#   --keep-universe         Leave the universe up on exit (default: tear down)
#   --vector-dimension N    Perceptual space width. Defaults to the corpus
#                           requirement (max offset+length over every machine),
#                           floored at the engine default of 7680
#   --engines SPEC          Engine spec (default: cpp:1,lsp:1,scala:1)
#   --report-dir DIR        Output directory (default: /tmp/re-corpus-parity)
#   --fresh                 Pass --fresh to startUniverse
#   --help                  Show this message
#
# Exit status is 0 only when every iteration passed both load parity and
# trajectory parity.
#
# Requires: bash 3.2+, curl, python3
# =============================================================================
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACHINES_DIR="${MACHINES_DIR:-$CI_DIR/../RealityEngine_Machines}"
REGISTRY_PORT="${RE_REGISTRY_PORT:-5999}"

SEED_MACHINE="domains/digital-logic/DLX011_req-ack-handshake.json"
MODE="cumulative"
LIMIT=0
START_INDEX=0
STEPS=0
SETTLE_MS=250
STOP_ON_FAIL=false
RESUME=false
SKIP_START=false
KEEP_UNIVERSE=false
ENGINES_SPEC="cpp:1,lsp:1,scala:1"
REPORT_DIR="/tmp/re-corpus-parity"
FRESH_FLAG=""
VECTOR_DIMENSION="${VECTOR_DIMENSION:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed-machine=*)  SEED_MACHINE="${1#*=}"; shift ;;
    --seed-machine)    SEED_MACHINE="$2"; shift 2 ;;
    --mode=*)          MODE="${1#*=}"; shift ;;
    --mode)            MODE="$2"; shift 2 ;;
    --limit=*)         LIMIT="${1#*=}"; shift ;;
    --limit)           LIMIT="$2"; shift 2 ;;
    --start-index=*)   START_INDEX="${1#*=}"; shift ;;
    --start-index)     START_INDEX="$2"; shift 2 ;;
    --steps=*)         STEPS="${1#*=}"; shift ;;
    --steps)           STEPS="$2"; shift 2 ;;
    --settle-ms=*)     SETTLE_MS="${1#*=}"; shift ;;
    --settle-ms)       SETTLE_MS="$2"; shift 2 ;;
    --stop-on-fail)    STOP_ON_FAIL=true; shift ;;
    --resume)          RESUME=true; SKIP_START=true; shift ;;
    --skip-start)      SKIP_START=true; shift ;;
    --keep-universe)   KEEP_UNIVERSE=true; shift ;;
    --engines=*)       ENGINES_SPEC="${1#*=}"; shift ;;
    --engines)         ENGINES_SPEC="$2"; shift 2 ;;
    --report-dir=*)    REPORT_DIR="${1#*=}"; shift ;;
    --report-dir)      REPORT_DIR="$2"; shift 2 ;;
    --vector-dimension=*) VECTOR_DIMENSION="${1#*=}"; shift ;;
    --vector-dimension)   VECTOR_DIMENSION="$2"; shift 2 ;;
    --fresh)           FRESH_FLAG="--fresh"; shift ;;
    --help|-h)         awk 'NR>2 && /^# ={5,}/{exit} NR>2 && /^#/{sub(/^# ?/,""); print}' "$SCRIPT"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$MODE" in
  cumulative|isolated) ;;
  *) echo "Bad --mode=$MODE (cumulative|isolated)" >&2; exit 2 ;;
esac

# ── Colour helpers ────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BLUE=$'\033[0;34m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
else
  BLUE=""; GREEN=""; RED=""; YELLOW=""; NC=""
fi
info() { echo "${BLUE}==>${NC} $*"; }
ok()   { echo "${GREEN} ok${NC} $*"; }
warn() { echo "${YELLOW}  !${NC} $*"; }
fail() { echo "${RED}FAIL${NC} $*" >&2; }

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$REPORT_DIR"

[ -d "$MACHINES_DIR/machines" ] || {
  fail "machine corpus not found at $MACHINES_DIR/machines"
  exit 1
}
[ -f "$MACHINES_DIR/machines/$SEED_MACHINE" ] || {
  fail "seed machine not found: $MACHINES_DIR/machines/$SEED_MACHINE"
  exit 1
}

CORPUS_SIZE="$(find "$MACHINES_DIR/machines" -name '*.json' | wc -l | tr -d ' ')"

# The perceptual space must be wide enough for every machine the loop will add,
# not just the one the universe boots with. All three engines default to 7680
# and 250 corpus machines map above it (max 16944) — booting at the default
# would put those machines' regions outside the space and report the resulting
# mess as an engine parity break. Size the space from the corpus up front.
CORPUS_REQUIRED_DIM="$(python3 - "$MACHINES_DIR/machines" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
required = 0
for path in root.rglob('*.json'):
    try:
        machine = json.loads(path.read_text(encoding='utf-8')).get('machine') or {}
    except (OSError, ValueError, AttributeError):
        continue
    mapping = machine.get('perceptualMapping') or {}
    for key in ('input', 'output'):
        region = mapping.get(key)
        if isinstance(region, dict):
            try:
                required = max(required, int(region['offset']) + int(region['length']))
            except (KeyError, TypeError, ValueError):
                pass
print(required)
PY
)"
if [ -z "$VECTOR_DIMENSION" ]; then
  VECTOR_DIMENSION=7680
  [ "$CORPUS_REQUIRED_DIM" -gt "$VECTOR_DIMENSION" ] && VECTOR_DIMENSION="$CORPUS_REQUIRED_DIM"
fi
export VECTOR_DIMENSION

# Loading a machine interns its inputSequences as a test source; the sweep drives
# the engines with those sequences, so they must come up active. Setting it here
# rather than activating over the API is not a preference: cpp answers
# PATCH /api/sources/:id {"active":true} with 200 and the new value echoed back,
# then reports the old one on the next GET, because its GET re-syncs test sources
# from the RE machine list at this same setting. On cpp the sequences are
# unactivatable through the API, and only this makes them active on all three.
export PE_SOURCE_ACTIVATE_ON_LOAD="${PE_SOURCE_ACTIVATE_ON_LOAD:-true}"

echo "============================================================"
echo " Incremental corpus parity — cpp / lsp / scala RE-PE pairs"
echo "============================================================"
echo "  Run id          $RUN_ID"
echo "  Engines         $ENGINES_SPEC"
echo "  Seed machine    $SEED_MACHINE"
echo "  Corpus          $MACHINES_DIR/machines ($CORPUS_SIZE machines)"
echo "  Mode            $MODE"
echo "  Vector dim      $VECTOR_DIMENSION (corpus requires $CORPUS_REQUIRED_DIM)"
echo "  Reports         $REPORT_DIR"
echo ""

if [ "$VECTOR_DIMENSION" -lt "$CORPUS_REQUIRED_DIM" ]; then
  warn "vector dimension $VECTOR_DIMENSION is below the corpus requirement $CORPUS_REQUIRED_DIM"
  warn "machines mapping above it cannot be evaluated and will be reported as capacity failures"
fi

# ── 1. Start the universe holding exactly one machine ─────────────────────────
# The single-machine corpus is materialised through the same
# --machine-corpus=standard-deployment path deployment validation uses, so the
# engines boot with one machine rather than being emptied afterwards. An engine
# that booted with 1328 machines and had 1327 deleted is not in the same state
# as one that booted with 1.
MANIFEST="$REPORT_DIR/seed-corpus-$RUN_ID.txt"
CORPUS_WORK_DIR="/tmp/realityengine-corpus-parity-seed-$RUN_ID"

teardown() {
  if [ "$KEEP_UNIVERSE" = false ] && [ "$SKIP_START" = false ]; then
    info "Stopping universe"
    bash "$CI_DIR/stopUniverse.sh" --all >/dev/null 2>&1 || true
  fi
  rm -rf "$CORPUS_WORK_DIR"
}
trap teardown EXIT

if [ "$SKIP_START" = false ]; then
  {
    echo "# Single-machine seed corpus for incremental parity run $RUN_ID"
    echo "$SEED_MACHINE"
  } > "$MANIFEST"

  info "Stopping any running universe"
  bash "$CI_DIR/stopUniverse.sh" --all >/dev/null 2>&1 || true

  info "Starting universe with a 1-machine corpus"
  # --pe-source-bootstrap=off: the loop bootstraps PE sources itself after each
  # load, so a startup bootstrap would only describe the seed machine.
  # MACHINE_CORPUS_WORK_DIR is an environment input rather than a flag; the
  # per-run directory keeps concurrent runs from materialising over each other.
  # --no-openclaw: parity needs the three RE/PE pairs and nothing else, and the
  # OpenClaw stage gates on an agent-index count that tracks the machine corpus
  # — with a deliberately one-machine corpus it fails on a mismatch that has no
  # bearing on whether the engines agree.
  #
  # --no-local-ai: same reasoning, and it is not hypothetical. The localAI
  # reality bridge registers ten `localai/*` machines into the RE at runtime,
  # which are not corpus machines and are not part of what this loop is
  # comparing. The first reproduction attempt for #167 brought localAIStack up,
  # those machines appeared, and the run reproduced RealityEngine_Scala#54 at
  # cells 7448/7456 instead of the divergence it was chasing — six hours spent
  # on the wrong finding. The loop passed --no-openclaw and not this one, which
  # #167 records as a harness bug in its own right.
  MACHINE_CORPUS_WORK_DIR="$CORPUS_WORK_DIR" \
  bash "$CI_DIR/startUniverse.sh" \
    --engines="$ENGINES_SPEC" \
    --machine-load=runtime \
    --machine-corpus=standard-deployment \
    --machine-corpus-manifest="$MANIFEST" \
    --pe-source-bootstrap=off \
    --no-openclaw \
    --no-local-ai \
    --warn-only \
    $FRESH_FLAG || START_STATUS=$?

  # A non-zero exit is not by itself disqualifying: startUniverse brings up
  # Manager, Prometheus, Grafana and OpenClaw alongside the engines, and a
  # late-stage failure in any of those leaves three healthy RE/PE pairs behind.
  # The precondition this run actually has is checked directly below; failing
  # here on the exit code alone would abandon a usable stack.
  if [ "${START_STATUS:-0}" -ne 0 ]; then
    warn "startUniverse.sh exited ${START_STATUS} — verifying the engines directly"
  fi
else
  info "Using the universe already running (--skip-start)"
fi

# ── 2. Wait for the registry and confirm three RE/PE pairs ────────────────────
REGISTRY_URL="http://127.0.0.1:${REGISTRY_PORT}/re-registry.json"
info "Waiting for registry at $REGISTRY_URL"
for _ in $(seq 1 60); do
  curl -sf --max-time 3 "$REGISTRY_URL" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf --max-time 3 "$REGISTRY_URL" >/dev/null 2>&1 || {
  fail "registry never came up at $REGISTRY_URL"
  exit 1
}

INSTANCE_COUNT="$(curl -sf --max-time 5 "$REGISTRY_URL" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("instances", [])))')"
if [ "$INSTANCE_COUNT" -lt 2 ]; then
  fail "registry lists $INSTANCE_COUNT runtime(s); parity needs at least two"
  exit 1
fi
[ "$INSTANCE_COUNT" -ge 3 ] || warn "registry lists $INSTANCE_COUNT runtimes, expected 3"
ok "registry lists $INSTANCE_COUNT RE/PE pair(s)"

# Registry presence is a claim; health is the precondition. Both halves of every
# pair must answer, and the space each RE actually came up with must cover the
# corpus — an engine that silently fell back to its 7680 default would report
# every machine above it as a capacity failure.
UNHEALTHY=0
while IFS=$'\t' read -r iid re_url pe_url; do
  for probe in "$re_url" "$pe_url"; do
    curl -sf --max-time 5 "$probe/api/health" >/dev/null 2>&1 || {
      fail "$iid: $probe/api/health did not answer"
      UNHEALTHY=$((UNHEALTHY + 1))
    }
  done
  # /api/config, not /api/engine/stats: only LSP reports a width in stats.
  re_dim="$(curl -sf --max-time 5 "$re_url/api/config" \
    | python3 -c 'import json,sys
try:
    print(int(json.load(sys.stdin).get("vectorDimension", 0)))
except Exception:
    print(0)' 2>/dev/null || echo 0)"
  if [ "${re_dim:-0}" -lt "$CORPUS_REQUIRED_DIM" ]; then
    warn "$iid RE space is $re_dim, corpus requires $CORPUS_REQUIRED_DIM"
  else
    ok "$iid healthy — space $re_dim"
  fi
done < <(curl -sf --max-time 5 "$REGISTRY_URL" | python3 -c '
import json, sys
for i in json.load(sys.stdin).get("instances", []):
    print("\t".join([i["id"], i["re_url"].rstrip("/"), i["pe_url"].rstrip("/")]))')

if [ "$UNHEALTHY" -gt 0 ]; then
  fail "$UNHEALTHY endpoint(s) unhealthy — not starting the parity run"
  exit 1
fi
echo ""

# ── 3. Baseline: parity on the single seed machine ────────────────────────────
# Run before the loop and reported separately. A stack that cannot agree on one
# machine has no business being asked about 1328, and a baseline failure here is
# a different finding from a machine that breaks parity when added.
info "Baseline parity on the seed machine"
BASELINE_DIR="$REPORT_DIR/baseline-$RUN_ID"
BASELINE_STATUS=0
python3 "$CI_DIR/scripts/regression-corpus-parity-loop.py" \
  --registry "$REGISTRY_URL" \
  --machines-root "$MACHINES_DIR/machines" \
  --out "$BASELINE_DIR" \
  --run-id "$RUN_ID-baseline" \
  --mode isolated \
  --steps "$STEPS" \
  --settle-ms "$SETTLE_MS" \
  --limit 1 \
  --start-index "$(python3 - "$MACHINES_DIR/machines" "$SEED_MACHINE" <<'PY'
import pathlib, sys
root, target = pathlib.Path(sys.argv[1]), sys.argv[2]
entries = sorted(str(p.relative_to(root)) for p in root.rglob('*.json'))
print(entries.index(target) if target in entries else 0)
PY
)" || BASELINE_STATUS=$?

if [ "$BASELINE_STATUS" -ne 0 ]; then
  fail "baseline parity on the seed machine failed — not starting the corpus loop"
  echo "  see $BASELINE_DIR/corpus-parity-loop.jsonl" >&2
  exit 1
fi
ok "baseline parity holds on $SEED_MACHINE"
echo ""

# ── 4. Incremental loop over the rest of the corpus ───────────────────────────
info "Incremental corpus loop ($MODE)"
LOOP_DIR="$REPORT_DIR/loop-$RUN_ID"
[ "$RESUME" = true ] && LOOP_DIR="$(ls -td "$REPORT_DIR"/loop-* 2>/dev/null | head -1)"
[ -n "$LOOP_DIR" ] || LOOP_DIR="$REPORT_DIR/loop-$RUN_ID"

LOOP_ARGS=(
  --registry "$REGISTRY_URL"
  --machines-root "$MACHINES_DIR/machines"
  --out "$LOOP_DIR"
  --run-id "$RUN_ID"
  --mode "$MODE"
  --steps "$STEPS"
  --settle-ms "$SETTLE_MS"
  --start-index "$START_INDEX"
  --limit "$LIMIT"
  --skip "$SEED_MACHINE"
)
[ "$STOP_ON_FAIL" = true ] && LOOP_ARGS+=(--stop-on-fail)
[ "$RESUME" = true ]       && LOOP_ARGS+=(--resume)

LOOP_STATUS=0
python3 "$CI_DIR/scripts/regression-corpus-parity-loop.py" "${LOOP_ARGS[@]}" || LOOP_STATUS=$?

echo ""
echo "============================================================"
if [ "$LOOP_STATUS" -eq 0 ]; then
  ok "corpus parity verified across all $INSTANCE_COUNT RE/PE pairs"
else
  fail "corpus parity broke — see $LOOP_DIR/corpus-parity-summary.json"
fi
echo "  Baseline  $BASELINE_DIR/corpus-parity-summary.json"
echo "  Loop      $LOOP_DIR/corpus-parity-summary.json"
echo "  Per-machine records  $LOOP_DIR/corpus-parity-loop.jsonl"
echo "============================================================"

exit "$LOOP_STATUS"
