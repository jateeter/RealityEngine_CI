#!/bin/bash
# =============================================================================
# stopUniverse.sh — engine-aware companion to startUniverse.sh
#
# Reads the selection stamped in .universe-engine-selection at startup time
# and stops the right engine.  When the stamp is missing or specifies ai
# (the default), the AI Docker stack is torn down; when it specifies cpp
# or lsp, that runtime's stop.sh is called instead.
#
# Usage:  ./stopUniverse.sh [--re-engine=ai|cpp|lsp] [--pe-engine=ai|cpp|lsp]
#                            [--all]      Tear down every engine regardless
#                                         of the stamp (useful after mixed runs)
#                            [--help]
# =============================================================================
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RE_DIR="$SCRIPT_DIR"
LAS_DIR="$SCRIPT_DIR/../localAIStack"
CPP_DIR="$SCRIPT_DIR/../RealityEngine_CPP"
LSP_DIR="$SCRIPT_DIR/../RealityEngine_LSP"
OCS_DIR="$SCRIPT_DIR/../localOpenClawStack"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}ℹ${NC} $*"; }
warn() { echo -e "${RED}⚠${NC} $*"; }

RE_ENGINE=""
PE_ENGINE=""
STOP_ALL=false
for arg in "$@"; do
  case "$arg" in
    --re-engine=*) RE_ENGINE="${arg#*=}" ;;
    --pe-engine=*) PE_ENGINE="${arg#*=}" ;;
    --all)         STOP_ALL=true ;;
    --help|-h)
      cat <<'USAGE'
Usage: ./stopUniverse.sh [--re-engine=ai|cpp|lsp] [--pe-engine=ai|cpp|lsp] [--all]

Without flags, reads .universe-engine-selection (stamped by startUniverse.sh)
and stops the engines listed there.  --all tears down everything regardless.
USAGE
      exit 0 ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

# Fall back to the stamped selection only when the operator didn't override
# via the CLI.  Parse the stamp file by hand instead of `source`ing it so
# CLI values (set before this point) aren't clobbered.
STAMPED_RE_ENGINE=""
STAMPED_PE_ENGINE=""
STAMPED_OPENCLAW="auto"
STAMPED_OCS_NATIVE_UNLOADED="false"
if [ -f "$RE_DIR/.universe-engine-selection" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      RE_ENGINE)           STAMPED_RE_ENGINE="$v" ;;
      PE_ENGINE)           STAMPED_PE_ENGINE="$v" ;;
      OPENCLAW)            STAMPED_OPENCLAW="$v" ;;
      OCS_NATIVE_UNLOADED) STAMPED_OCS_NATIVE_UNLOADED="$v" ;;
    esac
  done < "$RE_DIR/.universe-engine-selection"
fi
RE_ENGINE="${RE_ENGINE:-${STAMPED_RE_ENGINE:-ai}}"
PE_ENGINE="${PE_ENGINE:-${STAMPED_PE_ENGINE:-ai}}"

stop_openclaw_stack() {
  local stamp="${1:-auto}"
  local native_unloaded="${2:-false}"
  if [ "$stamp" = "no" ]; then
    info "OpenClaw: was not started — skipping"
  elif [ -d "$OCS_DIR" ] && [ -f "$OCS_DIR/docker-compose.yml" ]; then
    info "Stopping OpenClaw stack"
    (cd "$OCS_DIR" && docker compose down 2>/dev/null) || \
      warn "OpenClaw docker compose down returned non-zero"
    ok "OpenClaw compose down complete"
  else
    info "OpenClaw: not found at $OCS_DIR — nothing to stop"
  fi
  # Restore the native launchd service if startUniverse.sh unloaded it.
  if [ "$native_unloaded" = "true" ]; then
    local _plist="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    if [ -f "$_plist" ]; then
      info "Reloading native openclaw-gateway (launchd)..."
      launchctl load "$_plist" 2>/dev/null || warn "launchctl load returned non-zero"
      ok "Native openclaw-gateway restored"
    else
      warn "Native openclaw-gateway plist not found at $_plist — cannot restore"
    fi
  fi
}

stop_native_engine() {
  local engine_dir="$1" engine_name="$2"
  if [ -x "$engine_dir/stop.sh" ]; then
    info "Stopping $engine_name engine via $engine_dir/stop.sh"
    (cd "$engine_dir" && ./stop.sh) || warn "$engine_name stop.sh returned non-zero"
    ok "$engine_name engine stopped"
  else
    warn "$engine_dir/stop.sh missing or not executable — skipping"
  fi
}

stop_ai_stack() {
  stop_openclaw_stack "$STAMPED_OPENCLAW" "$STAMPED_OCS_NATIVE_UNLOADED"
  info "Stopping AI Docker stack"
  if [ -d "$RE_DIR" ] && [ -f "$RE_DIR/docker-compose.yml" ]; then
    (cd "$RE_DIR" && docker compose down 2>/dev/null) || warn "RE docker compose down returned non-zero"
    ok "RE compose down complete"
  fi
  if [ -d "$LAS_DIR" ] && [ -f "$LAS_DIR/docker-compose.yml" ]; then
    (cd "$LAS_DIR" && docker compose down 2>/dev/null) || warn "localAIStack docker compose down returned non-zero"
    ok "localAIStack compose down complete"
  fi
  # Ollama: stop only when started by us (PID file present)
  if [ -f /tmp/ollama_universe.pid ]; then
    local pid; pid="$(cat /tmp/ollama_universe.pid 2>/dev/null || true)"
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
      kill -TERM "$pid" 2>/dev/null || true
      ok "Ollama stopped (PID $pid)"
    fi
    rm -f /tmp/ollama_universe.pid
  fi
}

echo "════════════════════════════════════════════════════════════════════"
echo "  Universe Teardown"
echo "════════════════════════════════════════════════════════════════════"
info "Engine selection: RE_ENGINE=$RE_ENGINE  PE_ENGINE=$PE_ENGINE  (--all=$STOP_ALL)"
echo ""

if [ "$STOP_ALL" = true ]; then
  stop_native_engine "$CPP_DIR" "CPP"
  stop_native_engine "$LSP_DIR" "LSP"
  STAMPED_OCS_NATIVE_UNLOADED="${STAMPED_OCS_NATIVE_UNLOADED:-false}"
  stop_ai_stack
else
  # Dedup the engine set across RE and PE using plain flags so the script
  # works under bash 3.2 (macOS's system bash) — declare -A requires 4+.
  need_ai=false
  need_cpp=false
  need_lsp=false
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
fi

# Clear the selection stamp so the next start defaults fresh
rm -f "$RE_DIR/.universe-engine-selection"

echo ""
ok "Universe shutdown complete"
