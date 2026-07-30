#!/usr/bin/env bash
# =============================================================================
# statusUniverse.sh — live diff between what was started and what is running
#
# Reads .universe-engine-selection and /tmp/re-registry/re-registry.json,
# polls all known health endpoints, and prints a status table.
#
# Exit codes:
#   0   all stamped services are healthy
#   1   one or more stamped services are unhealthy or unreachable
#   2   no stamp found (universe not started via startUniverse.sh)
#
# Usage:
#   ./statusUniverse.sh [--json] [--quiet]
# =============================================================================
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAS_DIR="$CI_DIR/../localAIStack"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

JSON_OUT=false
QUIET=false
for arg in "$@"; do
  case "$arg" in
    --json)  JSON_OUT=true ;;
    --quiet) QUIET=true ;;
    --help|-h)
      echo "Usage: ./statusUniverse.sh [--json] [--quiet]"
      echo "  --json    Output JSON instead of table"
      echo "  --quiet   Suppress table; exit code only"
      exit 0 ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

# ── Read stamp ────────────────────────────────────────────────────────────────
STAMP="$CI_DIR/.universe-engine-selection"
if [ ! -f "$STAMP" ]; then
  [ "$QUIET" = false ] && echo "No .universe-engine-selection found — universe not started" >&2
  exit 2
fi

STAMPED_RE_ENGINE="ai"; STAMPED_PE_ENGINE="ai"
STAMPED_ENGINES=""; STAMPED_MULTI_ENGINE_MODE="false"
STAMPED_OPENCLAW="auto"; STAMPED_STARTED_AT=""
while IFS='=' read -r k v; do
  case "$k" in
    RE_ENGINE)         STAMPED_RE_ENGINE="$v" ;;
    PE_ENGINE)         STAMPED_PE_ENGINE="$v" ;;
    ENGINES)           STAMPED_ENGINES="$v" ;;
    MULTI_ENGINE_MODE) STAMPED_MULTI_ENGINE_MODE="$v" ;;
    OPENCLAW)          STAMPED_OPENCLAW="$v" ;;
    STARTED_AT)        STAMPED_STARTED_AT="$v" ;;
  esac
done < "$STAMP"

# ── Source registry helpers (for multi-engine mode) ───────────────────────────
REGISTRY_FILE="/tmp/re-registry/re-registry.json"
[ -f "$CI_DIR/scripts/registry.sh" ] && source "$CI_DIR/scripts/registry.sh" || true

# ── Health probe ──────────────────────────────────────────────────────────────
_health() {
  local url="$1"
  [ -z "$url" ] && { echo "n/a"; return; }
  if curl -skf --max-time 3 "$url" >/dev/null 2>&1; then echo "ok"
  else echo "FAIL"; fi
}

_container_health() {
  local container="$1" url="$2"
  local status
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || echo "")
  if { [ "$status" = "healthy" ] || [ "$status" = "running" ]; } && curl -skf --max-time 3 "$url" >/dev/null 2>&1; then echo "ok"
  else echo "FAIL"; fi
}

_container_health_status() {
  local container="$1"
  local status
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || echo "")
  [ "$status" = "healthy" ] || [ "$status" = "running" ] && echo "ok" || echo "FAIL"
}

# ── Collect service rows ──────────────────────────────────────────────────────
declare -a ROWS   # "engine|id|stamped|registry|health|ports"
OVERALL=0

_add_row() {
  local engine="$1" id="$2" stamped="$3" in_reg="$4" health="$5" ports="$6"
  ROWS+=("${engine}|${id}|${stamped}|${in_reg}|${health}|${ports}")
  [ "$health" = "ok" ] || [ "$health" = "n/a" ] || OVERALL=1
}

# Docker / fixed services (always stamped in non-multi mode)
if [ "$STAMPED_MULTI_ENGINE_MODE" = "false" ]; then
  _add_row "Docker RE"  "—" "✓" "n/a" "$(_health https://localhost:5001/api/health)" ":5001"
  _add_row "Docker PE"  "—" "✓" "n/a" "$(_health https://localhost:3004/api/health)" ":3004"
  _add_row "Visualizer" "—" "✓" "n/a" "$(_health https://localhost:5173/)"           ":5173"
fi

# Infrastructure (always expected)
_add_row "Grafana"     "—" "✓" "n/a" "$(_container_health reality-engine-grafana http://localhost:3002/api/health)" ":3002"
_add_row "Prometheus"  "—" "✓" "n/a" "$(_container_health reality-engine-prometheus http://localhost:9090/-/ready)" ":9090"
_add_row "Bridge Met." "—" "✓" "n/a" "$(_health http://localhost:7342/healthz)"    ":7342"
_add_row "Loki"        "—" "✓" "n/a" "$(_health https://localhost:3100/ready)"      ":3100"
_add_row "Qdrant"      "—" "✓" "n/a" "$(_health http://localhost:4333/collections)" ":4333"
_add_row "Ollama"      "—" "✓" "n/a" "$(_health http://localhost:11434/api/tags)"   ":11434"
_add_row "LAS API"     "—" "✓" "n/a" "$(_container_health_status localai_api)"       ":4000"

