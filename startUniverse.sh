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
CI_INTEGRATIONS_CONFIG="$CI_DIR/config/integrations.json"
CI_INTEGRATIONS_EXAMPLE="$CI_DIR/config/integrations.example.json"
MCP_HTTP_ENABLED="${MCP_HTTP_ENABLED:-true}"
OPENAPI_SWAGGER_ENABLED="${OPENAPI_SWAGGER_ENABLED:-true}"
RE_MCP_HTTP_HOST="${RE_MCP_HTTP_HOST:-127.0.0.1}"
RE_MCP_HTTP_PORT="${RE_MCP_HTTP_PORT:-7331}"
OPENAPI_SWAGGER_HOST="${OPENAPI_SWAGGER_HOST:-127.0.0.1}"
OPENAPI_SWAGGER_PORT="${OPENAPI_SWAGGER_PORT:-8088}"
MCP_HTTP_PID_FILE="${MCP_HTTP_PID_FILE:-/tmp/realityengine-mcp-http.pid}"
MCP_HTTP_LOG_FILE="${MCP_HTTP_LOG_FILE:-/tmp/realityengine-mcp-http.log}"
OPENAPI_SWAGGER_PID_FILE="${OPENAPI_SWAGGER_PID_FILE:-/tmp/realityengine-openapi-swagger.pid}"
OPENAPI_SWAGGER_LOG_FILE="${OPENAPI_SWAGGER_LOG_FILE:-/tmp/realityengine-openapi-swagger.log}"
BRIDGE_METRICS_HOST="${BRIDGE_METRICS_HOST:-0.0.0.0}"
BRIDGE_METRICS_PORT="${BRIDGE_METRICS_PORT:-7342}"
BRIDGE_METRICS_PID_FILE="${BRIDGE_METRICS_PID_FILE:-/tmp/realityengine-bridge-metrics.pid}"
BRIDGE_METRICS_LOG_FILE="${BRIDGE_METRICS_LOG_FILE:-/tmp/realityengine-bridge-metrics.log}"
BRIDGE_METRICS_LEDGER="${BRIDGE_METRICS_LEDGER:-/tmp/realityengine-openclaw-adapter-metrics.jsonl}"
PROMETHEUS_FILE_SD_DIR="${PROMETHEUS_FILE_SD_DIR:-/tmp/realityengine-prometheus-file-sd}"
MCP_HTTP_STARTED=false
OPENAPI_SWAGGER_STARTED=false
PROMETHEUS_STARTED=false
GRAFANA_STARTED=false
BRIDGE_METRICS_STARTED=false
LOCAL_AI_ENABLED="${LOCAL_AI_ENABLED:-true}"

# ── Flags ──────────────────────────────────────────────────────────────────
FRESH_START=false
MACHINE_LOAD="runtime"       # runtime | ci-seed | none
PE_SOURCE_BOOTSTRAP="auto"   # auto | off
VALIDATE_CORPUS="once"       # once | off
MANAGER_NATIVE=false
DRY_RUN=false
RE_ENGINE="${RE_ENGINE:-ai}"       # ai | cpp | lsp
PE_ENGINE="${PE_ENGINE:-ai}"       # ai | cpp | lsp
ENGINES=""                         # multi-engine: "scala:2,cpp:1" etc.
# Configurable native port bases — override in .env to avoid macOS AirPlay (port 5000)
SCALA_PE_BASE="${SCALA_PE_BASE:-5000}"
CPP_PE_BASE="${CPP_PE_BASE:-5300}"
LSP_PE_BASE="${LSP_PE_BASE:-5600}"
MQTT_BROKER_URL_OVERRIDE=""
MQTT_MAPPINGS_OVERRIDE=""
OPENCLAW="${OPENCLAW:-auto}"       # auto | yes | no
OCS_NATIVE_UNLOADED=false
VERSION_WARN_ONLY=false

print_usage() {
  cat <<'USAGE'
startUniverse.sh — engine-selectable CI orchestrator

  --fresh                       Wipe perception sources volume; rebuild images no-cache
  --machine-load=runtime        RE loads corpus from MACHINES_DIR at boot; CI never calls seed-machines.sh
                                  (default; sets RE_LOAD_MACHINES=1 on every native runtime wrapper)
  --machine-load=ci-seed        RE starts empty (RE_LOAD_MACHINES=0); CI calls seed-machines.sh --re-only
                                  once per RE instance after RE health, then triggers PE bootstrap
  --machine-load=none           RE starts empty; no seeding, no PE bootstrap regardless of other flags
  --pe-source-bootstrap=auto    After the machine-load phase, call POST /api/sources/bootstrap-from-machines
                                  on each PE instance (default)
  --pe-source-bootstrap=off     Skip PE source materialisation entirely
  --validate-corpus=once        Validate corpus JSON before seeding in ci-seed mode (default)
  --validate-corpus=off         Skip corpus validation in ci-seed mode
  --skip-seed                   Legacy alias for --machine-load=runtime --pe-source-bootstrap=off
  --manager-native              Start Visualizer+PE via RealityEngine_Manager/start.sh
                                instead of Docker (points to Docker public endpoints: RE :5001, PE :3004)
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
  --no-local-ai                 Skip Ollama and localAIStack API startup
  --no-mcp-http                 Skip RealityEngine MCP Streamable HTTP service startup
  --no-openapi-swagger          Skip OpenAPI/Swagger portal startup
  --warn-only                   Warn on sibling repo version mismatch instead of failing startup
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
    --fresh)                    FRESH_START=true ;;
    --machine-load=*)           MACHINE_LOAD="${arg#*=}" ;;
    --pe-source-bootstrap=*)    PE_SOURCE_BOOTSTRAP="${arg#*=}" ;;
    --validate-corpus=*)        VALIDATE_CORPUS="${arg#*=}" ;;
    --skip-seed)                MACHINE_LOAD=runtime; PE_SOURCE_BOOTSTRAP=off ;;  # legacy alias
    --manager-native)           MANAGER_NATIVE=true ;;
    --engines=*)           ENGINES="${arg#*=}" ;;
    --re-engine=*)         RE_ENGINE="${arg#*=}" ;;
    --pe-engine=*)         PE_ENGINE="${arg#*=}" ;;
    --mqtt-broker-url=*)   MQTT_BROKER_URL_OVERRIDE="${arg#*=}" ;;
    --mqtt-mappings=*)     MQTT_MAPPINGS_OVERRIDE="${arg#*=}" ;;
    --openclaw)            OPENCLAW=yes ;;
    --no-openclaw)         OPENCLAW=no ;;
    --no-local-ai)         LOCAL_AI_ENABLED=false ;;
    --no-mcp-http)         MCP_HTTP_ENABLED=false ;;
    --no-openapi-swagger)  OPENAPI_SWAGGER_ENABLED=false ;;
    --warn-only)           VERSION_WARN_ONLY=true ;;
    --dry-run)             DRY_RUN=true ;;
    --help|-h)             print_usage; exit 0 ;;
    *)                     echo "Unknown argument: $arg"; print_usage; exit 2 ;;
  esac
done

case "$RE_ENGINE"          in ai|cpp|lsp)              ;; *) echo "Bad --re-engine=$RE_ENGINE"; exit 2 ;; esac
case "$PE_ENGINE"          in ai|cpp|lsp)              ;; *) echo "Bad --pe-engine=$PE_ENGINE"; exit 2 ;; esac
case "$MACHINE_LOAD"       in runtime|ci-seed|none)    ;; *) echo "Bad --machine-load=$MACHINE_LOAD (runtime|ci-seed|none)"; exit 2 ;; esac
case "$PE_SOURCE_BOOTSTRAP" in auto|off)               ;; *) echo "Bad --pe-source-bootstrap=$PE_SOURCE_BOOTSTRAP (auto|off)"; exit 2 ;; esac
case "$VALIDATE_CORPUS"    in once|off)                ;; *) echo "Bad --validate-corpus=$VALIDATE_CORPUS (once|off)"; exit 2 ;; esac

# RE_LOAD_MACHINES flag passed to every native runtime wrapper
case "$MACHINE_LOAD" in
    runtime) _RE_LOAD_MACHINES=1 ;;
    *)       _RE_LOAD_MACHINES=0 ;;
esac

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
MCP_HTTP_ENABLED=$MCP_HTTP_ENABLED
OPENAPI_SWAGGER_ENABLED=$OPENAPI_SWAGGER_ENABLED
STARTED_AT=$(date -u +%FT%TZ)
EOF
fi  # end: if [ "$DRY_RUN" = false ] stamp

# Source multi-engine helpers
# shellcheck source=scripts/registry.sh
source "$CI_DIR/scripts/registry.sh"
# shellcheck source=scripts/allocate-ports.sh
source "$CI_DIR/scripts/allocate-ports.sh"

configure_openclaw_acp_defaults() {
    export ACP_ENABLED="${ACP_ENABLED:-true}"
    export ACP_PLATFORM="${ACP_PLATFORM:-OpenClaw}"
    export ACP_SURFACE="${ACP_SURFACE:-xACP}"
    export ACP_GATEWAY_URL="${ACP_GATEWAY_URL:-${OPENCLAW_GATEWAY_URL:-ws://127.0.0.1:18789}}"
    export OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-$ACP_GATEWAY_URL}"
    export ACP_SESSION_KEY="${ACP_SESSION_KEY:-${OPENCLAW_ACP_SESSION:-agent:main:main}}"
    export OPENCLAW_ACP_SESSION="${OPENCLAW_ACP_SESSION:-$ACP_SESSION_KEY}"
    export ACP_TARGET_AGENT="${ACP_TARGET_AGENT:-openclaw}"
    export ACP_COMPLETION_SOURCE_MAPPING_ID="${ACP_COMPLETION_SOURCE_MAPPING_ID:-acp-openclaw-completion}"
    export TRIGGERS_ENABLED="${TRIGGERS_ENABLED:-true}"
    export TRIGGER_DISPATCH_MODE="${TRIGGER_DISPATCH_MODE:-dry-run}"
    export INTEGRATIONS_CONFIG="$CI_INTEGRATIONS_CONFIG"
}

