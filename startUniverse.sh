#!/bin/bash
# =============================================================================
# startUniverse.sh — CI orchestrator for the full RealityEngine environment
#
# Source repos (all must be siblings of this RealityEngine_CI directory):
#   RealityEngine_Scala    — RE API (Akka HTTP / SBT)
#   RealityEngine_Manager  — Visualizer (Node) + Perception Engine (Node)
#   RealityEngine_Machines — Machine corpus (skills) + system-wide / e2e tests
#   RealityEngine_CPP      — Native C++ runtime
#   RealityEngine_LSP      — Common Lisp runtime
#   localAIStack           — Qdrant, Redis, FastAPI RAG, Open WebUI
#   localOpenClawStack     — OpenClaw ACP xACP gateway + Open WebUI
#
# Start sequence (AI / Docker path):
#   1    Pre-flight         docker compose v2, certs, port conflicts, orphan cleanup
#   2    Ollama             native LLM runtime
#   3    Infrastructure     CI Loki + localAIStack Qdrant + Redis
#   4    RealityEngine      Scala/Akka stack built from RealityEngine_Scala
#   5    localAIStack API   FastAPI lifespan hooks register sensors + machines
#   5.5  OpenClaw           optional ACP xACP gateway (auto-detected)
#   6    Integration        verify machines, sensors, Qdrant collections
#   7    Operability        smoke-tests: perceive, RAG health, sensor write
#   8    Summary
#
# Non-AI engines short-circuit to their native start.sh:
#   --re-engine=cpp|lsp   → RealityEngine_CPP/start.sh or RealityEngine_LSP/start.sh
#
# Usage:
#   ./startUniverse.sh [--fresh]
#                      [--engines=scala:N,cpp:N,lsp:N]   # multi-engine native mode
#                      [--re-engine=ai|cpp|lsp]           # single-engine (legacy)
#                      [--pe-engine=ai|cpp|lsp]
#                      [--mqtt-broker-url=URL]
#                      [--mqtt-mappings=PATH]
#                      [--openclaw] [--no-openclaw]
#                      [--help]
# =============================================================================
set -e
set -o pipefail

# ── Repository directories ──────────────────────────────────────────────────
# CI_DIR       — this repo: config/, certs/, docker-compose.yml, nginx/
# SCALA_DIR    — RealityEngine_Scala: build.sbt, src/ (RE API source)
# MGR_DIR      — RealityEngine_Manager: visualizer/, perception-engine/ (Node.js)
# MACHINES_DIR — RealityEngine_Machines: machine corpus (skills) + all system tests
# CPP_DIR      — RealityEngine_CPP: native C++ runtime binaries
# LSP_DIR      — RealityEngine_LSP: Common Lisp runtime
# LAS_DIR      — localAIStack: Qdrant, Redis, FastAPI, Open WebUI
# OCS_DIR      — localOpenClawStack: OpenClaw gateway

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCALA_DIR="$CI_DIR/../RealityEngine_Scala"
MGR_DIR="$CI_DIR/../RealityEngine_Manager"
MACHINES_DIR="$CI_DIR/../RealityEngine_Machines"
CPP_DIR="$CI_DIR/../RealityEngine_CPP"
LSP_DIR="$CI_DIR/../RealityEngine_LSP"
LAS_DIR="$CI_DIR/../localAIStack"
OCS_DIR="$CI_DIR/../localOpenClawStack"

# ── Flags ──────────────────────────────────────────────────────────────────
FRESH_START=false
SKIP_SEED=false
MANAGER_NATIVE=false
DRY_RUN=false
RE_ENGINE="${RE_ENGINE:-ai}"       # ai | cpp | lsp
PE_ENGINE="${PE_ENGINE:-ai}"       # ai | cpp | lsp
ENGINES=""                         # multi-engine: "scala:2,cpp:1" etc.
MQTT_BROKER_URL_OVERRIDE=""
MQTT_MAPPINGS_OVERRIDE=""
OPENCLAW="${OPENCLAW:-auto}"       # auto | yes | no
OCS_NATIVE_UNLOADED=false

print_usage() {
  cat <<'USAGE'
startUniverse.sh — engine-selectable CI orchestrator

  --fresh                       Wipe perception sources volume; rebuild images no-cache
  --skip-seed                   Skip seeding machines from RealityEngine_Machines
  --manager-native              Start Visualizer+PE via RealityEngine_Manager/start.sh
                                instead of Docker (uses Scala port presets: RE :5001, PE :5000)
  --engines=SPEC                Multi-engine native mode.  SPEC is a comma-separated list of
                                <runtime>:<count> pairs, e.g. --engines=scala:2,cpp:1
                                Spawns N native instances of each runtime on distinct ports.
                                Infrastructure (Loki/Qdrant/Redis) still starts via Docker.
                                Registry served at http://<HOST_IP>:5999/re-registry.json
  --re-engine=ai|cpp|lsp        Single-engine runtime (default: ai).  Ignored when --engines= set.
  --pe-engine=ai|cpp|lsp        Single PE runtime (default: ai).  Ignored when --engines= set.
  --mqtt-broker-url=URL         MQTT broker URL for PE bridge
  --mqtt-mappings=PATH          Path to MQTT mappings JSON file
  --openclaw                    Force-start OpenClaw even if auto-detect would skip it
  --no-openclaw                 Skip OpenClaw startup
  --dry-run                     Run all pre-flight checks and print the startup plan,
                                but skip all docker compose up / nohup / registry start.
                                Exits 0 on a coherent plan; non-zero if pre-flight fails.
  --help                        Show this message

Repos expected as siblings of RealityEngine_CI:
  RealityEngine_Scala    RealityEngine_Manager  RealityEngine_Machines
  RealityEngine_CPP      RealityEngine_LSP
  localAIStack           localOpenClawStack
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --fresh)               FRESH_START=true ;;
    --skip-seed)           SKIP_SEED=true ;;
    --manager-native)      MANAGER_NATIVE=true ;;
    --engines=*)           ENGINES="${arg#*=}" ;;
    --re-engine=*)         RE_ENGINE="${arg#*=}" ;;
    --pe-engine=*)         PE_ENGINE="${arg#*=}" ;;
    --mqtt-broker-url=*)   MQTT_BROKER_URL_OVERRIDE="${arg#*=}" ;;
    --mqtt-mappings=*)     MQTT_MAPPINGS_OVERRIDE="${arg#*=}" ;;
    --openclaw)            OPENCLAW=yes ;;
    --no-openclaw)         OPENCLAW=no ;;
    --dry-run)             DRY_RUN=true ;;
    --help|-h)             print_usage; exit 0 ;;
    *)                     echo "Unknown argument: $arg"; print_usage; exit 2 ;;
  esac
done

case "$RE_ENGINE" in ai|cpp|lsp) ;; *) echo "Bad --re-engine=$RE_ENGINE"; exit 2 ;; esac
case "$PE_ENGINE" in ai|cpp|lsp) ;; *) echo "Bad --pe-engine=$PE_ENGINE"; exit 2 ;; esac

# When --engines= is specified it supersedes --re-engine / --pe-engine
MULTI_ENGINE_MODE=false
[ -n "$ENGINES" ] && MULTI_ENGINE_MODE=true

# In dry-run mode skip the stamp write — nothing will actually start
if [ "$DRY_RUN" = false ]; then
# Stamp engine selection so stopUniverse.sh can tear down the right stack.
cat > "$CI_DIR/.universe-engine-selection" <<EOF
RE_ENGINE=$RE_ENGINE
PE_ENGINE=$PE_ENGINE
ENGINES=$ENGINES
MULTI_ENGINE_MODE=$MULTI_ENGINE_MODE
OPENCLAW=$OPENCLAW
OCS_NATIVE_UNLOADED=$OCS_NATIVE_UNLOADED
STARTED_AT=$(date -u +%FT%TZ)
EOF
fi  # end: if [ "$DRY_RUN" = false ] stamp

# Source multi-engine helpers
# shellcheck source=scripts/registry.sh
source "$CI_DIR/scripts/registry.sh"
# shellcheck source=scripts/allocate-ports.sh
source "$CI_DIR/scripts/allocate-ports.sh"

# ── Colours + helpers ─────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}ℹ${NC} $*"; }
warn() { echo -e "${RED}⚠${NC} $*"; }
hdr()  { echo -e "\n${CYAN}${BOLD}─── $* ───${NC}"; }
die()  { echo -e "\n${RED}✗  FATAL:${NC} $*\n"; exit 1; }

