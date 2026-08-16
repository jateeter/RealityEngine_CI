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
#   local  — the whole stack on operator hardware, no service exclusions.
#
# Both lanes boot the same machine corpus. The lanes are a statement about
# which services may run, and a corpus that differed between them made every
# hosted-vs-local comparison carry a second, unrelated variable. The local
# lane may still opt into --machine-corpus=full explicitly; the hosted lane
# may not. Full-corpus load behaviour belongs to dedicated scaling tests, not
# to a lane default.
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
LOCAL_AI_URL="${LOCAL_AI_URL:-http://localhost:4000}"

# Node is managed, not discovered. RealityEngine_Manager pins engines.node, the
# hosted lane pins the same version with actions/setup-node, and the harness
# activates it through nvm so every lane builds against one runtime.
NODE_VERSION="${NODE_VERSION:-25.5}"
NODE_ACTIVATE='export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"; \
  if [ -s "$NVM_DIR/nvm.sh" ]; then . "$NVM_DIR/nvm.sh" >/dev/null 2>&1; \
    nvm use '"$NODE_VERSION"' >/dev/null 2>&1 || nvm install '"$NODE_VERSION"' >/dev/null 2>&1; fi; '

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
  # The non-hosted members of the universe. Both are in the MVP since G4
  # (docs/MVP_ROADMAP.md), and both are cloned on every lane so the release
  # manifest pins them with everything else — a repo the MVP depends on that
  # the manifest does not pin is a hole in the reproducibility claim.
  #
  # What they *build* is lane-dependent, not what they pin: PIM's image
  # rebuild and the bridge's Swift toolchain need Docker and Xcode, so those
  # run on the local lane and record a skip reason on the hosted one.
  OpenCommons-Health---Personal-Information-Management
  localHealthkitBridge
)

usage() {
  cat <<'USAGE'
regression-test.sh — standard multi-engine regression workflow

Usage:
  bash scripts/regression-test.sh [--execute] [options]

Options:
  --execute                 Run the workflow. Default is plan-only.
  --profile hosted|local    Lane profile. Default: local
                              hosted — no localAI, no OpenClaw. Refuses any flag
                                       asking otherwise.
                              local  — localAI and OpenClaw.
                            Both lanes boot the standard-deployment corpus.
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
  --machine-corpus CORPUS   full | standard-deployment. Default: standard-deployment
                            on both profiles. full is an explicit opt-in and is
                            refused under --profile hosted.
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
    # What the hosted lane refuses is the *full* corpus, because full-corpus
    # load behaviour belongs to dedicated scaling tests rather than to a lane
    # default. A manifest-backed corpus is a named, bounded subset — the arbiter
    # fixtures are seven machines — so there is nothing about a hosted runner
    # that cannot boot one, and jateeter/RealityEngine_CI#123 needs exactly that.
    [ "$MACHINE_CORPUS" != "full" ] ||
      profile_refuse "load the full corpus (--machine-corpus=full)"
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
    # Same corpus as hosted. --machine-corpus=full stays available here as an
    # explicit opt-in; it is no longer what an unflagged local run boots.
    [ "$MACHINE_CORPUS_SET" = true ] || MACHINE_CORPUS="standard-deployment"
    # Pin one model for every engine on this lane.
    #
    # The runtimes now share a canonical default (llama3.1:8b, see
    # docs/INTEGRATION_ARCHITECTURE.md), so this pin no longer *corrects* a
    # disagreement — it states the lane's choice explicitly and keeps the lane
    # correct if a future default diverges again. The local-ai stage fails if
    # the engines disagree or if the resolved model is not installed, so a
    # regression here is caught rather than assumed away.
    #
    # Exported rather than passed as a flag: startUniverse spawns each engine
    # with inherited environment, so one export reaches all three.
    OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.1:8b}"
    export OLLAMA_MODEL
    ;;
  *)
    echo "Unsupported --profile: $PROFILE (hosted|local)" >&2
    exit 2
    ;;
esac