# Multi-engine native instances
if [ "$STAMPED_MULTI_ENGINE_MODE" = "true" ] && [ -f "$REGISTRY_FILE" ]; then
  while IFS= read -r _si_id; do
    _si_entry=$(registry_get "$_si_id" 2>/dev/null || echo "{}")
    _si_rt=$(echo "$_si_entry"   | python3 -c "import json,sys; print(json.load(sys.stdin).get('runtime','?'))" 2>/dev/null || echo "?")
    _si_re_url=$(echo "$_si_entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('re_url',''))"  2>/dev/null || echo "")
    _si_pe_url=$(echo "$_si_entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pe_url',''))"  2>/dev/null || echo "")
    _si_re_port=$(echo "$_si_entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('re_port','?'))" 2>/dev/null || echo "?")
    _si_pe_port=$(echo "$_si_entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pe_port','?'))" 2>/dev/null || echo "?")
    _si_re_h=$(_health "$_si_re_url/api/health")
    _si_pe_h=$(_health "$_si_pe_url/api/health")
    _add_row "$_si_rt" "$_si_id" "✓" "✓" "$_si_re_h" "RE:${_si_re_port}"
    _add_row "$_si_rt" "${_si_id}-pe" "✓" "✓" "$_si_pe_h" "PE:${_si_pe_port}"
  done < <(registry_ids 2>/dev/null || true)
elif [ "$STAMPED_MULTI_ENGINE_MODE" = "true" ] && [ ! -f "$REGISTRY_FILE" ]; then
  _add_row "registry" "—" "✓" "MISSING" "FAIL" ":5999"
  OVERALL=1
fi

# OpenClaw
if [ "$STAMPED_OPENCLAW" != "no" ] && [ -d "$CI_DIR/../localOpenClawStack" ]; then
  _ocs_gw_port=18789
  [ -f "$CI_DIR/../localOpenClawStack/.env" ] && {
    _p=$(grep -E '^OPENCLAW_GATEWAY_PORT=' "$CI_DIR/../localOpenClawStack/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$_p" ] && _ocs_gw_port="$_p"
  }
  _ocs_h=$(_health "http://localhost:${_ocs_gw_port}/healthz")
  _add_row "OpenClaw" "gateway" "auto" "n/a" "$_ocs_h" ":${_ocs_gw_port}"
fi

# ── Manifest cross-check ──────────────────────────────────────────────────────
MANIFEST="/tmp/universe-manifest.json"
MANIFEST_NOTE=""
if [ -f "$MANIFEST" ]; then
  _m_started=$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('started_at','?'))" 2>/dev/null || echo "?")
  MANIFEST_NOTE="  Manifest started_at: $_m_started"
fi

# ── Output ────────────────────────────────────────────────────────────────────
if [ "$JSON_OUT" = true ]; then
  python3 - "$MANIFEST" "${ROWS[@]}" <<'PYEOF'
import json, sys
rows = []
manifest_path = sys.argv[1]
manifest = {}
try:
    with open(manifest_path) as f:
        manifest = json.load(f)
except Exception:
    manifest = {}
for r in sys.argv[2:]:
    parts = r.split("|")
    rows.append({"engine": parts[0], "id": parts[1], "stamped": parts[2],
                 "registry": parts[3], "health": parts[4], "ports": parts[5]})
print(json.dumps({
    "services": rows,
    "manifest": {
        "path": manifest_path,
        "started_at": manifest.get("started_at", ""),
        "mcp_http_url": manifest.get("mcp_http_url", ""),
        "openai_mcp_profile": manifest.get("openai_mcp_profile", {"status": "not-run"})
    }
}, indent=2))
PYEOF
  exit "$OVERALL"
fi

if [ "$QUIET" = true ]; then
  exit "$OVERALL"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
printf "  ${CYAN}${BOLD}Universe Status${NC}  [started: %s]\n" "${STAMPED_STARTED_AT:-unknown}"
echo "════════════════════════════════════════════════════════════════════"
printf "  %-14s %-18s %-9s %-10s %-8s %s\n" "Engine" "ID" "Stamped" "Registry" "Health" "Ports"
echo "  ─────────────────────────────────────────────────────────────────"
for row in "${ROWS[@]}"; do
  IFS='|' read -r _r_engine _r_id _r_stamp _r_reg _r_health _r_ports <<< "$row"
  if [ "$_r_health" = "ok" ] || [ "$_r_health" = "n/a" ]; then
    _r_hcol="${GREEN}${_r_health}${NC}"
  else
    _r_hcol="${RED}${_r_health}${NC}"
  fi
  printf "  %-14s %-18s %-9s %-10s ${_r_hcol}%-3s %s\n" \
    "$_r_engine" "$_r_id" "$_r_stamp" "$_r_reg" "" "$_r_ports"
done
echo ""
[ -n "$MANIFEST_NOTE" ] && echo "$MANIFEST_NOTE"
if [ "$OVERALL" -eq 0 ]; then
  echo -e "  ${GREEN}All services healthy${NC}"
else
  echo -e "  ${RED}One or more services unhealthy — see FAIL rows above${NC}"
fi
echo ""
exit "$OVERALL"
