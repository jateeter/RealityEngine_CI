#!/bin/bash
# =============================================================================
# stopUniverse.sh — CI companion to startUniverse.sh
#
# Reads .universe-engine-selection stamped by startUniverse.sh and stops
# the correct engine stack.  Pass --all to tear down every engine at once.
#
# Usage:
#   ./stopUniverse.sh [--re-engine=ai|cpp|lsp] [--pe-engine=ai|cpp|lsp]
#                     [--all]
#                     [--instance=<id>]   stop one registry instance by id
#                     [--engines-only]    stop all native instances; leave Docker up
#                     [--stop-docker]     also run docker compose down for all stacks
#                                         (default: Docker containers are left running)
#                     [--help]
# =============================================================================
set -e
set -o pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAS_DIR="$CI_DIR/../localAIStack"
CPP_DIR="$CI_DIR/../RealityEngine_CPP"
LSP_DIR="$CI_DIR/../RealityEngine_LSP"
OCS_DIR="$CI_DIR/../localOpenClawStack"
MCP_HTTP_PID_FILE="${MCP_HTTP_PID_FILE:-/tmp/realityengine-mcp-http.pid}"
OPENAPI_SWAGGER_PID_FILE="${OPENAPI_SWAGGER_PID_FILE:-/tmp/realityengine-openapi-swagger.pid}"
BRIDGE_METRICS_PID_FILE="${BRIDGE_METRICS_PID_FILE:-/tmp/realityengine-bridge-metrics.pid}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}ℹ${NC} $*"; }
warn() { echo -e "${RED}⚠${NC} $*"; }

RE_ENGINE=""
PE_ENGINE=""
STOP_ALL=false
STOP_INSTANCE=""
ENGINES_ONLY=false
STOP_DOCKER=false   # default: leave Docker containers running

for arg in "$@"; do
  case "$arg" in
    --re-engine=*)   RE_ENGINE="${arg#*=}" ;;
    --pe-engine=*)   PE_ENGINE="${arg#*=}" ;;
    --all)           STOP_ALL=true ;;
    --instance=*)    STOP_INSTANCE="${arg#*=}" ;;
    --engines-only)  ENGINES_ONLY=true ;;
    --stop-docker)   STOP_DOCKER=true ;;
    --help|-h)
      cat <<'USAGE'
Usage: ./stopUniverse.sh [--re-engine=ai|cpp|lsp] [--pe-engine=ai|cpp|lsp]
                         [--all] [--instance=<id>] [--engines-only]
                         [--stop-docker]

Without flags, reads .universe-engine-selection and stops the engines recorded
there.  --all tears down every engine regardless of the stamp.
--instance=<id>  Stop one specific registry instance (e.g. scala-1, cpp-2)
--engines-only   Stop all native engine instances; leave Docker infrastructure up
--stop-docker    Also run docker compose down for all stacks (CI, localAIStack,
                 OpenClaw). Default is to leave Docker containers running so that
                 Docker Desktop remains stable across repeated test cycles.
USAGE
      exit 0 ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

# Read the stamp written by startUniverse.sh
STAMPED_RE_ENGINE=""
STAMPED_PE_ENGINE=""
STAMPED_ENGINES=""
STAMPED_MULTI_ENGINE_MODE="false"
STAMPED_OPENCLAW="auto"
STAMPED_OCS_NATIVE_UNLOADED="false"
if [ -f "$CI_DIR/.universe-engine-selection" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      RE_ENGINE)           STAMPED_RE_ENGINE="$v" ;;
      PE_ENGINE)           STAMPED_PE_ENGINE="$v" ;;
      ENGINES)             STAMPED_ENGINES="$v" ;;
      MULTI_ENGINE_MODE)   STAMPED_MULTI_ENGINE_MODE="$v" ;;
      OPENCLAW)            STAMPED_OPENCLAW="$v" ;;
      OCS_NATIVE_UNLOADED) STAMPED_OCS_NATIVE_UNLOADED="$v" ;;
    esac
  done < "$CI_DIR/.universe-engine-selection"
fi
RE_ENGINE="${RE_ENGINE:-${STAMPED_RE_ENGINE:-ai}}"
PE_ENGINE="${PE_ENGINE:-${STAMPED_PE_ENGINE:-ai}}"

