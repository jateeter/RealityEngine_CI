#!/usr/bin/env bash
# rust-conformance.sh: the follower lane (RealityEngine_CI#607, tier R2 of
# docs/RUST_VALIDATION_WORKFLOW.md).
#
# Builds RealityEngine_Rust, starts it beside a running universe on the same
# corpus and width, and holds it against the three voters on the RE-only parity
# stages: machine-set, engine-process, export, engine-config (--no-step) and
# arbitration-retention.
# Rust is a conformance follower (docs/QUORUM_CONTRACT.md section 1): it never
# votes, and it is never written into the universe's instance registry. The lane
# writes its own copies under --out.
#
# Each stage runs twice, through the stage's own comparison
# (scripts/lib/followers.py):
#   1. the voters alone. This is the verdict; if they disagree there is nothing
#      to follow, and Rust is `not-compared` for that stage.
#   2. the voters plus Rust as one more instance. Passing is `agrees`; failing
#      is `differs`, and the stage's report names the difference.
# A stage whose essential route Rust answers with SURFACE_SPEC.md's ruled 501
# `unsupported` is reported as `unsupported` and not run jointly.
#
# Every stage resets every voter it reads, as it does in the regression run.
# Do not point this at a universe whose state you want to keep.
#
# Not part of the certifying run, and never a vote. Exit status:
#   0  at least one stage agrees and none differs
#   1  a stage differs, the build is stale (provenance), or Rust would not start
#   3  unavailable: no universe, no corpus, or nothing was compared
#
# Usage:
#   scripts/rust-conformance.sh [--rust-repo DIR] [--registry URL|FILE]
#       [--corpus DIR] [--port 5801] [--out DIR] [--no-build]
#
#   --corpus   the machine directory the universe booted. Default: read from
#              the .universe-engine-selection stamp startUniverse.sh writes.
#              A universe started any other way (a release install) has no
#              stamp, so name it.
set -euo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "rust-conformance.sh needs bash 4+ (Homebrew's /opt/homebrew/bin/bash on a Mac)" >&2
  exit 2
fi

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_REPO="$CI_DIR/../RealityEngine_Rust"
REGISTRY=""
CORPUS=""
PORT=5801
OUT=""
BUILD=true

while [ $# -gt 0 ]; do
  case "$1" in
    --rust-repo) RUST_REPO="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --corpus) CORPUS="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --no-build) BUILD=false; shift ;;
    -h|--help) sed -n '2,37p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "rust-conformance.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

OUT="${OUT:-$CI_DIR/test-results/rust-conformance/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
LIB="$CI_DIR/scripts/lib"
say() { printf '\n== %s\n' "$*"; }
unavailable() { echo "rust-conformance: unavailable: $*" >&2; exit 3; }

# --- the universe ------------------------------------------------------------
if [ -z "$REGISTRY" ]; then
  # shellcheck source=lib/registry-url.sh
  source "$LIB/registry-url.sh"
  REGISTRY="$(registry_url)"
fi
case "$REGISTRY" in
  http://*|https://*)
    curl -sf --max-time 10 "$REGISTRY" > "$OUT/universe-registry.json" ||
      unavailable "no instance registry at $REGISTRY; start a universe first" ;;
  *) [ -f "$REGISTRY" ] || unavailable "no instance registry file $REGISTRY"
     cp "$REGISTRY" "$OUT/universe-registry.json" ;;
esac
VOTER_URLS="$(python3 - "$OUT/universe-registry.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for i in doc.get("instances", []):
    if i.get("role") != "follower" and i.get("re_url"):
        print(i["re_url"].rstrip("/"))
PY
)"
[ -n "$VOTER_URLS" ] || unavailable "the instance registry lists no voting engine"

if [ -z "$CORPUS" ]; then
  stamp="$CI_DIR/.universe-engine-selection"
  [ -f "$stamp" ] || unavailable "no .universe-engine-selection stamp; name the universe's corpus with --corpus"
  field() { sed -n "s/^$1=//p" "$stamp" | tail -1; }
  if [ "$(field POST_START_FULL_CORPUS)" = true ]; then root="$(field FULL_MACHINES_DIR)"
  else root="$(field MACHINE_CORPUS_ACTIVE_DIR)"; fi
  [ -n "$root" ] || unavailable "the stamp names no corpus; pass --corpus"
  CORPUS="$root/machines"
