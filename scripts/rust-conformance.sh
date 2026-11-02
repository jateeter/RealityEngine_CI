#!/usr/bin/env bash
# rust-conformance.sh: the follower lane (RealityEngine_CI#607, tier R2 of
# docs/RUST_VALIDATION_WORKFLOW.md).
#
# Builds RealityEngine_Rust, starts it as an RE+PE pair beside a running
# universe on the same corpus and width, and holds it against the three voters:
# the RE parity stages (machine-set, engine-process, export, engine-config
# --no-step, arbitration-retention) and the stages that push through each
# instance's PE (trajectory, pe-step-contract, reset-contract,
# escalation-dispatch, arbiter, metrics-parity), and mqtt-yuma, which tests each
# PE's bridge against a live broker.
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
#       [--corpus DIR] [--port 5801] [--pe-port 5800] [--out DIR] [--no-build]
#       [--mqtt-broker-url URL|none]
#
#   --corpus   the machine directory the universe booted. Default: read from
#              the .universe-engine-selection stamp startUniverse.sh writes.
#              A universe started any other way (a release install) has no
#              stamp, so name it.
#   --pe-port  rust-1's Perception Engine. It drives rust-1's RE and interns
#              that RE's machines at boot unless PE_SOURCE_BOOTSTRAP says not to.
#   --mqtt-broker-url  the broker mqtt-yuma tests every PE against. Default:
#              the live Yuma broker, as regression-test.sh uses; `none` skips
#              the stage. A broker that does not answer a TCP connect within
#              10s is a skip with its reason, never a failure.
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
PE_PORT=5800
OUT=""
BUILD=true
MQTT_BROKER_URL="${MQTT_BROKER_URL:-mqtt://yuma.lateraledge.cloud:1883}"

while [ $# -gt 0 ]; do
  case "$1" in
    --rust-repo) RUST_REPO="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --corpus) CORPUS="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --pe-port) PE_PORT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --no-build) BUILD=false; shift ;;
    --mqtt-broker-url) MQTT_BROKER_URL="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
say "start rust-1 on :$PORT (RE) and :$PE_PORT (PE), corpus $CORPUS, eventDimension $WIDTH"
if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/"; then
  unavailable "port $PORT is already serving; stop it or pass --port"
fi
if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PE_PORT/"; then
  unavailable "port $PE_PORT is already serving; stop it or pass --pe-port"
fi
UUID="$(python3 "$LIB/instance_uuids.py" allocate native rust-1 $$)"
CLOCK_DIR="$(python3 "$LIB/instance_uuids.py" clock-dir)"
INSTANCE_UUID="$UUID" INSTANCE_CLOCK_DIR="$CLOCK_DIR" MACHINES_DIR="$CORPUS" \
  VECTOR_DIMENSION="$WIDTH" REALITY_ENGINE_PORT="$PORT" \
  "$RUST_REPO/target/release/reality-engine" > "$OUT/rust-1.log" 2>&1 &
RUST_PID=$!
PE_PID=""
trap 'kill "$RUST_PID" ${PE_PID:+"$PE_PID"} 2>/dev/null || true; wait "$RUST_PID" ${PE_PID:+"$PE_PID"} 2>/dev/null || true' EXIT
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

# Its PE, driving its RE. It interns the RE's machines as it boots, so it is
# started once the RE is answering. It gets the environment startUniverse.sh
# gives the voters' PEs (scripts/lib/pe-env.sh): trigger dispatch, the
# integrations configuration, ACP/OpenClaw, the HealthKit token when the
# universe has one, localAI, and an MQTT client id of its own. escalation-dispatch,
# metrics-parity and mqtt-yuma read it.
# shellcheck source=scripts/lib/pe-env.sh
source "$LIB/pe-env.sh"
# shellcheck source=scripts/lib/healthkit-token.sh
source "$LIB/healthkit-token.sh"
HK_TOKEN="$(healthkit_token_read "$CI_DIR" 2>/dev/null || true)"
(
  pe_env_defaults "$CI_DIR/config/integrations.json"
  [ -n "$HK_TOKEN" ] && export HEALTHKIT_BRIDGE_TOKEN="$HK_TOKEN"
  export LOCAL_AI_API_URL="${LOCAL_AI_API_URL:-http://localhost:4000}"
  export LOCAL_AI_MACHINES_DIR="${LOCAL_AI_MACHINES_DIR:-$CI_DIR/../localAIStack/data/machines}"
  export MQTT_CLIENT_ID; MQTT_CLIENT_ID="$(mqtt_client_id rust-1 "$UUID")"
  export MQTT_BROKER_HOST=""
  PERCEPTION_ENGINE_PORT="$PE_PORT" RE_URL="$RUST_URL" MACHINES_DIR="$CORPUS" \
    VECTOR_DIMENSION="$WIDTH" \
    exec "$RUST_REPO/target/release/perception-engine"
) > "$OUT/rust-1-pe.log" 2>&1 &
PE_PID=$!
RUST_PE_URL="http://127.0.0.1:$PE_PORT"
started=false
for _ in $(seq 1 600); do
  kill -0 "$PE_PID" 2>/dev/null || break
  if curl -sf --max-time 2 -o /dev/null "$RUST_PE_URL/api/health"; then started=true; break; fi
  sleep 0.5
