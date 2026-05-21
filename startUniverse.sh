#!/bin/bash
# =============================================================================
# startUniverse.sh — Unified startup orchestrator
#
# Default engine = AI (TypeScript on Node, Docker compose stack).  Can be
# pointed at the CPP or LSP runtimes via --re-engine / --pe-engine.
#
# AI path (default) runs the dependency-safe sequence:
#   1    Pre-flight     — docker compose v2, certs, orphaned container cleanup
#   2    Ollama         — native LLM runtime
#   3    Infrastructure — RE Loki + localAIStack Qdrant + Redis
#   4    RealityEngine  — Scala/Akka stack (consumes Qdrant at :4333)
#   5    localAIStack API — FastAPI lifespan hooks register sensors + machines
#   5.5  OpenClaw       — optional ACP xACP gateway + Open WebUI (auto-detected)
#   6    Integration    — verify machines, sensors, and Qdrant collections
#   7    Operability    — live smoke-tests: perceive, RAG health, sensor write
#   8    Summary
#
# When --re-engine or --pe-engine is set to cpp or lsp, this script short-
# circuits to that runtime's native start.sh (no Docker, no localAIStack).
#
# Usage:  ./startUniverse.sh [--fresh] [--re-engine=ai|cpp|lsp]
#                            [--pe-engine=ai|cpp|lsp]
#                            [--mqtt-broker-url=URL]
#                            [--mqtt-mappings=PATH]
#                            [--openclaw] [--no-openclaw]
#                            [--help]
#
# Examples:
#   ./startUniverse.sh                                    # full AI stack
#   ./startUniverse.sh --re-engine=cpp --pe-engine=cpp    # native C++ binaries
#   ./startUniverse.sh --re-engine=lsp --pe-engine=lsp    # Common Lisp
#   ./startUniverse.sh --no-openclaw                      # skip OpenClaw even if configured
#   ./startUniverse.sh --re-engine=cpp \                  # MQTT bridge enabled
#       --mqtt-broker-url=mqtt://broker:1883 \
#       --mqtt-mappings=$PWD/../RealityEngine_CPP/config/mqtt-mappings.yuma-agriculture.json
#
# The stopUniverse.sh companion reads .universe-engine-selection (stamped
# below) to know which engine to tear down.
# =============================================================================
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RE_DIR="$SCRIPT_DIR"
LAS_DIR="$SCRIPT_DIR/../localAIStack"
CPP_DIR="$SCRIPT_DIR/../RealityEngine_CPP"
LSP_DIR="$SCRIPT_DIR/../RealityEngine_LSP"
OCS_DIR="$SCRIPT_DIR/../localOpenClawStack"

# ── flags ──────────────────────────────────────────────────────────────────
FRESH_START=false
RE_ENGINE="${RE_ENGINE:-ai}"       # ai | cpp | lsp   (default ai)
PE_ENGINE="${PE_ENGINE:-ai}"       # ai | cpp | lsp   (default ai)
MQTT_BROKER_URL_OVERRIDE=""
MQTT_MAPPINGS_OVERRIDE=""
OPENCLAW="${OPENCLAW:-auto}"       # auto | yes | no
OCS_NATIVE_UNLOADED=false          # set true in Phase 1 if native launchd gateway is stopped

print_engine_usage() {
  cat <<'USAGE'
startUniverse.sh — engine-selectable unified startup

  --fresh                       Wipe AI perception sources + rebuild images no-cache
  --re-engine=ai|cpp|lsp        Reality Engine implementation (default: ai)
  --pe-engine=ai|cpp|lsp        Perception Engine implementation (default: ai)
  --mqtt-broker-url=URL         MQTT_BROKER_URL (AI) / parsed for CPP/LSP
  --mqtt-mappings=PATH          MQTT_MAPPINGS_FILE — registry projecting topics into PE
  --openclaw                    Force-start OpenClaw even if auto-detect would skip it
  --no-openclaw                 Skip OpenClaw startup even if .env is configured
  --help                        Show this message

Examples:
  ./startUniverse.sh
  ./startUniverse.sh --re-engine=cpp --pe-engine=cpp
  ./startUniverse.sh --re-engine=lsp --pe-engine=lsp
  ./startUniverse.sh --no-openclaw
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --fresh)                FRESH_START=true ;;
    --re-engine=*)          RE_ENGINE="${arg#*=}" ;;
    --pe-engine=*)          PE_ENGINE="${arg#*=}" ;;
    --mqtt-broker-url=*)    MQTT_BROKER_URL_OVERRIDE="${arg#*=}" ;;
    --mqtt-mappings=*)      MQTT_MAPPINGS_OVERRIDE="${arg#*=}" ;;
    --openclaw)             OPENCLAW=yes ;;
    --no-openclaw)          OPENCLAW=no ;;
    --help|-h)              print_engine_usage; exit 0 ;;
    *)                      echo "Unknown argument: $arg"; print_engine_usage; exit 2 ;;
  esac
done

case "$RE_ENGINE" in ai|cpp|lsp) ;; *) echo "Bad --re-engine=$RE_ENGINE (expected ai|cpp|lsp)"; exit 2 ;; esac
case "$PE_ENGINE" in ai|cpp|lsp) ;; *) echo "Bad --pe-engine=$PE_ENGINE (expected ai|cpp|lsp)"; exit 2 ;; esac