WARNS=()
add_warn() { WARNS+=("$*"); }

poll_http() {
    local url="$1" label="$2" max="${3:-30}" flags="${4:--sf}"
    local n=0
    while [ "$n" -lt "$max" ]; do
        if curl $flags "$url" > /dev/null 2>&1; then
            ok "$label"
            return 0
        fi
        n=$((n+1)); echo -n "."; sleep 2
    done
    echo ""; return 1
}

# ── Host IP detection ─────────────────────────────────────────────────────
HOST_IP="$(bash "$CI_DIR/scripts/detect-host-ip.sh" 2>/dev/null || echo "127.0.0.1")"
export HOST_IP
[ "$HOST_IP" = "127.0.0.1" ] && \
    warn "Could not detect LAN IP — using 127.0.0.1 (multi-engine URLs will be local-only)"

# ── Multi-engine spawn helpers ────────────────────────────────────────────

_poll_native_health() {
    local url="$1" label="$2" max="${3:-45}"
    local n=0
    while [ "$n" -lt "$max" ]; do
        if curl -sf --max-time 2 "$url" > /dev/null 2>&1; then
            ok "$label"
            return 0
        fi
        n=$((n+1)); echo -n "."; sleep 2
    done
    echo ""; warn "$label — did not respond after $((max*2))s"
    return 1
}

spawn_scala_instance() {
    local id="$1" idx="$2"
    local ports; ports=$(allocate_ports scala "$idx") || { warn "Cannot allocate ports for $id"; return 1; }
    local re_port pe_port
    read -r re_port pe_port <<< "$ports"

    info "Spawning $id  (RE=$HOST_IP:$re_port  PE=$HOST_IP:$pe_port)"

    if [ ! -x "$SCALA_DIR/start.sh" ]; then
        warn "$id: $SCALA_DIR/start.sh not found or not executable — skipping"
        return 1
    fi
    if [ ! -x "$MGR_DIR/perception-engine/start.sh" ]; then
        warn "$id: $MGR_DIR/perception-engine/start.sh not found — skipping PE"
    fi

    # Spawn RE (Scala)
    INSTANCE_ID="$id" HOST="$HOST_IP" PORT="$re_port" \
        nohup bash "$SCALA_DIR/start.sh" \
        > "/tmp/re-${id}.log" 2>&1 &
    local pid_re=$!

    # Spawn PE alongside
    local pid_pe=""
    if [ -x "$MGR_DIR/perception-engine/start.sh" ]; then
        INSTANCE_ID="$id" HOST="$HOST_IP" PORT="$pe_port" \
            nohup bash "$MGR_DIR/perception-engine/start.sh" \
            > "/tmp/pe-${id}.log" 2>&1 &
        pid_pe=$!
    fi

    echo -n "  $id RE "
    _poll_native_health "http://$HOST_IP:$re_port/api/health" "$id RE ready"
    if [ -n "$pid_pe" ]; then
        echo -n "  $id PE "
        _poll_native_health "http://$HOST_IP:$pe_port/api/health" "$id PE ready"
    fi

    registry_add "$id" "scala" \
        "http://$HOST_IP:$re_port" \
        "http://$HOST_IP:$pe_port" \
        "$pid_re" "${pid_pe:-}"
}

spawn_cpp_instance() {
    local id="$1" idx="$2"
    local ports; ports=$(allocate_ports cpp "$idx") || { warn "Cannot allocate ports for $id"; return 1; }
    local re_port pe_port
    read -r re_port pe_port <<< "$ports"

    info "Spawning $id  (RE=$HOST_IP:$re_port  PE=$HOST_IP:$pe_port)"
    [ -x "$CPP_DIR/start.sh" ] || { warn "$id: $CPP_DIR/start.sh not found — skipping"; return 1; }

    INSTANCE_ID="$id" \
    REALITY_ENGINE_HOST="$HOST_IP" \
    REALITY_ENGINE_PORT="$re_port" \
    PERCEPTION_ENGINE_PORT="$pe_port" \
        nohup bash "$CPP_DIR/start.sh" \
        > "/tmp/re-${id}.log" 2>&1 &
    local pid_re=$!

    echo -n "  $id RE "
    _poll_native_health "http://$HOST_IP:$re_port/api/health" "$id RE ready"
    echo -n "  $id PE "
    _poll_native_health "http://$HOST_IP:$pe_port/api/health" "$id PE ready"

    # CPP start.sh backgrounds the binaries and exits; read the actual engine PIDs from disk
    local pid_re_actual pid_pe_actual
    pid_re_actual=$(cat "$CPP_DIR/run/reality_engine-${id}.pid" 2>/dev/null || echo "")
    pid_pe_actual=$(cat "$CPP_DIR/run/perception_engine-${id}.pid" 2>/dev/null || echo "")

    registry_add "$id" "cpp" \
        "http://$HOST_IP:$re_port" \
        "http://$HOST_IP:$pe_port" \
        "${pid_re_actual:-}" "${pid_pe_actual:-}"
}

spawn_lsp_instance() {
    local id="$1" idx="$2"
    local ports; ports=$(allocate_ports lsp "$idx") || { warn "Cannot allocate ports for $id"; return 1; }
    local re_port pe_port
    read -r re_port pe_port <<< "$ports"

    info "Spawning $id  (RE=$HOST_IP:$re_port  PE=$HOST_IP:$pe_port)"
    [ -x "$LSP_DIR/start.sh" ] || { warn "$id: $LSP_DIR/start.sh not found — skipping"; return 1; }

    INSTANCE_ID="$id" \
    REALITY_ENGINE_HOST="$HOST_IP" \
    REALITY_ENGINE_PORT="$re_port" \
    PERCEPTION_ENGINE_PORT="$pe_port" \
        nohup bash "$LSP_DIR/start.sh" \
        > "/tmp/re-${id}.log" 2>&1 &
    local pid_re=$!

    echo -n "  $id RE "
    _poll_native_health "http://$HOST_IP:$re_port/api/health" "$id RE ready"
    echo -n "  $id PE "
    _poll_native_health "http://$HOST_IP:$pe_port/api/health" "$id PE ready"

    # LSP start.sh backgrounds sbcl and exits; read the actual engine PIDs from disk
    local pid_re_actual pid_pe_actual
    pid_re_actual=$(cat "$LSP_DIR/run/reality-engine-${id}.pid" 2>/dev/null || echo "")
    pid_pe_actual=$(cat "$LSP_DIR/run/perception-engine-${id}.pid" 2>/dev/null || echo "")

    registry_add "$id" "lsp" \
        "http://$HOST_IP:$re_port" \
        "http://$HOST_IP:$pe_port" \
        "${pid_re_actual:-}" "${pid_pe_actual:-}"
}

# ── Engine-selection short-circuit ────────────────────────────────────────
# cpp/lsp engines run from their own repos without Docker or localAIStack.

run_native_engine() {
  local engine_dir="$1" engine_name="$2"
  [ -d "$engine_dir" ] || die "$engine_name repo not found at $engine_dir"
  [ -x "$engine_dir/start.sh" ] || die "$engine_dir/start.sh missing or not executable"

  if [ -n "$MQTT_BROKER_URL_OVERRIDE" ]; then
    export MQTT_BROKER_URL="$MQTT_BROKER_URL_OVERRIDE"
    local stripped="${MQTT_BROKER_URL_OVERRIDE#mqtt://}"; stripped="${stripped#mqtts://}"
    export MQTT_BROKER_HOST="${stripped%%:*}"
    local rest="${stripped#*:}"; export MQTT_BROKER_PORT="${rest%%/*}"
    [ "$MQTT_BROKER_PORT" = "$stripped" ] && MQTT_BROKER_PORT=1883
  fi
  [ -n "$MQTT_MAPPINGS_OVERRIDE" ] && export MQTT_MAPPINGS_FILE="$MQTT_MAPPINGS_OVERRIDE"

  echo "════════════════════════════════════════════════════════════════════"
  echo "  Delegating to $engine_name engine: $engine_dir/start.sh"
  echo "  RE_ENGINE=$RE_ENGINE  PE_ENGINE=$PE_ENGINE"
  [ -n "${MQTT_BROKER_URL:-}${MQTT_BROKER_HOST:-}" ] && \
    echo "  MQTT broker: ${MQTT_BROKER_URL:-${MQTT_BROKER_HOST}:${MQTT_BROKER_PORT:-1883}}"
  echo "════════════════════════════════════════════════════════════════════"
  exec "$engine_dir/start.sh"
}