ensure_ci_integrations_config() {
    configure_openclaw_acp_defaults
    [ -f "$CI_INTEGRATIONS_EXAMPLE" ] || die "Integration registry template missing: $CI_INTEGRATIONS_EXAMPLE"
    if [ "$DRY_RUN" = true ]; then
        info "Dry-run: would generate integration registry at $CI_INTEGRATIONS_CONFIG"
        return
    fi
    python3 - "$CI_INTEGRATIONS_EXAMPLE" "$CI_INTEGRATIONS_CONFIG" <<'PYEOF'
import json
import os
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
data = json.loads(src.read_text())
for item in data.get("integrations", []):
    if item.get("id") == "openclaw-xacp" or item.get("kind") in ("acp", "openclaw-acp"):
        item["enabled"] = os.environ.get("ACP_ENABLED", "true").lower() not in ("0", "false", "no", "off")
        item["platform"] = os.environ.get("ACP_PLATFORM", item.get("platform", "OpenClaw"))
        item["surface"] = os.environ.get("ACP_SURFACE", item.get("surface", "xACP"))
        item["gatewayUrl"] = os.environ.get("OPENCLAW_GATEWAY_URL") or os.environ.get("ACP_GATEWAY_URL", item.get("gatewayUrl", "ws://127.0.0.1:18789"))
        item["sessionKey"] = os.environ.get("OPENCLAW_ACP_SESSION") or os.environ.get("ACP_SESSION_KEY", item.get("sessionKey", "agent:main:main"))
        item["targetAgent"] = os.environ.get("ACP_TARGET_AGENT", item.get("targetAgent", "openclaw"))
        item["completionSourceMappingId"] = os.environ.get("ACP_COMPLETION_SOURCE_MAPPING_ID", "acp-openclaw-completion")
dst.write_text(json.dumps(data, indent=2) + "\n")
PYEOF
    ok "Integration registry ready: $CI_INTEGRATIONS_CONFIG"
}

configure_localai_bridge_targets() {
    if [ "$MULTI_ENGINE_MODE" = true ]; then
        _localai_bridge_urls=$(python3 - "$REGISTRY_FILE" <<'PYEOF'
import json
import sys

try:
    with open(sys.argv[1]) as f:
        instances = json.load(f).get("instances", [])
    first = instances[0] if instances else {}
    re_port = first.get("re_port")
    pe_port = first.get("pe_port")
    if re_port and pe_port:
        print(f"http://host.docker.internal:{re_port} http://host.docker.internal:{pe_port}")
except Exception:
    pass
PYEOF
)
        if [ -n "$_localai_bridge_urls" ]; then
            read -r LOCALAI_RE_URL LOCALAI_PE_URL <<< "$_localai_bridge_urls"
        else
            add_warn "Could not derive localAIStack RE/PE bridge URLs from registry"
            return
        fi
    else
        LOCALAI_RE_URL="${LOCALAI_RE_URL:-https://host.docker.internal:5001}"
        LOCALAI_PE_URL="${LOCALAI_PE_URL:-https://host.docker.internal:3004}"
    fi

    export RE_URL="$LOCALAI_RE_URL"
    export PE_URL="$LOCALAI_PE_URL"
    export RE_SSL_VERIFY="${RE_SSL_VERIFY:-false}"
    info "localAIStack bridge target — RE: $RE_URL  PE: $PE_URL"
}

generate_prometheus_file_sd() {
    mkdir -p "$PROMETHEUS_FILE_SD_DIR"
    python3 - "$REGISTRY_FILE" \
        "$PROMETHEUS_FILE_SD_DIR/reality-engine-targets.json" \
        "$PROMETHEUS_FILE_SD_DIR/perception-engine-targets.json" <<'PYEOF'
import json
import pathlib
import sys

registry_path = pathlib.Path(sys.argv[1])
re_path = pathlib.Path(sys.argv[2])
pe_path = pathlib.Path(sys.argv[3])
allowed = {"scala", "cpp", "lsp"}
re_targets = []
pe_targets = []

try:
    registry = json.loads(registry_path.read_text())
except Exception:
    registry = {"instances": []}

for inst in registry.get("instances", []):
    runtime = str(inst.get("runtime", "")).lower()
    if runtime not in allowed:
        continue
    iid = inst.get("id", runtime)
    re_port = inst.get("re_port")
    pe_port = inst.get("pe_port")
    if re_port:
        re_targets.append({
            "targets": [f"host.docker.internal:{int(re_port)}"],
            "labels": {
                "runtime": runtime,
                "engine": runtime,
                "instance": iid,
                "component": "reality-engine",
                "source": "registry"
            }
        })
    if pe_port:
        pe_targets.append({
            "targets": [f"host.docker.internal:{int(pe_port)}"],
            "labels": {
                "runtime": runtime,
                "engine": runtime,
                "instance": iid,
                "component": "perception-engine",
                "source": "registry"
            }
        })

re_path.write_text(json.dumps(re_targets, indent=2) + "\n")
pe_path.write_text(json.dumps(pe_targets, indent=2) + "\n")
print(f"{len(re_targets)} RE targets, {len(pe_targets)} PE targets")
PYEOF
}

start_bridge_metrics_exporter() {
    command -v node >/dev/null 2>&1 || { add_warn "Bridge metrics exporter skipped — node is not on PATH"; return 0; }
    local url="http://${BRIDGE_METRICS_HOST}:${BRIDGE_METRICS_PORT}"
    if pid_alive "$BRIDGE_METRICS_PID_FILE" && curl -sf --max-time 3 "$url/healthz" >/dev/null 2>&1; then
        BRIDGE_METRICS_STARTED=true
        ok "AI bridge metrics already running: $url/metrics"
        return 0
    fi

    local blocker
    blocker="$(port_listener_pid "$BRIDGE_METRICS_PORT")"
    if [ -n "$blocker" ]; then
        if curl -sf --max-time 3 "$url/healthz" >/dev/null 2>&1; then
            BRIDGE_METRICS_STARTED=true
            ok "AI bridge metrics reachable on existing listener: $url/metrics"
        else
            add_warn "AI bridge metrics port $BRIDGE_METRICS_PORT is in use by PID $blocker"
        fi
        return 0
    fi

    info "Starting AI bridge metrics exporter on $url/metrics..."
    (
      cd "$CI_DIR"
      BRIDGE_METRICS_HOST="$BRIDGE_METRICS_HOST" \
      BRIDGE_METRICS_PORT="$BRIDGE_METRICS_PORT" \
      BRIDGE_METRICS_LEDGER="$BRIDGE_METRICS_LEDGER" \
      OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://127.0.0.1:${OCS_GW_PORT:-18789}}" \
      OPENCLAW_GATEWAY_TOKEN="${_ocs_token:-${OPENCLAW_GATEWAY_TOKEN:-}}" \
      LOCALAI_API_URL="${LOCALAI_API_URL:-http://127.0.0.1:4000}" \
      QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:4333}" \
      OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}" \
      nohup node scripts/bridge-metrics-exporter.mjs > "$BRIDGE_METRICS_LOG_FILE" 2>&1 &
      echo $! > "$BRIDGE_METRICS_PID_FILE"
    )
    if poll_http "$url/healthz" "AI bridge metrics health ready" 20 "-sf --max-time 3"; then
        BRIDGE_METRICS_STARTED=true
    else
        add_warn "AI bridge metrics exporter did not become healthy — see $BRIDGE_METRICS_LOG_FILE"
    fi
}

start_observability_stack() {
    local target_summary
    target_summary="$(generate_prometheus_file_sd 2>/tmp/prometheus_file_sd_err.log)" || \
        add_warn "Prometheus file_sd generation failed — $(cat /tmp/prometheus_file_sd_err.log 2>/dev/null)"
    [ -n "$target_summary" ] && info "Prometheus registry targets: $target_summary"

    start_bridge_metrics_exporter

    info "Starting Prometheus + Grafana..."
    (cd "$CI_DIR" && docker compose up -d --remove-orphans prometheus grafana \
        2>/tmp/observability_start_err.log) > /dev/null || {
        add_warn "Prometheus/Grafana startup failed — $(tail -5 /tmp/observability_start_err.log 2>/dev/null)"
        return 0
    }

    if wait_container_ready "Prometheus" reality-engine-prometheus \
        "http://localhost:9090/-/ready" "http://localhost:9090" 45; then
        PROMETHEUS_STARTED=true
    else
        write_container_health_diagnostics "Prometheus" reality-engine-prometheus \
            "http://localhost:9090/-/ready" /tmp/realityengine-prometheus-health-diagnostics.log
        add_warn "Prometheus did not become ready — dockerHealth=$(docker_health_status reality-engine-prometheus) hostHttp=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:9090/-/ready 2>/dev/null || true) lastHealth='$(docker_last_health_output reality-engine-prometheus)' diagnostics: /tmp/realityengine-prometheus-health-diagnostics.log"
    fi

    if wait_container_ready "Grafana" reality-engine-grafana \
        "http://localhost:3002/api/health" "http://localhost:3002" 45; then
        GRAFANA_STARTED=true
    else
        write_container_health_diagnostics "Grafana" reality-engine-grafana \
            "http://localhost:3002/api/health" /tmp/realityengine-grafana-health-diagnostics.log
        add_warn "Grafana did not become healthy — dockerHealth=$(docker_health_status reality-engine-grafana) hostHttp=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:3002/api/health 2>/dev/null || true) lastHealth='$(docker_last_health_output reality-engine-grafana)' diagnostics: /tmp/realityengine-grafana-health-diagnostics.log"
    fi
}

validate_metrics_surfaces() {
    info "Validating RE metric surfaces..."
    set +e
    if [ "$MULTI_ENGINE_MODE" = true ] && [ -f "$REGISTRY_FILE" ]; then
        python3 - "$REGISTRY_FILE" <<'PYEOF' | while IFS='|' read -r _id _component _url; do
import json
import sys
with open(sys.argv[1]) as f:
    instances = json.load(f).get("instances", [])
for inst in instances:
    iid = inst.get("id", "?")
    if inst.get("re_url"):
        print(f"{iid}|RE|{inst['re_url']}/api/metrics")
PYEOF
            _bytes=$(curl -sf --max-time 4 "$_url" 2>/dev/null | wc -c | tr -d ' ')
            if [ "${_bytes:-0}" -gt 0 ]; then
                ok "$_id $_component metrics non-empty ($_bytes bytes)"
            else
                add_warn "$_id $_component metrics empty or unavailable at $_url"
            fi
        done
    else
        for _url in "https://localhost:5001/api/metrics"; do
            _bytes=$(curl -skf --max-time 4 "$_url" 2>/dev/null | wc -c | tr -d ' ')
            if [ "${_bytes:-0}" -gt 0 ]; then
                ok "Metrics non-empty at $_url ($_bytes bytes)"
            else
                add_warn "Metrics empty or unavailable at $_url"
            fi
        done
    fi
    set -e
}

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

docker_health_status() {
    local container="$1"
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$container" 2>/dev/null || echo "missing"
}

docker_last_health_output() {
    local container="$1"
    { docker inspect "$container" 2>/dev/null || echo "[]"; } | python3 -c '
import json
import sys
try:
    data = json.load(sys.stdin)
    if not data:
        print("container inspect unavailable")
        raise SystemExit(0)
    health = data[0].get("State", {}).get("Health", {})
    log = health.get("Log") or []
    if not log:
        print("no healthcheck log")
    else:
        last = log[-1]
        output = (last.get("Output") or "").strip().replace("\n", " ")
        print("exit=%s start=%s end=%s output=%s" % (
            last.get("ExitCode"),
            last.get("Start"),
            last.get("End"),
            output))
except Exception as exc:
    print("healthcheck log unavailable: %s" % exc)
'
}

