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
LIVE_TESTS=true

# Lane profile. The hosted GitHub-Actions lane and the local lane differ in
# what they are *permitted* to start, not merely in what they happen to start:
#
#   hosted — never localAI/Ollama, never OpenClaw, never the full corpus.
#            None can be honestly exercised on a hosted runner with no GPU,
#            no local stack, and a six-hour platform ceiling.
#   local  — the whole stack on operator hardware, no exclusions.
#
# The hosted profile refuses a conflicting flag instead of quietly correcting
# it. Correcting hides the mistake; a silently-enabled Ollama on a hosted
# runner presents as a 350-minute timeout, not as anything readable.
PROFILE="local"
OPENCLAW_FLAG=""             # resolved from PROFILE unless set explicitly
LOCAL_AI=""                  # true|false, resolved from PROFILE
MACHINE_CORPUS=""            # full|standard-deployment, resolved from PROFILE
OPENCLAW_SET=false
LOCAL_AI_SET=false
MACHINE_CORPUS_SET=false

# Mirrors startUniverse.sh's default; where the standard-deployment subset is
# materialised and booted from.
MACHINE_CORPUS_WORK_DIR="${MACHINE_CORPUS_WORK_DIR:-/tmp/realityengine-standard-deployment-corpus}"

MQTT_BROKER_URL="${MQTT_BROKER_URL:-}"
MQTT_MAPPINGS="${MQTT_MAPPINGS:-}"
MCP_URL="${MCP_URL:-http://127.0.0.1:7331}"
SWAGGER_URL="${SWAGGER_URL:-http://127.0.0.1:8088}"
ENGINES_SPEC="cpp:1,lsp:1,scala:1"
RETAIN=20
COMPARE_RUN=""
ARCHIVE_DIR=""

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
  --profile hosted|local    Lane profile. Default: local
                              hosted — no localAI, no OpenClaw, standard-deployment
                                       corpus. Refuses any flag asking otherwise.
                              local  — localAI, OpenClaw, full corpus.
  --branch NAME             Regression branch name for run-local worktrees.
  --history-dir DIR         Run-history root. Default: .regression-tests
  --run-id ID               Override generated run id.
  --no-cold-start           Do not create run-local worktrees.
  --skip-build              Skip full build phase.
  --skip-start              Skip universe start phase; use current deployment.
  --build-only              Create worktrees and build only; skip start/live tests.
  --engines SPEC            Engine spec. Default: cpp:1,lsp:1,scala:1
  --mqtt-broker-url URL     Yuma MQTT broker URL.
  --mqtt-mappings PATH      Yuma MQTT mappings file.
  --mcp-url URL             MCP HTTP base URL. Default: http://127.0.0.1:7331
  --swagger-url URL         OpenAPI Swagger base URL. Default: http://127.0.0.1:8088
  --openclaw                Require OpenClaw. Default under --profile local.
  --no-openclaw             Skip OpenClaw. Forced under --profile hosted.
  --local-ai                Start Ollama and localAIStack. Default under --profile local.
  --no-local-ai             Skip both. Forced under --profile hosted.
  --machine-corpus CORPUS   full | standard-deployment. Default: per profile.
  --retain N                Keep latest N local run histories. Default: 20
  --compare RUN_ID          Compare against a previous run id. Default: latest completed run.
  --archive PATH            Copy certification artifacts to PATH/<run-id>.
  --help                    Show this help.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --branch=*) BRANCH_NAME="${1#*=}"; shift ;;
    --branch) BRANCH_NAME="$2"; shift 2 ;;
    --history-dir=*) HISTORY_DIR="${1#*=}"; shift ;;
    --history-dir) HISTORY_DIR="$2"; shift 2 ;;
    --run-id=*) RUN_ID="${1#*=}"; shift ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --no-cold-start) COLD_START=false; shift ;;
    --skip-build) BUILD=false; shift ;;
    --skip-start) START=false; shift ;;
    --build-only) START=false; LIVE_TESTS=false; shift ;;
    --engines=*) ENGINES_SPEC="${1#*=}"; shift ;;
    --engines) ENGINES_SPEC="$2"; shift 2 ;;
    --mqtt-broker-url=*) MQTT_BROKER_URL="${1#*=}"; shift ;;
    --mqtt-broker-url) MQTT_BROKER_URL="$2"; shift 2 ;;
    --mqtt-mappings=*) MQTT_MAPPINGS="${1#*=}"; shift ;;
    --mqtt-mappings) MQTT_MAPPINGS="$2"; shift 2 ;;
    --mcp-url=*) MCP_URL="${1#*=}"; shift ;;
    --mcp-url) MCP_URL="$2"; shift 2 ;;
    --swagger-url=*) SWAGGER_URL="${1#*=}"; shift ;;
    --swagger-url) SWAGGER_URL="$2"; shift 2 ;;
    --openclaw) OPENCLAW_FLAG="--openclaw"; OPENCLAW_SET=true; shift ;;
    --no-openclaw) OPENCLAW_FLAG="--no-openclaw"; OPENCLAW_SET=true; shift ;;
    --local-ai) LOCAL_AI=true; LOCAL_AI_SET=true; shift ;;
    --no-local-ai) LOCAL_AI=false; LOCAL_AI_SET=true; shift ;;
    --machine-corpus=*) MACHINE_CORPUS="${1#*=}"; MACHINE_CORPUS_SET=true; shift ;;
    --machine-corpus) MACHINE_CORPUS="$2"; MACHINE_CORPUS_SET=true; shift 2 ;;
    --retain=*) RETAIN="${1#*=}"; shift ;;
    --retain) RETAIN="$2"; shift 2 ;;
    --compare=*) COMPARE_RUN="${1#*=}"; shift ;;
    --compare) COMPARE_RUN="$2"; shift 2 ;;
    --archive=*) ARCHIVE_DIR="${1#*=}"; shift ;;
    --archive) ARCHIVE_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# ── Profile resolution ───────────────────────────────────────────────────────