if [ "$MULTI_ENGINE_MODE" = false ]; then
  if [ "$RE_ENGINE" = "cpp" ] || [ "$PE_ENGINE" = "cpp" ]; then
    run_native_engine "$CPP_DIR" "CPP"
  fi
  if [ "$RE_ENGINE" = "lsp" ] || [ "$PE_ENGINE" = "lsp" ]; then
    run_native_engine "$LSP_DIR" "LSP"
  fi
fi

# ── AI path: Docker stack from CI repo docker-compose.yml ─────────────────
# Build contexts reference sibling repos (see docker-compose.yml):
#   reality-engine        ← RealityEngine_Scala source
#   perception-engine-*   ← RealityEngine_Manager/perception-engine/
#   visualizer-*          ← RealityEngine_Manager/visualizer/
# The CI docker-compose.yml passes SCALA_DIR and MGR_DIR as build-args
# so each service Dockerfile can COPY from the right source tree.
# TODO (Roadmap Phase 1): Update docker-compose.yml build contexts + machine
#       volume to reference RealityEngine_Scala, RealityEngine_Manager, and
#       RealityEngine_Machines (see ROADMAP.md Phase 1).

if [ -n "$MQTT_BROKER_URL_OVERRIDE" ]; then
  export MQTT_BROKER_URL="$MQTT_BROKER_URL_OVERRIDE"
fi
if [ -n "$MQTT_MAPPINGS_OVERRIDE" ]; then
  [ -f "$MQTT_MAPPINGS_OVERRIDE" ] || die "MQTT mappings file not found: $MQTT_MAPPINGS_OVERRIDE"
  export MQTT_MAPPINGS_FILE="$MQTT_MAPPINGS_OVERRIDE"
  export MQTT_MAPPINGS_JSON="$(cat "$MQTT_MAPPINGS_OVERRIDE")"
  info "MQTT mappings loaded inline (${#MQTT_MAPPINGS_JSON} bytes from ${MQTT_MAPPINGS_OVERRIDE##*/})"
fi

# Pass sibling repo paths to docker-compose so build contexts and volume mounts resolve correctly.
export SCALA_DIR MGR_DIR MACHINES_DIR

# =============================================================================
hdr "1 · Pre-flight"
# =============================================================================

docker compose version > /dev/null 2>&1 || \
    die "docker compose (v2) not found — install Docker Desktop >= 3.x"
COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "unknown")
ok "docker compose v$COMPOSE_VER"

# Version compatibility check (warns only — does not block startup)
if [ -x "$CI_DIR/scripts/validate-versions.sh" ]; then
    bash "$CI_DIR/scripts/validate-versions.sh" --warn-only || true
fi

# Verify required sibling repos are present
for dir_var in SCALA_DIR MGR_DIR MACHINES_DIR LAS_DIR; do
    eval dir="\$$dir_var"
    [ -d "$dir" ] || die "$dir_var not found at $dir\n  Expected sibling repos: RealityEngine_Scala, RealityEngine_Manager, RealityEngine_Machines, localAIStack"
done
ok "Sibling repos found: RealityEngine_Scala, RealityEngine_Manager, RealityEngine_Machines, localAIStack"

docker info > /dev/null 2>&1 || die "Docker daemon not running — start Docker Desktop first"
ok "Docker daemon reachable"

[ -f "$CI_DIR/.env" ] || die ".env not found — copy .env.example and configure"
# shellcheck source=/dev/null
source "$CI_DIR/.env"

# TLS certificates
MISSING_CERTS=""
for f in certs/server.crt certs/server.key certs/ca.crt certs/keystore.p12; do
    [ ! -f "$CI_DIR/$f" ] && MISSING_CERTS="$MISSING_CERTS $f"
done
[ -n "$MISSING_CERTS" ] && \
    die "Missing TLS cert(s):$MISSING_CERTS\n  Run:  bash $CI_DIR/certs/generate-dev-certs.sh"
openssl x509 -in "$CI_DIR/certs/server.crt" -noout -text 2>/dev/null \
    | grep -q "DNS:reality-engine" || \
    die "certs/server.crt missing SANs\n  Run:  bash $CI_DIR/certs/generate-dev-certs.sh"
ok "TLS certificates valid"

# Loki Docker logging driver
LOKI_ENABLED=$(docker plugin inspect loki --format '{{.Enabled}}' 2>/dev/null || echo "missing")
if [ "$LOKI_ENABLED" = "missing" ]; then
    info "Installing Loki Docker logging driver..."
    docker plugin install grafana/loki-docker-driver:latest \
        --alias loki --grant-all-permissions 2>/dev/null || \
        die "Loki Docker driver install failed — run:  bash $CI_DIR/scripts/setup-loki-driver.sh"
elif [ "$LOKI_ENABLED" = "false" ]; then
    info "Enabling Loki Docker logging driver..."
    docker plugin enable loki 2>/dev/null || die "Could not enable loki plugin"
fi
ok "Loki Docker logging driver ready"

# Block local node processes that would conflict with Docker port bindings
CONFLICTS=""
for port in 3000 3001 3004 3005 5173; do
    proc=$(lsof -i ":$port" 2>/dev/null | awk '/LISTEN/{print $1}' | head -1 || true)
    [ "$proc" = "node" ] && CONFLICTS="$CONFLICTS ${port}(node)"
done
[ -n "$CONFLICTS" ] && \
    die "Local node processes on RE ports:$CONFLICTS\n  Stop them first (see RealityEngine_Manager/stop.sh)"
ok "No port conflicts"

# Pre-check all native engine ports before spawning begins — fail fast before partial starts
if [ "$MULTI_ENGINE_MODE" = true ]; then
    info "Pre-checking native engine ports (${ENGINES})..."
    IFS=',' read -ra _pf_specs <<< "$ENGINES"
    for _pf_spec in "${_pf_specs[@]}"; do
        _pf_rt=$(echo "$_pf_spec" | cut -d: -f1 | tr -d ' ')
        _pf_ct=$(echo "$_pf_spec" | cut -d: -f2 | tr -d ' ')
        _pf_ct="${_pf_ct:-1}"
        case "$_pf_rt" in
            scala) _pf_base_re=5001; _pf_base_pe=5000 ;;
            cpp)   _pf_base_re=5301; _pf_base_pe=5300 ;;
            lsp)   _pf_base_re=5601; _pf_base_pe=5600 ;;
            *) continue ;;
        esac
        for (( _pf_i=1; _pf_i<=_pf_ct; _pf_i++ )); do
            _pf_re=$(( _pf_base_re + (_pf_i - 1) * 100 ))
            _pf_pe=$(( _pf_base_pe + (_pf_i - 1) * 100 ))
            for _pf_port in "$_pf_re" "$_pf_pe"; do
                if lsof -i ":${_pf_port}" -sTCP:LISTEN >/dev/null 2>&1; then
                    die "Native engine port ${_pf_port} (${_pf_rt} instance ${_pf_i}) already in use\n  Stop the blocking process and retry"
                fi
            done
        done
    done
    ok "Native engine ports free"
fi

# ── Orphan container cleanup ──────────────────────────────────────────────
info "Checking for orphaned containers..."
(cd "$CI_DIR" && docker compose down 2>/dev/null) || true

ORPHANS=$(docker ps -a --format "{{.ID}} {{.Image}}" 2>/dev/null \
    | awk '/realityengine_ci-|realityengine-/{print $1}' || true)
[ -n "$ORPHANS" ] && docker rm -f $ORPHANS > /dev/null 2>&1 || true

docker rm -f \
    reality-engine-app \
    reality-engine-visualizer-backend \
    reality-engine-visualizer-frontend \
    reality-engine-perception-backend \
    reality-engine-perception-frontend \
    reality-engine-tls-proxy \
    reality-engine-loki \
    reality-engine-grafana \
    reality-engine-prometheus > /dev/null 2>&1 || true

REMAINING=$(docker ps -a --format "{{.Names}}" 2>/dev/null \
    | grep -c "reality-engine-" || true)
[ "$REMAINING" -gt 0 ] && add_warn "$REMAINING RE container(s) still present before startup" \
    || ok "RE container state clean"

(cd "$LAS_DIR" && docker compose down 2>/dev/null) || true
docker rm -f localai_qdrant localai_redis localai_loki localai_grafana localai_api localai_webui \
    > /dev/null 2>&1 || true