write_container_health_diagnostics() {
    local label="$1" container="$2" host_url="$3" diag_file="$4"
    {
        echo "$label readiness diagnostics"
        echo "container: $container"
        echo "dockerHealth: $(docker_health_status "$container")"
        echo "hostUrl: $host_url"
        echo "hostHttp: $(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$host_url" 2>/dev/null || true)"
        echo "lastHealthcheck: $(docker_last_health_output "$container")"
        echo
        echo "recent logs:"
        docker logs --tail 40 "$container" 2>&1 || true
    } > "$diag_file"
}

wait_container_ready() {
    local label="$1" container="$2" host_url="$3" display_url="$4" max="${5:-45}"
    local n=0 status
    while [ "$n" -lt "$max" ]; do
        status="$(docker_health_status "$container")"
        if [ "$status" = "healthy" ] && curl -sf --max-time 3 "$host_url" >/dev/null 2>&1; then
            ok "$label ready: $display_url"
            return 0
        fi
        n=$((n+1)); echo -n "."; sleep 2
    done
    echo ""
    return 1
}

pid_alive() {
    local pid_file="$1"
    [ -f "$pid_file" ] || return 1
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

port_listener_pid() {
    local port="$1"
    lsof -ti TCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1 || true
}

configure_mcp_targets() {
    if [ "$MULTI_ENGINE_MODE" = true ]; then
        export RE_REGISTRY_URL="${RE_REGISTRY_URL:-http://$HOST_IP:${REGISTRY_PORT}/re-registry.json}"
        unset RE_URL PE_URL REALITY_ENGINE_URL PERCEPTION_ENGINE_URL
    else
        export RE_URL="${RE_URL:-https://localhost:5001}"
        export PE_URL="${PE_URL:-https://localhost:3004}"
        export RE_MCP_INSECURE_TLS="${RE_MCP_INSECURE_TLS:-1}"
    fi
}

ensure_mcp_dependencies() {
    [ -f "$CI_DIR/mcp/package.json" ] || { add_warn "MCP package missing: $CI_DIR/mcp/package.json"; return 1; }
    if [ ! -d "$CI_DIR/mcp/node_modules/@modelcontextprotocol/sdk" ]; then
        info "Installing MCP gateway dependencies..."
        (cd "$CI_DIR/mcp" && npm install --omit=dev --no-audit --no-fund --package-lock=false > /tmp/realityengine-mcp-npm-install.log 2>&1) || {
            add_warn "MCP dependency install failed — see /tmp/realityengine-mcp-npm-install.log"
            return 1
        }
    fi
}

start_mcp_http_service() {
    [ "$MCP_HTTP_ENABLED" = "true" ] || { info "MCP HTTP: skipped (MCP_HTTP_ENABLED=false)"; return 0; }
    command -v node >/dev/null 2>&1 || { add_warn "MCP HTTP skipped — node is not on PATH"; return 0; }
    ensure_mcp_dependencies || return 0
    configure_mcp_targets

    local url="http://${RE_MCP_HTTP_HOST}:${RE_MCP_HTTP_PORT}"
    if pid_alive "$MCP_HTTP_PID_FILE" && curl -sf --max-time 3 "$url/healthz" >/dev/null 2>&1; then
        MCP_HTTP_STARTED=true
        ok "MCP HTTP already running: $url/mcp"
        return 0
    fi

    local blocker
    blocker="$(port_listener_pid "$RE_MCP_HTTP_PORT")"
    if [ -n "$blocker" ]; then
        if curl -sf --max-time 3 "$url/healthz" >/dev/null 2>&1; then
            MCP_HTTP_STARTED=true
            ok "MCP HTTP reachable on existing listener: $url/mcp"
        else
            add_warn "MCP HTTP port $RE_MCP_HTTP_PORT is in use by PID $blocker, but /healthz did not respond"
        fi
        return 0
    fi

    info "Starting MCP HTTP gateway on $url/mcp..."
    (
      cd "$CI_DIR"
      RE_REGISTRY_URL="${RE_REGISTRY_URL:-}" \
      RE_URL="${RE_URL:-}" \
      PE_URL="${PE_URL:-}" \
      RE_MCP_INSECURE_TLS="${RE_MCP_INSECURE_TLS:-}" \
      RE_MCP_HTTP_HOST="$RE_MCP_HTTP_HOST" \
      RE_MCP_HTTP_PORT="$RE_MCP_HTTP_PORT" \
      nohup node mcp/src/http-server.js > "$MCP_HTTP_LOG_FILE" 2>&1 &
      echo $! > "$MCP_HTTP_PID_FILE"
    )
    if poll_http "$url/healthz" "MCP HTTP health ready" 20 "-sf --max-time 3"; then
        MCP_HTTP_STARTED=true
    else
        add_warn "MCP HTTP gateway did not become healthy — see $MCP_HTTP_LOG_FILE"
    fi
}

start_openapi_swagger_service() {
    [ "$OPENAPI_SWAGGER_ENABLED" = "true" ] || { info "OpenAPI Swagger: skipped (OPENAPI_SWAGGER_ENABLED=false)"; return 0; }
    [ -f "$CI_DIR/docs/openapi/index.html" ] || { add_warn "Swagger portal missing; run bash scripts/generate-openapi.sh"; return 0; }

    local url="http://${OPENAPI_SWAGGER_HOST}:${OPENAPI_SWAGGER_PORT}"
    if pid_alive "$OPENAPI_SWAGGER_PID_FILE" && curl -sf --max-time 3 "$url/" >/dev/null 2>&1; then
        OPENAPI_SWAGGER_STARTED=true
        ok "OpenAPI Swagger already running: $url/"
        return 0
    fi

    local blocker
    blocker="$(port_listener_pid "$OPENAPI_SWAGGER_PORT")"
    if [ -n "$blocker" ]; then
        if curl -sf --max-time 3 "$url/" >/dev/null 2>&1; then
            OPENAPI_SWAGGER_STARTED=true
            ok "OpenAPI Swagger reachable on existing listener: $url/"
        else
            add_warn "OpenAPI Swagger port $OPENAPI_SWAGGER_PORT is in use by PID $blocker, but portal did not respond"
        fi
        return 0
    fi

    info "Starting OpenAPI Swagger portal on $url/..."
    (
      cd "$CI_DIR"
      RE_REGISTRY_PATH="$REGISTRY_FILE" \
      OPENAPI_SWAGGER_HOST="$OPENAPI_SWAGGER_HOST" \
      nohup bash scripts/serve-openapi.sh "$OPENAPI_SWAGGER_PORT" > "$OPENAPI_SWAGGER_LOG_FILE" 2>&1 &
      echo $! > "$OPENAPI_SWAGGER_PID_FILE"
    )
    if poll_http "$url/" "OpenAPI Swagger portal ready" 20 "-sf --max-time 3"; then
        OPENAPI_SWAGGER_STARTED=true
    else
        add_warn "OpenAPI Swagger portal did not become healthy — see $OPENAPI_SWAGGER_LOG_FILE"
    fi
}

validate_mcp_and_openapi() {
    set +e
    if [ "$MCP_HTTP_ENABLED" = "true" ]; then
        local mcp_url="http://${RE_MCP_HTTP_HOST}:${RE_MCP_HTTP_PORT}"
        if curl -sf --max-time 5 "$mcp_url/healthz" >/dev/null 2>&1; then
            ok "MCP HTTP health: $mcp_url/healthz"
        else
            add_warn "MCP HTTP /healthz unavailable at $mcp_url/healthz"
        fi
        if (cd "$CI_DIR/mcp" && RE_REGISTRY_URL="${RE_REGISTRY_URL:-}" RE_URL="${RE_URL:-}" PE_URL="${PE_URL:-}" RE_MCP_INSECURE_TLS="${RE_MCP_INSECURE_TLS:-}" npm run -s list-tools >/tmp/realityengine-mcp-tools.txt 2>&1); then
            ok "MCP tool catalogue available"
        else
            add_warn "MCP tool catalogue check failed — see /tmp/realityengine-mcp-tools.txt"
        fi
        local init_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"realityengine-startup","version":"1.0.0"}}}'
        local init_code
        init_code="$(curl -sS --max-time 5 -o /tmp/realityengine-mcp-init.json -w '%{http_code}' -X POST "$mcp_url/mcp" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d "$init_body" 2>/tmp/realityengine-mcp-init.err || echo 000)"
        case "$init_code" in
            2*) ok "MCP Streamable HTTP initialize accepted" ;;
            *)  add_warn "MCP Streamable HTTP initialize failed (HTTP $init_code) — see /tmp/realityengine-mcp-init.json" ;;
        esac
    fi

    if [ "$OPENAPI_SWAGGER_ENABLED" = "true" ]; then
        local swagger_url="http://${OPENAPI_SWAGGER_HOST}:${OPENAPI_SWAGGER_PORT}"
        if curl -sf --max-time 5 "$swagger_url/" >/dev/null 2>&1; then
            ok "Swagger portal available: $swagger_url/"
        else
            add_warn "Swagger portal unavailable at $swagger_url/"
        fi
        if curl -sf --max-time 5 "$swagger_url/cpp-re.yaml" | grep -q '^openapi:'; then
            ok "Swagger raw OpenAPI spec available: cpp-re.yaml"
        else
            add_warn "Swagger raw OpenAPI spec unavailable or invalid at $swagger_url/cpp-re.yaml"
        fi
        if curl -sf --max-time 5 "$swagger_url/scala-pe.yaml" | grep -q '^openapi:'; then
            ok "Swagger PE OpenAPI spec available: scala-pe.yaml"
        else
            add_warn "Swagger PE OpenAPI spec unavailable or invalid at $swagger_url/scala-pe.yaml"
        fi
        local swagger_runtime
        swagger_runtime="$(python3 - "$REGISTRY_FILE" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        registry = json.load(f)
except Exception:
    registry = {"instances": []}
for instance in registry.get("instances", []):
    runtime = instance.get("runtime")
    if runtime and instance.get("re_url") and instance.get("pe_url") and instance.get("status", "running") == "running":
        print(runtime)
        break
PYEOF
)"
        if [ -n "$swagger_runtime" ]; then
            if curl -sf --max-time 5 "$swagger_url/${swagger_runtime}-re.yaml" | grep -q "url: ${swagger_url}/proxy/${swagger_runtime}/re"; then
                ok "Swagger RE spec uses same-origin proxy for ${swagger_runtime}"
            else
                add_warn "Swagger RE spec for ${swagger_runtime} does not expose same-origin proxy server"
            fi
            if curl -sf --max-time 5 "$swagger_url/${swagger_runtime}-pe.yaml" | grep -q "url: ${swagger_url}/proxy/${swagger_runtime}/pe"; then
                ok "Swagger PE spec uses same-origin proxy for ${swagger_runtime}"
            else
                add_warn "Swagger PE spec for ${swagger_runtime} does not expose same-origin proxy server"
            fi
            if curl -sf --max-time 5 "$swagger_url/proxy/${swagger_runtime}/re/api/health" >/dev/null 2>&1; then
                ok "Swagger RE proxy executes against active ${swagger_runtime}"
            else
                add_warn "Swagger RE proxy execution failed for ${swagger_runtime}"
            fi
            if curl -sf --max-time 5 "$swagger_url/proxy/${swagger_runtime}/pe/api/health" >/dev/null 2>&1; then
                ok "Swagger PE proxy executes against active ${swagger_runtime}"
            else
                add_warn "Swagger PE proxy execution failed for ${swagger_runtime}"
            fi
        else
            add_warn "Swagger proxy validation skipped: no active registry instance found in $REGISTRY_FILE"
        fi
    fi
    set -e
}

