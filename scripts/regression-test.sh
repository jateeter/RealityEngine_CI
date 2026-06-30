#!/usr/bin/env bash
# RealityEngine regression-test workflow orchestrator.
#
# Default mode is a safe plan. Use --execute to run commands that create
# worktrees, build repositories, start the universe, and run live tests.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="$(cd "$CI_DIR/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
HISTORY_DIR="$CI_DIR/.regression-tests"
RUN_DIR=""
BRANCH_NAME="Regression-Test"
EXECUTE=false
COLD_START=true
BUILD=true
START=true
OPENCLAW_FLAG="--openclaw"
MQTT_BROKER_URL="${MQTT_BROKER_URL:-}"
MQTT_MAPPINGS="${MQTT_MAPPINGS:-}"
MCP_URL="${MCP_URL:-http://127.0.0.1:7331}"
ENGINES_SPEC="cpp:1,lsp:1,scala:1"
RETAIN=20

REPOS=(
  RealityEngine_CI
  RealityEngine_CPP
  RealityEngine_LSP
  RealityEngine_Scala
  RealityEngine_Machines
  RealityEngine_Manager
  localAIStack
  localOpenClawStack
)

usage() {
  cat <<'USAGE'
regression-test.sh — standard multi-engine regression workflow

Usage:
  bash scripts/regression-test.sh [--execute] [options]

Options:
  --execute                 Run the workflow. Default is plan-only.
  --branch NAME             Regression branch name for run-local worktrees.
  --history-dir DIR         Run-history root. Default: .regression-tests
  --run-id ID               Override generated run id.
  --no-cold-start           Do not create run-local worktrees.
  --skip-build              Skip full build phase.
  --skip-start              Skip universe start phase; use current deployment.
  --engines SPEC            Engine spec. Default: cpp:1,lsp:1,scala:1
  --mqtt-broker-url URL     Yuma MQTT broker URL.
  --mqtt-mappings PATH      Yuma MQTT mappings file.
  --mcp-url URL             MCP HTTP base URL. Default: http://127.0.0.1:7331
  --openclaw                Require OpenClaw. Default.
  --no-openclaw             Skip OpenClaw.
  --retain N                Keep latest N local run histories. Default: 20
  --help                    Show this help.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --branch=*) BRANCH_NAME="${1#*=}"; shift ;;
    --branch) BRANCH_NAME="$2"; shift 2 ;;
    --history-dir=*) HISTORY_DIR="${1#*=}"; shift ;;
    --history-dir) HISTORY_DIR="$2"; shift 2 ;;
    --run-id=*) RUN_ID="${1#*=}"; shift ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --no-cold-start) COLD_START=false; shift ;;
    --skip-build) BUILD=false; shift ;;
    --skip-start) START=false; shift ;;
    --engines=*) ENGINES_SPEC="${1#*=}"; shift ;;
    --engines) ENGINES_SPEC="$2"; shift 2 ;;
    --mqtt-broker-url=*) MQTT_BROKER_URL="${1#*=}"; shift ;;
    --mqtt-broker-url) MQTT_BROKER_URL="$2"; shift 2 ;;
    --mqtt-mappings=*) MQTT_MAPPINGS="${1#*=}"; shift ;;
    --mqtt-mappings) MQTT_MAPPINGS="$2"; shift 2 ;;
    --mcp-url=*) MCP_URL="${1#*=}"; shift ;;
    --mcp-url) MCP_URL="$2"; shift 2 ;;
    --openclaw) OPENCLAW_FLAG="--openclaw"; shift ;;
    --no-openclaw) OPENCLAW_FLAG="--no-openclaw"; shift ;;
    --retain=*) RETAIN="${1#*=}"; shift ;;
    --retain) RETAIN="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

RUN_DIR="$HISTORY_DIR/runs/$RUN_ID"
LOG_DIR="$RUN_DIR/logs"
REPORT_DIR="$RUN_DIR/reports"
WORKTREE_DIR="$RUN_DIR/worktrees"
WORKTREE_BRANCH="$BRANCH_NAME-$RUN_ID"

log() { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

repo_path() {
  printf '%s/%s\n' "$WS" "$1"
}

worktree_path() {
  printf '%s/%s\n' "$WORKTREE_DIR" "$1"
}

run_cmd() {
  local label="$1"; shift
  local log_file="$LOG_DIR/${label//[^A-Za-z0-9_.-]/_}.log"
  log "+ $*"
  if [ "$EXECUTE" = false ]; then
    return 0
  fi
  "$@" > "$log_file" 2>&1
}

record_manifest() {
  mkdir -p "$RUN_DIR"
  python3 - "$RUN_DIR/manifest.json" "$RUN_ID" "$BRANCH_NAME" "$WORKTREE_BRANCH" "$ENGINES_SPEC" <<'PYEOF'
import json
import sys
from pathlib import Path

path, run_id, branch, worktree_branch, engines = sys.argv[1:]
payload = {
    "runId": run_id,
    "branch": branch,
    "worktreeBranch": worktree_branch,
    "engineSpec": engines,
    "status": "planned",
    "repos": [],
    "artifacts": {
        "logs": "logs",
        "reports": "reports",
        "worktrees": "worktrees",
    },
}
Path(path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PYEOF
}

update_manifest_status() {
  local status="$1"
  [ -n "$RUN_DIR" ] || return 0
  [ -f "$RUN_DIR/manifest.json" ] || return 0
  python3 - "$RUN_DIR/manifest.json" "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PYEOF'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
status = sys.argv[2]
timestamp = sys.argv[3]
payload = json.loads(path.read_text(encoding="utf-8"))
payload["status"] = status
payload["finishedAt"] = timestamp
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYEOF
}

plan() {
  step "Regression Test Plan"
  log "run id:       $RUN_ID"
  log "history dir:  $HISTORY_DIR"
  log "branch:       $BRANCH_NAME"
  log "run branch:   $WORKTREE_BRANCH"
  log "engines:      $ENGINES_SPEC"
  log "cold start:   $COLD_START"
  log "build:        $BUILD"
  log "start:        $START"
  log "openclaw:     $OPENCLAW_FLAG"
  log "mqtt broker:  ${MQTT_BROKER_URL:-<not configured>}"
  log "mcp url:      $MCP_URL"
  log ""
  log "repositories:"
  for repo in "${REPOS[@]}"; do
    log "  - $repo"
  done
  if [ "$EXECUTE" = false ]; then
    log ""
    log "Plan-only mode. Re-run with --execute to create worktrees and run tests."
  fi
}

prepare_history() {
  mkdir -p "$LOG_DIR" "$REPORT_DIR" "$WORKTREE_DIR"
  record_manifest
  trap 'update_manifest_status failed' ERR
}

create_worktrees() {
  [ "$COLD_START" = true ] || return 0
  step "Cold-start worktrees"
  for repo in "${REPOS[@]}"; do
    local source target
    source="$(repo_path "$repo")"
    target="$(worktree_path "$repo")"
    if [ ! -d "$source/.git" ]; then
      log "SKIP $repo: missing git repo at $source"
      continue
    fi
    run_cmd "fetch-$repo" git -C "$source" fetch origin main
    run_cmd "worktree-$repo" git -C "$source" worktree add -B "$WORKTREE_BRANCH" "$target" origin/main
  done
}

repo_root() {
  local repo="$1"
  if [ "$COLD_START" = true ]; then
    worktree_path "$repo"
  else
    repo_path "$repo"
  fi
}

build_repos() {
  [ "$BUILD" = true ] || return 0
  step "Full build"
  run_cmd "build-ci-npm-install" bash -lc "cd '$(repo_root RealityEngine_CI)' && npm ci"
  run_cmd "build-ci-mcp-test" bash -lc "cd '$(repo_root RealityEngine_CI)/mcp' && npm install && npm test"
  run_cmd "build-cpp" bash -lc "cd '$(repo_root RealityEngine_CPP)' && make all"
  run_cmd "build-lsp" bash -lc "cd '$(repo_root RealityEngine_LSP)' && make build"
  run_cmd "build-scala" bash -lc "cd '$(repo_root RealityEngine_Scala)' && sbt clean compile"
  run_cmd "validate-machines" bash -lc "cd '$(repo_root RealityEngine_Machines)' && bash scripts/validate-corpus.sh"
  for package_dir in \
    "visualizer/backend" \
    "visualizer/frontend" \
    "perception-engine/backend" \
    "perception-engine/frontend"; do
    run_cmd "build-manager-${package_dir//\//-}" bash -lc \
      "cd '$(repo_root RealityEngine_Manager)/$package_dir' && npm ci && npm run build"
  done
  run_cmd "build-localai-compose" bash -lc "cd '$(repo_root localAIStack)' && docker compose build"
  run_cmd "build-openclaw-compose" bash -lc "cd '$(repo_root localOpenClawStack)' && docker compose build"
}

start_universe() {
  [ "$START" = true ] || return 0
  step "Cold-start standard multi-engine universe"
  local ci
  ci="$(repo_root RealityEngine_CI)"
  local args=(
    "--fresh"
    "--engines=$ENGINES_SPEC"
    "--machine-load=runtime"
    "--pe-source-bootstrap=auto"
    "$OPENCLAW_FLAG"
    "--warn-only"
  )
  [ -n "$MQTT_BROKER_URL" ] && args+=("--mqtt-broker-url=$MQTT_BROKER_URL")
  [ -n "$MQTT_MAPPINGS" ] && args+=("--mqtt-mappings=$MQTT_MAPPINGS")
  run_cmd "start-universe" bash -lc "cd '$ci' && ./startUniverse.sh ${args[*]}"
}

run_universal_vectors() {
  step "Universal input event vector parity"
  local ci machines
  ci="$(repo_root RealityEngine_CI)"
  machines="$(repo_root RealityEngine_Machines)/machines"
  run_cmd "universal-vectors" python3 "$ci/scripts/regression-universal-vectors.py" \
    --registry /tmp/re-registry/re-registry.json \
    --machines "$machines" \
    --events 5 \
    --run-id "$RUN_ID" \
    --out "$RUN_DIR/responses/universal-vectors"
}

registry_pe_lines() {
  python3 - /tmp/re-registry/re-registry.json <<'PYEOF'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"could not read registry {path}: {exc}") from exc

for item in data.get("instances", []):
    runtime = item.get("runtime")
    pe_url = item.get("pe_url")
    status = item.get("status", "running")
    if runtime and pe_url and status == "running":
        print(f"{runtime}|{pe_url}")
PYEOF
}

run_mqtt_yuma() {
  step "MQTT Yuma stream"
  if [ -z "$MQTT_BROKER_URL" ]; then
    log "SKIP MQTT: --mqtt-broker-url not provided"
    return 0
  fi
  local ci
  ci="$(repo_root RealityEngine_CI)"
  local mqtt_args=(--broker-url "$MQTT_BROKER_URL" --skip-enable)
  [ -n "$MQTT_MAPPINGS" ] && mqtt_args+=(--mappings "$MQTT_MAPPINGS")
  local found=false
  while IFS='|' read -r runtime pe_url; do
    [ -n "$runtime" ] || continue
    found=true
    run_cmd "mqtt-yuma-$runtime" bash "$ci/scripts/test-mqtt-yuma.sh" \
      --pe-url "$pe_url" \
      "${mqtt_args[@]}"
  done < <(registry_pe_lines)
  [ "$found" = true ] || { log "SKIP MQTT: no running PE instances in registry"; return 0; }
}

run_mcp() {
  step "MCP open service"
  run_cmd "mcp-health" curl -sf "$MCP_URL/healthz"
  local init_body
  init_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"realityengine-regression","version":"1.0.0"}}}'
  run_cmd "mcp-initialize" curl -sS -X POST "$MCP_URL/mcp" \
    -H "content-type: application/json" \
    -H "accept: application/json, text/event-stream" \
    -d "$init_body"
  run_cmd "mcp-list-tools" bash -lc "cd '$(repo_root RealityEngine_CI)/mcp' && RE_REGISTRY_URL='http://127.0.0.1:5999/re-registry.json' npm run -s list-tools"
}