# Stamp the engine selection so stopUniverse.sh can find it later.  Lives
# alongside this script so it persists across invocations.
cat > "$RE_DIR/.universe-engine-selection" <<EOF
RE_ENGINE=$RE_ENGINE
PE_ENGINE=$PE_ENGINE
OPENCLAW=$OPENCLAW
OCS_NATIVE_UNLOADED=$OCS_NATIVE_UNLOADED
STARTED_AT=$(date -u +%FT%TZ)
EOF

# ── colours + helpers (defined early so any block below can use them) ──────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}ℹ${NC} $*"; }
warn() { echo -e "${RED}⚠${NC} $*"; }
hdr()  { echo -e "\n${CYAN}${BOLD}─── $* ───${NC}"; }
die()  { echo -e "\n${RED}✗  FATAL:${NC} $*\n"; exit 1; }

WARNS=()
add_warn() { WARNS+=("$*"); }

# ── poll_http <url> <label> <max_tries> <curl_flags> ───────────────────────
# Returns 0 on first success, 1 on timeout.  Dots shown while waiting.
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

# ── Engine-selection short-circuit ─────────────────────────────────────────
# When the operator picks a non-AI engine, we skip the Docker compose dance
# entirely and delegate to that runtime's native start.sh.  MQTT env vars
# are passed through so the bridge boots from the same configuration.

run_native_engine() {
  local engine_dir="$1"  # absolute path to engine repo (e.g. _CPP)
  local engine_name="$2" # display name (e.g. CPP)

  [ -d "$engine_dir" ] || { echo "✗ $engine_name engine repo not found at $engine_dir"; exit 1; }
  [ -x "$engine_dir/start.sh" ] || { echo "✗ $engine_dir/start.sh missing or not executable"; exit 1; }

  # MQTT env vars — both CPP (HOST/PORT) and AI (URL) shapes can be derived
  # from a single mqtt://host:port URL.  Pass both so each runtime picks
  # what its bridge boot logic expects.
  if [ -n "$MQTT_BROKER_URL_OVERRIDE" ]; then
    export MQTT_BROKER_URL="$MQTT_BROKER_URL_OVERRIDE"
    # parse host + port for CPP-style env vars
    local stripped="${MQTT_BROKER_URL_OVERRIDE#mqtt://}"
    stripped="${stripped#mqtts://}"
    export MQTT_BROKER_HOST="${stripped%%:*}"
    local rest="${stripped#*:}"
    export MQTT_BROKER_PORT="${rest%%/*}"
    [ "$MQTT_BROKER_PORT" = "$stripped" ] && MQTT_BROKER_PORT=1883
  fi
  [ -n "$MQTT_MAPPINGS_OVERRIDE" ] && export MQTT_MAPPINGS_FILE="$MQTT_MAPPINGS_OVERRIDE"

  echo "════════════════════════════════════════════════════════════════════"
  echo "  Delegating to $engine_name engine: $engine_dir/start.sh"
  echo "════════════════════════════════════════════════════════════════════"
  echo "  RE_ENGINE=$RE_ENGINE  PE_ENGINE=$PE_ENGINE"
  [ -n "${MQTT_BROKER_URL:-}${MQTT_BROKER_HOST:-}" ] && \
    echo "  MQTT broker: ${MQTT_BROKER_URL:-${MQTT_BROKER_HOST}:${MQTT_BROKER_PORT:-1883}}"
  [ -n "${MQTT_MAPPINGS_FILE:-}" ] && \
    echo "  MQTT mappings: $MQTT_MAPPINGS_FILE"
  echo ""

  exec "$engine_dir/start.sh"
}

if [ "$RE_ENGINE" = "cpp" ] || [ "$PE_ENGINE" = "cpp" ]; then
  run_native_engine "$CPP_DIR" "CPP"
fi
if [ "$RE_ENGINE" = "lsp" ] || [ "$PE_ENGINE" = "lsp" ]; then
  run_native_engine "$LSP_DIR" "LSP"
fi

# ── From here on: AI engine path (the original Docker-based stack) ─────────

# Propagate the MQTT overrides to the AI Docker stack via env so the PE
# container picks them up.  Two subtleties:
#   1. --mqtt-mappings=PATH points at a host file, but the PE container
#      can't see the host's filesystem.  Read the file contents in the
#      orchestrator and pass them inline via MQTT_MAPPINGS_JSON, which
#      the PE backend's MappingRegistry.fromJson also accepts.
#   2. MQTT_BROKER_URL is a plain env passthrough — the PE container's
#      docker-compose service declares the env vars on its environment
#      block so they propagate from the host shell.
if [ -n "$MQTT_BROKER_URL_OVERRIDE" ]; then
  export MQTT_BROKER_URL="$MQTT_BROKER_URL_OVERRIDE"
fi
if [ -n "$MQTT_MAPPINGS_OVERRIDE" ]; then
  if [ ! -f "$MQTT_MAPPINGS_OVERRIDE" ]; then
    die "MQTT mappings file not found: $MQTT_MAPPINGS_OVERRIDE"
  fi
  # Pass contents inline so the PE container doesn't need a host mount.
  # MQTT_MAPPINGS_FILE is still exported for non-Docker engines (CPP / LSP
  # delegations short-circuit above this block); but for the AI Docker
  # path the file ABSOLUTELY MUST be readable by the container, so we
  # default to the JSON-inline form here.
  export MQTT_MAPPINGS_FILE="$MQTT_MAPPINGS_OVERRIDE"
  export MQTT_MAPPINGS_JSON="$(cat "$MQTT_MAPPINGS_OVERRIDE")"
  info "MQTT mappings loaded inline (${#MQTT_MAPPINGS_JSON} bytes from ${MQTT_MAPPINGS_OVERRIDE##*/})"