# ── C++ build-prerequisite validation (macOS toolchain + Boost) ────────────
# The native CPP engine builds via `make` (RealityEngine_CPP/start.sh), which
# needs two host prerequisites that have bitten us with cryptic mid-build
# "file not found" errors:
#   1. Boost headers (boost/asio.hpp)  — installed via `brew install boost`.
#   2. A COMPLETE libc++ from the active macOS SDK — the Command Line Tools'
#      bundled /usr/include/c++/v1 can be stale and missing umbrella headers
#      such as <atomic> / <cctype>.  The CPP Makefile anchors the build to the
#      SDK to dodge this, but if the SDK copy is also incomplete it still fails.
# We validate by compiling a tiny probe with the SAME flags the Makefile uses
# (SDK anchoring + Boost include), so a problem surfaces here with a clear
# remediation rather than deep inside `make`.  No-op when CPP is not selected.
validate_cpp_build_deps() {
    info "Validating C++ build prerequisites (libc++ headers + Boost)..."

    local cxx="${CXX:-c++}"
    command -v "$cxx" >/dev/null 2>&1 || cxx=g++
    command -v "$cxx" >/dev/null 2>&1 || {
        warn "No C++ compiler found on PATH."
        warn "  → Install the Xcode Command Line Tools:  xcode-select --install"
        return 1
    }

    # Boost include path (brew on macOS; rely on system path elsewhere).
    local boost_inc="" bp=""
    if command -v brew >/dev/null 2>&1; then
        bp="$(brew --prefix boost 2>/dev/null || true)"
        [ -n "$bp" ] && boost_inc="-I$bp/include"
    fi

    # macOS SDK anchoring — mirrors RealityEngine_CPP/Makefile so the probe
    # exercises exactly the include search order the real build will use.
    local sdk_flags="" sdkroot=""
    if [ "$(uname -s)" = "Darwin" ]; then
        sdkroot="$(xcrun --show-sdk-path 2>/dev/null || true)"
        [ -n "$sdkroot" ] && sdk_flags="-isysroot $sdkroot -isystem $sdkroot/usr/include/c++/v1"
    fi

    local probe errlog
    probe="$(mktemp -t re-cpp-probe.XXXXXX)" || return 1
    mv "$probe" "$probe.cpp"; probe="$probe.cpp"
    errlog="$(mktemp -t re-cpp-probe-log.XXXXXX)"
    cat > "$probe" <<'CPP'
#include <atomic>
#include <cctype>
#include <boost/asio.hpp>
int main() { std::atomic<int> a{0}; return std::isspace(' ') ? a.load() : 0; }
CPP

    # shellcheck disable=SC2086
    # sdk_flags/boost_inc are intentionally word-split.
    if "$cxx" -std=c++20 -fsyntax-only $sdk_flags $boost_inc "$probe" >"$errlog" 2>&1; then
        ok "C++ build prerequisites OK${bp:+ (Boost: $bp)}${sdkroot:+, SDK: ${sdkroot##*/}}"
        rm -f "$probe" "$errlog"
        return 0
    fi

    warn "C++ build prerequisites check FAILED — the native CPP engine will not build:"
    head -8 "$errlog" | sed 's/^/    /'
    if grep -qiE "boost/asio|boost/" "$errlog"; then
        warn "  → Boost headers missing.  Fix:  brew install boost"
    fi
    if grep -qiE "'atomic'|'cctype'|<atomic>|<cctype>|file not found" "$errlog"; then
        warn "  → libc++ umbrella headers missing from the active SDK toolchain."
        warn "    Reinstall the Command Line Tools:"
        warn "      sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
    fi
    rm -f "$probe" "$errlog"
    return 1
}

# ── Lisp runtime-prerequisite validation (SBCL + Quicklisp) ────────────────
# The native LSP engine (RealityEngine_LSP/start.sh) needs two prerequisites:
#   1. SBCL on PATH — the Common Lisp runtime.
#   2. Quicklisp (setup.lisp) — provisions the ASDF dependencies (alexandria,
#      hunchentoot, drakma, yason, …) via ql:quickload. start.sh resolves it
#      from $LSP_DIR/quicklisp/setup.lisp first, then $HOME/quicklisp/setup.lisp;
#      we mirror that search so the check matches what start.sh will actually use.
# Without either, start.sh dies with a terse message; validating here surfaces
# the gap up front with install remediation. No-op when LSP is not selected.
validate_lsp_runtime_deps() {
    info "Validating Lisp runtime prerequisites (SBCL + Quicklisp)..."

    if ! command -v sbcl >/dev/null 2>&1; then
        warn "SBCL not found on PATH — the native LSP engine cannot run."
        warn "  → Install it:  brew install sbcl"
        return 1
    fi
    local sbcl_ver; sbcl_ver="$(sbcl --version 2>/dev/null || echo sbcl)"

    # Mirror start.sh's resolution order: repo-local first, then $HOME.
    local ql=""
    if [ -f "$LSP_DIR/quicklisp/setup.lisp" ]; then
        ql="$LSP_DIR/quicklisp/setup.lisp"
    elif [ -f "$HOME/quicklisp/setup.lisp" ]; then
        ql="$HOME/quicklisp/setup.lisp"
    fi
    if [ -z "$ql" ]; then
        warn "Quicklisp not found — the LSP engine needs it to load ASDF dependencies."
        warn "  Expected at $LSP_DIR/quicklisp/setup.lisp or $HOME/quicklisp/setup.lisp"
        warn "  → Install it:"
        warn "      curl -sSLo /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp"
        warn "      sbcl --non-interactive --load /tmp/quicklisp.lisp --eval '(quicklisp-quickstart:install)'"
        return 1
    fi

    ok "Lisp runtime prerequisites OK ($sbcl_ver; Quicklisp: ${ql/#$HOME/~})"
    return 0
}

# ── Host IP detection ─────────────────────────────────────────────────────
HOST_IP="$(bash "$CI_DIR/scripts/detect-host-ip.sh" 2>/dev/null || echo "127.0.0.1")"
export HOST_IP
[ "$HOST_IP" = "127.0.0.1" ] && \
    warn "Could not detect LAN IP — using 127.0.0.1 (multi-engine URLs will be local-only)"

# ── Multi-engine spawn helpers ────────────────────────────────────────────

_poll_native_health() {
    local url="$1" label="$2" max="${3:-${NATIVE_HEALTH_ATTEMPTS:-45}}"
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

    [ -x "$SCALA_DIR/start.sh" ] || die "$id: $SCALA_DIR/start.sh not found or not executable"

    INSTANCE_ID="$id" \
    RE_LOAD_MACHINES="$_RE_LOAD_MACHINES" \
    HOST="0.0.0.0" \
    REALITY_ENGINE_PORT="$re_port" \
    PERCEPTION_ENGINE_PORT="$pe_port" \
    REALITY_ENGINE_URL="http://$HOST_IP:$re_port" \
    MACHINES_DIR="$MACHINES_DIR/machines" \
    INTEGRATIONS_CONFIG="$INTEGRATIONS_CONFIG" \
    ACP_ENABLED="$ACP_ENABLED" \
    ACP_GATEWAY_URL="$ACP_GATEWAY_URL" \
    OPENCLAW_GATEWAY_URL="$OPENCLAW_GATEWAY_URL" \
    ACP_SESSION_KEY="$ACP_SESSION_KEY" \
    OPENCLAW_ACP_SESSION="$OPENCLAW_ACP_SESSION" \
    ACP_TARGET_AGENT="$ACP_TARGET_AGENT" \
    ACP_COMPLETION_SOURCE_MAPPING_ID="$ACP_COMPLETION_SOURCE_MAPPING_ID" \
    TRIGGERS_ENABLED="$TRIGGERS_ENABLED" \
    TRIGGER_DISPATCH_MODE="$TRIGGER_DISPATCH_MODE" \
        nohup bash "$SCALA_DIR/start.sh" \
        > "/tmp/re-${id}.log" 2>&1 &
    local pid_re=$!

    echo -n "  $id RE "
    _poll_native_health "http://$HOST_IP:$re_port/api/health" "$id RE ready"
    echo -n "  $id PE "
    _poll_native_health "http://$HOST_IP:$pe_port/api/health" "$id PE ready"

    # Scala start.sh backgrounds both JVMs and exits; read actual engine PIDs from disk.
    local pid_re_actual pid_pe_actual
    pid_re_actual=$(cat "$SCALA_DIR/run/reality-engine-${id}.pid" 2>/dev/null || echo "")
    pid_pe_actual=$(cat "$SCALA_DIR/run/perception-engine-${id}.pid" 2>/dev/null || echo "")

    registry_add "$id" "scala" \
        "http://$HOST_IP:$re_port" \
        "http://$HOST_IP:$pe_port" \
        "${pid_re_actual:-$pid_re}" "${pid_pe_actual:-}"
}