# Source registry helpers for multi-engine teardown
REGISTRY_FILE="/tmp/re-registry/re-registry.json"
[ -f "$CI_DIR/scripts/registry.sh" ] && source "$CI_DIR/scripts/registry.sh" || true

# startUniverse.sh sources .env *after* defaulting the port bases, so .env wins
# and the engines bind where it says. Teardown never read it, so it swept the
# defaults instead: on a host that sets SCALA_PE_BASE=5100 — which .env.example
# recommends, to dodge macOS AirPlay on 5000 — this swept 5000/5001, warned that
# AirPlay held a port it had no business touching, and left the actual Scala
# engine running on 5100/5101 for the next start to collide with.
# shellcheck source=/dev/null
[ -f "$CI_DIR/.env" ] && source "$CI_DIR/.env" || true

_term_and_wait() {
  local pid="$1" label="$2"
  [ -z "$pid" ] && return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    info "$label (PID $pid) already exited"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 1; waited=$((waited+1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "$label (PID $pid) did not exit after ${waited}s — sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.5
  fi
}

# Kill any process still listening on the given port (last-resort cleanup).
# Used after normal stop sequences to ensure ports are free for the next start.
_kill_port() {
  local port="$1"
  local pid pcmd
  pid=$(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null | head -1 || true)
  [ -z "$pid" ] && return 0
  # Never force-kill protected processes (issue #41). The Docker daemon/proxy
  # (com.docker.backend) holds *published container ports* (e.g. 5001) on behalf
  # of containers; killing it crashes Docker Desktop and corrupts the container
  # store, leaving unremovable ghost containers. macOS Control Center holds :5000
  # (AirPlay). Stop the owning container/app instead of nuking the port holder.
  pcmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
  case "$pcmd" in
    *com.docker*|*Docker.app*|*ControlCenter*)
      warn "Port $port held by protected process (PID $pid: ${pcmd%% *}) — NOT killing; stop the owning container/app instead"
      return 0 ;;
  esac
  warn "Port $port still held by PID $pid after stop — force-killing"
  kill -KILL "$pid" 2>/dev/null || true
}

_stop_pid_file() {
  local pid_file="$1" label="$2"
  [ -f "$pid_file" ] || return 0
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    _term_and_wait "$pid" "$label"
    ok "$label stopped"
  fi
  rm -f "$pid_file"
}

stop_api_surface_services() {
  _stop_pid_file "$MCP_HTTP_PID_FILE" "MCP HTTP gateway"
  _stop_pid_file "$OPENAPI_SWAGGER_PID_FILE" "OpenAPI Swagger portal"
  _stop_pid_file "$BRIDGE_METRICS_PID_FILE" "AI bridge metrics exporter"
}

# Sweep all native engine ports and kill any survivors.
_sweep_native_ports() {
  local _cpp_re=$(( ${CPP_PE_BASE:-5300} + 1 ))
  local _cpp_pe=${CPP_PE_BASE:-5300}
  local _lsp_re=$(( ${LSP_PE_BASE:-5600} + 1 ))
  local _lsp_pe=${LSP_PE_BASE:-5600}
  local _sc_re=$(( ${SCALA_PE_BASE:-5000} + 1 ))
  local _sc_pe=${SCALA_PE_BASE:-5000}
  # The registry shim outlives the engines it advertises: it is a bare
  # python3 http.server, so nothing in the engine teardown reaches it and the
  # next start finds :5999 already bound.
  for _p in $_cpp_re $_cpp_pe $_lsp_re $_lsp_pe $_sc_re $_sc_pe "${REGISTRY_PORT:-5999}"; do
    _kill_port "$_p"
  done
}

stop_instance() {
  local id="$1"
  local entry
  if ! entry=$(registry_get "$id" 2>/dev/null); then
    warn "Instance '$id' not in registry — attempting PID file fallback"
    local pid_re_file="/tmp/re-${id}.pid" pid_pe_file="/tmp/pe-${id}.pid"
    if [ -f "$pid_re_file" ]; then
      _term_and_wait "$(cat "$pid_re_file" 2>/dev/null || true)" "$id RE"
    fi
    if [ -f "$pid_pe_file" ]; then
      _term_and_wait "$(cat "$pid_pe_file" 2>/dev/null || true)" "$id PE"
    fi
    return
  fi
  local pid_re pid_pe
  pid_re=$(echo "$entry" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pid_re') or '')" 2>/dev/null || true)
  pid_pe=$(echo "$entry" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pid_pe') or '')" 2>/dev/null || true)
  _term_and_wait "$pid_pe" "$id PE"
  _term_and_wait "$pid_re" "$id RE"
  registry_remove "$id" 2>/dev/null || true
  ok "Stopped instance: $id"
}

stop_all_engines() {
  if [ ! -f "$REGISTRY_FILE" ]; then
    info "No registry found — no native instances to stop"
    return
  fi
  info "Stopping all registered native engine instances..."
  while IFS= read -r _id; do
    stop_instance "$_id"
  done < <(registry_ids 2>/dev/null)
  registry_stop_server 2>/dev/null || true
  rm -f "$REGISTRY_FILE"
  ok "All native instances stopped"
}

stop_openclaw_stack() {
  local stamp="${1:-auto}" native_unloaded="${2:-false}"
  if [ "$stamp" = "no" ]; then
    info "OpenClaw: was not started — skipping"
  elif [ "$STOP_DOCKER" = true ] && [ -d "$OCS_DIR" ] && [ -f "$OCS_DIR/docker-compose.yml" ]; then
    info "Stopping OpenClaw stack..."
    (cd "$OCS_DIR" && docker compose down 2>/dev/null) || warn "OpenClaw compose down returned non-zero"
    ok "OpenClaw stopped"
  elif [ "$STOP_DOCKER" = false ]; then
    info "OpenClaw: leaving Docker containers running (use --stop-docker to tear down)"
  else
    info "OpenClaw: not found at $OCS_DIR — nothing to stop"
  fi
  if [ "$native_unloaded" = "true" ]; then
    local _plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    if [ -f "$_plist" ]; then
      info "Reloading native openclaw-gateway (launchd)..."
      launchctl load "$_plist" 2>/dev/null || warn "launchctl load returned non-zero"
      ok "Native openclaw-gateway restored"
    else
      warn "Native openclaw-gateway plist not found — cannot restore"
    fi
  fi
}

stop_native_engine() {
  local engine_dir="$1" engine_name="$2"
  if [ -x "$engine_dir/stop.sh" ]; then
    info "Stopping $engine_name engine via $engine_dir/stop.sh..."
    (cd "$engine_dir" && ./stop.sh) || warn "$engine_name stop.sh returned non-zero"
    ok "$engine_name engine stopped"
  else
    warn "$engine_dir/stop.sh missing or not executable — skipping"
  fi
}

stop_manager_native() {
  if [ -f /tmp/manager_universe.pid ]; then
    local pid; pid="$(cat /tmp/manager_universe.pid 2>/dev/null || true)"
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
      info "Stopping Manager native process (PID $pid)..."
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      ok "Manager native stopped"
    fi
    rm -f /tmp/manager_universe.pid
  fi
  # Also delegate to Manager's own stop.sh if it exists
  if [ -d "$CI_DIR/../RealityEngine_Manager" ] && \
     [ -x "$CI_DIR/../RealityEngine_Manager/stop.sh" ]; then
    info "Running RealityEngine_Manager/stop.sh..."
    (cd "$CI_DIR/../RealityEngine_Manager" && ./stop.sh 2>/dev/null) || true
  fi
}

stop_ai_stack() {
  stop_api_surface_services
  stop_openclaw_stack "$STAMPED_OPENCLAW" "$STAMPED_OCS_NATIVE_UNLOADED"
  stop_manager_native

  if [ "$STOP_DOCKER" = true ]; then
    info "Stopping RealityEngine CI Docker stack..."
    if [ -f "$CI_DIR/docker-compose.yml" ]; then
      (cd "$CI_DIR" && docker compose down 2>/dev/null) || warn "CI compose down returned non-zero"
      ok "CI compose down complete"
    fi

    info "Stopping localAIStack..."
    if [ -d "$LAS_DIR" ] && [ -f "$LAS_DIR/docker-compose.yml" ]; then
      (cd "$LAS_DIR" && docker compose down 2>/dev/null) || warn "localAIStack compose down returned non-zero"
      ok "localAIStack stopped"
    fi
  else
    info "Docker stacks: leaving containers running (use --stop-docker to tear down)"
  fi

  # Stop Ollama only if startUniverse.sh started it (PID file present)
  if [ -f /tmp/ollama_universe.pid ]; then
    local pid; pid="$(cat /tmp/ollama_universe.pid 2>/dev/null || true)"
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
      kill -TERM "$pid" 2>/dev/null || true
      ok "Ollama stopped (PID $pid)"
    fi
    rm -f /tmp/ollama_universe.pid
  fi
}

# ── Manifest cross-check (Phase 6 observability) ──────────────────────────────
MANIFEST="/tmp/universe-manifest.json"
if [ -f "$MANIFEST" ]; then
  _m_started=$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('started_at','?'))" 2>/dev/null || echo "?")
  _m_ollama=$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('ollama_started_by_universe', False))" 2>/dev/null || echo "False")
  info "Manifest: universe started at $_m_started"
  # Warn if manifest shows openclaw_started but container is gone
  _m_ocs=$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('openclaw_started', False))" 2>/dev/null || echo "False")
  if [ "$_m_ocs" = "True" ] && ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "openclaw-gateway"; then
    info "Manifest: openclaw_started=True but container not running (may already be stopped)"
  fi