fi

# =============================================================================
hdr "1 · Pre-flight"
# =============================================================================

# docker compose v2 is required for --wait, BuildKit integration, and --force-recreate
docker compose version > /dev/null 2>&1 || \
    die "docker compose (v2) not found.  Install Docker Desktop >= 3.x or the compose plugin."
COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "unknown")
ok "docker compose v$COMPOSE_VER"

[ -d "$LAS_DIR" ] || \
    die "localAIStack not found at $LAS_DIR\n  Clone it alongside RealityEngine_AI and retry."

docker info > /dev/null 2>&1 || die "Docker daemon is not running — start Docker Desktop first"
ok "Docker daemon reachable"

[ -f "$RE_DIR/.env" ] || die ".env not found — run scripts/setup.sh first"
# shellcheck source=/dev/null
source "$RE_DIR/.env"

# TLS certificates (required by all RE HTTPS services)
MISSING_CERTS=""
for f in certs/server.crt certs/server.key certs/ca.crt certs/keystore.p12; do
    [ ! -f "$RE_DIR/$f" ] && MISSING_CERTS="$MISSING_CERTS $f"
done
[ -n "$MISSING_CERTS" ] && \
    die "Missing TLS cert(s):$MISSING_CERTS\n  Run:  bash $RE_DIR/certs/generate-dev-certs.sh"
openssl x509 -in "$RE_DIR/certs/server.crt" -noout -text 2>/dev/null \
    | grep -q "DNS:reality-engine" || \
    die "certs/server.crt is missing SANs\n  Run:  bash $RE_DIR/certs/generate-dev-certs.sh"
ok "TLS certificates valid"

# Loki Docker logging driver (required by all RE compose services)
# docker plugin ls grep only checks presence, not ENABLED state — use inspect instead.
LOKI_ENABLED=$(docker plugin inspect loki --format '{{.Enabled}}' 2>/dev/null || echo "missing")
if [ "$LOKI_ENABLED" = "missing" ]; then
    info "Installing Loki Docker logging driver..."
    docker plugin install grafana/loki-docker-driver:latest \
        --alias loki --grant-all-permissions 2>/dev/null || \
        die "Loki Docker driver installation failed\n  Run manually:  bash $RE_DIR/scripts/setup-loki-driver.sh"
elif [ "$LOKI_ENABLED" = "false" ]; then
    info "Enabling Loki Docker logging driver (was installed but disabled)..."
    docker plugin enable loki 2>/dev/null || \
        die "Loki Docker driver could not be enabled\n  Run manually:  docker plugin enable loki"
fi
ok "Loki Docker logging driver installed and enabled"

# Block if local node processes hold RE ports (Docker would conflict)
CONFLICTS=""
for port in 3000 3001 3004 3005 5173; do
    proc=$(lsof -i ":$port" 2>/dev/null | awk '/LISTEN/{print $1}' | head -1 || true)
    [ "$proc" = "node" ] && CONFLICTS="$CONFLICTS ${port}(node)"
done
[ -n "$CONFLICTS" ] && \
    die "Local node processes on RE ports:$CONFLICTS\n  Stop them with:  ./scripts/stop-local.sh"
ok "No port conflicts"

# ── Orphaned container cleanup ─────────────────────────────────────────────
# docker compose down only removes containers tracked by the compose project.
# Containers from `docker compose run`, previous builds, or renamed projects
# (e.g. lucid_gould from an earlier manual run) must be removed explicitly.
info "Checking for orphaned containers..."

# Remove containers managed by the compose project first
(cd "$RE_DIR" && docker compose down 2>/dev/null) || true

# Remove any remaining containers using RE images by image name pattern
ORPHANS=$(docker ps -a --format "{{.ID}} {{.Image}}" 2>/dev/null \
    | awk '/realityengine_ai-|realityengine-/{print $1}' || true)
if [ -n "$ORPHANS" ]; then
    # shellcheck disable=SC2086
    docker rm -f $ORPHANS > /dev/null 2>&1 || true
fi

# Also sweep named RE containers that may have survived
docker rm -f \
    reality-engine-app \
    reality-engine-visualizer-backend \
    reality-engine-visualizer-frontend \
    reality-engine-perception-backend \
    reality-engine-perception-frontend \
    reality-engine-tls-proxy \
    reality-engine-loki \
    reality-engine-grafana > /dev/null 2>&1 || true

REMAINING=$(docker ps -a --format "{{.Names}}" 2>/dev/null \
    | grep -c "reality-engine-" || true)
if [ "$REMAINING" -gt 0 ]; then
    warn "Some RE containers could not be removed — they may cause startup conflicts"
    add_warn "$REMAINING RE container(s) still present before startup"
else
    ok "RE container state clean"
fi

# Symmetric cleanup for the localAIStack compose project.  Its services
# (qdrant, redis, loki, grafana, api, webui) use hardcoded container_name
# entries, so a stale container from a previous LAS run — even one created
# outside the compose project label — will collide with `docker compose up`
# in Phase 3.  Without this sweep the start fails with:
#   Conflict. The container name "/localai_qdrant" is already in use...
(cd "$LAS_DIR" && docker compose down 2>/dev/null) || true
docker rm -f \
    localai_qdrant \
    localai_redis \
    localai_loki \
    localai_grafana \
    localai_api \
    localai_webui > /dev/null 2>&1 || true

LAS_REMAINING=$(docker ps -a --format "{{.Names}}" 2>/dev/null \
    | grep -c "^localai_" || true)