fi
[ -d "$CORPUS" ] || unavailable "corpus directory $CORPUS does not exist"

# The width the voters run at. Rust seeds at it, as startUniverse.sh seeds them.
WIDTH=""
for url in $VOTER_URLS; do
  WIDTH="$(curl -sf --max-time 10 "$url/api/config" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("eventDimension",""))' 2>/dev/null)" || WIDTH=""
  [ -n "$WIDTH" ] && break
done
[ -n "$WIDTH" ] || unavailable "no voter reported eventDimension on GET /api/config"

# --- the build ---------------------------------------------------------------
[ -d "$RUST_REPO" ] || unavailable "no RealityEngine_Rust checkout at $RUST_REPO; pass --rust-repo"
RUST_REPO="$(cd "$RUST_REPO" && pwd)"
say "build: $RUST_REPO"
if $BUILD; then
  (cd "$RUST_REPO" && cargo build --release --quiet) || { echo "rust-conformance: build failed" >&2; exit 1; }
fi
if [ "${RE_SKIP_PROVENANCE:-}" = 1 ]; then
  echo "RE_SKIP_PROVENANCE=1: build provenance not checked; this result does not certify"
else
  python3 "$CI_DIR/scripts/verify-build-provenance.py" --repos rust || exit 1
fi

# --- start Rust as rust-1 ----------------------------------------------------
say "start rust-1 on :$PORT, corpus $CORPUS, eventDimension $WIDTH"
if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/"; then
  unavailable "port $PORT is already serving; stop it or pass --port"
fi
UUID="$(python3 "$LIB/instance_uuids.py" allocate native rust-1 $$)"
CLOCK_DIR="$(python3 "$LIB/instance_uuids.py" clock-dir)"
INSTANCE_UUID="$UUID" INSTANCE_CLOCK_DIR="$CLOCK_DIR" MACHINES_DIR="$CORPUS" \
  VECTOR_DIMENSION="$WIDTH" REALITY_ENGINE_PORT="$PORT" \
  "$RUST_REPO/target/release/reality-engine" > "$OUT/rust-1.log" 2>&1 &
RUST_PID=$!
trap 'kill "$RUST_PID" 2>/dev/null || true; wait "$RUST_PID" 2>/dev/null || true' EXIT
RUST_URL="http://127.0.0.1:$PORT"
started=false
for _ in $(seq 1 600); do
  kill -0 "$RUST_PID" 2>/dev/null || break
  if curl -sf --max-time 2 -o /dev/null "$RUST_URL/api/health"; then started=true; break; fi
  sleep 0.5
done
if ! $started; then
  echo "rust-conformance: rust-1 did not start; see $OUT/rust-1.log" >&2
  tail -5 "$OUT/rust-1.log" >&2 || true
  exit 1
fi
grep -m2 'reality-engine:' "$OUT/rust-1.log" || true

# The lane's own instance data: the universe's, plus rust-1 as a follower.
python3 - "$OUT/universe-registry.json" "$OUT/follower-registry.json" "$RUST_URL" "$UUID" <<'PY'
import json, sys
src, dst, url, uuid = sys.argv[1:]
doc = json.load(open(src))
doc.setdefault("instances", []).append({
    "id": "rust-1", "runtime": "rust", "role": "follower",
    "re_url": url, "pe_url": "", "pe_participation": "unsupported",
    "instance_uuid": uuid, "status": "running"})
json.dump(doc, open(dst, "w"), indent=2)
PY
python3 "$LIB/followers.py" split "$OUT/follower-registry.json" \
  "$OUT/voters-registry.json" "$OUT/joint-registry.json" >/dev/null