done
if ! $started; then
  echo "rust-conformance: rust-1's PE did not start; see $OUT/rust-1-pe.log" >&2
  tail -5 "$OUT/rust-1-pe.log" >&2 || true
  exit 1
fi
grep -m2 'perception-engine:' "$OUT/rust-1-pe.log" || true

# --- the localAI slice -------------------------------------------------------
# localAIStack declares its machines and sensors (`localai/*`) in every engine
# its instance registry names, once, from its API's startup hooks. rust-1 joins
# after that and is in no registry localAI reads, so without this step the
# voters hold a slice rust-1 does not, and every stage reports that stimulus as
# an engine difference. The lane runs the same hooks, in the same order, inside
# the localAI API container, against an instance registry naming rust-1 alone.
LOCALAI_CONTAINER="${LOCALAI_CONTAINER:-localai_api}"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$LOCALAI_CONTAINER"; then
  say "localAI slice: registering localAIStack's machines and sensors in rust-1"
  python3 - "$OUT/localai-follower-registry.json" "$PORT" "$PE_PORT" "$UUID" <<'PY'
import json, sys
dst, port, pe_port, uuid = sys.argv[1:]
host = "http://host.docker.internal"
json.dump({"instances": [{"id": "rust-1", "runtime": "rust", "role": "follower",
                          "re_url": f"{host}:{port}", "pe_url": f"{host}:{pe_port}",
                          "instance_uuid": uuid, "status": "running"}]},
          open(dst, "w"))
PY
  docker cp "$OUT/localai-follower-registry.json" "$LOCALAI_CONTAINER:/tmp/rust-follower-registry.json" >/dev/null
  # main.py's lifespan sequence (localAIStack services/api/main.py).
  if ! docker exec -w /app -e RE_REGISTRY_URL=file:///tmp/rust-follower-registry.json \
      "$LOCALAI_CONTAINER" python -c '
import json
from core import reality_bridge as r
steps = {"sensors": r.register_sensors(), "rag_machine": r.import_machine_if_missing(),
         "session_machines": r.import_session_machines(), "health_machine": r.import_health_machines(),
         "carekit_machine": r.import_carekit_machine(), "domain_machines": r.import_domain_machines(),
         "topology": r.bind_graph_topology()}
print(json.dumps(steps))
' > "$OUT/localai-slice.json" 2> "$OUT/localai-slice.log"; then
    echo "rust-conformance: the localAI registration failed; see $OUT/localai-slice.log" >&2
  fi
  # The machines arrived after rust-1's PE interned at boot. Intern them now,
  # as startUniverse.sh's --pe-source-bootstrap=auto does for the voters, so
  # each localai/* machine has its test source.
  curl -sf --max-time 120 -X POST "$RUST_PE_URL/api/sources/bootstrap-from-machines" \
    -H 'Content-Type: application/json' -d '{}' > "$OUT/localai-bootstrap.json" ||
    echo "rust-conformance: rust-1's PE bootstrap failed" >&2
  python3 - "$OUT/universe-registry.json" "$RUST_URL" "$RUST_PE_URL" "$OUT/localai-slice.json" <<'PY'
import json, sys, urllib.request
registry, re_url, pe_url, steps = sys.argv[1:]
def slice_of(re, pe):
    get = lambda u: json.load(urllib.request.urlopen(u, timeout=30))
    machines = get(re + "/api/machines")
    machines = machines.get("machines", machines) if isinstance(machines, dict) else machines
    sources = get(pe + "/api/sources")["sources"]
    return (sorted(m["name"] for m in machines if str(m.get("name", "")).startswith("localai/")),
            sorted((s.get("type"), s.get("name", "")) for s in sources
                   if str(s.get("name", "")).startswith("localai/")))