if [ "$LAS_REMAINING" -gt 0 ]; then
    warn "Some localAIStack containers could not be removed — they may cause startup conflicts"
    add_warn "$LAS_REMAINING localai_* container(s) still present before startup"
else
    ok "localAIStack container state clean"
fi

# OpenClaw container cleanup — always sweep regardless of OPENCLAW flag so
# a previous run's leftovers never cause a name collision on next start.
if [ -d "$OCS_DIR" ] && [ -f "$OCS_DIR/docker-compose.yml" ]; then
    (cd "$OCS_DIR" && docker compose down 2>/dev/null) || true
    docker rm -f openclaw-gateway open-webui browser > /dev/null 2>&1 || true
fi
# Stop any native openclaw-gateway that may be holding the gateway port.
# A native install (e.g. via Homebrew/npm) managed by launchd with KeepAlive:true
# restarts immediately after a plain `kill`; `launchctl unload` is required to
# prevent the respawn.  Record the action so stopUniverse.sh can reload it.
_ocs_gw_port_cleanup=18789
if [ -f "$OCS_DIR/.env" ]; then
    _p=$(grep -E '^OPENCLAW_GATEWAY_PORT=' "$OCS_DIR/.env" 2>/dev/null \
        | tail -1 | cut -d= -f2- || true)
    [ -n "$_p" ] && _ocs_gw_port_cleanup="$_p"
fi
_OCS_LAUNCHD_PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
if launchctl list 2>/dev/null | grep -q "ai.openclaw.gateway"; then
    info "Unloading native openclaw-gateway (launchd) to free port $_ocs_gw_port_cleanup..."
    launchctl unload "$_OCS_LAUNCHD_PLIST" 2>/dev/null || true
    OCS_NATIVE_UNLOADED=true
    ok "Native openclaw-gateway unloaded (will be restored by stopUniverse.sh)"
    # Update the stamp so stopUniverse.sh sees the correct value even though
    # the stamp was written earlier in this script (before Phase 1 ran).
    sed -i '' "s/^OCS_NATIVE_UNLOADED=.*/OCS_NATIVE_UNLOADED=true/" \
        "$RE_DIR/.universe-engine-selection" 2>/dev/null || true
else
    # Not a launchd service — fall back to a plain kill if something else holds the port.
    _ocs_port_pid=$(lsof -ti TCP:"$_ocs_gw_port_cleanup" -sTCP:LISTEN 2>/dev/null | head -1 || true)
    if [ -n "$_ocs_port_pid" ]; then
        info "Stopping native process on port $_ocs_gw_port_cleanup (PID $_ocs_port_pid)..."
        kill "$_ocs_port_pid" 2>/dev/null || true
        sleep 1
    fi
fi

# Settle time for Docker Desktop VirtioFS file-lock release after container removal
sleep 2

if [ "$FRESH_START" = true ]; then
    echo ""
    warn "Fresh start — perception source data will be wiped; all images rebuilt without cache"
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
    info "Waiting for Ollama..."
    poll_http "http://localhost:11434/api/tags" "Ollama ready" 30 "-sf" || \
        die "Ollama failed to start\n  Log:  /tmp/ollama_universe.log"
fi