fi

echo "════════════════════════════════════════════════════════════════════"
echo "  Universe Teardown  [RealityEngine_CI]"
echo "════════════════════════════════════════════════════════════════════"
info "Engine selection: RE_ENGINE=$RE_ENGINE  PE_ENGINE=$PE_ENGINE  --all=$STOP_ALL"
[ -n "$STOP_INSTANCE" ] && info "  --instance=$STOP_INSTANCE"
[ "$ENGINES_ONLY" = true ] && info "  --engines-only"
echo ""

# ── Per-instance stop ──────────────────────────────────────────────────────
if [ -n "$STOP_INSTANCE" ]; then
  stop_instance "$STOP_INSTANCE"
  echo ""
  ok "Instance $STOP_INSTANCE stopped"
  # Only remove the stamp when the registry is fully empty; leave it while other instances remain
  _remaining=$(registry_ids 2>/dev/null | grep -c . || echo 0)
  if [ "$_remaining" -eq 0 ]; then
    rm -f "$CI_DIR/.universe-engine-selection"
    ok "All instances stopped — stamp removed"
  else
    info "$_remaining instance(s) still registered — stamp retained for remaining teardown"
  fi
  exit 0
fi

# ── Engines-only: stop all native instances, leave Docker up ───────────────
if [ "$ENGINES_ONLY" = true ]; then
  stop_api_surface_services
  stop_all_engines
  _sweep_native_ports
  rm -f "$CI_DIR/.universe-engine-selection"
  echo ""
  ok "Native engine instances stopped (Docker infrastructure still running)"
  exit 0