voter = next(i for i in json.load(open(registry))["instances"] if i.get("role") != "follower")
theirs, ours = slice_of(voter["re_url"], voter["pe_url"]), slice_of(re_url, pe_url)
# The hooks log to stdout; their results are the last line.
lines = open(steps).read().strip().splitlines()
print(f"  steps {lines[-1] if lines else '(none)'}")
print(f"  {voter['id']}: {len(theirs[0])} machines, {len(theirs[1])} sources; "
      f"rust-1: {len(ours[0])} machines, {len(ours[1])} sources"
      + ("" if theirs == ours else " — the slices differ; stages will report it"))
PY
else
  say "localAI slice: no $LOCALAI_CONTAINER container; rust-1 holds no localai/* slice"
fi

# The lane's own instance data: the universe's, plus rust-1 as a follower.
python3 - "$OUT/universe-registry.json" "$OUT/follower-registry.json" "$RUST_URL" "$RUST_PE_URL" "$UUID" <<'PY'
import json, sys
src, dst, url, pe_url, uuid = sys.argv[1:]
doc = json.load(open(src))
doc.setdefault("instances", []).append({
    "id": "rust-1", "runtime": "rust", "role": "follower",
    "re_url": url, "pe_url": pe_url,
    "instance_uuid": uuid, "status": "running"})
json.dump(doc, open(dst, "w"), indent=2)
PY
python3 "$LIB/followers.py" split "$OUT/follower-registry.json" \
  "$OUT/voters-registry.json" "$OUT/joint-registry.json" >/dev/null

# --- the stages --------------------------------------------------------------
# stage name | essential routes (METHOD path, `probe` for a parameter) | command
# The routes are the ones without which the stage measures nothing; a route the
# stage only reads on the side (engine-process's /api/runtime/vector-space) is
# not one, and the width is passed in instead. `pe:` marks a PE route.
declare -A ROUTES=(
  [machine-set]="GET /api/machines"
  [engine-process]="POST /api/engine/process|GET /api/engine/config/transitionsInhibited"
  [export]="GET /api/machines/probe/export"
  [engine-config]="GET /api/engine/config"
  [arbitration-retention]="GET /api/arbitration"
  [trajectory]="pe:POST /api/push|pe:GET /api/sources|GET /api/engine/isre-history|GET /api/engine/osre-history"
  [pe-step-contract]="pe:POST /api/push"
  [reset-contract]="pe:POST /api/reset|pe:GET /api/sources|pe:POST /api/sources/bootstrap-from-machines"
  [escalation-dispatch]="pe:POST /api/push|pe:GET /api/metrics|pe:GET /api/dispatch/ledger"
  [arbiter]="GET /api/arbitration|pe:GET /api/sources/contention|pe:POST /api/sensors/probe"
  [metrics-parity]="pe:GET /api/metrics"
  [mqtt-yuma]="pe:POST /api/mqtt/enable|pe:GET /api/mqtt/status|pe:POST /api/mqtt/disable"
)
# mqtt-yuma runs last: it leaves each PE holding the broker's sensors, which
# every instance then holds alike.
STAGES=(machine-set engine-process export engine-config arbitration-retention
        trajectory pe-step-contract reset-contract
        escalation-dispatch arbiter metrics-parity mqtt-yuma)

# escalation-dispatch requires a RED escalation on the corpora that carry the
# escalation trio, as regression-test.sh does.
EXPECT_ESCALATION=()
if [ -f "$CI_DIR/.universe-engine-selection" ]; then
  case "$(sed -n 's/^MACHINE_CORPUS=//p' "$CI_DIR/.universe-engine-selection" | tail -1)" in
    regression|full) EXPECT_ESCALATION=(--expect-escalation) ;;
  esac
fi

# The broker is tested if it is there and skipped, with the reason, if it does
# not answer a TCP connect within 10s (regression-test.sh's rule).
MQTT_SKIP=""
case "$MQTT_BROKER_URL" in
  ""|none|off|skip) MQTT_SKIP="no broker (--mqtt-broker-url none)" ;;
  *) if ! why="$(python3 - "$MQTT_BROKER_URL" <<'PY'