spawn_cpp_instance() {
    local id="$1" idx="$2"
    local ports; ports=$(allocate_ports cpp "$idx") || { warn "Cannot allocate ports for $id"; return 1; }
    local re_port pe_port
    read -r re_port pe_port <<< "$ports"

    info "Spawning $id  (RE=$HOST_IP:$re_port  PE=$HOST_IP:$pe_port)"
    [ -x "$CPP_DIR/start.sh" ] || die "$id: $CPP_DIR/start.sh not found or not executable"

    INSTANCE_ID="$id" \
    RE_LOAD_MACHINES="$_RE_LOAD_MACHINES" \
    REALITY_ENGINE_HOST="$HOST_IP" \
    REALITY_ENGINE_PORT="$re_port" \
    PERCEPTION_ENGINE_PORT="$pe_port" \
    MACHINES_DIR="$MACHINES_DIR/machines" \
    INTEGRATIONS_CONFIG="$INTEGRATIONS_CONFIG" \
    ACP_ENABLED="$ACP_ENABLED" \
    ACP_GATEWAY_URL="$ACP_GATEWAY_URL" \
    OPENCLAW_GATEWAY_URL="$OPENCLAW_GATEWAY_URL" \
    ACP_SESSION_KEY="$ACP_SESSION_KEY" \
    OPENCLAW_ACP_SESSION="$OPENCLAW_ACP_SESSION" \
    ACP_TARGET_AGENT="$ACP_TARGET_AGENT" \
    ACP_COMPLETION_SOURCE_MAPPING_ID="$ACP_COMPLETION_SOURCE_MAPPING_ID" \
    TRIGGERS_ENABLED="$TRIGGERS_ENABLED" \
    TRIGGER_DISPATCH_MODE="$TRIGGER_DISPATCH_MODE" \
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
    [ -x "$LSP_DIR/start.sh" ] || die "$id: $LSP_DIR/start.sh not found or not executable"

    INSTANCE_ID="$id" \
    RE_LOAD_MACHINES="$_RE_LOAD_MACHINES" \
    REALITY_ENGINE_HOST="$HOST_IP" \
    REALITY_ENGINE_PORT="$re_port" \
    PERCEPTION_ENGINE_PORT="$pe_port" \
    MACHINES_DIR="$MACHINES_DIR/machines" \
    INTEGRATIONS_CONFIG="$INTEGRATIONS_CONFIG" \
    ACP_ENABLED="$ACP_ENABLED" \
    ACP_GATEWAY_URL="$ACP_GATEWAY_URL" \
    OPENCLAW_GATEWAY_URL="$OPENCLAW_GATEWAY_URL" \
    ACP_SESSION_KEY="$ACP_SESSION_KEY" \
    OPENCLAW_ACP_SESSION="$OPENCLAW_ACP_SESSION" \
    ACP_TARGET_AGENT="$ACP_TARGET_AGENT" \
    ACP_COMPLETION_SOURCE_MAPPING_ID="$ACP_COMPLETION_SOURCE_MAPPING_ID" \
    TRIGGERS_ENABLED="$TRIGGERS_ENABLED" \
    TRIGGER_DISPATCH_MODE="$TRIGGER_DISPATCH_MODE" \
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
    # Parse host and port via Python urlparse — handles mqtt://, mqtts://, auth tokens, paths
    _mqtt_parsed=$(python3 - "$MQTT_BROKER_URL_OVERRIDE" <<'PYEOF' 2>/dev/null
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1])
default_port = 8883 if u.scheme == 'mqtts' else 1883
print(u.hostname or '')
print(u.port or default_port)
PYEOF
)
    export MQTT_BROKER_HOST=$(printf '%s\n' "$_mqtt_parsed" | sed -n '1p')
    export MQTT_BROKER_PORT=$(printf '%s\n' "$_mqtt_parsed" | sed -n '2p')
    [ -z "$MQTT_BROKER_PORT" ] && MQTT_BROKER_PORT=1883
  fi
  [ -n "$MQTT_MAPPINGS_OVERRIDE" ] && export MQTT_MAPPINGS_FILE="$MQTT_MAPPINGS_OVERRIDE"

  echo "════════════════════════════════════════════════════════════════════"
  echo "  Delegating to $engine_name engine: $engine_dir/start.sh"
  echo "  RE_ENGINE=$RE_ENGINE  PE_ENGINE=$PE_ENGINE"
  [ -n "${MQTT_BROKER_URL:-}${MQTT_BROKER_HOST:-}" ] && \
    echo "  MQTT broker: ${MQTT_BROKER_URL:-${MQTT_BROKER_HOST}:${MQTT_BROKER_PORT:-1883}}"
  echo "  Integrations config: ${INTEGRATIONS_CONFIG}"
  echo "  OpenClaw ACP: enabled=${ACP_ENABLED} gateway=${ACP_GATEWAY_URL} target=${ACP_TARGET_AGENT} mapping=${ACP_COMPLETION_SOURCE_MAPPING_ID}"
  echo "════════════════════════════════════════════════════════════════════"
  exec "$engine_dir/start.sh"
}

ensure_ci_integrations_config

if [ "$MULTI_ENGINE_MODE" = false ]; then
  if [ "$RE_ENGINE" = "cpp" ] || [ "$PE_ENGINE" = "cpp" ]; then
    validate_cpp_build_deps || die "C++ build prerequisites not satisfied (see remediation above)"
    run_native_engine "$CPP_DIR" "CPP"
  fi
  if [ "$RE_ENGINE" = "lsp" ] || [ "$PE_ENGINE" = "lsp" ]; then
    validate_lsp_runtime_deps || die "Lisp runtime prerequisites not satisfied (see remediation above)"
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
# Roadmap Phase 1 complete: docker-compose.yml build contexts reference
# ../RealityEngine_Scala and ../RealityEngine_Manager/*, and the RE machine
# volume mounts ${MACHINES_DIR}/machines from RealityEngine_Machines.

if [ -n "$MQTT_BROKER_URL_OVERRIDE" ]; then
  export MQTT_BROKER_URL="$MQTT_BROKER_URL_OVERRIDE"
  # Bug 4 fix: CPP from_environment() reads MQTT_BROKER_HOST/PORT, not MQTT_BROKER_URL.
  # Export them in the main body so multi-engine mode engines inherit them at boot.
  _mqtt_parsed=$(python3 - "$MQTT_BROKER_URL_OVERRIDE" <<'PYEOF' 2>/dev/null
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1])
default_port = 8883 if u.scheme == 'mqtts' else 1883
print(u.hostname or '')
print(u.port or default_port)
PYEOF
)
  export MQTT_BROKER_HOST=$(printf '%s\n' "$_mqtt_parsed" | sed -n '1p')
  export MQTT_BROKER_PORT=$(printf '%s\n' "$_mqtt_parsed" | sed -n '2p')
  [ -z "$MQTT_BROKER_PORT" ] && MQTT_BROKER_PORT=1883
  unset _mqtt_parsed
fi
if [ -n "$MQTT_MAPPINGS_OVERRIDE" ]; then
  [ -f "$MQTT_MAPPINGS_OVERRIDE" ] || die "MQTT mappings file not found: $MQTT_MAPPINGS_OVERRIDE"
  export MQTT_MAPPINGS_FILE="$MQTT_MAPPINGS_OVERRIDE"
  export MQTT_MAPPINGS_JSON="$(cat "$MQTT_MAPPINGS_OVERRIDE")"
  info "MQTT mappings loaded inline (${#MQTT_MAPPINGS_JSON} bytes from ${MQTT_MAPPINGS_OVERRIDE##*/})"
fi

# Pass sibling repo paths to docker-compose so build contexts and volume mounts resolve correctly.
export SCALA_DIR MGR_DIR MACHINES_DIR PROMETHEUS_FILE_SD_DIR
export ACP_ENABLED ACP_PLATFORM ACP_SURFACE ACP_GATEWAY_URL OPENCLAW_GATEWAY_URL
export ACP_SESSION_KEY OPENCLAW_ACP_SESSION ACP_TARGET_AGENT ACP_COMPLETION_SOURCE_MAPPING_ID INTEGRATIONS_CONFIG

# =============================================================================
hdr "1 · Pre-flight"
# =============================================================================

docker compose version > /dev/null 2>&1 || \
    die "docker compose (v2) not found — install Docker Desktop >= 3.x"
COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "unknown")
ok "docker compose v$COMPOSE_VER"

# Version compatibility check — blocks startup on branch mismatch
if [ -x "$CI_DIR/scripts/validate-versions.sh" ]; then
    if [ "$VERSION_WARN_ONLY" = true ]; then
        bash "$CI_DIR/scripts/validate-versions.sh" --warn-only
    else
        bash "$CI_DIR/scripts/validate-versions.sh"
    fi
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
ensure_ci_integrations_config

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

# Warn if keystore password is still the dev default
if [ "${KEYSTORE_PASSWORD:-realityengine}" = "realityengine" ]; then
    warn "KEYSTORE_PASSWORD is set to the default dev value — set a strong password in .env before sharing this environment"
fi

# Loki Docker logging driver
LOKI_ENABLED=$(docker plugin inspect loki --format '{{.Enabled}}' 2>/dev/null || echo "missing")
if [ "$LOKI_ENABLED" = "missing" ]; then
    info "Installing Loki Docker logging driver..."
    if ! docker plugin install grafana/loki-docker-driver:latest \
            --alias loki --grant-all-permissions 2>/dev/null; then
        warn "Loki Docker driver install failed."
        warn "Plugin installation requires elevated privileges. Install it first:"
        warn "  sudo docker plugin install grafana/loki-docker-driver:latest --alias loki --grant-all-permissions"
        warn "Or run:  sudo bash $CI_DIR/scripts/setup-loki-driver.sh"
        die "Loki log driver not available"
    fi
elif [ "$LOKI_ENABLED" = "false" ]; then
    info "Enabling Loki Docker logging driver..."
    docker plugin enable loki 2>/dev/null || die "Could not enable loki plugin"
fi
ok "Loki Docker logging driver ready"

# In multi-engine mode the Manager (ports 3001 + 5173) is started natively
# by this script. Stop any previous instance before the port conflict check
# so a restart doesn't die on its own previously-started Manager.
if [ "$MULTI_ENGINE_MODE" = true ] && [ -x "$MGR_DIR/stop.sh" ]; then
    if [ -f "$MGR_DIR/.manager-pids" ] || \
       lsof -ti :3001 -sTCP:LISTEN >/dev/null 2>&1 || \
       lsof -ti :5173 -sTCP:LISTEN >/dev/null 2>&1; then
        info "Stopping previous Manager instance before port check..."
        "$MGR_DIR/stop.sh" --force > /dev/null 2>&1 || true
        rm -f "$MGR_DIR/.manager-pids"
        sleep 1
    fi
fi

# Block any process that would conflict with Docker port bindings
CONFLICTS=""
for port in 3001 3004 3005 5001 5173; do
    pid=$(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null | head -1 || true)
    if [ -n "$pid" ]; then
        proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "pid:$pid")
        CONFLICTS="$CONFLICTS ${port}(${proc})"
    fi
done
[ -n "$CONFLICTS" ] && \
    die "Processes already listening on RE ports:$CONFLICTS\n  Stop them first (see RealityEngine_Manager/stop.sh)"
ok "No port conflicts"

# Pre-check all native engine ports before spawning begins — fail fast before partial starts
if [ "$MULTI_ENGINE_MODE" = true ]; then
    info "Pre-checking native engine ports (${ENGINES})..."
    _pf_all_ports=""
    _pf_has_cpp=false
    _pf_has_lsp=false
    IFS=',' read -ra _pf_specs <<< "$ENGINES"
    for _pf_spec in "${_pf_specs[@]}"; do
        _pf_rt=$(echo "$_pf_spec" | cut -d: -f1 | tr -d ' ')
        _pf_ct=$(echo "$_pf_spec" | cut -d: -f2 | tr -d ' ')
        _pf_ct="${_pf_ct:-1}"
        case "$_pf_rt" in
            scala) _pf_base_pe=$SCALA_PE_BASE; _pf_base_re=$(( SCALA_PE_BASE + 1 )) ;;
            cpp)   _pf_base_pe=$CPP_PE_BASE;   _pf_base_re=$(( CPP_PE_BASE + 1 )); _pf_has_cpp=true ;;
            lsp)   _pf_base_pe=$LSP_PE_BASE;   _pf_base_re=$(( LSP_PE_BASE + 1 )); _pf_has_lsp=true ;;
            *) continue ;;
        esac
        for (( _pf_i=1; _pf_i<=_pf_ct; _pf_i++ )); do
            _pf_all_ports="$_pf_all_ports $(( _pf_base_re + (_pf_i-1)*100 )) $(( _pf_base_pe + (_pf_i-1)*100 ))"
        done
    done
    # Detect cross-runtime band collisions before any process is spawned
    _DUPE=$(printf '%s\n' $_pf_all_ports | sort -n | uniq -d)
    [ -n "$_DUPE" ] && \
        die "Cross-runtime port collision in --engines=$ENGINES — ports$(printf ' %s' $_DUPE) would be double-allocated\n  See DEPLOYMENT_CONTRACT.md § Per-Runtime Instance Limits"
    # Check host occupancy
    for _pf_port in $_pf_all_ports; do
        if lsof -i ":${_pf_port}" -sTCP:LISTEN >/dev/null 2>&1; then
            die "Native engine port ${_pf_port} already in use\n  Stop the blocking process and retry"
        fi
    done
    ok "Native engine ports free"

    # If any cpp instance will spawn, validate its build prerequisites up front
    # so a missing Boost / incomplete SDK libc++ fails fast rather than mid-make.
    if [ "$_pf_has_cpp" = true ]; then
        validate_cpp_build_deps || die "C++ build prerequisites not satisfied (see remediation above)"
    fi
    # Likewise validate SBCL + Quicklisp before spawning any lsp instance.
    if [ "$_pf_has_lsp" = true ]; then
        validate_lsp_runtime_deps || die "Lisp runtime prerequisites not satisfied (see remediation above)"
    fi