LAS_REMAINING=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -c "^localai_" || true)
[ "$LAS_REMAINING" -gt 0 ] && add_warn "$LAS_REMAINING localai_* container(s) still present" \
    || ok "localAIStack container state clean"

# OpenClaw cleanup
if [ -d "$OCS_DIR" ] && [ -f "$OCS_DIR/docker-compose.yml" ]; then
    (cd "$OCS_DIR" && docker compose down 2>/dev/null) || true
    docker rm -f openclaw-gateway open-webui browser > /dev/null 2>&1 || true
fi

# Stop native openclaw-gateway if managed by launchd (frees the port for Docker)
_ocs_gw_port=18789
[ -f "$OCS_DIR/.env" ] && {
    _p=$(grep -E '^OPENCLAW_GATEWAY_PORT=' "$OCS_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$_p" ] && _ocs_gw_port="$_p"
}
_OCS_LAUNCHD_PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
if launchctl list 2>/dev/null | grep -q "ai.openclaw.gateway"; then
    info "Unloading native openclaw-gateway (launchd) to free port $_ocs_gw_port..."
    launchctl unload "$_OCS_LAUNCHD_PLIST" 2>/dev/null || true
    OCS_NATIVE_UNLOADED=true
    ok "Native openclaw-gateway unloaded (restored by stopUniverse.sh)"
    sed -i '' "s/^OCS_NATIVE_UNLOADED=.*/OCS_NATIVE_UNLOADED=true/" \
        "$CI_DIR/.universe-engine-selection" 2>/dev/null || true
else
    _ocs_port_pid=$(lsof -ti TCP:"$_ocs_gw_port" -sTCP:LISTEN 2>/dev/null | head -1 || true)
    [ -n "$_ocs_port_pid" ] && { kill "$_ocs_port_pid" 2>/dev/null || true; sleep 1; }
fi

sleep 2

[ "$FRESH_START" = true ] && warn "Fresh start — perception volume wiped; all images rebuilt no-cache"

# ── Dry-run: print plan and exit without starting anything ────────────────────
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "  Dry-Run Plan  (pre-flight passed — nothing will be started)"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    printf "  %-28s %s\n" "Mode"       "${MULTI_ENGINE_MODE:+multi-engine ($ENGINES)}${MULTI_ENGINE_MODE:-false}"
    printf "  %-28s %s\n" "RE engine"  "$RE_ENGINE"
    printf "  %-28s %s\n" "PE engine"  "$PE_ENGINE"
    printf "  %-28s %s\n" "Fresh"      "$FRESH_START"
    printf "  %-28s %s\n" "Skip seed"  "$SKIP_SEED"
    printf "  %-28s %s\n" "OpenClaw"   "$OPENCLAW"
    printf "  %-28s %s\n" "Host IP"    "$HOST_IP"
    if [ "$MULTI_ENGINE_MODE" = true ]; then
        echo ""
        echo "  Instances that would spawn:"
        IFS=',' read -ra _dr_specs <<< "$ENGINES"
        _dr_idx_s=0; _dr_idx_c=0; _dr_idx_l=0
        for _dr_spec in "${_dr_specs[@]}"; do
            _dr_rt=$(echo "$_dr_spec" | cut -d: -f1 | tr -d ' ')
            _dr_ct=$(echo "$_dr_spec" | cut -d: -f2 | tr -d ' ')
            _dr_ct="${_dr_ct:-1}"
            case "$_dr_rt" in
                scala) _dr_base_re=5001; _dr_base_pe=5000 ;;
                cpp)   _dr_base_re=5301; _dr_base_pe=5300 ;;
                lsp)   _dr_base_re=5601; _dr_base_pe=5600 ;;
                *) continue ;;
            esac
            for (( _dr_i=1; _dr_i<=_dr_ct; _dr_i++ )); do
                case "$_dr_rt" in
                    scala) _dr_idx_s=$((_dr_idx_s+1)); _dr_idx=$_dr_idx_s ;;
                    cpp)   _dr_idx_c=$((_dr_idx_c+1)); _dr_idx=$_dr_idx_c ;;
                    lsp)   _dr_idx_l=$((_dr_idx_l+1)); _dr_idx=$_dr_idx_l ;;
                esac
                _dr_re=$(( _dr_base_re + (_dr_idx-1)*100 ))
                _dr_pe=$(( _dr_base_pe + (_dr_idx-1)*100 ))
                printf "    %-16s RE=%-6s PE=%-6s start.sh=%s\n" \
                    "${_dr_rt}-${_dr_idx}" "$HOST_IP:$_dr_re" "$HOST_IP:$_dr_pe" \
                    "$(eval echo "\${${_dr_rt^^}_DIR:-?}")/start.sh"
            done
        done
        printf "  %-28s %s\n" "Registry" "http://$HOST_IP:${REGISTRY_PORT}/re-registry.json"
    else
        echo ""
        echo "  Docker services that would start:"
        echo "    CI Loki · Qdrant · Redis · RE API (Scala) · Visualizer · PE · localAIStack API"
    fi
    echo ""
    echo "  Seed machines: $([ "$SKIP_SEED" = true ] && echo "skipped" || echo "yes")"
    echo ""
    echo "  Pre-flight: PASSED — run without --dry-run to start"
    echo ""
    exit 0
fi

# =============================================================================
hdr "2 · Ollama"
# =============================================================================

if curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
    ok "Ollama already running"
else
    info "Starting Ollama..."
    ollama serve > /tmp/ollama_universe.log 2>&1 &
    echo $! > /tmp/ollama_universe.pid
    poll_http "http://localhost:11434/api/tags" "Ollama ready" 30 "-sf" || \
        die "Ollama failed to start — log: /tmp/ollama_universe.log"
fi