# Any manifest in config/ is a corpus, not just the two that were hardcoded.
#
# config/arbiter-fixture-corpus.txt and config/standard-deployment-plus-ring-corpus.txt
# were merged and then referenced by nothing — no script, workflow or doc in this
# repo could select them, because this case statement rejected every name but
# two. startUniverse.sh has taken --machine-corpus-manifest=PATH all along; the
# harness simply never passed it. See jateeter/RealityEngine_CI#123.
MACHINE_CORPUS_MANIFEST=""
case "$MACHINE_CORPUS" in
  full) ;;
  standard-deployment)
    MACHINE_CORPUS_MANIFEST="$CI_DIR/config/standard-deployment-corpus.txt" ;;
  *)
    MACHINE_CORPUS_MANIFEST="$CI_DIR/config/$MACHINE_CORPUS-corpus.txt"
    if [ ! -f "$MACHINE_CORPUS_MANIFEST" ]; then
      echo "Unsupported --machine-corpus: $MACHINE_CORPUS" >&2
      echo "Expected 'full', or a manifest at config/<name>-corpus.txt. Available:" >&2
      for _m in "$CI_DIR"/config/*-corpus.txt; do
        [ -f "$_m" ] || continue
        _n="$(basename "$_m")"; _n="${_n%-corpus.txt}"
        printf '  %s (%s machines)\n' "$_n" \
          "$(grep -cvE '^\s*(#|$)' "$_m" 2>/dev/null || echo '?')" >&2
      done
      exit 2
    fi
    # Materialisation is what --machine-corpus=standard-deployment triggers in
    # startUniverse.sh, so any manifest-backed corpus rides the same path.
    MACHINE_CORPUS_BOOT="standard-deployment" ;;
esac
MACHINE_CORPUS_BOOT="${MACHINE_CORPUS_BOOT:-$MACHINE_CORPUS}"

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

# A member repo can legitimately be absent. The hosted lane checks out only the
# repos its runner can use, so PIM and the HealthKit bridge are not there at
# all, and create_worktrees skips them. Any stage bound to an absent member has
# to skip with a recorded reason: running it anyway fails on `cd` into a
# worktree that was never created, which reports the lane's own composition as
# a regression in the code under test.
repo_present() {
  [ -d "$(repo_path "$1")/.git" ]
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
  # Node comes from nvm, not from whatever a login shell happens to resolve.
  # `bash -lc` picks up /etc/profile and path_helper on macOS, which floats
  # system paths ahead of any version manager — so the harness activates the
  # version it needs inside the shell rather than inspecting what it was
  # handed. The hosted lane does the same thing with actions/setup-node.
  if [ "$1" = "bash" ] && [ "$2" = "-lc" ]; then
    "$1" "$2" "$NODE_ACTIVATE$3" > "$log_file" 2>&1
  else
    "$@" > "$log_file" 2>&1
  fi
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
  [ "$LOCAL_AI" = true ] && log "ollama model: ${OLLAMA_MODEL:-<engine default>}"
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

# ── Docker preflight (local lane) ───────────────────────────────────────────
# build_repos runs `docker compose build` for three stacks and start_universe
# needs the daemon for Loki, Qdrant and Redis. With the daemon down, both fail
# in a way that reads as a broken build rather than a host that was not ready —
# so the lane checks and starts it rather than discovering it 20 minutes in.
#
# Local-only. A hosted runner has a daemon by construction, and `open -a Docker`
# is meaningless there.
docker_ready() { docker info >/dev/null 2>&1; }

start_docker_daemon() {
  if docker_ready; then
    log "Docker daemon already running"
    return 0
  fi
  log "Docker daemon is down — starting it"
  case "$(uname -s)" in
    Darwin) open -a Docker >/dev/null 2>&1 || { log "ERROR: could not launch Docker Desktop"; return 1; } ;;
    Linux)  systemctl start docker >/dev/null 2>&1 || sudo systemctl start docker >/dev/null 2>&1 || {
              log "ERROR: could not start the docker service"; return 1; } ;;
    *)      log "ERROR: no way to start Docker on $(uname -s)"; return 1 ;;
  esac
  local waited=0 limit="${DOCKER_START_TIMEOUT:-120}"
  while [ "$waited" -lt "$limit" ]; do
    if docker_ready; then
      log "Docker daemon ready after ${waited}s"
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done
  log "ERROR: Docker daemon did not become ready within ${limit}s"
  return 1
}

# The ports this lane needs free. Derived from the same bases startUniverse.sh
# reads, including $CI_DIR/.env overrides — this host pins SCALA_PE_BASE=5100
# precisely because macOS AirPlay squats on 5000, so hardcoding the defaults
# here would check ports the run never uses and miss the ones it does.
lane_ports() {
  local cpp lsp scala
  # shellcheck disable=SC1091
  [ -f "$CI_DIR/.env" ] && . "$CI_DIR/.env" >/dev/null 2>&1 || true
  cpp="${CPP_PE_BASE:-5300}"; lsp="${LSP_PE_BASE:-5600}"; scala="${SCALA_PE_BASE:-5000}"
  printf '%s\n' "$cpp" "$(( cpp + 1 ))" "$lsp" "$(( lsp + 1 ))" "$scala" "$(( scala + 1 ))" \
    3001 5173 5999 4000 18789 8080 7331 8088
}

prepare_docker() {
  [ "$PROFILE" = "local" ] || return 0
  step "Docker preflight"
  start_docker_daemon || {
    log "The local lane cannot build or start anything without Docker."
    exit 1
  }

  # Teardown reuses stopUniverse.sh rather than reimplementing it: that path
  # already knows every stack to compose-down and every engine port to sweep,
  # including the guards that refuse to kill Docker's own proxy or the macOS
  # AirPlay listener. Non-fatal — there may be nothing to stop.
  run_cmd "docker-preflight-stop" bash -lc \
    "cd '$CI_DIR' && ./stopUniverse.sh --stop-docker" || \
    log "stopUniverse returned non-zero (likely nothing was running) — continuing"

  # Drop the images this project built, so the run builds them again rather
  # than certifying a layer cached from an earlier commit. `--rmi local` is
  # scoped to images compose built without a custom tag, so unrelated images
  # on the host are untouched.
  local stack
  for stack in "$CI_DIR" "$WS/localAIStack" "$WS/localOpenClawStack" \
               "$WS/OpenCommons-Health---Personal-Information-Management"; do
    [ -f "$stack/docker-compose.yml" ] || [ -f "$stack/compose.yml" ] || continue
    # MACHINES_DIR is the one variable the CI compose file requires outright
    # (`:?MACHINES_DIR must be set`) rather than defaulting. Compose interpolates
    # before it will enumerate what to remove, so without this the cleanup dies
    # on config parsing and that stack's images silently survive the run.
    run_cmd "docker-preflight-rmi-$(basename "$stack")" bash -lc \
      "cd '$stack' && MACHINES_DIR='$WS/RealityEngine_Machines' docker compose down --rmi local --remove-orphans" || \
      log "image cleanup for $(basename "$stack") returned non-zero — continuing"
  done

  # Ports must be clear before start_universe, not discovered busy inside it.
  local port busy=() holder
  while read -r port; do
    [ -n "$port" ] || continue
    if lsof -ti ":$port" -sTCP:LISTEN >/dev/null 2>&1; then
      holder="$(ps -o comm= -p "$(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null | head -1)" 2>/dev/null || echo unknown)"
      busy+=("$port($holder)")
    fi
  done < <(lane_ports)
  if [ "${#busy[@]}" -gt 0 ]; then
    log "ERROR: ports still held after teardown: ${busy[*]}"
    log "Free them before re-running; startUniverse would fail on these anyway."
    write_skip_report "docker-preflight-ports.json" "ports still held: ${busy[*]}"
    exit 1
  fi
  log "Lane ports are clear"
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
      # Recorded, not just logged: an absent member changes what this run
      # certifies, and that belongs in the artifacts next to every other skip.
      log "SKIP $repo: missing git repo at $source"
      write_skip_report "worktree-$repo-skipped.json" \
        "missing git repo at $source; member not checked out on this lane"
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
  # RealityEngine_LSP/quicklisp/ is untracked, so a cold-start worktree never
  # has it and `make build` dies with "Missing Quicklisp". The hosted lane only
  # worked because the *workflow* bootstrapped Quicklisp into $HOME before
  # invoking this script — a harness that only runs when its caller happens to
  # have prepared the environment is not a harness. Bootstrapping here makes
  # every lane self-sufficient. The script is idempotent, so this is a no-op
  # once $HOME/quicklisp exists.
  run_repo_cmd "RealityEngine_LSP" "build" "bootstrap-quicklisp" bash -lc \
    "cd '$(repo_root RealityEngine_LSP)' && bash scripts/bootstrap-quicklisp.sh --home"
  run_repo_cmd "RealityEngine_LSP" "build" "build-lsp" bash -lc "cd '$(repo_root RealityEngine_LSP)' && make build"
  run_repo_cmd "RealityEngine_Scala" "build" "build-scala" bash -lc "cd '$(repo_root RealityEngine_Scala)' && sbt clean compile"
  run_repo_cmd "RealityEngine_Machines" "build" "validate-machines" bash -lc "cd '$(repo_root RealityEngine_Machines)' && bash scripts/validate-corpus.sh"
  # TypeScript is typechecked explicitly rather than relied on as a side effect
  # of bundling. Playwright transpiles specs without typechecking them, so
  # these suites had never been checked at all — adding this surfaced a derived
  # fixture type that resolved to `never`, silently unchecking every use of it.
  run_repo_cmd "RealityEngine_Machines" "build" "typecheck-machines" bash -lc "cd '$(repo_root RealityEngine_Machines)' && npm ci && npm run typecheck"
  run_repo_cmd "RealityEngine_CI" "build" "typecheck-ci" bash -lc "cd '$(repo_root RealityEngine_CI)' && npm run typecheck"
  for package_dir in \
    "visualizer/backend" \
    "visualizer/frontend" \
    "perception-engine/backend" \
    "perception-engine/frontend"; do
    run_repo_cmd "RealityEngine_Manager" "build" "build-manager-${package_dir//\//-}" bash -lc \
      "cd '$(repo_root RealityEngine_Manager)/$package_dir' && npm ci && npm run build"
    run_repo_cmd "RealityEngine_Manager" "build" "typecheck-manager-${package_dir//\//-}" bash -lc \
      "cd '$(repo_root RealityEngine_Manager)/$package_dir' && npm run typecheck"
  done
  # PIM joined the MVP at G4. It already had a typecheck script; nothing ran it
  # from here, because the harness did not know the repo existed. Typecheck is
  # cheap and needs only npm, so it is lane-independent in cost — but not in
  # availability. It runs wherever PIM is actually checked out, and records why
  # it did not where PIM is not.
  if repo_present "OpenCommons-Health---Personal-Information-Management"; then
    run_repo_cmd "OpenCommons-Health---Personal-Information-Management" "build" "typecheck-pim" bash -lc \
      "cd '$(repo_root OpenCommons-Health---Personal-Information-Management)' && npm ci && npm run typecheck"
  else
    write_skip_report "typecheck-pim-skipped.json" \
      "PIM is not checked out on this lane; nothing to typecheck"
    log "SKIP typecheck-pim — PIM not checked out"
  fi

  # ── Non-hosted members ────────────────────────────────────────────────────
  # PIM's images and the bridge's Swift package need Docker and Xcode. The
  # hosted lane has neither in a usable form, so these build on the local lane
  # and record why they did not on the hosted one. A build that quietly does
  # not happen is the same failure as a stage that quietly does not run.
  if [ "$PROFILE" = "local" ] && repo_present "OpenCommons-Health---Personal-Information-Management"; then
    # PIM's compose interpolates CSS_ACCOUNT_PASSWORD from .env, which is
    # gitignored and so absent from a cold-start worktree — the build fails
    # before a layer is read. Seed from .env.example, the same way this repo
    # seeds its own, and deliberately *not* from the operator's real .env:
    # copying that would pull live credentials into a run directory that gets
    # archived as a certification artifact.
    run_repo_cmd "OpenCommons-Health---Personal-Information-Management" "build" "prepare-pim-env" bash -lc \
      "cd '$(repo_root OpenCommons-Health---Personal-Information-Management)' && { [ -f .env ] || cp .env.example .env; }"
    run_repo_cmd "OpenCommons-Health---Personal-Information-Management" "build" "build-pim-compose" bash -lc \
      "cd '$(repo_root OpenCommons-Health---Personal-Information-Management)' && docker compose build"
  elif [ "$PROFILE" = "local" ]; then
    write_skip_report "build-pim-compose-skipped.json" \
      "PIM is not checked out on this lane; nothing to build"
    log "SKIP PIM image rebuild — PIM not checked out"
  else
    write_skip_report "build-pim-compose-skipped.json" \
      "PIM image rebuild needs Docker; hosted lane runs typecheck only"
    log "SKIP PIM image rebuild — hosted profile"
  fi
  if [ "$PROFILE" = "local" ] && repo_present "localHealthkitBridge"; then
    run_repo_cmd "localHealthkitBridge" "build" "build-healthkit-bridge" bash -lc \
      "cd '$(repo_root localHealthkitBridge)' && swift build"
    run_repo_cmd "localHealthkitBridge" "build" "test-healthkit-bridge" bash -lc \
      "cd '$(repo_root localHealthkitBridge)' && swift test"
  elif [ "$PROFILE" = "local" ]; then
    write_skip_report "build-healthkit-bridge-skipped.json" \
      "localHealthkitBridge is not checked out on this lane; nothing to build"
    log "SKIP HealthKit bridge build — bridge not checked out"
  else
    write_skip_report "build-healthkit-bridge-skipped.json" \
      "Swift/Xcode toolchain is macOS-only; hosted lane cannot build the bridge"
    log "SKIP HealthKit bridge build — hosted profile"
  fi
  # Build only what this lane can actually start. The hosted profile *refuses*
  # --local-ai and --openclaw (see the profile block above), so building their
  # images buys no coverage — it only widens the blast radius. On 2026-08-15 a
  # dependabot base-image bump in localAIStack (python 3.11 -> 3.14, past the
  # ceiling unstructured==0.25.2 declares) failed this build and took the whole
  # scheduled run red before a single engine started. That break belongs to
  # localAIStack's own CI, which builds the same image on every push.
  if [ "$LOCAL_AI" = true ]; then
    run_repo_cmd "localAIStack" "build" "build-localai-compose" bash -lc "cd '$(repo_root localAIStack)' && docker compose build"
  else
    write_skip_report "build-localai-compose-skipped.json" \
      "this lane does not run localAI; its image is built by localAIStack CI"
    log "SKIP localAI image build — lane does not run localAI"
  fi
  if [ "$OPENCLAW_FLAG" != "--no-openclaw" ]; then
    run_repo_cmd "localOpenClawStack" "build" "build-openclaw-compose" bash -lc "cd '$(repo_root localOpenClawStack)' && docker compose build"
  else
    write_skip_report "build-openclaw-compose-skipped.json" \
      "this lane does not run OpenClaw; its image is built by localOpenClawStack CI"
    log "SKIP OpenClaw image build — lane does not run OpenClaw"
  fi
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

  # OpenClaw's gateway is fatal without .env and a real OPENCLAW_GATEWAY_TOKEN.
  # The file is gitignored, so a cold-start worktree never has it, and phase 5.5
  # kills a universe that came up whole — three engines, Manager, Prometheus and
  # localAIStack all healthy — for a config file nobody copied.
  #
  # Same reasoning as the CI .env above: on the local lane the operator's file is
  # what makes this the universe under test, and .env.example's placeholder token
  # would certify a gateway nobody runs.
  local ocs src_ocs
  ocs="$(repo_root localOpenClawStack)"
  src_ocs="$(repo_path localOpenClawStack)"
  if [ ! -d "$ocs" ]; then
    log "SKIP OpenClaw .env: worktree not present"
  elif [ -f "$ocs/.env" ]; then
    log "OpenClaw .env already present"
  elif [ "$PROFILE" = "local" ] && [ -f "$src_ocs/.env" ]; then
    cp "$src_ocs/.env" "$ocs/.env"
    log "OpenClaw .env copied from $src_ocs"
  elif [ -f "$ocs/.env.example" ]; then
    cp "$ocs/.env.example" "$ocs/.env"
    log "OpenClaw .env seeded from .env.example — gateway token is a placeholder"
  else
    log "WARNING: no OpenClaw .env or .env.example; startUniverse will fail at phase 5.5"
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
    "--machine-corpus=$MACHINE_CORPUS_BOOT"
    "$OPENCLAW_FLAG"
    "--warn-only"
  )
  [ "$LOCAL_AI" = true ] || args+=("--no-local-ai")
  [ -n "$MACHINE_CORPUS_MANIFEST" ] && args+=("--machine-corpus-manifest=$MACHINE_CORPUS_MANIFEST")
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
  if [ "$MACHINE_CORPUS_BOOT" = "standard-deployment" ]; then
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

# A stage that does not run must say so in a report, not just in the log. A
# silent skip is indistinguishable from coverage when someone reads the run
# afterwards — which is how four checks in this harness passed for months
# without checking anything.
write_skip_report() {
  local report="$1" reason="$2"
  mkdir -p "$REPORT_DIR"
  python3 - "$REPORT_DIR/$report" "$reason" <<'PYEOF'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(
    json.dumps({"status": "skipped", "reason": sys.argv[2]}, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PYEOF
}

# ── Local lane only ─────────────────────────────────────────────────────────
# The hosted profile refuses local AI, OpenClaw, the full corpus and the
# HealthKit bridge (see the profile block). The two stages below are what the
# local lane exists to exercise: without them, --profile local enables those
# surfaces and then tests nothing that the hosted lane does not already cover.

run_local_ai() {
  step "Local AI provider reachability"
  if [ "$LOCAL_AI" != true ]; then
    log "SKIP local AI: disabled on this profile"
    write_skip_report "local-ai-skipped.json" "local AI disabled (--profile $PROFILE)"
    return 0
  fi
  local ci
  ci="$(repo_root RealityEngine_CI)"
  run_cmd "local-ai-probe" python3 "$ci/scripts/regression-local-ai.py" \
    --registry /tmp/re-registry/re-registry.json \
    --localai-url "$LOCAL_AI_URL" \
    --out "$REPORT_DIR/local-ai.json"
}

run_healthkit_bridge() {
  step "HealthKit bridge simulator leg"
  if [ "$PROFILE" != "local" ]; then
    log "SKIP HealthKit bridge: hosted profile refuses the bridge"
    write_skip_report "healthkit-bridge-skipped.json" "hosted profile refuses the HealthKit bridge"
    return 0
  fi

  # The bridge is a repos-group member, so this drives the cold-start worktree
  # at the pinned commit rather than whatever the operator's checkout happens
  # to contain. Testing the working copy would certify something the manifest
  # does not pin.
  local bridge
  bridge="$(repo_root localHealthkitBridge)"
  if [ ! -x "$bridge/scripts/e2e_simulator.sh" ]; then
    log "SKIP HealthKit bridge: localHealthkitBridge worktree has no e2e_simulator.sh"
    write_skip_report "healthkit-bridge-skipped.json" "localHealthkitBridge worktree missing e2e_simulator.sh"
    return 0
  fi

  # Xcode and an iOS runtime are macOS-only. Report the reason rather than
  # failing a lane that is otherwise valid on Linux.
  local missing=""
  for tool in xcrun xcodegen jq; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    log "SKIP HealthKit bridge: missing toolchain —$missing"
    write_skip_report "healthkit-bridge-skipped.json" "missing toolchain:$missing"
    return 0
  fi

  # The bridge posts to one PE. Any runtime satisfies the ingest contract —
  # RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts
  # enforces that — so the first live instance is enough, and the contract
  # spec is what covers the other two.
  local pe_url=""
  while IFS='|' read -r instance_id runtime url; do
    [ -n "$instance_id" ] || continue
    pe_url="$url"
    break
  done < <(registry_instance_lines)

  if [ -z "$pe_url" ]; then
    log "SKIP HealthKit bridge: no running PE instances in registry"
    write_skip_report "healthkit-bridge-skipped.json" "no running PE instances in registry"
    return 0
  fi

  # HealthKit ingest auth is on by default: startUniverse generates a stable
  # token, persists it to config/.healthkit-bridge-token and hands it to the
  # PE. Launching the app without it gets a 401 the app reports as
  # "deliver failed unauthorized" and the script reports only as
  # "expected >=3 healthkit sensors, saw 0" — a real auth failure that reads
  # like the bridge never ran.
  local token="${HEALTHKIT_BRIDGE_TOKEN:-}"
  if [ -z "$token" ] && [ -s "$CI_DIR/config/.healthkit-bridge-token" ]; then
    token="$(cat "$CI_DIR/config/.healthkit-bridge-token")"
  fi
  if [ -z "$token" ]; then
    # --no-healthkit-token is a legitimate configuration; the PE then accepts
    # unauthenticated ingest. Say so rather than leaving the reason to be
    # inferred from a 401 three layers down.
    log "HealthKit bridge: no token configured — expecting the PE to accept unauthenticated ingest"
  fi

  log "HealthKit bridge simulator leg against $pe_url"
  run_cmd "healthkit-bridge-simulator" \
    env PE_BASE_URL="$pe_url" HEALTHKIT_BRIDGE_TOKEN="$token" \
    bash "$bridge/scripts/e2e_simulator.sh"
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
# Before any worktree or build: the build phase itself needs the daemon.
prepare_docker
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
  run_stage "local-ai"          run_local_ai
  run_stage "openclaw"          run_openclaw
  # Last: it drives a simulator and is the slowest stage, so a failure here
  # should not delay the report on everything before it.
  run_stage "healthkit-bridge"  run_healthkit_bridge
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