fi

# ── Orphan container cleanup ──────────────────────────────────────────────
info "Checking for orphaned containers..."
# Use `rm -sf` (stop + remove) rather than `down` so stale compose state
# (container ID exists in compose but not in Docker) doesn't block startup.
# `down` silently fails on "No such container" and leaves the reference; `rm -sf`
# operates on names and succeeds even when compose state is partially stale.
(cd "$CI_DIR" && docker compose rm -sf 2>/dev/null) || true
(cd "$CI_DIR" && docker compose down --remove-orphans 2>/dev/null) || true

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

# Prune stopped CI containers to clear any stale container IDs
docker container prune -f --filter "label=com.docker.compose.project=realityengine_ci" \
    > /dev/null 2>&1 || true

REMAINING=$(docker ps -a --format "{{.Names}}" 2>/dev/null \
    | grep -c "reality-engine-" || true)
[ "$REMAINING" -gt 0 ] && add_warn "$REMAINING RE container(s) still present before startup" \
    || ok "RE container state clean"

# localAIStack cleanup — rm -sf clears stale compose references before down
(cd "$LAS_DIR" && docker compose rm -sf 2>/dev/null) || true
(cd "$LAS_DIR" && docker compose down --remove-orphans 2>/dev/null) || true
docker rm -f localai_qdrant localai_redis localai_loki localai_grafana localai_api localai_webui \
    > /dev/null 2>&1 || true
# Prune stopped localai_* containers to clear stale IDs before step 3
docker container prune -f --filter "label=com.docker.compose.project=localai" \
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
    printf "  %-28s %s\n" "Fresh"              "$FRESH_START"
    printf "  %-28s %s\n" "Machine load"       "$MACHINE_LOAD"
    printf "  %-28s %s\n" "PE source bootstrap" "$PE_SOURCE_BOOTSTRAP"
    printf "  %-28s %s\n" "Validate corpus"    "$VALIDATE_CORPUS"
    printf "  %-28s %s\n" "RE_LOAD_MACHINES"   "$_RE_LOAD_MACHINES"
    printf "  %-28s %s\n" "OpenClaw"           "$OPENCLAW"
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
                scala) _dr_base_pe=$SCALA_PE_BASE; _dr_base_re=$(( SCALA_PE_BASE + 1 )) ;;
                cpp)   _dr_base_pe=$CPP_PE_BASE;   _dr_base_re=$(( CPP_PE_BASE + 1 ))   ;;
                lsp)   _dr_base_pe=$LSP_PE_BASE;   _dr_base_re=$(( LSP_PE_BASE + 1 ))   ;;
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
        if [ "$LOCAL_AI_ENABLED" = true ]; then
            echo "    CI Loki · Qdrant · Redis · RE API (Scala) · Visualizer · PE · localAIStack API"
        else
            echo "    CI Loki · Qdrant · Redis · RE API (Scala) · Visualizer · PE"
        fi
    fi
    echo ""
    echo "  Machine load:       $MACHINE_LOAD  (RE_LOAD_MACHINES=$_RE_LOAD_MACHINES)"
    echo "  PE bootstrap:       $PE_SOURCE_BOOTSTRAP"
    echo "  Validate corpus:    $VALIDATE_CORPUS"
    echo ""
    echo "  Pre-flight: PASSED — run without --dry-run to start"
    echo ""
    exit 0
fi

# =============================================================================
hdr "2 · Ollama"
# =============================================================================

if [ "$LOCAL_AI_ENABLED" != true ]; then
    info "Ollama: skipped (--no-local-ai)"
elif curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
    ok "Ollama already running"
else
    info "Starting Ollama..."
    ollama serve > /tmp/ollama_universe.log 2>&1 &
    echo $! > /tmp/ollama_universe.pid
    poll_http "http://localhost:11434/api/tags" "Ollama ready" 30 "-sf" || \
        die "Ollama failed to start — log: /tmp/ollama_universe.log"
fi

if [ "$LOCAL_AI_ENABLED" = true ]; then
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
fi

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
(cd "$CI_DIR" && docker compose up -d --remove-orphans loki \
    2>/tmp/infra_start_err.log) > /dev/null || \
    die "docker compose up failed for Loki\n$(tail -5 /tmp/infra_start_err.log 2>/dev/null)"
(cd "$LAS_DIR" && docker compose up -d --remove-orphans qdrant redis \
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
            die "Invalid count '${_count}' for runtime '${_runtime}' — must be a positive integer"
        fi
        case "$_runtime" in
            scala)
                for (( _i=1; _i<=_count; _i++ )); do
                    INSTANCE_IDX_SCALA=$(( INSTANCE_IDX_SCALA + 1 ))
                    spawn_scala_instance "scala-${INSTANCE_IDX_SCALA}" "$INSTANCE_IDX_SCALA"
                done ;;
            cpp)
                for (( _i=1; _i<=_count; _i++ )); do
                    INSTANCE_IDX_CPP=$(( INSTANCE_IDX_CPP + 1 ))
                    spawn_cpp_instance "cpp-${INSTANCE_IDX_CPP}" "$INSTANCE_IDX_CPP"
                done ;;
            lsp)
                for (( _i=1; _i<=_count; _i++ )); do
                    INSTANCE_IDX_LSP=$(( INSTANCE_IDX_LSP + 1 ))
                    spawn_lsp_instance "lsp-${INSTANCE_IDX_LSP}" "$INSTANCE_IDX_LSP"
                done ;;
            *)
                die "Unknown runtime in --engines spec: '$_runtime'" ;;
        esac
    done

    # Generate nginx upstreams from registry (for Docker TLS proxy if running)
    bash "$CI_DIR/scripts/gen-nginx-upstreams.sh" 2>/dev/null || true

    _inst_count=$(registry_ids 2>/dev/null | wc -l | tr -d ' ')
    ok "$_inst_count instance(s) registered"

    # ── Corpus load phase ─────────────────────────────────────────────────────
    case "$MACHINE_LOAD" in
        runtime)
            # RE loaded corpus from MACHINES_DIR at boot (RE_LOAD_MACHINES=1).
            # No CI seeding needed. Bootstrap PE sources if requested.
            info "Machine load: runtime — corpus loaded by each RE at boot"
            if [ "$PE_SOURCE_BOOTSTRAP" = "auto" ]; then
                while IFS= read -r _inst_id; do
                    _inst_entry=$(registry_get "$_inst_id" 2>/dev/null || true)
                    _pe_url=$(echo "$_inst_entry" \
                        | python3 -c "import json,sys; print(json.load(sys.stdin).get('pe_url',''))" 2>/dev/null || true)
                    [ -z "$_pe_url" ] && continue
                    info "PE source bootstrap → $_inst_id ($_pe_url)..."
                    bash "$CI_DIR/scripts/pe-source-bootstrap.sh" "$_pe_url" \
                        > "/tmp/pe_bootstrap_${_inst_id}.log" 2>&1 \
                        && ok "PE sources bootstrapped ($_inst_id)" \
                        || add_warn "PE bootstrap for $_inst_id had errors — check /tmp/pe_bootstrap_${_inst_id}.log"
                done < <(registry_ids 2>/dev/null)
            fi
            ;;
        ci-seed)
            # RE started empty (RE_LOAD_MACHINES=0). CI seeds RE, then PE bootstrap.
            _seed_ok=true
            if [ "$VALIDATE_CORPUS" = "once" ] && [ -x "$MACHINES_DIR/scripts/validate-corpus.sh" ]; then
                info "Validating machine corpus..."
                if bash "$MACHINES_DIR/scripts/validate-corpus.sh" > /tmp/corpus_validate.log 2>&1; then
                    ok "Machine corpus valid"
                else
                    add_warn "Machine corpus validation failed — seed skipped (check /tmp/corpus_validate.log)"
                    _seed_ok=false
                fi
            fi
            if [ "$_seed_ok" = true ] && [ -x "$MACHINES_DIR/scripts/seed-machines.sh" ]; then
                while IFS= read -r _inst_id; do
                    _inst_entry=$(registry_get "$_inst_id" 2>/dev/null || true)
                    _re_url=$(echo "$_inst_entry" \
                        | python3 -c "import json,sys; print(json.load(sys.stdin).get('re_url',''))" 2>/dev/null || true)
                    _pe_url=$(echo "$_inst_entry" \
                        | python3 -c "import json,sys; print(json.load(sys.stdin).get('pe_url',''))" 2>/dev/null || true)
                    [ -z "$_re_url" ] && continue
                    info "Seeding RE machines → $_inst_id ($_re_url)..."
                    bash "$MACHINES_DIR/scripts/seed-machines.sh" --re-only "$_re_url" \
                        > "/tmp/corpus_seed_${_inst_id}.log" 2>&1 \
                        || add_warn "RE seed to $_inst_id completed with errors — check /tmp/corpus_seed_${_inst_id}.log"
                    if [ "$PE_SOURCE_BOOTSTRAP" = "auto" ] && [ -n "$_pe_url" ]; then
                        info "PE source bootstrap → $_inst_id ($_pe_url)..."
                        bash "$CI_DIR/scripts/pe-source-bootstrap.sh" "$_pe_url" \
                            >> "/tmp/corpus_seed_${_inst_id}.log" 2>&1 \
                            || add_warn "PE bootstrap for $_inst_id had errors"
                    fi
                done < <(registry_ids 2>/dev/null)
            fi
            ;;
        none)
            info "Machine load: none — RE empty, no seeding, no PE bootstrap"
            ;;
    esac
fi

# =============================================================================
hdr "4 · RealityEngine  (Scala/Akka built from RealityEngine_Scala)"
# =============================================================================