set +e
TAGS_JSON=$(curl -sf http://localhost:11434/api/tags 2>/dev/null || echo '{"models":[]}')
EMBED_MODEL_REQUIRED="${EMBED_MODEL:-}"
[ -z "$EMBED_MODEL_REQUIRED" ] && [ -f "$LAS_DIR/.env" ] && \
    EMBED_MODEL_REQUIRED=$(grep -E '^EMBED_MODEL=' "$LAS_DIR/.env" | tail -1 | cut -d= -f2-)
EMBED_MODEL_REQUIRED="${EMBED_MODEL_REQUIRED:-ternary-bonsai:4}"
set -e

for model in "llama3" "$EMBED_MODEL_REQUIRED"; do
    MATCH=$(echo "$TAGS_JSON" | python3 -c \
        "import json,sys
ms=[m['name'] for m in json.load(sys.stdin).get('models',[]) if '$model' in m['name']]
print(ms[0] if ms else '')" 2>/dev/null || echo "")
    if [ -n "$MATCH" ]; then ok "Model: $MATCH"
    else add_warn "Ollama model '$model' not found — pull with:  ollama pull $model"
         warn "Model not found: $model"
    fi
done

# =============================================================================
hdr "3 · Infrastructure  (CI Loki + Qdrant + Redis)"
# =============================================================================

if [ "$FRESH_START" = true ]; then
    PERCEPTION_VOL=$(docker volume ls --format "{{.Name}}" \
        | grep "_perception_sources_data$" | head -1 || true)
    if [ -n "$PERCEPTION_VOL" ]; then
        info "Removing perception sources volume: $PERCEPTION_VOL"
        docker volume rm "$PERCEPTION_VOL" > /dev/null 2>&1 || true
        ok "Perception volume cleared"
    fi
fi

info "Starting Loki (CI) + Qdrant + Redis..."
(cd "$CI_DIR" && docker compose up -d loki \
    2>/tmp/infra_start_err.log) > /dev/null || \
    die "docker compose up failed for Loki\n$(tail -5 /tmp/infra_start_err.log 2>/dev/null)"
(cd "$LAS_DIR" && docker compose up -d qdrant redis \
    2>>/tmp/infra_start_err.log) > /dev/null || \
    die "docker compose up failed for Qdrant/Redis\n$(tail -5 /tmp/infra_start_err.log 2>/dev/null)"

info "Waiting for Loki..."
poll_http "https://localhost:3100/ready" "Loki ready" 30 "-skf" || \
    die "Loki failed — check:  docker logs reality-engine-loki"

info "Waiting for Qdrant..."
poll_http "http://localhost:4333/collections" "Qdrant ready" 30 "-sf" || \
    die "Qdrant failed — check:  docker logs localai_qdrant"

info "Waiting for Redis..."
n=0
while [ "$n" -lt 20 ]; do
    docker exec localai_redis redis-cli ping 2>/dev/null | grep -q "PONG" && { ok "Redis ready"; break; }
    n=$((n+1)); echo -n "."; sleep 2
done
echo ""
[ "$n" -ge 20 ] && die "Redis failed — check:  docker logs localai_redis"

# =============================================================================
# 3.5 · Instance Registry  (multi-engine mode only)
# =============================================================================
if [ "$MULTI_ENGINE_MODE" = true ]; then
    hdr "3.5 · Instance Registry + Multi-Engine Spawn"
    info "Host LAN IP: $HOST_IP"

    # Initialise the registry file and start the REST shim on :5999
    rm -f "$REGISTRY_FILE"
    registry_start_server
    # Poll until the REST shim accepts connections (python3 server takes 1-2 s to bind)
    _reg_n=0
    while [ "$_reg_n" -lt 10 ]; do
        curl -sf "http://127.0.0.1:${REGISTRY_PORT}/re-registry.json" > /dev/null 2>&1 && break
        _reg_n=$((_reg_n+1)); sleep 1
    done
    [ "$_reg_n" -ge 10 ] && die "Registry REST shim on :${REGISTRY_PORT} did not become ready"
    ok "Registry REST shim ready  http://$HOST_IP:${REGISTRY_PORT}/re-registry.json"

    # Parse --engines=scala:2,cpp:1 and spawn each set of instances
    INSTANCE_IDX_SCALA=0; INSTANCE_IDX_CPP=0; INSTANCE_IDX_LSP=0
    IFS=',' read -ra _ENGINE_SPECS <<< "$ENGINES"
    for _spec in "${_ENGINE_SPECS[@]}"; do
        _runtime=$(echo "$_spec" | cut -d: -f1 | tr -d ' ')
        _count=$(echo  "$_spec" | cut -d: -f2 | tr -d ' ')
        _count="${_count:-1}"
        if ! [[ "$_count" =~ ^[1-9][0-9]*$ ]]; then
            warn "Invalid count '${_count}' for runtime '${_runtime}' — must be a positive integer; skipping"
            continue
        fi
        case "$_runtime" in
            scala)
                for (( _i=1; _i<=_count; _i++ )); do
                    INSTANCE_IDX_SCALA=$(( INSTANCE_IDX_SCALA + 1 ))
                    spawn_scala_instance "scala-${INSTANCE_IDX_SCALA}" "$INSTANCE_IDX_SCALA" || true
                done ;;
            cpp)
                for (( _i=1; _i<=_count; _i++ )); do
                    INSTANCE_IDX_CPP=$(( INSTANCE_IDX_CPP + 1 ))
                    spawn_cpp_instance "cpp-${INSTANCE_IDX_CPP}" "$INSTANCE_IDX_CPP" || true
                done ;;
            lsp)
                for (( _i=1; _i<=_count; _i++ )); do
                    INSTANCE_IDX_LSP=$(( INSTANCE_IDX_LSP + 1 ))
                    spawn_lsp_instance "lsp-${INSTANCE_IDX_LSP}" "$INSTANCE_IDX_LSP" || true
                done ;;
            *)
                warn "Unknown runtime in --engines spec: '$_runtime' — skipping" ;;
        esac
    done

    # Generate nginx upstreams from registry (for Docker TLS proxy if running)
    bash "$CI_DIR/scripts/gen-nginx-upstreams.sh" 2>/dev/null || true

    _inst_count=$(registry_ids 2>/dev/null | wc -l | tr -d ' ')
    ok "$_inst_count instance(s) registered"

    # Seed machines to each registered instance unless --skip-seed
    if [ "$SKIP_SEED" = false ] && [ -x "$MACHINES_DIR/scripts/seed-machines.sh" ]; then
        if bash "$MACHINES_DIR/scripts/validate-corpus.sh" > /tmp/corpus_validate.log 2>&1; then
            while IFS= read -r _inst_id; do
                _re_url=$(registry_get "$_inst_id" 2>/dev/null \
                    | python3 -c "import json,sys; print(json.load(sys.stdin).get('re_url',''))" 2>/dev/null || true)
                [ -z "$_re_url" ] && continue
                info "Seeding machines → $_inst_id ($_re_url)..."
                bash "$MACHINES_DIR/scripts/seed-machines.sh" "$_re_url" \
                    > "/tmp/corpus_seed_${_inst_id}.log" 2>&1 || \
                    add_warn "Seed to $_inst_id completed with errors"
            done < <(registry_ids 2>/dev/null)
        else
            add_warn "Machine corpus validation failed — seed skipped"
        fi
    fi
fi

# =============================================================================
hdr "4 · RealityEngine  (Scala/Akka built from RealityEngine_Scala)"
# =============================================================================

# ── manager-native: delegate Visualizer + PE to RealityEngine_Manager ─────
# When --manager-native is set the Docker compose stack runs only the RE API
# (Scala), Loki, Grafana, and the tls-proxy.  Visualizer and PE start natively
# via RealityEngine_Manager/start.sh using the Scala port preset (RE :5001, PE :5000).
# This mode is useful for frontend/PE development without Docker rebuilds.
if [ "$MANAGER_NATIVE" = true ]; then
    [ -d "$MGR_DIR" ] || die "--manager-native requires RealityEngine_Manager at $MGR_DIR"
    [ -x "$MGR_DIR/start.sh" ] || die "$MGR_DIR/start.sh missing or not executable"
    info "--manager-native: Visualizer + PE will be started via RealityEngine_Manager/start.sh"
    info "  RE API: https://localhost:5001  PE: http://localhost:5000"
fi

if [ "$MULTI_ENGINE_MODE" = true ]; then
    info "Multi-engine mode — Docker RE/PE services skipped (native instances already running)"
else

cd "$CI_DIR"

BUILDER="reality-engine-builder"
if ! docker buildx inspect "$BUILDER" > /dev/null 2>&1; then
    info "Creating isolated BuildKit builder (one-time)..."
    docker buildx create --name "$BUILDER" --driver docker-container \
        --bootstrap > /dev/null 2>&1 || \
        die "BuildKit builder creation failed — check Docker Desktop is healthy"
    ok "BuildKit builder created"
else
    ok "BuildKit builder ready ($BUILDER)"
fi
docker buildx use "$BUILDER" > /dev/null 2>&1

if [ "$FRESH_START" = true ]; then
    info "Building RE images (no cache)..."
    SCALA_DIR="$SCALA_DIR" MGR_DIR="$MGR_DIR" docker compose build --no-cache || \
        die "RE image build failed — run:  docker compose build --no-cache"
else
    info "Building RE images (cached)..."
    SCALA_DIR="$SCALA_DIR" MGR_DIR="$MGR_DIR" docker compose build || \
        die "RE image build failed — run:  docker compose build"
fi

docker buildx use default > /dev/null 2>&1 || true

info "Starting RE services (waiting for all healthchecks, timeout 360s)..."
docker compose up -d --wait --wait-timeout 360 || \
    die "RE services failed to reach healthy state\n  Check:  docker compose logs"
ok "All RE services healthy"

info "Confirming RE external endpoints..."
if [ "$MANAGER_NATIVE" = true ]; then
    echo -n "  API "
    poll_http "https://localhost:5001/api/health" "RE API reachable (:5001)" 15 "-skf" || \
        add_warn "RE API not reachable on https://localhost:5001 (Scala native port)"
    # Start Manager (Visualizer + PE) natively — Scala preset
    info "Starting RealityEngine_Manager natively (--scala)..."
    echo "" >> /tmp/manager_universe.log 2>&1 || true
    "$MGR_DIR/start.sh" --scala > /tmp/manager_universe.log 2>&1 &
    MANAGER_PID=$!
    echo "$MANAGER_PID" > /tmp/manager_universe.pid
    echo -n "  VIZ "
    poll_http "http://localhost:3001/health" "Visualizer backend ready" 30 "-sf" || \
        add_warn "Visualizer backend not reachable on :3001"
    echo -n "  PE  "
    poll_http "http://localhost:5000/api/health" "PE backend ready (:5000)" 30 "-sf" || \
        add_warn "PE backend not reachable on :5000 (Scala native port)"
else
    echo -n "  API "
    poll_http "https://localhost:3000/api/health" "RE API reachable" 15 "-skf" || \
        add_warn "RE API not reachable on https://localhost:3000 after startup"
    echo -n "  PE  "
    poll_http "https://localhost:3004/api/health" "PE Backend reachable" 15 "-skf" || \
        add_warn "Perception Engine not reachable on https://localhost:3004 after startup"