import socket, sys, urllib.parse
url = sys.argv[1]
u = urllib.parse.urlparse(url if "://" in url else f"mqtt://{url}")
try:
    socket.create_connection((u.hostname, u.port or 1883), timeout=10).close()
except Exception as exc:
    print(f"{u.hostname}:{u.port or 1883}: {exc.__class__.__name__}: {exc}")
    sys.exit(1)
PY
)"; then MQTT_SKIP="broker $MQTT_BROKER_URL not responding within 10s ($why)"; fi ;;
esac

# mqtt_yuma <registry> <report>: test-mqtt-yuma.sh on every PE the instance data
# names, then disable every bridge it enabled, so no bridge pushes into a later
# run (regression-test.sh mutes them the same way). Fails if any PE fails.
mqtt_yuma() {
  local registry="$1" report="$2" failed=0 id url
  while IFS='|' read -r id url; do
    if ! bash "$CI_DIR/scripts/test-mqtt-yuma.sh" --pe-url "$url" \
        --broker-url "$MQTT_BROKER_URL" --report-json "${report%.json}.$id.json"; then
      echo "FAIL mqtt-yuma: $id"; failed=1
    fi
  done < <(python3 -c 'import json,sys
for i in json.load(open(sys.argv[1]))["instances"]:
    if i.get("pe_url"): print(i["id"] + "|" + i["pe_url"])' "$registry")
  while IFS= read -r url; do
    curl -s --max-time 10 -X POST "$url/api/mqtt/disable" > /dev/null || true
  done < <(python3 -c 'import json,sys
for i in json.load(open(sys.argv[1]))["instances"]:
    if i.get("pe_url"): print(i["pe_url"])' "$registry")
  return "$failed"
}

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
    # The three below run as regression-test.sh runs them: the corpus's own
    # interned stimulus, and reset-contract leaving the trajectory to its stage.
    trajectory) python3 "$CI_DIR/scripts/regression-trajectory-parity.py" \
      --registry "$registry" --out "$report" ;;
    pe-step-contract) python3 "$CI_DIR/scripts/regression-pe-step-contract.py" \
      --registry "$registry" --machines "$CORPUS" --out "$report" ;;
    reset-contract) python3 "$CI_DIR/scripts/regression-reset-contract.py" \
      --registry "$registry" --skip-trajectory --out "$report" ;;
    # The four below were run by hand beside the lane until 2026-11-01; each is
    # invoked as regression-test.sh invokes it.
    escalation-dispatch) python3 "$CI_DIR/scripts/regression-escalation-dispatch.py" \
      --registry "$registry" --out "$report" "${EXPECT_ESCALATION[@]}" ;;
    arbiter) python3 "$CI_DIR/scripts/regression-arbiter.py" \
      --registry "$registry" --contributions "$CI_DIR/config/arbiter-contributions.json" \
      --machines "$CI_DIR/../RealityEngine_Machines" --lane local --out "$report" ;;
    metrics-parity) RE_REGISTRY_URL="file://$registry" \
      bash "$CI_DIR/scripts/verify-metrics-parity.sh" ;;
    mqtt-yuma) mqtt_yuma "$registry" "$report" ;;
  esac
}

declare -A VERDICT
for stage in "${STAGES[@]}"; do
  say "$stage"
  if [ "$stage" = mqtt-yuma ] && [ -n "$MQTT_SKIP" ]; then
    VERDICT[$stage]=not-compared
    echo "skipped: $MQTT_SKIP"
    continue
  fi
  unsupported=()
  IFS='|' read -r -a routes <<< "${ROUTES[$stage]}"
  for route in "${routes[@]}"; do
    base="$RUST_URL"
    case "$route" in pe:*) base="$RUST_PE_URL"; route="${route#pe:}" ;; esac
    read -r method path <<< "$route"
    if [ "$(python3 "$LIB/followers.py" probe "$base" "$method" "$path")" = unsupported ]; then
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
for stage in "${STAGES[@]}"; do printf '  %-21s %s\n' "$stage" "${VERDICT[$stage]}"; done
echo "reports: $OUT"

verdicts=" ${VERDICT[*]} "
if [[ "$verdicts" == *" differs "* ]]; then exit 1; fi
if [[ "$verdicts" != *" agrees "* ]]; then
  echo "rust-conformance: no stage compared rust-1; this is not a pass" >&2
  exit 3
fi
exit 0