fi

# ── Full teardown ──────────────────────────────────────────────────────────

# Stop any native multi-engine instances first (if --engines= was used)
if [ "$STAMPED_MULTI_ENGINE_MODE" = "true" ] || [ "$STOP_ALL" = true ]; then
  stop_all_engines
fi

if [ "$STOP_ALL" = true ]; then
  stop_native_engine "$CPP_DIR" "CPP"
  stop_native_engine "$LSP_DIR" "LSP"
  stop_ai_stack
else
  need_ai=false; need_cpp=false; need_lsp=false
  for engine in "$RE_ENGINE" "$PE_ENGINE"; do
    case "$engine" in
      ai)  need_ai=true ;;
      cpp) need_cpp=true ;;
      lsp) need_lsp=true ;;
    esac
  done
  $need_cpp && stop_native_engine "$CPP_DIR" "CPP"
  $need_lsp && stop_native_engine "$LSP_DIR" "LSP"
  $need_ai  && stop_ai_stack
  # Multi-engine mode uses Docker only for infrastructure
  [ "$STAMPED_MULTI_ENGINE_MODE" = "true" ] && stop_ai_stack
fi

_sweep_native_ports

rm -f "$CI_DIR/.universe-engine-selection"
echo ""
ok "Universe shutdown complete"