# An unset knob takes the profile's value; a knob the caller set is checked
# against the profile and, on the hosted lane, refused. Six independent
# variables can drift out of agreement with each other. One profile cannot.
FRESH_FLAG=""
PROFILE_CONFLICT=false
profile_refuse() {
  printf 'error: --profile hosted will not %s\n' "$1" >&2
  PROFILE_CONFLICT=true
}

case "$PROFILE" in
  hosted)
    # No --fresh. It runs `docker builder prune -af` and rebuilds five images
    # with --no-cache to clear state a persistent host accumulates. A hosted
    # runner is pristine by construction, so that buys nothing and spends the
    # disk headroom the no-cache rebuild itself warns about running out of.
    FRESH_FLAG=""
    [ "$OPENCLAW_SET" = true ]       || OPENCLAW_FLAG="--no-openclaw"
    [ "$LOCAL_AI_SET" = true ]       || LOCAL_AI=false
    [ "$MACHINE_CORPUS_SET" = true ] || MACHINE_CORPUS="standard-deployment"
    [ "$OPENCLAW_FLAG" = "--no-openclaw" ] || profile_refuse "run OpenClaw (--openclaw)"
    [ "$LOCAL_AI" = false ] || profile_refuse "run localAI/Ollama (--local-ai)"
    [ "$MACHINE_CORPUS" = "standard-deployment" ] ||
      profile_refuse "load the '$MACHINE_CORPUS' corpus (--machine-corpus=$MACHINE_CORPUS)"
    if [ "$PROFILE_CONFLICT" = true ]; then
      echo "       These never run on a hosted runner. Use --profile local," >&2
      echo "       which runs the full stack on operator hardware." >&2
      exit 2
    fi
    ;;
  local)
    FRESH_FLAG="--fresh"
    [ "$OPENCLAW_SET" = true ]       || OPENCLAW_FLAG="--openclaw"
    [ "$LOCAL_AI_SET" = true ]       || LOCAL_AI=true
    [ "$MACHINE_CORPUS_SET" = true ] || MACHINE_CORPUS="full"
    ;;
  *)
    echo "Unsupported --profile: $PROFILE (hosted|local)" >&2
    exit 2
    ;;
esac

case "$MACHINE_CORPUS" in
  full|standard-deployment) ;;
  *) echo "Unsupported --machine-corpus: $MACHINE_CORPUS (full|standard-deployment)" >&2; exit 2 ;;
esac

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

# Every command's output goes to a log file, so a failure otherwise surfaces as
# a bare exit code with the explanation sitting in a file nobody can reach —
# on CI the run directory is discarded when the job ends. Print the tail.
dump_log_tail() {
  local label="$1" status="$2" log_file="$3"
  echo "" >&2
  echo "--- $label failed (exit $status) — last 80 lines of $log_file ---" >&2
  tail -n 80 "$log_file" >&2 2>/dev/null || echo "(no log file)" >&2
  echo "--- end $label ---" >&2
}