fi

set +e
PE_SRC_COUNT=$(curl -sk https://localhost:3004/api/sources 2>/dev/null \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('sources',[])))" \
    2>/dev/null || echo "?")
RE_MACHINE_COUNT=$(curl -sk https://localhost:3000/api/machines 2>/dev/null \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('machines',[])))" \
    2>/dev/null || echo "?")
set -e
ok "RE baseline: $RE_MACHINE_COUNT machines, $PE_SRC_COUNT PE sources"

# ── Machine corpus seed from RealityEngine_Machines ────────────────────────
if [ "$SKIP_SEED" = true ]; then
    info "Machine seeding skipped (--skip-seed)"
elif [ -x "$MACHINES_DIR/scripts/seed-machines.sh" ]; then
    info "Validating machine corpus..."
    if bash "$MACHINES_DIR/scripts/validate-corpus.sh" > /tmp/corpus_validate.log 2>&1; then
        ok "Machine corpus valid"
        info "Seeding machines from RealityEngine_Machines..."
        if bash "$MACHINES_DIR/scripts/seed-machines.sh" "https://localhost:3000" \
                > /tmp/corpus_seed.log 2>&1; then
            SEEDED_COUNT=$(grep -c "^." /tmp/corpus_seed.log 2>/dev/null || echo "?")
            ok "Machine corpus seeded (see /tmp/corpus_seed.log)"
        else
            add_warn "Machine seeding completed with errors — check /tmp/corpus_seed.log"
            warn "Some machines failed to seed"
        fi
    else
        add_warn "Machine corpus validation failed — seed skipped (check /tmp/corpus_validate.log)"
        warn "Corpus validation failed — skipping seed"
    fi
else
    info "RealityEngine_Machines/scripts/seed-machines.sh not found — skipping seed"
    info "  Populate $MACHINES_DIR/machines/ and re-run to seed the corpus"
fi

fi  # end: if [ "$MULTI_ENGINE_MODE" = false ] Docker RE block

# =============================================================================
hdr "5 · localAIStack API  (FastAPI + RAG + Ollama bridge)"
# =============================================================================

info "Building localAIStack API image..."
(cd "$LAS_DIR" && docker compose build api 2>&1) | tail -5
info "Starting localAIStack API (lifespan hooks register machines + sensors)..."
(cd "$LAS_DIR" && docker compose up -d --force-recreate --wait \
    --wait-timeout 120 api 2>&1) || \
    die "localAIStack API failed to reach healthy state\n  Check:  docker logs localai_api"
(cd "$LAS_DIR" && docker compose up -d open-webui) > /dev/null 2>&1 || true
ok "localAIStack API ready"