# ── manager-native: delegate Visualizer + PE to RealityEngine_Manager ─────
# When --manager-native is set the Docker compose stack runs only the RE API
# (Scala), Loki, Grafana, and the tls-proxy. Visualizer starts natively
# via RealityEngine_Manager/start.sh and points at the Docker public RE/PE endpoints.
# This mode is useful for frontend/PE development without Docker rebuilds.
if [ "$MANAGER_NATIVE" = true ]; then
    [ -d "$MGR_DIR" ] || die "--manager-native requires RealityEngine_Manager at $MGR_DIR"
    [ -x "$MGR_DIR/start.sh" ] || die "$MGR_DIR/start.sh missing or not executable"
    info "--manager-native: Visualizer + PE will be started via RealityEngine_Manager/start.sh"
    info "  RE API: https://localhost:5001  PE: https://localhost:3004"
fi

if [ "$MULTI_ENGINE_MODE" = true ]; then
    info "Multi-engine mode — Docker RE/PE services skipped (native instances already running)"

    # Start Manager (Visualizer backend + frontend) natively so port 5173 is available.
    # The visualizer backend uses RE_REGISTRY_URL to discover and switch instances;
    # --re/--pe provide the fallback for the first instance before the registry is polled.
    if [ -x "$MGR_DIR/start.sh" ]; then
        # Clear stale .manager-pids so start.sh doesn't exit early.
        # The pre-flight port check (above) already confirmed no live Manager process.
        rm -f "$MGR_DIR/.manager-pids"

        # Get first registered instance's URLs from the registry for the initial fallback
        _first_re_url=$(python3 -c "
import json, sys
try:
    with open('$REGISTRY_FILE') as f:
        inst = json.load(f).get('instances', [])
    print(inst[0]['re_url'] if inst else '')
except Exception:
    print('')
" 2>/dev/null || true)
        _first_pe_url=$(python3 -c "
import json, sys
try:
    with open('$REGISTRY_FILE') as f:
        inst = json.load(f).get('instances', [])
    print(inst[0]['pe_url'] if inst else '')
except Exception:
    print('')
" 2>/dev/null || true)
        _re_arg="${_first_re_url:-http://localhost:$(( SCALA_PE_BASE + 1 ))}"
        _pe_arg="${_first_pe_url:-http://localhost:${SCALA_PE_BASE}}"

        info "Starting Manager (Visualizer) natively — RE: $_re_arg  registry: http://$HOST_IP:${REGISTRY_PORT}/re-registry.json"
        RE_REGISTRY_URL="http://$HOST_IP:${REGISTRY_PORT}/re-registry.json" \
            VIZ_RATE_LIMIT_MAX="${VIZ_RATE_LIMIT_MAX:-5000}" \
            VIZ_MACHINES_RATE_LIMIT_MAX="${VIZ_MACHINES_RATE_LIMIT_MAX:-2000}" \
            nohup "$MGR_DIR/start.sh" --re "$_re_arg" --pe "$_pe_arg" --no-seed \
            > /tmp/manager_universe.log 2>&1 &
        MANAGER_PID=$!
        echo "$MANAGER_PID" > /tmp/manager_universe.pid
        echo -n "  MGR backend "
        # 60 × 2 s = 2 min — enough for npm install --prefer-offline on a cold cache
        poll_http "http://localhost:3001/health" "Manager backend ready (:3001)" 60 "-sf" || \
            add_warn "Manager backend not reachable on :3001 — check /tmp/manager_universe.log"
        echo -n "  MGR frontend "
        # Vite starts after the backend; 30 × 2 s = 60 s is more than enough
        poll_http "http://localhost:5173/" "Manager frontend ready (:5173)" 30 "-sf" || \
            add_warn "Manager frontend not reachable on :5173 — check $(ls "$MGR_DIR"/.manager-logs/frontend.log 2>/dev/null || echo '/tmp/manager_universe.log')"
    else
        add_warn "RealityEngine_Manager/start.sh not found — port 5173 will not be available"
    fi
else

cd "$CI_DIR"

# Build on the DEFAULT (docker-driver) builder so freshly-built images land in
# the engine image store and `docker compose up` can find them.
#
# An isolated `docker-container`-driver builder must NOT be used here: with that
# driver `docker compose build` only *names* the image inside the builder cache
# ("naming to ...:latest done") and does not load it into the engine store
# (that needs `--load`). The subsequent `docker compose up` then fails with
# `No such image: realityengine_ci-<svc>:latest` and the stack never starts.
# The docker driver builds straight into the store, which is what `up` reads.
docker buildx use default > /dev/null 2>&1 || true
ok "Using default (docker-driver) builder — images load into the engine store"

# RE image build.
#
# For --fresh we rebuild each service in SERIAL with an explicit, staged
# remove → rebuild → verify per image. A single parallel `docker compose build
# --no-cache` races the per-image "delete previous image, write new image" step
# in the engine store: while several builds replace their images concurrently,
# one image (most often reality-engine) is momentarily absent when
# `docker compose up` resolves it — surfacing as `No such image:
# realityengine_ci-<svc>:latest`. Serializing remove→build→verify per image
# keeps each replacement atomic and ordered, so every image is present before
# `up`.
RE_BUILD_SERVICES="reality-engine visualizer-backend visualizer-frontend perception-engine-backend perception-engine-frontend"
if [ "$FRESH_START" = true ]; then
    # Reclaim build cache first. A --fresh build is --no-cache, so accumulated
    # build cache is dead weight that fills the Docker VM disk. Under disk
    # pressure BuildKit's GC evicts freshly-built images mid-rebuild — the
    # large reality-engine image vanishes between its build and `up`, surfacing
    # as "No such image: realityengine_ci-reality-engine:latest". Pruning keeps
    # enough headroom that the serial rebuild's images survive to `up`.
    info "Reclaiming Docker build cache before no-cache rebuild (frees VM disk)..."
    docker builder prune -af > /dev/null 2>&1 || true
    info "Building RE images (no cache; serial remove → rebuild → verify per image)..."
    for _svc in $RE_BUILD_SERVICES; do
        _img="realityengine_ci-${_svc}:latest"
        info "  [$_svc] removing previous image..."
        docker image rm -f "$_img" > /dev/null 2>&1 || true
        info "  [$_svc] rebuilding (no cache)..."
        SCALA_DIR="$SCALA_DIR" MGR_DIR="$MGR_DIR" docker compose build --no-cache "$_svc" || \
            die "RE image build failed for $_svc — run:  docker compose build --no-cache $_svc"
        docker image inspect "$_img" > /dev/null 2>&1 || \
            die "$_img not in engine store after rebuild — image remove/rebuild staging failed for $_svc"
        ok "  [$_svc] rebuilt → present in engine store"
    done
    ok "All RE images rebuilt serially and present in engine store"
else
    info "Building RE images (cached)..."
    SCALA_DIR="$SCALA_DIR" MGR_DIR="$MGR_DIR" docker compose build || \
        die "RE image build failed — run:  docker compose build"
    # Verify each image is present; rebuild individually if the parallel build
    # left one out (same staging race, just less likely without --no-cache).
    for _svc in $RE_BUILD_SERVICES; do
        _img="realityengine_ci-${_svc}:latest"
        docker image inspect "$_img" > /dev/null 2>&1 || {
            warn "Image $_img missing after build — rebuilding $_svc individually..."
            SCALA_DIR="$SCALA_DIR" MGR_DIR="$MGR_DIR" docker compose build "$_svc" || \
                die "Individual rebuild of $_svc failed"
        }
    done
    ok "All RE images present in engine store"
fi

info "Starting RE services (waiting for all healthchecks, timeout 360s)..."
docker compose up -d --wait --wait-timeout 360 || \
    die "RE services failed to reach healthy state\n  Check:  docker compose logs"
ok "All RE services healthy"

info "Confirming RE external endpoints..."
if [ "$MANAGER_NATIVE" = true ]; then
    echo -n "  API "
    poll_http "https://localhost:5001/api/health" "RE API reachable (:5001)" 15 "-skf" || \
        add_warn "RE API not reachable on https://localhost:5001"
    # Start Manager (Visualizer + PE) natively — Scala preset
    info "Starting RealityEngine_Manager natively (--scala)..."
    echo "" >> /tmp/manager_universe.log 2>&1 || true
    "$MGR_DIR/start.sh" --re https://localhost:5001 --pe https://localhost:3004 > /tmp/manager_universe.log 2>&1 &
    MANAGER_PID=$!
    echo "$MANAGER_PID" > /tmp/manager_universe.pid
    echo -n "  VIZ "
    poll_http "http://localhost:3001/health" "Visualizer backend ready" 30 "-sf" || \
        add_warn "Visualizer backend not reachable on :3001"
    echo -n "  PE  "
    poll_http "https://localhost:3004/api/health" "PE backend ready (:3004)" 30 "-skf" || \
        add_warn "PE backend not reachable on https://localhost:3004"
else
    echo -n "  API "
    poll_http "https://localhost:5001/api/health" "RE API reachable" 15 "-skf" || \
        add_warn "RE API not reachable on https://localhost:5001 after startup"
    echo -n "  PE  "
    poll_http "https://localhost:3004/api/health" "PE Backend reachable" 15 "-skf" || \
        add_warn "Perception Engine not reachable on https://localhost:3004 after startup"
fi

set +e
PE_SRC_COUNT=$(curl -sk https://localhost:3004/api/sources 2>/dev/null \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('sources',[])))" \
    2>/dev/null || echo "?")
RE_MACHINE_COUNT=$(curl -sk https://localhost:5001/api/machines 2>/dev/null \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('machines',[])))" \
    2>/dev/null || echo "?")
set -e
ok "RE baseline: $RE_MACHINE_COUNT machines, $PE_SRC_COUNT PE sources"

# ── Corpus load phase (Docker RE) ─────────────────────────────────────────
case "$MACHINE_LOAD" in
    runtime)
        # Docker RE loaded corpus from its own MACHINES_DIR volume at boot.
        info "Machine load: runtime — corpus loaded by Docker RE at boot"
        if [ "$PE_SOURCE_BOOTSTRAP" = "auto" ]; then
            info "Bootstrapping PE test sources from RE machines..."
            bash "$CI_DIR/scripts/pe-source-bootstrap.sh" "https://localhost:3004" \
                > /tmp/pe_bootstrap.log 2>&1 \
                && ok "PE sources bootstrapped (see /tmp/pe_bootstrap.log)" \
                || add_warn "PE source bootstrap completed with errors — check /tmp/pe_bootstrap.log"
        fi
        ;;
    ci-seed)
        CORPUS_VALID=true
        if [ "$VALIDATE_CORPUS" = "once" ] && [ -x "$MACHINES_DIR/scripts/validate-corpus.sh" ]; then
            info "Validating machine corpus..."
            if bash "$MACHINES_DIR/scripts/validate-corpus.sh" > /tmp/corpus_validate.log 2>&1; then
                ok "Machine corpus valid"
            else
                add_warn "Machine corpus validation failed — seed skipped (check /tmp/corpus_validate.log)"
                CORPUS_VALID=false
            fi
        fi
        if [ "$CORPUS_VALID" != true ]; then
            info "Machine seed skipped because corpus validation failed"
        elif [ -x "$MACHINES_DIR/scripts/seed-machines.sh" ]; then
            info "Seeding RE machines from RealityEngine_Machines (RE only)..."
            bash "$MACHINES_DIR/scripts/seed-machines.sh" --re-only \
                "https://localhost:5001" > /tmp/corpus_seed.log 2>&1 \
                && ok "RE machines seeded (see /tmp/corpus_seed.log)" \
                || add_warn "Machine seeding completed with errors — check /tmp/corpus_seed.log"
            if [ "$PE_SOURCE_BOOTSTRAP" = "auto" ]; then
                info "Bootstrapping PE test sources from RE machines..."
                bash "$CI_DIR/scripts/pe-source-bootstrap.sh" "https://localhost:3004" \
                    >> /tmp/corpus_seed.log 2>&1 \
                    && ok "PE sources bootstrapped" \
                    || add_warn "PE source bootstrap completed with errors"
            fi
        else
            info "RealityEngine_Machines/scripts/seed-machines.sh not found — skipping seed"
        fi
        ;;
    none)
        info "Machine load: none — RE empty, no seeding, no PE bootstrap"
        ;;