run_cmd() {
  local label="$1"; shift
  local log_file="$LOG_DIR/${label//[^A-Za-z0-9_.-]/_}.log"
  local status=0
  log "+ $*"
  if [ "$EXECUTE" = false ]; then
    return 0
  fi
  "$@" > "$log_file" 2>&1 || status=$?
  [ "$status" -eq 0 ] || dump_log_tail "$label" "$status" "$log_file"
  return "$status"
}

record_repo_provenance() {
  local repo="$1"
  [ -f "$RUN_DIR/manifest.json" ] || return 0
  python3 - "$RUN_DIR/manifest.json" "$repo" "$(repo_path "$repo")" "$(repo_root "$repo")" "$COLD_START" "$WORKTREE_BRANCH" <<'PYEOF'
import json
import subprocess
import sys
from pathlib import Path

manifest_path, repo, source_path, active_path, cold_start, worktree_branch = sys.argv[1:]

def git(path: str, *args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", path, *args],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except Exception:
        return ""

manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
repos = manifest.setdefault("repos", [])
entry = next((item for item in repos if item.get("name") == repo), None)
if entry is None:
    entry = {"name": repo, "commands": []}
    repos.append(entry)

source = Path(source_path)
active = Path(active_path)
entry.update(
    {
        "sourcePath": source_path,
        "activePath": active_path,
        "coldStart": cold_start == "true",
        "worktreeBranch": worktree_branch,
        "exists": (source / ".git").exists(),
        "remoteUrl": git(source_path, "config", "--get", "remote.origin.url") if source.exists() else "",
        "originMainSha": git(source_path, "rev-parse", "origin/main") if source.exists() else "",
        "sourceHeadSha": git(source_path, "rev-parse", "HEAD") if source.exists() else "",
        "worktreeSha": git(active_path, "rev-parse", "HEAD") if active.exists() else "",
    }
)
Path(manifest_path).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYEOF
}

record_command_result() {
  local repo="$1"
  local phase="$2"
  local label="$3"
  local command="$4"
  local status="$5"
  local log_rel="$6"
  [ -f "$RUN_DIR/manifest.json" ] || return 0
  python3 - "$RUN_DIR/manifest.json" "$repo" "$phase" "$label" "$command" "$status" "$log_rel" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PYEOF'
import json
import sys
from pathlib import Path

manifest_path, repo, phase, label, command, status, log_rel, finished_at = sys.argv[1:]
manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
repos = manifest.setdefault("repos", [])
entry = next((item for item in repos if item.get("name") == repo), None)
if entry is None:
    entry = {"name": repo, "commands": []}
    repos.append(entry)

commands = entry.setdefault("commands", [])
commands.append(
    {
        "phase": phase,
        "label": label,
        "command": command,
        "status": "passed" if status == "0" else "failed",
        "exitCode": int(status),
        "log": log_rel,
        "finishedAt": finished_at,
    }
)
if phase == "build":
    entry["buildStatus"] = "failed" if status != "0" else entry.get("buildStatus", "passed")

Path(manifest_path).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYEOF
}

run_repo_cmd() {
  local repo="$1"; shift
  local phase="$1"; shift
  local label="$1"; shift
  local log_rel="logs/${label//[^A-Za-z0-9_.-]/_}.log"
  local log_file="$RUN_DIR/$log_rel"
  local status
  log "+ $*"
  if [ "$EXECUTE" = false ]; then
    return 0
  fi
  set +e
  "$@" > "$log_file" 2>&1
  status=$?
  set -e
  record_command_result "$repo" "$phase" "$label" "$*" "$status" "$log_rel"
  [ "$status" -eq 0 ] || dump_log_tail "$label" "$status" "$log_file"
  return "$status"
}

record_manifest() {
  mkdir -p "$RUN_DIR"
  python3 - "$RUN_DIR/manifest.json" "$RUN_ID" "$BRANCH_NAME" "$WORKTREE_BRANCH" "$ENGINES_SPEC" \
    "$PROFILE" "$LOCAL_AI" "$MACHINE_CORPUS" "$OPENCLAW_FLAG" <<'PYEOF'
import json
import sys
from pathlib import Path

(path, run_id, branch, worktree_branch, engines,
 profile, local_ai, machine_corpus, openclaw_flag) = sys.argv[1:]
payload = {
    "runId": run_id,
    "branch": branch,
    "worktreeBranch": worktree_branch,
    "engineSpec": engines,
    # The lane is part of the evidence. A hosted run and a local run are not
    # interchangeable certifications, and a reader of this artifact should not
    # have to infer which one produced it.
    "profile": profile,
    "coverage": {
        "localAI": local_ai == "true",
        "openclaw": openclaw_flag == "--openclaw",
        "machineCorpus": machine_corpus,
    },
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
  log "profile:      $PROFILE"
  log "history dir:  $HISTORY_DIR"
  log "branch:       $BRANCH_NAME"
  log "run branch:   $WORKTREE_BRANCH"
  log "engines:      $ENGINES_SPEC"
  log "cold start:   $COLD_START"
  log "build:        $BUILD"
  log "start:        $START"
  log "live tests:   $LIVE_TESTS"
  log "openclaw:     $OPENCLAW_FLAG"
  log "local ai:     $LOCAL_AI"
  log "corpus:       $MACHINE_CORPUS"
  log "mqtt broker:  ${MQTT_BROKER_URL:-<not configured>}"
  log "mcp url:      $MCP_URL"
  log "swagger url:  $SWAGGER_URL"
  log "compare:      ${COMPARE_RUN:-<latest completed>}"
  log "archive:      ${ARCHIVE_DIR:-<not configured>}"
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
  for repo in "${REPOS[@]}"; do
    record_repo_provenance "$repo"
  done
  trap 'update_manifest_status failed' ERR
}

create_worktrees() {
  [ "$COLD_START" = true ] || return 0
  step "Cold-start worktrees"
  for repo in "${REPOS[@]}"; do
    local source target
    source="$(repo_path "$repo")"
    target="$(worktree_path "$repo")"
    record_repo_provenance "$repo"
    if [ ! -d "$source/.git" ]; then
      log "SKIP $repo: missing git repo at $source"
      continue
    fi
    run_repo_cmd "$repo" "provenance" "fetch-$repo" git -C "$source" fetch origin main
    run_repo_cmd "$repo" "provenance" "worktree-$repo" git -C "$source" worktree add -B "$WORKTREE_BRANCH" "$target" origin/main
    record_repo_provenance "$repo"
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
  for repo in "${REPOS[@]}"; do
    record_repo_provenance "$repo"
  done
  run_repo_cmd "RealityEngine_CI" "build" "build-ci-npm-install" bash -lc "cd '$(repo_root RealityEngine_CI)' && npm ci"
  run_repo_cmd "RealityEngine_CI" "build" "build-ci-mcp-test" bash -lc "cd '$(repo_root RealityEngine_CI)/mcp' && npm install && npm test"
  # The engine route table the MCP e2e asserts against is generated from the
  # C++ runtime. If the engine adds or moves a route and the fixture is not
  # regenerated, the e2e is checking a stale contract — catch that here, where
  # both repos are checked out at the run's pinned SHAs.
  run_repo_cmd "RealityEngine_CI" "build" "build-ci-mcp-routes-check" bash -lc \
    "cd '$(repo_root RealityEngine_CI)/mcp' && REALITY_ENGINE_CPP_DIR='$(repo_root RealityEngine_CPP)' npm run routes:check"
  run_repo_cmd "RealityEngine_CPP" "build" "build-cpp" bash -lc "cd '$(repo_root RealityEngine_CPP)' && make all"
  run_repo_cmd "RealityEngine_LSP" "build" "build-lsp" bash -lc "cd '$(repo_root RealityEngine_LSP)' && make build"
  run_repo_cmd "RealityEngine_Scala" "build" "build-scala" bash -lc "cd '$(repo_root RealityEngine_Scala)' && sbt clean compile"
  run_repo_cmd "RealityEngine_Machines" "build" "validate-machines" bash -lc "cd '$(repo_root RealityEngine_Machines)' && bash scripts/validate-corpus.sh"
  for package_dir in \
    "visualizer/backend" \
    "visualizer/frontend" \
    "perception-engine/backend" \
    "perception-engine/frontend"; do
    run_repo_cmd "RealityEngine_Manager" "build" "build-manager-${package_dir//\//-}" bash -lc \
      "cd '$(repo_root RealityEngine_Manager)/$package_dir' && npm ci && npm run build"
  done
  run_repo_cmd "localAIStack" "build" "build-localai-compose" bash -lc "cd '$(repo_root localAIStack)' && docker compose build"
  run_repo_cmd "localOpenClawStack" "build" "build-openclaw-compose" bash -lc "cd '$(repo_root localOpenClawStack)' && docker compose build"
}

# With a broker configured but no mapping registry, the bridge starts and
# subscribes to nothing, so the MQTT stage waits out its full timeout for
# sensor sources that were never going to appear. Defaults to the run's own
# worktree copy of the registry rather than the checkout's, so the mappings
# are the ones this run is certifying. Runs after the worktrees exist.
resolve_mqtt_mappings() {
  [ -n "$MQTT_BROKER_URL" ] || return 0
  [ -z "$MQTT_MAPPINGS" ] || return 0
  local default_mappings
  default_mappings="$(repo_root RealityEngine_CPP)/config/mqtt-mappings.yuma.json"
  if [ -f "$default_mappings" ]; then
    MQTT_MAPPINGS="$default_mappings"
    log "mqtt mappings defaulted to $MQTT_MAPPINGS"
  else
    log "WARN: MQTT broker configured but no mapping registry at $default_mappings"
  fi
}

# startUniverse.sh dies without $CI_DIR/.env and four TLS artifacts under
# certs/. Both are gitignored, so a cold-start worktree — which is every
# regression run — never has them, and $CI_DIR is the worktree, not the
# checkout. This is why the full lane has never started a universe on any
# runner: it dies at ".env not found" before the first engine.
prepare_runtime_config() {
  [ "$START" = true ] || return 0
  step "Runtime config for the run worktree"
  local ci src_ci
  ci="$(repo_root RealityEngine_CI)"
  src_ci="$(repo_path RealityEngine_CI)"

  if [ "$EXECUTE" = false ]; then
    log "+ provision $ci/.env and $ci/certs/"
    return 0
  fi


  if [ -f "$ci/.env" ]; then
    log ".env already present"
  elif [ "$PROFILE" = "local" ] && [ -f "$src_ci/.env" ]; then
    # The operator's .env carries what the local stack actually needs — broker
    # URLs, gateway session keys. Seeding from .env.example instead would
    # certify a universe other than the one being certified.
    cp "$src_ci/.env" "$ci/.env"
    log ".env copied from $src_ci"
  else
    cp "$ci/.env.example" "$ci/.env"
    log ".env seeded from .env.example"
  fi

  local missing=false f
  for f in certs/server.crt certs/server.key certs/ca.crt certs/keystore.p12; do
    [ -f "$ci/$f" ] || missing=true
  done
  if [ "$missing" = true ]; then
    run_cmd "generate-dev-certs" bash -lc "cd '$ci' && bash certs/generate-dev-certs.sh"
  else
    log "dev certs already present"
  fi
}

start_universe() {
  [ "$START" = true ] || return 0
  step "Cold-start standard multi-engine universe"
  local ci
  ci="$(repo_root RealityEngine_CI)"
  # This argument list was hardcoded, so --machine-corpus and --no-local-ai
  # had no way to reach startUniverse.sh: every run took its defaults, which
  # are the full corpus and localAI on — exactly the two things the hosted
  # lane must never do.
  local args=()
  [ -n "$FRESH_FLAG" ] && args+=("$FRESH_FLAG")
  args+=(
    "--engines=$ENGINES_SPEC"
    "--machine-load=runtime"
    "--pe-source-bootstrap=auto"
    "--machine-corpus=$MACHINE_CORPUS"
    "$OPENCLAW_FLAG"
    "--warn-only"
  )
  [ "$LOCAL_AI" = true ] || args+=("--no-local-ai")
  [ -n "$MQTT_BROKER_URL" ] && args+=("--mqtt-broker-url=$MQTT_BROKER_URL")
  [ -n "$MQTT_MAPPINGS" ] && args+=("--mqtt-mappings=$MQTT_MAPPINGS")
  run_cmd "start-universe" bash -lc "cd '$ci' && ./startUniverse.sh ${args[*]}"
}

run_service_inventory() {
  step "Service inventory and readiness gates"
  local ci
  ci="$(repo_root RealityEngine_CI)"
  local args=(
    "--registry" "/tmp/re-registry/re-registry.json"
    "--engine-spec" "$ENGINES_SPEC"
    "--out" "$REPORT_DIR/service-inventory.json"
    "--manifest" "$RUN_DIR/manifest.json"
    "--mcp-url" "$MCP_URL"
    "--swagger-url" "$SWAGGER_URL"
  )
  [ "$OPENCLAW_FLAG" = "--openclaw" ] && args+=("--require-openclaw")
  run_cmd "service-inventory" python3 "$ci/scripts/regression-service-inventory.py" "${args[@]}"
}

# The corpus the running engines actually loaded. Under
# --machine-corpus=standard-deployment, startUniverse.sh materialises the
# subset into MACHINE_CORPUS_WORK_DIR and boots from that; scanning the full
# worktree corpus instead would build parity events out of machines no running
# engine has ever seen.
active_machines_dir() {
  if [ "$MACHINE_CORPUS" = "standard-deployment" ]; then
    printf '%s/machines\n' "$MACHINE_CORPUS_WORK_DIR"
  else
    printf '%s/machines\n' "$(repo_root RealityEngine_Machines)"
  fi
}

run_universal_vectors() {
  step "Universal input event vector parity"
  local ci machines
  ci="$(repo_root RealityEngine_CI)"
  machines="$(active_machines_dir)"
  run_cmd "universal-vectors" python3 "$ci/scripts/regression-universal-vectors.py" \
    --registry /tmp/re-registry/re-registry.json \
    --machines "$machines" \
    --events 5 \
    --run-id "$RUN_ID" \
    --out "$RUN_DIR/responses/universal-vectors"
}

registry_instance_lines() {
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
    instance_id = item.get("id") or item.get("runtime")
    runtime = item.get("runtime")
    pe_url = item.get("pe_url")
    status = item.get("status", "running")
    if runtime and pe_url and status == "running":
        print(f"{instance_id}|{runtime}|{pe_url}")
PYEOF
}

write_mqtt_skip_report() {
  local reason="$1"
  mkdir -p "$REPORT_DIR"
  python3 - "$REPORT_DIR/mqtt-yuma-skipped.json" "$reason" "$MQTT_BROKER_URL" <<'PYEOF'
import json
import sys
from pathlib import Path

path, reason, broker = sys.argv[1:]
Path(path).write_text(json.dumps({
    "status": "skipped",
    "reason": reason,
    "brokerUrl": broker,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYEOF
}

run_mqtt_yuma() {
  step "MQTT Yuma stream"
  if [ -z "$MQTT_BROKER_URL" ]; then
    log "SKIP MQTT: --mqtt-broker-url not provided"
    write_mqtt_skip_report "--mqtt-broker-url not provided"
    return 0
  fi
  local ci
  ci="$(repo_root RealityEngine_CI)"
  local mqtt_args=(--broker-url "$MQTT_BROKER_URL" --skip-enable)
  [ -n "$MQTT_MAPPINGS" ] && mqtt_args+=(--mappings "$MQTT_MAPPINGS")
  local found=false
  while IFS='|' read -r instance_id runtime pe_url; do
    [ -n "$instance_id" ] || continue
    found=true
    run_cmd "mqtt-yuma-$instance_id" bash "$ci/scripts/test-mqtt-yuma.sh" \
      --pe-url "$pe_url" \
      --report-json "$REPORT_DIR/mqtt-yuma-$instance_id.json" \
      "${mqtt_args[@]}"
  done < <(registry_instance_lines)
  [ "$found" = true ] || { log "SKIP MQTT: no running PE instances in registry"; write_mqtt_skip_report "no running PE instances in registry"; return 0; }
}

run_mcp() {
  step "MCP open service"
  local ci
  ci="$(repo_root RealityEngine_CI)"
  run_cmd "mcp-smoke" node "$ci/scripts/regression-mcp-smoke.mjs" \
    --mcp-url "$MCP_URL" \
    --registry /tmp/re-registry/re-registry.json \
    --manifest "$ci/mcp/manifest.json" \
    --profile "$ci/mcp/openai-mcp-profile.json" \
    --out "$REPORT_DIR/mcp-smoke.json"
}

run_openclaw() {
  step "OpenClaw async handoff and PE completion return"
  if [ "$OPENCLAW_FLAG" != "--openclaw" ]; then
    log "SKIP OpenClaw: disabled"
    mkdir -p "$REPORT_DIR"
    python3 - "$REPORT_DIR/openclaw-skipped.json" <<'PYEOF'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({"status": "skipped", "reason": "--no-openclaw"}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYEOF
    return 0
  fi
  local ci
  ci="$(repo_root RealityEngine_CI)"
  local found=false
  while IFS='|' read -r instance_id runtime pe_url; do
    [ -n "$instance_id" ] || continue
    found=true
    run_cmd "openclaw-integration-$instance_id" env \
      PE_URL="$pe_url" \
      OPENCLAW_E2E_RUN_ID="$RUN_ID-$instance_id" \
      bash "$ci/scripts/test-openclaw-integration.sh" \
      --report-json "$REPORT_DIR/openclaw-integration-$instance_id.json"
  done < <(registry_instance_lines)
  if [ "$found" != true ]; then
    log "SKIP OpenClaw: no running PE instances in registry"
    mkdir -p "$REPORT_DIR"
    python3 - "$REPORT_DIR/openclaw-skipped.json" <<'PYEOF'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({"status": "skipped", "reason": "no running PE instances in registry"}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYEOF
    return 0
  fi
}

generate_regression_report() {
  step "Regression summary and comparison"
  local ci args
  ci="$(repo_root RealityEngine_CI)"
  args=(
    "--run-dir" "$RUN_DIR"
    "--history-dir" "$HISTORY_DIR"
  )
  [ -n "$COMPARE_RUN" ] && args+=("--compare-run" "$COMPARE_RUN")
  [ -n "$ARCHIVE_DIR" ] && args+=("--archive" "$ARCHIVE_DIR")
  run_cmd "regression-report" python3 "$ci/scripts/regression-report.py" "${args[@]}"

  # Candidate release manifest: pin every repo to the commit this run actually
  # built. Emitted on every run so a green one yields a ready-to-tag manifest
  # with no separate step to remember; --allow-unverified keeps a red run from
  # aborting the report, and marks the result provisional so it cannot be
  # mistaken for a certified pin.
  python3 "$ci/scripts/release-manifest.py" generate \
    --run-dir "$RUN_DIR" \
    --version "${RELEASE_VERSION:-untagged}" \
    --out "$RUN_DIR/release-manifest.json" \
    --allow-unverified >/dev/null 2>&1 \
    && echo "release manifest → $RUN_DIR/release-manifest.json" \
    || echo "release manifest skipped (could not pin this run)"
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

# Stages are independent measurements, so one failing must not stop the rest.
# Under plain `set -e` the first failure aborted the run and every later stage
# produced nothing at all — so a suite with five stages surfaced its problems
# strictly one per run, and each run costs about half an hour. The suite still
# fails; it just reports everything it learned before doing so.
STAGE_FAILURES=()
run_stage() {
  local name="$1"; shift
  local status=0
  "$@" || status=$?
  if [ "$status" -ne 0 ]; then
    STAGE_FAILURES+=("$name")
    log ""
    log "STAGE FAILED: $name (exit $status) — continuing so the later stages still report"
  fi
  return 0
}

plan
if [ "$EXECUTE" = false ]; then
  exit 0
fi

prepare_history
create_worktrees
build_repos
if [ "$LIVE_TESTS" = true ]; then
  resolve_mqtt_mappings
  prepare_runtime_config
  # start_universe stays fatal: with no universe the later stages have nothing
  # to measure, and their failures would say nothing about the runtimes.
  start_universe
  run_stage "service-inventory" run_service_inventory
  run_stage "universal-vectors" run_universal_vectors
  run_stage "mqtt-yuma"         run_mqtt_yuma
  run_stage "mcp"               run_mcp
  run_stage "openclaw"          run_openclaw
else
  log ""
  log "Live tests skipped (--build-only)."
fi
if [ "${#STAGE_FAILURES[@]}" -gt 0 ]; then
  update_manifest_status failed
else
  update_manifest_status completed
fi
generate_regression_report
retain_history

log ""
log "Regression workflow executed."
log "Run directory: $RUN_DIR"

if [ "${#STAGE_FAILURES[@]}" -gt 0 ]; then
  log ""
  log "FAILED stages (${#STAGE_FAILURES[@]}): ${STAGE_FAILURES[*]}"
  exit 1
fi