set +e
HEALTH_JSON=$(curl -sf http://localhost:4000/health 2>/dev/null || echo '{}')
echo "$HEALTH_JSON" | python3 -c "
import json, sys
h = json.load(sys.stdin).get('services', {})
for k, v in h.items():
    if k == 'ollama_models':
        models = ', '.join(v) if v else 'none'
        print(f'  ℹ  models    : {models}')
    else:
        icon = '✓' if v == 'ok' else '⚠'
        print(f'  {icon}  {k:<10}: {v}')
" 2>/dev/null || true
set -e

# =============================================================================
hdr "5.5 · OpenClaw  (ACP xACP gateway)"
# =============================================================================

OCS_STARTED=false
OCS_GW_PORT=18789
OCS_UI_PORT=8080

if [ "$OPENCLAW" = "no" ]; then
    info "OpenClaw: skipped (--no-openclaw)"
else
    _ocs_ok=false
    if [ ! -d "$OCS_DIR" ] || [ ! -f "$OCS_DIR/docker-compose.yml" ]; then
        [ "$OPENCLAW" = "yes" ] && \
            die "OpenClaw repo not found at $OCS_DIR" || \
            info "OpenClaw: repo not found — skipping (use --openclaw to require)"
    elif [ ! -f "$OCS_DIR/.env" ]; then
        [ "$OPENCLAW" = "yes" ] && \
            die "OpenClaw .env missing — copy $OCS_DIR/.env.example and set OPENCLAW_GATEWAY_TOKEN" || \
            info "OpenClaw: .env not configured — skipping"
    else
        _ocs_token=$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' "$OCS_DIR/.env" 2>/dev/null \
            | tail -1 | cut -d= -f2- || true)
        if [ -z "$_ocs_token" ] || [ "$_ocs_token" = "change-me-to-a-random-secret" ]; then
            [ "$OPENCLAW" = "yes" ] && \
                die "OPENCLAW_GATEWAY_TOKEN not set in $OCS_DIR/.env" || \
                info "OpenClaw: OPENCLAW_GATEWAY_TOKEN not configured — skipping"
        else
            _ocs_ok=true
            _p=$(grep -E '^OPENCLAW_GATEWAY_PORT=' "$OCS_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)
            [ -n "$_p" ] && OCS_GW_PORT="$_p"
            _p=$(grep -E '^OPEN_WEBUI_PORT=' "$OCS_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)
            [ -n "$_p" ] && OCS_UI_PORT="$_p"
        fi
    fi

    if [ "$_ocs_ok" = true ]; then
        mkdir -p "$OCS_DIR/openclaw"
        if [ ! -f "$OCS_DIR/openclaw/openclaw.json" ] && [ -f "$HOME/.openclaw/openclaw.json" ]; then
            cp "$HOME/.openclaw/openclaw.json" "$OCS_DIR/openclaw/openclaw.json"
            info "Seeded OpenClaw config from ~/.openclaw/openclaw.json"
        fi
        if [ -f "$OCS_DIR/openclaw/openclaw.json" ] && command -v python3 >/dev/null 2>&1; then
            python3 - "$OCS_DIR/openclaw/openclaw.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
d.setdefault('gateway', {})['bind'] = 'lan'
d.setdefault('gateway', {})['mode'] = 'local'
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
PYEOF
            ok "OpenClaw config: gateway.bind=lan, gateway.mode=local"
        fi

        for _ocs_check_port in "$OCS_GW_PORT" "$OCS_UI_PORT"; do
            _ocs_blocker=$(lsof -ti TCP:"$_ocs_check_port" -sTCP:LISTEN 2>/dev/null | head -1 || true)
            [ -n "$_ocs_blocker" ] && \
                die "OpenClaw port $_ocs_check_port in use by PID $_ocs_blocker — stop it and retry"
        done

        info "Starting OpenClaw (gateway :$OCS_GW_PORT, webui :$OCS_UI_PORT)..."
        (cd "$OCS_DIR" && docker compose up -d 2>/tmp/ocs_start_err.log) > /dev/null || \
            die "OpenClaw compose up failed\n$(tail -5 /tmp/ocs_start_err.log 2>/dev/null)"

        if poll_http "http://localhost:${OCS_GW_PORT}/healthz" "openclaw-gateway ready" 30 "-sf"; then
            OCS_STARTED=true
            info "Waiting for open-webui..."
            _n=0
            while [ "$_n" -lt 20 ]; do
                _s=$(curl -so /dev/null -w "%{http_code}" "http://localhost:${OCS_UI_PORT}/" 2>/dev/null || true)
                case "$_s" in 200|302) ok "open-webui ready"; break ;; esac
                _n=$((_n+1)); echo -n "."; sleep 3
            done
            echo ""
            [ "$_n" -ge 20 ] && add_warn "open-webui (:$OCS_UI_PORT) did not respond"
        else
            add_warn "openclaw-gateway (:$OCS_GW_PORT) did not respond"
        fi
    fi
fi

# =============================================================================
hdr "6 · Integration Verification"
# =============================================================================

if [ "$MULTI_ENGINE_MODE" = false ]; then
set +e
VERIFY_PASS=false
for attempt in 1 2 3; do
    [ "$attempt" -gt 1 ] && { info "Retry $attempt/3 — waiting 15s for hooks to settle..."; sleep 15; }

    RE_MACHINES=$(curl -sk https://localhost:3000/api/machines 2>/dev/null || echo '{"machines":[]}')
    MACHINE_LABELS=$(echo "$RE_MACHINES" | python3 -c "
import json, sys
for m in json.load(sys.stdin).get('machines', []):
    print(m.get('id','') + ' ' + m.get('name',''))
" 2>/dev/null || echo "")

    PE_SOURCES=$(curl -sk https://localhost:3004/api/sources 2>/dev/null || echo '{"sources":[]}')
    SENSOR_COUNT=$(echo "$PE_SOURCES" | python3 -c "
import json, sys
print(len([s for s in json.load(sys.stdin).get('sources',[]) if s.get('type')=='sensor']))
" 2>/dev/null || echo "0")

    HAS_RAG=$(echo "$MACHINE_LABELS" | grep -qi "rag.*corrective\|corrective.*rag" && echo true || echo false)
    HAS_SESS_RAG=$(echo "$MACHINE_LABELS" | grep -qi "session.*rag\|rag.*session" && echo true || echo false)
    HAS_SESS_AGT=$(echo "$MACHINE_LABELS" | grep -qi "session.*agent\|agent.*session" && echo true || echo false)
    HAS_SENSORS=$([ "$SENSOR_COUNT" -gt 0 ] && echo true || echo false)

    if [ "$HAS_RAG" = "true" ] && [ "$HAS_SESS_RAG" = "true" ] && \
       [ "$HAS_SESS_AGT" = "true" ] && [ "$HAS_SENSORS" = "true" ]; then
        VERIFY_PASS=true; break
    fi
done

TOTAL_MACHINES=$(echo "$RE_MACHINES" | python3 -c \
    "import json,sys; print(len(json.load(sys.stdin).get('machines',[])))" 2>/dev/null || echo "0")

[ "$HAS_RAG" = "true" ]      && ok "Machine registered: rag_corrective_cycle"      || { add_warn "rag_corrective_cycle not in RE"; warn "Machine NOT registered: rag_corrective_cycle"; }
[ "$HAS_SESS_RAG" = "true" ] && ok "Machine registered: session_rag_context"       || { add_warn "session_rag_context not in RE"; warn "Machine NOT registered: session_rag_context"; }
[ "$HAS_SESS_AGT" = "true" ] && ok "Machine registered: session_agent_context"     || { add_warn "session_agent_context not in RE"; warn "Machine NOT registered: session_agent_context"; }
ok "Total machines in RE: $TOTAL_MACHINES"

if [ "$HAS_SENSORS" = "true" ]; then
    ok "Sensor sources registered: $SENSOR_COUNT"
    echo "$PE_SOURCES" | python3 -c "
import json, sys
for s in json.load(sys.stdin).get('sources', []):
    if s.get('type') == 'sensor':
        r = s.get('region', {})
        print(f\"  sensor  [{r.get('offset','?')}:{r.get('length','?')}]  {s['name']}\")
" 2>/dev/null || true
else
    add_warn "No sensor sources in PE — localAIStack lifespan hooks may have failed"
    warn "No sensor sources registered in PE"
fi

RAG_COVERED=$(echo "$PE_SOURCES" | python3 -c "
import json, sys
offsets=[s.get('region',{}).get('offset') for s in json.load(sys.stdin).get('sources',[]) if s.get('type')=='sensor']
print('true' if 64 in offsets or 68 in offsets else 'false')
" 2>/dev/null || echo "false")
[ "$RAG_COVERED" = "true" ] && ok "RAG signal regions [64:72] mapped" || \
    { add_warn "RAG signal regions [64:72] not mapped"; warn "RAG regions [64:72] not found"; }

QDRANT_COLLS=$(curl -sf http://localhost:4333/collections 2>/dev/null || echo '{}')
COLL_LIST=$(echo "$QDRANT_COLLS" | python3 -c \
    "import json,sys; print([c['name'] for c in json.load(sys.stdin).get('result',{}).get('collections',[])])" \
    2>/dev/null || echo "[]")
for coll in "localai_docs" "reality-vectors"; do
    echo "$COLL_LIST" | grep -q "$coll" && ok "Qdrant collection: $coll" || \
        info "Qdrant '$coll': will be created on first use"
done

[ "$VERIFY_PASS" = "false" ] && \
    add_warn "Integration hooks incomplete — run:  (cd $LAS_DIR && docker compose restart api)"
set -e

else
  # Multi-engine mode: verify each registered native instance
  set +e
  _me_inst_ids=$(registry_ids 2>/dev/null || true)
  if [ -z "$_me_inst_ids" ]; then
      add_warn "Multi-engine mode but no registered instances to verify"
  else
      while IFS= read -r _vi_id; do
          _vi_entry=$(registry_get "$_vi_id" 2>/dev/null || true)
          _vi_re_url=$(echo "$_vi_entry" | python3 -c \
              "import json,sys; print(json.load(sys.stdin).get('re_url',''))" 2>/dev/null || true)
          _vi_pe_url=$(echo "$_vi_entry" | python3 -c \
              "import json,sys; print(json.load(sys.stdin).get('pe_url',''))" 2>/dev/null || true)
          _vi_re_ok=$(curl -sf --max-time 3 "$_vi_re_url/api/health" > /dev/null 2>&1 && echo true || echo false)
          _vi_pe_ok=$(curl -sf --max-time 3 "$_vi_pe_url/api/health" > /dev/null 2>&1 && echo true || echo false)
          _vi_mc=$(curl -sf --max-time 5 "$_vi_re_url/api/machines" 2>/dev/null \
              | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('machines',[])))" \
              2>/dev/null || echo "?")
          _vi_sc=$(curl -sf --max-time 5 "$_vi_pe_url/api/sources" 2>/dev/null \
              | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('sources',[])))" \
              2>/dev/null || echo "?")
          [ "$_vi_re_ok" = true ] \
              && ok "${_vi_id}  RE ok  machines: ${_vi_mc}" \
              || { add_warn "${_vi_id} RE not healthy"; warn "${_vi_id} RE health: FAIL"; }
          [ "$_vi_pe_ok" = true ] \
              && ok "${_vi_id}  PE ok  sources: ${_vi_sc}" \
              || { add_warn "${_vi_id} PE not healthy"; warn "${_vi_id} PE health: FAIL"; }
      done < <(echo "$_me_inst_ids")
  fi
  set -e
fi

# =============================================================================
hdr "7 · Operability  (smoke tests)"
# =============================================================================

SMOKE_DIM="${VECTOR_DIMENSION:-768}"
if [ "$MULTI_ENGINE_MODE" = false ]; then
set +e
info "RE perceive smoke-test (${SMOKE_DIM}-element zero vector)..."
ZERO_VEC=$(python3 -c "import json; print(json.dumps([0.0]*${SMOKE_DIM}))" 2>/dev/null || echo "")
if [ -n "$ZERO_VEC" ]; then
    PERCEIVE_RESP=$(curl -sk -X POST https://localhost:3000/api/perceive \
        -H "Content-Type: application/json" \
        -d "{\"vector\": $ZERO_VEC}" --max-time 15 2>/dev/null || echo "")
    if [ -n "$PERCEIVE_RESP" ]; then
        PERCEIVE_INFO=$(echo "$PERCEIVE_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
step = d.get('step', d)
results = step.get('machineResults', {})
n = len(results) if isinstance(results, dict) else '?'
ps = step.get('perceptualSpace', [])
nz = sum(1 for v in ps if v != 0.0) if ps else 0
print(f'machines_evaluated={n}, non-zero_perceptual_elements={nz}')
" 2>/dev/null || echo "response received")
        ok "RE perceive: $PERCEIVE_INFO"
    else
        add_warn "RE perceive returned no response"; warn "RE perceive: no response"
    fi
fi

info "localAIStack RAG readiness..."
LAS_HEALTH=$(curl -sf http://localhost:4000/health --max-time 5 2>/dev/null || echo "")
if [ -n "$LAS_HEALTH" ]; then
    LAS_STATUS=$(echo "$LAS_HEALTH" | python3 -c \
        "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
    [ "$LAS_STATUS" = "ok" ] && ok "localAIStack API: all services healthy" || \
        { add_warn "localAIStack API status: $LAS_STATUS"; warn "localAIStack API: $LAS_STATUS"; }
else
    add_warn "localAIStack API /health not responding"; warn "localAIStack API: no response"
fi

info "Integration path smoke-test (sensor write → PE)..."
SENSOR_WRITE=$(curl -sk -X POST https://localhost:3004/api/sensors/localai_rag_retrieval \
    -H "Content-Type: application/json" -d '{"values": [2.0, 0.85, 0.0, 0.0]}' \
    --max-time 5 2>/dev/null || echo "")
if echo "$SENSOR_WRITE" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') or d.get('id') or d.get('success') or d.get('updated') else 1)" \
    2>/dev/null; then
    ok "Integration path: sensor write accepted by PE"
elif [ -n "$SENSOR_WRITE" ]; then
    add_warn "Sensor write unexpected response"; warn "Sensor write: $(echo "$SENSOR_WRITE" | head -c 120)"
else
    add_warn "Sensor write no response — trigger on first RAG query"
    info "Sensor 'localai_rag_retrieval' registers on first RAG query"
fi
set -e

else
  # Multi-engine mode: smoke tests against first registered instance
  set +e
  _sm_first_id=$(registry_ids 2>/dev/null | head -1 || true)
  if [ -n "$_sm_first_id" ]; then
      _sm_entry=$(registry_get "$_sm_first_id" 2>/dev/null || true)
      _sm_re_url=$(echo "$_sm_entry" | python3 -c \
          "import json,sys; print(json.load(sys.stdin).get('re_url',''))" 2>/dev/null || true)
      _sm_pe_url=$(echo "$_sm_entry" | python3 -c \
          "import json,sys; print(json.load(sys.stdin).get('pe_url',''))" 2>/dev/null || true)

      info "RE perceive smoke-test against ${_sm_first_id} (${SMOKE_DIM}-element zero vector)..."
      ZERO_VEC=$(python3 -c "import json; print(json.dumps([0.0]*${SMOKE_DIM}))" 2>/dev/null || echo "")
      if [ -n "$ZERO_VEC" ] && [ -n "$_sm_re_url" ]; then
          PERCEIVE_RESP=$(curl -sf --max-time 15 -X POST "$_sm_re_url/api/perceive" \
              -H "Content-Type: application/json" \
              -d "{\"vector\": $ZERO_VEC}" 2>/dev/null || echo "")
          if [ -n "$PERCEIVE_RESP" ]; then
              PERCEIVE_INFO=$(echo "$PERCEIVE_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
step = d.get('step', d)
results = step.get('machineResults', {})
n = len(results) if isinstance(results, dict) else '?'
ps = step.get('perceptualSpace', [])
nz = sum(1 for v in ps if v != 0.0) if ps else 0
print(f'machines_evaluated={n}, non-zero_perceptual_elements={nz}')
" 2>/dev/null || echo "response received")
              ok "RE perceive [${_sm_first_id}]: $PERCEIVE_INFO"
          else
              add_warn "${_sm_first_id} perceive returned no response"
              warn "RE perceive [${_sm_first_id}]: no response"
          fi
      fi

      if [ -n "$_sm_pe_url" ]; then
          info "Sensor write smoke-test against ${_sm_first_id}..."
          SENSOR_WRITE=$(curl -sf --max-time 5 -X POST "$_sm_pe_url/api/sensors/localai_rag_retrieval" \
              -H "Content-Type: application/json" -d '{"values": [2.0, 0.85, 0.0, 0.0]}' \
              2>/dev/null || echo "")
          if echo "$SENSOR_WRITE" | python3 -c \
              "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') or d.get('id') or d.get('success') or d.get('updated') else 1)" \
              2>/dev/null; then
              ok "Sensor write [${_sm_first_id}]: accepted"
          elif [ -n "$SENSOR_WRITE" ]; then
              add_warn "Sensor write unexpected response"
              warn "Sensor write [${_sm_first_id}]: $(echo "$SENSOR_WRITE" | head -c 120)"
          else
              add_warn "Sensor write no response — trigger on first RAG query"
          fi
      fi
  else
      add_warn "No registry instances available for smoke tests"
  fi

  info "localAIStack RAG readiness..."
  LAS_HEALTH=$(curl -sf http://localhost:4000/health --max-time 5 2>/dev/null || echo "")
  if [ -n "$LAS_HEALTH" ]; then
      LAS_STATUS=$(echo "$LAS_HEALTH" | python3 -c \
          "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
      [ "$LAS_STATUS" = "ok" ] && ok "localAIStack API: all services healthy" || \
          { add_warn "localAIStack API status: $LAS_STATUS"; warn "localAIStack API: $LAS_STATUS"; }
  else
      add_warn "localAIStack API /health not responding"
      warn "localAIStack API: no response"
  fi
  set -e
fi

# =============================================================================
hdr "8 · Summary"
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Universe Running  [CI orchestration from RealityEngine_CI]"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  localAIStack"
printf "    %-30s %s\n" "API + RAG Orchestration"   "http://localhost:4000"
printf "    %-30s %s\n" "API Docs (Swagger UI)"     "http://localhost:4000/docs"
printf "    %-30s %s\n" "Open WebUI (Chat)"         "http://localhost:4080"
printf "    %-30s %s\n" "Qdrant Dashboard"          "http://localhost:4333/dashboard"
printf "    %-30s %s\n" "Ollama"                    "http://localhost:11434"
echo ""
if [ "$OCS_STARTED" = true ]; then
echo "  OpenClaw"
printf "    %-30s %s\n" "ACP xACP Gateway"          "http://localhost:${OCS_GW_PORT}"
printf "    %-30s %s\n" "Open WebUI (Chat)"         "http://localhost:${OCS_UI_PORT}"
echo ""
fi
if [ "$MULTI_ENGINE_MODE" = true ]; then
echo "  RealityEngine  — Multi-Engine Native Mode"
printf "    %-30s %s\n" "Instance Registry"         "http://$HOST_IP:${REGISTRY_PORT}/re-registry.json"
echo ""
if [ -f "$REGISTRY_FILE" ]; then
    python3 - "$REGISTRY_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    reg = json.load(f)
for inst in reg.get('instances', []):
    iid = inst['id']
    runtime = inst.get('runtime', '?')
    re_url = inst.get('re_url', '?')
    pe_url = inst.get('pe_url', '?')
    print(f"  {iid} ({runtime})")
    print(f"    {'RE API':<30} {re_url}")
    print(f"    {'PE API':<30} {pe_url}")
    print()
PYEOF
fi
else
echo "  RealityEngine  (source: RealityEngine_Scala + RealityEngine_Manager)"
printf "    %-30s %s\n" "API"                       "https://localhost:3000"
printf "    %-30s %s\n" "Visualizer"                "https://localhost:5173"
printf "    %-30s %s\n" "Perception Engine API"     "https://localhost:3004"
printf "    %-30s %s\n" "Perception Engine UI"      "https://localhost:3005"
printf "    %-30s %s\n" "Grafana (CI Logs)"         "https://localhost:3002"
echo ""
echo "  Note: RE endpoints use a self-signed TLS cert (browser will warn)"
echo "        Silence:  bash $CI_DIR/certs/generate-dev-certs.sh"
echo ""
fi

if [ "${#WARNS[@]}" -gt 0 ]; then
    echo "════════════════════════════════════════════════════════════════════"
    printf "  ${YELLOW}Integration Warnings${NC}  (%d)\n" "${#WARNS[@]}"
    echo "════════════════════════════════════════════════════════════════════"
    for w in "${WARNS[@]}"; do warn "  $w"; done
    echo ""
    echo "  Re-trigger localAIStack hooks:"
    echo "    (cd $LAS_DIR && docker compose restart api)"
    echo ""
else
    echo "════════════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Integration verified — all systems nominal${NC}"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
fi

# ── Write universe manifest ────────────────────────────────────────────────────
_docker_svcs="loki,qdrant,redis"
[ "$MULTI_ENGINE_MODE" = false ] && _docker_svcs="$_docker_svcs,reality-engine,visualizer,perception-engine,localai_api"
[ "$MULTI_ENGINE_MODE" = true  ] && _docker_svcs="$_docker_svcs,localai_api"
_ollama_started=false
[ -f /tmp/ollama_universe.pid ] && _ollama_started=true
python3 - <<MANIFEST_EOF
import json, os
manifest = {
    "started_at":              "$(date -u +%FT%TZ)",
    "mode":                    "multi-engine" if "$MULTI_ENGINE_MODE" == "true" else "docker",
    "engines":                 "$ENGINES",
    "re_engine":               "$RE_ENGINE",
    "pe_engine":               "$PE_ENGINE",
    "host_ip":                 "$HOST_IP",
    "registry_url":            "http://$HOST_IP:${REGISTRY_PORT}/re-registry.json" if "$MULTI_ENGINE_MODE" == "true" else "",
    "docker_services":         [s for s in "$_docker_svcs".split(",") if s],
    "ollama_started_by_universe": "$_ollama_started" == "true",
    "openclaw_started":        "$OCS_STARTED" == "true",
    "warns":                   ${#WARNS[@]},
}
with open("/tmp/universe-manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
MANIFEST_EOF
ok "Universe manifest written: /tmp/universe-manifest.json"