esac

fi  # end: if [ "$MULTI_ENGINE_MODE" = false ] Docker RE block

start_observability_stack
validate_metrics_surfaces

if [ "$LOCAL_AI_ENABLED" = true ]; then
    configure_localai_bridge_targets
fi

# =============================================================================
hdr "5 · localAIStack API  (FastAPI + RAG + Ollama bridge)"
# =============================================================================

if [ "$LOCAL_AI_ENABLED" != true ]; then
    info "localAIStack API: skipped (--no-local-ai)"
else
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
fi

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
        for _ocs_check_port in "$OCS_GW_PORT" "$OCS_UI_PORT"; do
            _ocs_blocker=$(lsof -ti TCP:"$_ocs_check_port" -sTCP:LISTEN 2>/dev/null | head -1 || true)
            [ -n "$_ocs_blocker" ] && \
                die "OpenClaw port $_ocs_check_port in use by PID $_ocs_blocker — stop it and retry"
        done

        info "Starting OpenClaw (gateway :$OCS_GW_PORT, webui :$OCS_UI_PORT)..."
        (cd "$OCS_DIR" && ./scripts/start.sh > /tmp/ocs_start.log 2>&1) || \
            die "OpenClaw startup failed\n$(tail -20 /tmp/ocs_start.log 2>/dev/null)"

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
hdr "5.6 · MCP + OpenAPI Service Surfaces"
# =============================================================================

start_mcp_http_service
start_openapi_swagger_service

# =============================================================================
hdr "6 · Integration Verification"
# =============================================================================

validate_mcp_and_openapi

if [ "$MULTI_ENGINE_MODE" = false ]; then
set +e
VERIFY_PASS=false
for attempt in 1 2 3; do
    [ "$attempt" -gt 1 ] && { info "Retry $attempt/3 — waiting 15s for hooks to settle..."; sleep 15; }

    RE_MACHINES=$(curl -sk https://localhost:5001/api/machines 2>/dev/null || echo '{"machines":[]}')
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
    add_warn "Integration hooks incomplete — rerun startUniverse or recreate localAIStack api with RE_URL=$RE_URL PE_URL=$PE_URL"
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

SMOKE_DIM="${VECTOR_DIMENSION:-7680}"
if [ "$MULTI_ENGINE_MODE" = false ]; then
set +e
info "RE perceive smoke-test (${SMOKE_DIM}-element zero vector)..."
ZERO_VEC=$(python3 -c "import json; print(json.dumps([0.0]*${SMOKE_DIM}))" 2>/dev/null || echo "")
if [ -n "$ZERO_VEC" ]; then
    PERCEIVE_RESP=$(curl -sk -X POST https://localhost:5001/api/perceive \
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

if [ "$LOCAL_AI_ENABLED" = true ]; then
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

# ── MQTT Yuma integration test (when broker is configured) ────────────────
if [ -n "${MQTT_BROKER_URL:-}" ] && [ "$MULTI_ENGINE_MODE" = false ]; then
  if [ -x "$CI_DIR/scripts/test-mqtt-yuma.sh" ]; then
    hdr "7.5 · MQTT Yuma Integration"
    MQTT_YUMA_ARGS=(--pe-url "https://localhost:3004" --broker-url "$MQTT_BROKER_URL")
    [ -n "${MQTT_MAPPINGS_FILE:-}" ] && [ -f "$MQTT_MAPPINGS_FILE" ] && \
      MQTT_YUMA_ARGS+=(--mappings "$MQTT_MAPPINGS_FILE")
    [ -n "${MQTT_USERNAME:-}" ] && MQTT_YUMA_ARGS+=(--username "$MQTT_USERNAME")
    [ -n "${MQTT_PASSWORD:-}" ] && MQTT_YUMA_ARGS+=(--password "$MQTT_PASSWORD")
    # Bridge was already started by PE at boot via env vars — skip re-enable
    MQTT_YUMA_ARGS+=(--skip-enable)
    set +e
    bash "$CI_DIR/scripts/test-mqtt-yuma.sh" "${MQTT_YUMA_ARGS[@]}" || \
      add_warn "MQTT Yuma integration test failed — check broker connectivity"
    set -e
  fi
fi

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
              if curl -sf --max-time 10 -X POST "$_sm_re_url/api/engine/reset" \
                  -H "Content-Type: application/json" \
                  -d '{}' >/dev/null 2>&1; then
                  ok "RE reset after perceive smoke-test (${_sm_first_id})"
              else
                  add_warn "${_sm_first_id} reset after perceive smoke-test returned no response"
                  warn "RE reset after perceive smoke-test [${_sm_first_id}]: no response"
              fi
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

  if [ "$LOCAL_AI_ENABLED" = true ]; then
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
echo "  API Integration Surfaces"
if [ "$MCP_HTTP_ENABLED" = "true" ]; then
printf "    %-30s %s\n" "MCP HTTP Gateway"          "http://${RE_MCP_HTTP_HOST}:${RE_MCP_HTTP_PORT}/mcp"
printf "    %-30s %s\n" "MCP Health"                "http://${RE_MCP_HTTP_HOST}:${RE_MCP_HTTP_PORT}/healthz"
fi
if [ "$OPENAPI_SWAGGER_ENABLED" = "true" ]; then
printf "    %-30s %s\n" "OpenAPI Swagger"           "http://${OPENAPI_SWAGGER_HOST}:${OPENAPI_SWAGGER_PORT}/"
printf "    %-30s %s\n" "OpenAPI Specs"             "http://${OPENAPI_SWAGGER_HOST}:${OPENAPI_SWAGGER_PORT}/{cpp,lsp,scala}-{re,pe}.yaml"
fi
echo ""
echo "  Observability"
printf "    %-30s %s\n" "Grafana"                   "http://localhost:3002"
printf "    %-30s %s\n" "Prometheus"                "http://localhost:9090"
printf "    %-30s %s\n" "AI Bridge Metrics"         "http://localhost:${BRIDGE_METRICS_PORT}/metrics"
printf "    %-30s %s\n" "Loki"                      "https://localhost:3100"
echo ""
if [ "$OCS_STARTED" = true ]; then
echo "  OpenClaw"
printf "    %-30s %s\n" "ACP xACP Gateway"          "http://localhost:${OCS_GW_PORT}"
printf "    %-30s %s\n" "Open WebUI (Chat)"         "http://localhost:${OCS_UI_PORT}"
echo ""
fi
if [ "$MULTI_ENGINE_MODE" = true ]; then
echo "  RealityEngine  — Multi-Engine Native Mode"
printf "    %-30s %s\n" "Visualizer UI"             "http://localhost:5173"
printf "    %-30s %s\n" "Visualizer Backend"        "http://localhost:3001"
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
printf "    %-30s %s\n" "Grafana (TLS proxy)"       "https://localhost:3000"
printf "    %-30s %s\n" "RE API (Docker/Scala)"     "https://localhost:5001"
printf "    %-30s %s\n" "Visualizer"                "https://localhost:5173"
printf "    %-30s %s\n" "Perception Engine API"     "https://localhost:3004"
printf "    %-30s %s\n" "Perception Engine UI"      "https://localhost:3005"
if [ -n "${MQTT_BROKER_URL:-}" ]; then
printf "    %-30s %s\n" "MQTT broker"               "$MQTT_BROKER_URL"
printf "    %-30s %s\n" "MQTT status"               "https://localhost:3004/api/mqtt/status"
fi
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
    if [ "$LOCAL_AI_ENABLED" = true ]; then
        echo "  Re-trigger localAIStack hooks with the active bridge target:"
        echo "    (cd $LAS_DIR && RE_URL=$RE_URL PE_URL=$PE_URL RE_SSL_VERIFY=${RE_SSL_VERIFY:-false} docker compose up -d --force-recreate api)"
        echo ""
    fi
else
    echo "════════════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Integration verified — all systems nominal${NC}"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
fi

# ── Write universe manifest ────────────────────────────────────────────────────
_docker_svcs="loki,prometheus,grafana,qdrant,redis"
[ "$MULTI_ENGINE_MODE" = false ] && _docker_svcs="$_docker_svcs,reality-engine,visualizer,perception-engine"
[ "$LOCAL_AI_ENABLED" = true ] && _docker_svcs="$_docker_svcs,localai_api"
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
    "prometheus_started":      "$PROMETHEUS_STARTED" == "true",
    "prometheus_url":          "http://localhost:9090",
    "grafana_started":         "$GRAFANA_STARTED" == "true",
    "grafana_url":             "http://localhost:3002",
    "bridge_metrics_started":  "$BRIDGE_METRICS_STARTED" == "true",
    "bridge_metrics_url":      "http://localhost:${BRIDGE_METRICS_PORT}/metrics",
    "mcp_http_enabled":        "$MCP_HTTP_ENABLED" == "true",
    "mcp_http_started":        "$MCP_HTTP_STARTED" == "true",
    "mcp_http_url":            "http://${RE_MCP_HTTP_HOST}:${RE_MCP_HTTP_PORT}/mcp",
    "openapi_swagger_enabled": "$OPENAPI_SWAGGER_ENABLED" == "true",
    "openapi_swagger_started": "$OPENAPI_SWAGGER_STARTED" == "true",
    "openapi_swagger_url":     "http://${OPENAPI_SWAGGER_HOST}:${OPENAPI_SWAGGER_PORT}/",
    "warns":                   ${#WARNS[@]},
}
with open("/tmp/universe-manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
MANIFEST_EOF
ok "Universe manifest written: /tmp/universe-manifest.json"

if [ "${UNIVERSE_HOLD_OPEN:-false}" = "true" ]; then
    info "UNIVERSE_HOLD_OPEN=true — keeping startUniverse.sh alive; stop with ./stopUniverse.sh"
    while true; do
        sleep 3600
    done
fi