# --- the stages --------------------------------------------------------------
# stage name | essential routes (METHOD path, `probe` for a parameter) | command
# The routes are the ones without which the stage measures nothing; a route the
# stage only reads on the side (engine-process's /api/runtime/vector-space) is
# not one, and the width is passed in instead.
declare -A ROUTES=(
  [machine-set]="GET /api/machines"
  [engine-process]="POST /api/engine/process|GET /api/engine/config/transitionsInhibited"
  [export]="GET /api/machines/probe/export"
  [engine-config]="GET /api/engine/config"
  [arbitration-retention]="GET /api/arbitration"
)
STAGES=(machine-set engine-process export engine-config arbitration-retention)

run_stage() {  # run_stage <stage> <registry> <report>
  local stage="$1" registry="$2" report="$3"
  case "$stage" in
    machine-set) python3 "$CI_DIR/scripts/regression-machine-set-parity.py" \
      --registry "$registry" --out "$report" ;;
    engine-process) python3 "$CI_DIR/scripts/regression-engine-process-parity.py" \
      --registry "$registry" --machines "$CORPUS" --universal-dimension "$WIDTH" --out "$report" ;;
    export) python3 "$CI_DIR/scripts/regression-export-parity.py" \
      --registry "$registry" --machines 24 --out "$report" ;;
    engine-config) python3 "$CI_DIR/scripts/regression-engine-config-parity.py" \
      --registry "$registry" --json "$report" --no-step ;;
    arbitration-retention) python3 "$CI_DIR/scripts/regression-arbitration-retention.py" \
      --registry "$registry" --out "$report" ;;
  esac
}

declare -A VERDICT
for stage in "${STAGES[@]}"; do
  say "$stage"
  unsupported=()
  IFS='|' read -r -a routes <<< "${ROUTES[$stage]}"
  for route in "${routes[@]}"; do
    read -r method path <<< "$route"
    if [ "$(python3 "$LIB/followers.py" probe "$RUST_URL" "$method" "$path")" = unsupported ]; then
      unsupported+=("$method $path")
    fi
  done
  voters_exit=0
  run_stage "$stage" "$OUT/voters-registry.json" "$OUT/$stage.voters.json" \
    > "$OUT/$stage.voters.log" 2>&1 || voters_exit=$?
  joint_exit=0
  if [ "$voters_exit" -eq 0 ] && [ ${#unsupported[@]} -eq 0 ]; then
    run_stage "$stage" "$OUT/joint-registry.json" "$OUT/$stage.joint.json" \
      > "$OUT/$stage.joint.log" 2>&1 || joint_exit=$?
  fi
  VERDICT[$stage]="$(python3 "$LIB/followers.py" verdict "$voters_exit" "$joint_exit" "${unsupported[@]}")"
  echo "voters: exit $voters_exit; rust-1: ${VERDICT[$stage]}${unsupported:+ (${unsupported[*]})}"
  case "${VERDICT[$stage]}" in
    differs) grep -E 'FAIL|✗' "$OUT/$stage.joint.log" | head -5 || true ;;
    not-compared) grep -E 'FAIL|✗|QUORUM' "$OUT/$stage.voters.log" | head -3 || true ;;
  esac
done

# --- the result --------------------------------------------------------------
python3 - "$OUT/summary.json" "$UUID" "$CORPUS" "$WIDTH" \
  "$(for s in "${STAGES[@]}"; do printf '%s=%s ' "$s" "${VERDICT[$s]}"; done)" <<'PY'
import json, sys
out, uuid, corpus, width, pairs = sys.argv[1:]
stages = dict(p.split("=", 1) for p in pairs.split())
json.dump({"follower": "rust-1", "instanceUuid": uuid, "corpus": corpus,
           "eventDimension": int(width), "stages": stages}, open(out, "w"), indent=2)
PY
say "rust-1 against the voters"
for stage in "${STAGES[@]}"; do printf '  %-15s %s\n' "$stage" "${VERDICT[$stage]}"; done
echo "reports: $OUT"

verdicts=" ${VERDICT[*]} "
if [[ "$verdicts" == *" differs "* ]]; then exit 1; fi
if [[ "$verdicts" != *" agrees "* ]]; then
  echo "rust-conformance: no stage compared rust-1; this is not a pass" >&2
  exit 3
fi
exit 0