# Inventory models; warn on missing required ones.
# Embedding model comes from localAIStack/.env (EMBED_MODEL); fall back to ternary-bonsai:4.
set +e
TAGS_JSON=$(curl -sf http://localhost:11434/api/tags 2>/dev/null || echo '{"models":[]}')
EMBED_MODEL_REQUIRED="${EMBED_MODEL:-}"
if [ -z "$EMBED_MODEL_REQUIRED" ] && [ -f "$LAS_DIR/.env" ]; then
    EMBED_MODEL_REQUIRED=$(grep -E '^EMBED_MODEL=' "$LAS_DIR/.env" | tail -1 | cut -d= -f2-)
fi
EMBED_MODEL_REQUIRED="${EMBED_MODEL_REQUIRED:-ternary-bonsai:4}"
set -e
for model in "llama3" "$EMBED_MODEL_REQUIRED"; do
    MATCH=$(echo "$TAGS_JSON" | python3 -c \
        "import json,sys
ms=[m['name'] for m in json.load(sys.stdin).get('models',[]) if '$model' in m['name']]
print(ms[0] if ms else '')" 2>/dev/null || echo "")
    if [ -n "$MATCH" ]; then
        ok "Model: $MATCH"
    else
        add_warn "Ollama model '$model' not found — pull with:  ollama pull $model"
        warn "Model not found: $model (RAG/embeddings may fail)"
    fi
done

# =============================================================================
hdr "3 · Infrastructure  (RE Loki + Qdrant + Redis)"
# =============================================================================

# --fresh: clear RE perception volume before containers start
if [ "$FRESH_START" = true ]; then
    PERCEPTION_VOL=$(docker volume ls --format "{{.Name}}" \
        | grep "_perception_sources_data$" | head -1 || true)
    if [ -n "$PERCEPTION_VOL" ]; then
        info "Removing perception sources volume: $PERCEPTION_VOL"
        docker volume rm "$PERCEPTION_VOL" > /dev/null 2>&1 || true
        ok "Perception source data cleared"
    else
        info "No perception sources volume found (already clean)"
    fi
fi

info "Starting Loki (RE) + Qdrant + Redis..."
# Loki lives in RE's compose and must start before RE containers because their
# Docker logging driver pushes to https://localhost:3100/loki/api/v1/push.
# Grafana depends on Loki and will start with the rest of RE in Phase 4.
# stderr captured so die() can surface the first failure lines.
(cd "$RE_DIR"  && docker compose up -d loki \
    2>/tmp/infra_start_err.log) > /dev/null || \
    die "docker compose up failed for Loki\n$(tail -5 /tmp/infra_start_err.log 2>/dev/null)\n  Run manually:  cd $RE_DIR && docker compose up loki"
(cd "$LAS_DIR" && docker compose up -d qdrant redis \
    2>>/tmp/infra_start_err.log) > /dev/null || \
    die "docker compose up failed for Qdrant/Redis\n$(tail -5 /tmp/infra_start_err.log 2>/dev/null)\n  Run manually:  cd $LAS_DIR && docker compose up qdrant redis"

# Loki: wait for /ready  (HTTPS on port 3100; -k skips self-signed cert check)
info "Waiting for Loki..."
poll_http "https://localhost:3100/ready" "Loki ready" 30 "-skf" || \
    die "Loki failed to start\n  Check:  docker logs reality-engine-loki"

# Grafana (reality-engine-grafana) has no direct host port — it is only reachable
# through the TLS proxy at https://localhost:3002 after Phase 4 completes.
# Startup is verified by the compose healthcheck in Phase 4 --wait.
info "Grafana will be verified via TLS proxy in Phase 4 (no direct host port)"

# Qdrant: wait for REST API to accept connections
info "Waiting for Qdrant..."
poll_http "http://localhost:4333/collections" "Qdrant ready" 30 "-sf" || \
    die "Qdrant failed to start\n  Check:  docker logs localai_qdrant"

# Redis: wait for PONG
info "Waiting for Redis..."
n=0
while [ "$n" -lt 20 ]; do
    if docker exec localai_redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        ok "Redis ready"; break
    fi
    n=$((n+1)); echo -n "."; sleep 2
done
echo ""
[ "$n" -ge 20 ] && die "Redis failed to start\n  Check:  docker logs localai_redis"

# =============================================================================
hdr "4 · RealityEngine"
# =============================================================================

cd "$RE_DIR"

# Isolated BuildKit builder — prevents VirtioFS deadlocks on macOS Docker Desktop
# that manifest as hangs at "load .dockerignore" / "load build definition"
BUILDER="reality-engine-builder"
if ! docker buildx inspect "$BUILDER" > /dev/null 2>&1; then
    info "Creating isolated BuildKit builder (one-time setup)..."
    docker buildx create --name "$BUILDER" --driver docker-container \
        --bootstrap > /dev/null 2>&1 || \
        die "BuildKit builder creation failed — check Docker Desktop is healthy"
    ok "BuildKit builder created"
else
    ok "BuildKit builder ready ($BUILDER)"
fi
docker buildx use "$BUILDER" > /dev/null 2>&1

if [ "$FRESH_START" = true ]; then
    info "Building RE images (no cache — sbt deps served from BuildKit cache mounts)..."
    docker compose build --no-cache || \
        die "RE image build failed (no-cache)\n  Run:  docker compose build --no-cache"
else
    info "Building RE images (cached)..."
    docker compose build || \
        die "RE image build failed\n  Run:  docker compose build  (or --no-cache to force rebuild)"
fi

docker buildx use default > /dev/null 2>&1 || true

# Start all RE services and block until every healthcheck passes.
# --wait-timeout 360: Scala JVM cold-start + sbt is slow; 6 min is conservative.
# Startup order enforced by depends_on conditions in docker-compose.yml:
#   Loki → RE/Visualizer/Perception → tls-proxy
info "Starting RE services (waiting for all healthchecks)..."
docker compose up -d --wait --wait-timeout 360 || \
    die "RE services failed to reach healthy state within 6 minutes\n  Check:  docker compose logs"
ok "All RE services healthy"

# tls-proxy healthcheck is nginx -t (config validation only).
# Do a short host-level poll to confirm external port bindings are live.
info "Confirming RE external endpoints..."
echo -n "  API "
poll_http "https://localhost:3000/api/health" "RE API reachable" 15 "-skf" || {
    add_warn "RE API not reachable on https://localhost:3000 after startup"
    warn "RE API endpoint not responding — TLS proxy may still be binding"
}
echo -n "  PE  "
poll_http "https://localhost:3004/api/health" "PE Backend reachable" 15 "-skf" || {
    add_warn "Perception Engine not reachable on https://localhost:3004 after startup"
    warn "PE endpoint not responding"
}

# Baseline source count (pre-integration)
set +e
PE_SRC_COUNT=$(curl -sk https://localhost:3004/api/sources 2>/dev/null \
    | python3 -c \
        "import json,sys; print(len(json.load(sys.stdin).get('sources',[])))" \
        2>/dev/null || echo "?")
RE_MACHINE_COUNT=$(curl -sk https://localhost:3000/api/machines 2>/dev/null \
    | python3 -c \
        "import json,sys; print(len(json.load(sys.stdin).get('machines',[])))" \
        2>/dev/null || echo "?")
set -e
ok "RE baseline: $RE_MACHINE_COUNT machines, $PE_SRC_COUNT PE sources"

# =============================================================================
hdr "5 · localAIStack API"
# =============================================================================

# --force-recreate ensures the FastAPI lifespan hooks always re-fire against
# the now-live RealityEngine.  Hooks registered:
#   register_sensors()        → PE sensor sources at [64:72]
#   import_machine_if_missing → rag_corrective_cycle machine in RE
#   import_session_machines() → session_rag_context / session_agent_context in RE
#   bind_graph_topology()     → per-node topology sensors + machines

info "Building localAIStack API image..."
# --build ensures image rebuilds when services/api/requirements.txt or the
# Dockerfile change (e.g. when strawberry-graphql is added); cache hits keep
# this near-instant when nothing moved.
(cd "$LAS_DIR" && docker compose build api 2>&1) | tail -5
info "Starting localAIStack API (lifespan hooks will register integration)..."
# --wait on 'api' only: open-webui has no healthcheck and --wait would block.
(cd "$LAS_DIR" && docker compose up -d --force-recreate --wait \
    --wait-timeout 120 api 2>&1) || \
    die "localAIStack API failed to reach healthy state\n  Check:  docker logs localai_api"

# Start open-webui detached without waiting (no healthcheck defined)
(cd "$LAS_DIR" && docker compose up -d open-webui) > /dev/null 2>&1 || true

ok "localAIStack API ready"

# Report per-service health from /health endpoint
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
hdr "5.5 · OpenClaw  (ACP xACP gateway + Open WebUI)"
# =============================================================================

OCS_STARTED=false
OCS_GW_PORT=18789
OCS_UI_PORT=8080

if [ "$OPENCLAW" = "no" ]; then
    info "OpenClaw: skipped (--no-openclaw)"
else
    _ocs_ok=false
    if [ ! -d "$OCS_DIR" ] || [ ! -f "$OCS_DIR/docker-compose.yml" ]; then
        if [ "$OPENCLAW" = "yes" ]; then
            die "OpenClaw repo not found at $OCS_DIR — clone it alongside RealityEngine_AI and retry"
        else
            info "OpenClaw: repo not found at $OCS_DIR — skipping (use --openclaw to require it)"
        fi
    elif [ ! -f "$OCS_DIR/.env" ]; then
        if [ "$OPENCLAW" = "yes" ]; then
            die "OpenClaw .env missing — copy $OCS_DIR/.env.example and set OPENCLAW_GATEWAY_TOKEN"
        else
            info "OpenClaw: .env not configured — skipping"
            info "  To enable:  cp $OCS_DIR/.env.example $OCS_DIR/.env  then edit OPENCLAW_GATEWAY_TOKEN"
        fi
    else
        _ocs_token=$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' "$OCS_DIR/.env" 2>/dev/null \
            | tail -1 | cut -d= -f2- || true)
        if [ -z "$_ocs_token" ] || [ "$_ocs_token" = "change-me-to-a-random-secret" ]; then
            if [ "$OPENCLAW" = "yes" ]; then
                die "OPENCLAW_GATEWAY_TOKEN not set in $OCS_DIR/.env — edit it before starting"
            else
                info "OpenClaw: OPENCLAW_GATEWAY_TOKEN not configured — skipping"
            fi
        else
            _ocs_ok=true
            # Honour port overrides from .env
            _p=$(grep -E '^OPENCLAW_GATEWAY_PORT=' "$OCS_DIR/.env" 2>/dev/null \
                | tail -1 | cut -d= -f2- || true)
            [ -n "$_p" ] && OCS_GW_PORT="$_p"
            _p=$(grep -E '^OPEN_WEBUI_PORT=' "$OCS_DIR/.env" 2>/dev/null \
                | tail -1 | cut -d= -f2- || true)
            [ -n "$_p" ] && OCS_UI_PORT="$_p"
        fi
    fi

    if [ "$_ocs_ok" = true ]; then
        # Seed the openclaw config dir from the native install if not already present.
        # The gateway container volume-mounts ./openclaw as /home/node/.openclaw.
        # Two constraints apply:
        #   1. A config file must exist — the gateway exits "Missing config" without one.
        #   2. gateway.bind must be "lan" (not "loopback") so Docker port publishing
        #      can forward traffic from the host to the container's HTTP server.
        #      The native install uses "loopback"; the env-var override does not take
        #      effect when a config file sets it explicitly, so we patch it after copy.
        mkdir -p "$OCS_DIR/openclaw"
        if [ ! -f "$OCS_DIR/openclaw/openclaw.json" ] && \
           [ -f "$HOME/.openclaw/openclaw.json" ]; then
            cp "$HOME/.openclaw/openclaw.json" "$OCS_DIR/openclaw/openclaw.json"
            info "Seeded OpenClaw config from ~/.openclaw/openclaw.json"
        fi
        # Patch gateway.bind to "lan" regardless of source — ensures the container's
        # HTTP server binds to all interfaces so Docker's port publishing reaches it.
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
        info "Starting OpenClaw (gateway :$OCS_GW_PORT, webui :$OCS_UI_PORT)..."
        # Pre-flight: verify ports are free (a native openclaw-gateway would have
        # been killed in Phase 1, but something else might still be listening).
        for _ocs_check_port in "$OCS_GW_PORT" "$OCS_UI_PORT"; do
            _ocs_blocker=$(lsof -ti TCP:"$_ocs_check_port" -sTCP:LISTEN 2>/dev/null | head -1 || true)
            if [ -n "$_ocs_blocker" ]; then
                die "OpenClaw port $_ocs_check_port is still in use by PID $_ocs_blocker\n  Stop that process and re-run."
            fi
        done
        (cd "$OCS_DIR" && docker compose up -d \
            2>/tmp/ocs_start_err.log) > /dev/null || \
            die "OpenClaw docker compose up failed\n$(tail -5 /tmp/ocs_start_err.log 2>/dev/null)\n  Manual check:  cd $OCS_DIR && docker compose up 2>&1 | tail -20"

        info "Waiting for openclaw-gateway..."
        if poll_http "http://localhost:${OCS_GW_PORT}/healthz" \
                "openclaw-gateway ready" 30 "-sf"; then
            OCS_STARTED=true
            # Best-effort webui poll (no healthcheck in compose)
            info "Waiting for open-webui..."
            _n=0
            while [ "$_n" -lt 20 ]; do
                _s=$(curl -so /dev/null -w "%{http_code}" \
                    "http://localhost:${OCS_UI_PORT}/" 2>/dev/null || true)
                case "$_s" in 200|302) ok "open-webui ready"; break ;; esac
                _n=$((_n+1)); echo -n "."; sleep 3
            done
            echo ""
            [ "$_n" -ge 20 ] && {
                add_warn "open-webui (:$OCS_UI_PORT) did not respond — check:  docker logs open-webui"
                warn "open-webui health check timed out"
            }
        else
            add_warn "openclaw-gateway (:$OCS_GW_PORT) did not respond — check:  docker logs openclaw-gateway"
            warn "openclaw-gateway health check timed out"
        fi
    fi
fi

# =============================================================================
hdr "6 · Integration Verification"
# =============================================================================
# The lifespan hooks are async and may still be completing.  Retry up to 3 times
# with a 15s pause so transient startup races don't produce false failures.

set +e

VERIFY_PASS=false
for attempt in 1 2 3; do
    [ "$attempt" -gt 1 ] && { info "Retry $attempt/3 — waiting 15s for hooks to complete..."; sleep 15; }

    RE_MACHINES=$(curl -sk https://localhost:3000/api/machines 2>/dev/null \
        || echo '{"machines":[]}')
    MACHINE_LABELS=$(echo "$RE_MACHINES" | python3 -c "
import json, sys
ms = json.load(sys.stdin).get('machines', [])
for m in ms: print(m.get('id','') + ' ' + m.get('name',''))
" 2>/dev/null || echo "")

    PE_SOURCES=$(curl -sk https://localhost:3004/api/sources 2>/dev/null \
        || echo '{"sources":[]}')
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
        VERIFY_PASS=true
        break
    fi
done

# ── RE machines ────────────────────────────────────────────────────────────
info "RE machine registrations..."
TOTAL_MACHINES=$(echo "$RE_MACHINES" | python3 -c \
    "import json,sys; print(len(json.load(sys.stdin).get('machines',[])))" \
    2>/dev/null || echo "0")

if [ "$HAS_RAG" = "true" ]; then
    ok "Machine registered: rag_corrective_cycle"
else
    add_warn "rag_corrective_cycle machine not in RE — RAG routing decisions will not flow into perceptual space"
    warn "Machine NOT registered: rag_corrective_cycle"
fi
if [ "$HAS_SESS_RAG" = "true" ]; then
    ok "Machine registered: session_rag_context"
else
    add_warn "session_rag_context machine not in RE — session state carry will not work"
    warn "Machine NOT registered: session_rag_context"
fi
if [ "$HAS_SESS_AGT" = "true" ]; then
    ok "Machine registered: session_agent_context"
else
    add_warn "session_agent_context machine not in RE — agent session carry will not work"
    warn "Machine NOT registered: session_agent_context"
fi
ok "Total machines in RE: $TOTAL_MACHINES"

# ── PE sensor sources ──────────────────────────────────────────────────────
info "PE sensor registrations..."
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
    add_warn "No sensor sources in PE — localAIStack lifespan hooks may have failed (docker logs localai_api)"
    warn "No sensor sources registered in PE"
fi

# Verify the RAG signal regions [64:72] are covered
RAG_COVERED=$(echo "$PE_SOURCES" | python3 -c "
import json, sys
offsets=[s.get('region',{}).get('offset') for s in json.load(sys.stdin).get('sources',[]) if s.get('type')=='sensor']
print('true' if 64 in offsets or 68 in offsets else 'false')
" 2>/dev/null || echo "false")
if [ "$RAG_COVERED" = "true" ]; then
    ok "RAG signal regions [64:72] mapped"
else
    add_warn "RAG signal regions [64:72] not mapped — RAG routing will not update perceptual state"
    warn "RAG signal regions [64:72] not found in sensor sources"
fi

# ── Qdrant collections ─────────────────────────────────────────────────────
info "Qdrant collections..."
QDRANT_COLLS=$(curl -sf http://localhost:4333/collections 2>/dev/null || echo '{}')
COLL_LIST=$(echo "$QDRANT_COLLS" | python3 -c \
    "import json,sys; print([c['name'] for c in json.load(sys.stdin).get('result',{}).get('collections',[])])" \
    2>/dev/null || echo "[]")

for coll in "localai_docs" "reality-vectors"; do
    if echo "$COLL_LIST" | grep -q "$coll"; then
        ok "Qdrant collection: $coll"
    else
        add_warn "Qdrant collection '$coll' not yet created (auto-created on first use)"
        info "Qdrant '$coll': will be created on first document ingest / perceive call"
    fi
done

if [ "$VERIFY_PASS" = "false" ]; then
    add_warn "Integration hooks did not complete within 3 attempts — run:  (cd $LAS_DIR && docker compose restart api)"
fi

set -e

# =============================================================================
hdr "7 · Operability"
# =============================================================================

set +e

# ── RE perceive smoke-test ─────────────────────────────────────────────────
SMOKE_DIM="${VECTOR_DIMENSION:-768}"
info "RE perceive smoke-test (${SMOKE_DIM}-element zero vector)..."
ZERO_VEC=$(python3 -c "import json; print(json.dumps([0.0]*${SMOKE_DIM}))" 2>/dev/null || echo "")
if [ -n "$ZERO_VEC" ]; then
    PERCEIVE_RESP=$(curl -sk -X POST https://localhost:3000/api/perceive \
        -H "Content-Type: application/json" \
        -d "{\"vector\": $ZERO_VEC}" \
        --max-time 15 2>/dev/null || echo "")
    if [ -n "$PERCEIVE_RESP" ]; then
        PERCEIVE_INFO=$(echo "$PERCEIVE_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
# SimulationStep is returned directly (not nested under 'step')
step = d.get('step', d)
results = step.get('machineResults', {})
n = len(results) if isinstance(results, dict) else '?'
ps = step.get('perceptualSpace', [])
nz = sum(1 for v in ps if v != 0.0) if ps else 0
print(f'machines_evaluated={n}, non-zero_perceptual_elements={nz}')
" 2>/dev/null || echo "response received")
        ok "RE perceive: $PERCEIVE_INFO"
    else
        add_warn "RE perceive returned no response — check:  docker logs reality-engine-app"
        warn "RE perceive: no response"
    fi
else
    warn "python3 unavailable — skipping RE perceive smoke-test"
fi

# ── localAIStack RAG readiness ─────────────────────────────────────────────
info "localAIStack RAG readiness..."
LAS_HEALTH=$(curl -sf http://localhost:4000/health --max-time 5 2>/dev/null || echo "")
if [ -n "$LAS_HEALTH" ]; then
    LAS_STATUS=$(echo "$LAS_HEALTH" | python3 -c \
        "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" \
        2>/dev/null || echo "unknown")
    if [ "$LAS_STATUS" = "ok" ]; then
        ok "localAIStack API: all services healthy"
    else
        add_warn "localAIStack API status: $LAS_STATUS (some sub-services may be unavailable)"
        warn "localAIStack API status: $LAS_STATUS"
    fi
else
    add_warn "localAIStack API health endpoint not responding"
    warn "localAIStack API: no response from /health"
fi

# ── Integration path smoke-test ────────────────────────────────────────────
# Write a test signal to the localai_rag_retrieval sensor in PE.
# A successful write confirms the full signal path is live:
#   localAIStack graph node → PE sensor write → perceptual space update
info "Integration path smoke-test (sensor write → PE)..."
SENSOR_WRITE=$(curl -sk -X POST https://localhost:3004/api/sensors/localai_rag_retrieval \
    -H "Content-Type: application/json" \
    -d '{"values": [2.0, 0.85, 0.0, 0.0]}' \
    --max-time 5 2>/dev/null || echo "")
if echo "$SENSOR_WRITE" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') or d.get('id') or d.get('success') or d.get('updated') else 1)" \
    2>/dev/null; then
    ok "Integration path: sensor write accepted by PE"
elif [ -n "$SENSOR_WRITE" ]; then
    add_warn "Sensor write returned unexpected response — sensor may not be registered yet"
    warn "Sensor write: $(echo "$SENSOR_WRITE" | head -c 120)"
else
    add_warn "Sensor write returned no response — run a RAG query first to trigger sensor registration"
    info "Sensor 'localai_rag_retrieval' registers on first localAIStack RAG query"
fi

set -e

# =============================================================================
hdr "8 · Summary"
# =============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Universe Running"
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
printf "    %-30s %s\n" "API key"                   "OPENCLAW_GATEWAY_TOKEN in $OCS_DIR/.env"
echo ""
fi
echo "  RealityEngine"
printf "    %-30s %s\n" "API"                       "https://localhost:3000"
printf "    %-30s %s\n" "Visualizer"                "https://localhost:5173"
printf "    %-30s %s\n" "Perception Engine API"     "https://localhost:3004"
printf "    %-30s %s\n" "Perception Engine UI"      "https://localhost:3005"
printf "    %-30s %s\n" "Grafana (RE Logs)"         "https://localhost:3002"
echo ""
echo "  Note: RE endpoints use a self-signed TLS cert (browser will warn)"
echo "        Silence it:  bash $RE_DIR/certs/generate-dev-certs.sh"
echo ""

if [ "${#WARNS[@]}" -gt 0 ]; then
    echo "════════════════════════════════════════════════════════════════════"
    printf "  ${YELLOW}Integration Warnings${NC}  (%d)\n" "${#WARNS[@]}"
    echo "════════════════════════════════════════════════════════════════════"
    for w in "${WARNS[@]}"; do warn "  $w"; done
    echo ""
    echo "  To re-trigger localAIStack integration hooks:"
    echo "    (cd $LAS_DIR && docker compose restart api)"
    echo ""
    echo "  Then verify:"
    echo "    # Machines (should include rag_corrective_cycle, session_*)"
    echo "    curl -sk https://localhost:3000/api/machines | python3 -c \\"
    echo "      \"import json,sys; [print(m['id']) for m in json.load(sys.stdin)['machines'] if any(k in m['id'] for k in ['rag','session'])]\""
    echo ""
    echo "    # Sensor sources (should show type=sensor entries)"
    echo "    curl -sk https://localhost:3004/api/sources | python3 -c \\"
    echo "      \"import json,sys; [print(s['name'],s['region']) for s in json.load(sys.stdin)['sources'] if s['type']=='sensor']\""
    echo ""
else
    echo "════════════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Integration verified — all systems nominal${NC}"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
fi