run_openclaw() {
  step "OpenClaw async handoff and PE completion return"
  [ "$OPENCLAW_FLAG" = "--openclaw" ] || { log "SKIP OpenClaw: disabled"; return 0; }
  local ci
  ci="$(repo_root RealityEngine_CI)"
  local found=false
  while IFS='|' read -r runtime pe_url; do
    [ -n "$runtime" ] || continue
    found=true
    run_cmd "openclaw-integration-$runtime" env \
      PE_URL="$pe_url" \
      OPENCLAW_E2E_RUN_ID="$RUN_ID-$runtime" \
      bash "$ci/scripts/test-openclaw-integration.sh"
  done < <(registry_pe_lines)
  [ "$found" = true ] || { log "SKIP OpenClaw: no running PE instances in registry"; return 0; }
}

write_summary() {
  mkdir -p "$RUN_DIR"
  cat > "$RUN_DIR/summary.md" <<EOF
# Regression Test Run $RUN_ID

- Branch: \`$BRANCH_NAME\`
- Run branch: \`$WORKTREE_BRANCH\`
- Engine spec: \`$ENGINES_SPEC\`
- Cold start: \`$COLD_START\`
- OpenClaw: \`$OPENCLAW_FLAG\`
- MQTT broker: \`${MQTT_BROKER_URL:-<not configured>}\`
- MCP URL: \`$MCP_URL\`

Artifacts are under this run directory:

- \`logs/\`
- \`reports/\`
- \`responses/\`
- \`worktrees/\`
EOF
}

retain_history() {
  [ "$EXECUTE" = true ] || return 0
  [ "$RETAIN" -gt 0 ] 2>/dev/null || return 0
  if [ -d "$HISTORY_DIR/runs" ]; then
    while IFS= read -r old_run; do
      [ -n "$old_run" ] || continue
      for repo in "${REPOS[@]}"; do
        local source tree
        source="$(repo_path "$repo")"
        tree="$old_run/worktrees/$repo"
        if [ -d "$source/.git" ] && [ -d "$tree/.git" ]; then
          git -C "$source" worktree remove --force "$tree" >/dev/null 2>&1 || true
          git -C "$source" worktree prune >/dev/null 2>&1 || true
        fi
      done
      rm -rf "$old_run"
    done < <(find "$HISTORY_DIR/runs" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +"$((RETAIN + 1))")
  fi
}

plan
if [ "$EXECUTE" = false ]; then
  exit 0
fi

prepare_history
create_worktrees
build_repos
start_universe
run_universal_vectors
run_mqtt_yuma
run_mcp
run_openclaw
write_summary
retain_history
update_manifest_status completed

log ""
log "Regression workflow executed."
log "Run directory: $RUN_DIR"
