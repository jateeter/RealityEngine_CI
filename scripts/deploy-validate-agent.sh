#!/usr/bin/env bash
# =============================================================================
# deploy-validate-agent.sh — local deployment-validation agent for the
# RealityEngine universe. Validates BOTH the containerized (Docker) footprint
# and the native local-process footprint (Scala/Manager/CPP/LSP). OpenClaw and
# localAIStack are validated containerized-only.
#
# What it does, in one cycle:
#   Phase 0  Preflight        docker/compose, .env, certs, sibling repos, gh auth
#   Phase 1  Full deploy      ./startUniverse.sh [--fresh] (Docker AI path)
#   Phase 2  Health gate      poll every public Docker endpoint
#   Phase 3  Restart matrix   CONTAINERIZED lane — stop→start→re-health each
#                             Docker unit via compose service recreate (RE/Scala,
#                             Manager Viz+PE) or its repo scripts/start.sh
#                             (localAIStack, OpenClaw — containerized only).
#   Phase 3N Native lane      LOCAL-PROCESS lane — start→health→restart→stop each
#                             native runtime via its own start.sh on OFF-BAND
#                             ports so it coexists with the Docker stack:
#                             Scala (5101/5100), Manager backend (3011),
#                             CPP (5301/5300), LSP (5601/5600). CPP/LSP have no
#                             container image, so native is their only lane.
#   Phase 4  Operational tests bash scripts/run-all-tests.sh --deployment
#   Phase 5  Summary          populated roadmap status table + manifest
#
# On any failure it records a finding and (with --create-issues) opens or
# updates ONE deduplicated GitHub issue in the repo that owns the failure.
# When gh is unavailable/offline it writes an issue DRAFT to
# .deploy-validate/issues/ instead, so a cycle never blocks on the network.
#
# Usage:
#   scripts/deploy-validate-agent.sh [--fresh] [--footprint=docker|native|both]
#                                    [--restart-only] [--no-deploy]
#                                    [--skip-tests] [--openclaw|--no-openclaw]
#                                    [--create-issues] [--dry-run]
#                                    [--cycle=N] [--interval=SECONDS] [--help]
#
#   --fresh           Clean build: startUniverse rebuilds all images --no-cache
#                     and wipes the perception_sources volume.
#   --footprint=...   Which lanes to validate (default: both):
#                       docker  containerized restart matrix only (Phase 3)
#                       native  local-process lane only (Phase 3N)
#                       both    both lanes. OpenClaw + localAIStack are always
#                               containerized only, regardless of this flag.
#   --restart-only    Skip the full deploy; assume the stack is up and only run
#                     the per-unit restart matrix + tests.
#   --no-deploy       Skip Phase 1 entirely (health-gate the current stack).
#   --skip-tests      Skip Phase 4 operational tests.
#   --openclaw / --no-openclaw   Force-include / exclude the OpenClaw unit.
#   --create-issues   File/refresh GitHub issues on failure (needs gh + network).
#   --dry-run         Plan only — delegates to startUniverse.sh --dry-run, lists
#                     the restart matrix and test gate, starts nothing.
#   --cycle=N         Repeat the whole workflow N times (default 1).
#   --interval=S      Seconds to wait between cycles (default 0).
#   --help            This message.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WS="$(cd "$CI_DIR/.." && pwd)"

SCALA_DIR="$WS/RealityEngine_Scala"
MGR_DIR="$WS/RealityEngine_Manager"
MACHINES_DIR="$WS/RealityEngine_Machines"
LAS_DIR="$WS/localAIStack"
OCS_DIR="$WS/localOpenClawStack"

# The CI docker-compose.yml requires these for build contexts and the RE machine
# volume (`${MACHINES_DIR:?...}/machines`). Export them so direct `docker compose`
# calls in the restart matrix interpolate the same way startUniverse.sh does.
export SCALA_DIR MGR_DIR MACHINES_DIR

STATE_DIR="$CI_DIR/.deploy-validate"
ISSUE_DIR="$STATE_DIR/issues"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG="$STATE_DIR/run-$RUN_TS.log"
ROADMAP_OUT="$STATE_DIR/roadmap-status.md"

# ── Flags ───────────────────────────────────────────────────────────────────
FRESH=false
FOOTPRINT="both"         # docker | native | both
DO_DEPLOY=true
RESTART_ONLY=false
DO_TESTS=true
OPENCLAW="auto"          # auto | yes | no
CREATE_ISSUES=false
DRY_RUN=false
CYCLES=1
INTERVAL=0

# ── Colours / logging ───────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
_log() { echo -e "$*" | tee -a "$RUN_LOG" >&2; }
ok()   { _log "${GREEN}✓${NC} $*"; }
info() { _log "${YELLOW}ℹ${NC} $*"; }
warn() { _log "${RED}⚠${NC} $*"; }
hdr()  { _log "\n${CYAN}${BOLD}─── $* ───${NC}"; }

# ── Result accumulation:  "STATUS|phase|label|owner_repo|note" ──────────────
declare -a RESULTS=()
record() { RESULTS+=("$1|$2|$3|${4:-}|${5:-}"); }
PASS_N=0; FAIL_N=0; SKIP_N=0

print_usage() { sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --fresh)          FRESH=true ;;
    --footprint=*)    FOOTPRINT="${arg#*=}" ;;
    --restart-only)   RESTART_ONLY=true; DO_DEPLOY=false ;;
    --no-deploy)      DO_DEPLOY=false ;;
    --skip-tests)     DO_TESTS=false ;;
    --openclaw)       OPENCLAW=yes ;;
    --no-openclaw)    OPENCLAW=no ;;
    --create-issues)  CREATE_ISSUES=true ;;
    --dry-run)        DRY_RUN=true ;;
    --cycle=*)        CYCLES="${arg#*=}" ;;
    --interval=*)     INTERVAL="${arg#*=}" ;;
    --help|-h)        print_usage; exit 0 ;;
    *) echo "Unknown argument: $arg"; print_usage; exit 2 ;;
  esac
done

case "$FOOTPRINT" in docker|native|both) ;; *) echo "Bad --footprint=$FOOTPRINT (docker|native|both)"; exit 2 ;; esac

# FRESH is the string "true"/"false", so ${FRESH:+...} would wrongly trigger on
# "false" (non-empty). Derive explicit flag/label strings keyed on the value.
FRESH_FLAG=""; FRESH_LABEL=""
if [ "$FRESH" = true ]; then FRESH_FLAG="--fresh"; FRESH_LABEL=" (--fresh clean build)"; fi

mkdir -p "$STATE_DIR" "$ISSUE_DIR"

# ── Single-instance lock ────────────────────────────────────────────────────
# Two concurrent runs collide on the buildx/compose lock and race image/volume
# teardown (esp. with --fresh). mkdir is atomic, so it is a safe lock primitive.
LOCK_DIR="$STATE_DIR/.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  _other="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?')"
  if [ "$_other" != "?" ] && kill -0 "$_other" 2>/dev/null; then
    echo "Another deploy-validate-agent is already running (pid $_other). Aborting." >&2
    exit 3
  fi
  # Stale lock from a crashed run — reclaim it.
  rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR"
fi
echo "$$" > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

: > "$RUN_LOG"

# ── HTTP poll helper (TLS-insensitive; RE/PE use self-signed certs) ─────────
poll() {
  local url="$1" label="$2" max="${3:-30}" flags="${4:--skf}"
  local n=0
  while [ "$n" -lt "$max" ]; do
    curl $flags --max-time 4 "$url" >/dev/null 2>&1 && { ok "$label"; return 0; }
    n=$((n+1)); sleep 2
  done
  warn "$label — no response after $((max*2))s ($url)"
  return 1
}

# =============================================================================
# Issue routing — failures map to the repo that owns the failing unit.
# =============================================================================
owner_repo() {  # owner_repo <unit-key>  ->  jateeter/<repo>
  case "$1" in
    reality-engine|re|scala)       echo "RealityEngine_Scala" ;;
    manager|visualizer|pe)         echo "RealityEngine_Manager" ;;
    cpp)                           echo "RealityEngine_CPP" ;;
    lsp)                           echo "RealityEngine_LSP" ;;
    localai|localai-api|infra-localai) echo "localAIStack" ;;
    openclaw)                      echo "localOpenClawStack" ;;
    tests|machines|corpus)         echo "RealityEngine_Machines" ;;
    *)                             echo "RealityEngine_CI" ;;   # orchestration default
  esac
}
GH_OWNER="jateeter"

gh_ready() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
  return 0
}

# Open or refresh a single deduplicated issue per (repo, unit). The marker line
# makes the issue idempotent across cycles: we search for it and comment rather
# than spawn duplicates.
file_issue() {
  local unit="$1" phase="$2" label="$3" note="$4"
  local repo; repo="$(owner_repo "$unit")"
  local marker="<!-- deploy-validate-agent:${unit}:${phase} -->"
  local title="[deploy-validate] ${phase}: ${label}"
  local body
  body="$(cat <<EOF
${marker}

**Detected by** \`deploy-validate-agent.sh\` on $(date -u +%FT%TZ)
**Cycle phase:** ${phase}
**Failing unit:** \`${unit}\`  →  routed to \`${GH_OWNER}/${repo}\`

## What failed
${label}

## Detail
${note:-No additional detail captured.}

## Reproduce
\`\`\`bash
cd ${CI_DIR}
scripts/deploy-validate-agent.sh ${FRESH_FLAG:+$FRESH_FLAG }--restart-only   # focused re-run
# or full cycle:
scripts/deploy-validate-agent.sh ${FRESH_FLAG}
\`\`\`

Run log: \`${RUN_LOG}\`
EOF
)"

  if [ "$CREATE_ISSUES" = false ]; then
    return 0
  fi

  if gh_ready; then
    # Dedup: find an open issue carrying our marker for this unit+phase.
    local existing
    existing="$(gh issue list -R "$GH_OWNER/$repo" --state open --search "$marker in:body" \
                  --json number --jq '.[0].number' 2>/dev/null || true)"
    if [ -n "$existing" ] && [ "$existing" != "null" ]; then
      gh issue comment -R "$GH_OWNER/$repo" "$existing" \
        --body "Recurred on $(date -u +%FT%TZ) (cycle phase ${phase}).\n\n${note}" >/dev/null 2>&1 \
        && info "Updated existing issue $GH_OWNER/$repo#$existing" \
        || warn "Could not comment on $GH_OWNER/$repo#$existing"
    else
      local url
      url="$(gh issue create -R "$GH_OWNER/$repo" --title "$title" --body "$body" \
               --label "deployment,validation-agent" 2>/dev/null || true)"
      [ -n "$url" ] && ok "Filed issue: $url" || warn "gh issue create failed for $repo"
    fi
  else
    # Offline / unauthenticated fallback: write a draft so the cycle never blocks.
    local draft="$ISSUE_DIR/${repo}__${unit}__${phase}.md"
    { echo "# $title"; echo "# repo: $GH_OWNER/$repo"; echo ""; echo "$body"; } > "$draft"
    warn "gh unavailable — wrote issue draft: $draft"
  fi
}

# Central failure handler: log, record, and (maybe) file an issue.
fail() {  # fail <unit> <phase> <label> <note>
  warn "FAIL [$2] $3"
  record FAIL "$2" "$3" "$(owner_repo "$1")" "$4"
  FAIL_N=$((FAIL_N+1))
  file_issue "$1" "$2" "$3" "$4"
}
pass() { ok "$3"; record PASS "$2" "$3" "" ""; PASS_N=$((PASS_N+1)); }
skip() { info "SKIP $3 — $4"; record SKIP "$2" "$3" "" "$4"; SKIP_N=$((SKIP_N+1)); }

# =============================================================================
# Phase 0 · Preflight
# =============================================================================
phase_preflight() {
  hdr "Phase 0 · Preflight"
  docker info >/dev/null 2>&1 \
    && pass orchestration preflight "Docker daemon reachable" \
    || { fail orchestration preflight "Docker daemon not running" "Start Docker Desktop"; return 1; }
  docker compose version >/dev/null 2>&1 \
    && pass orchestration preflight "docker compose v2 present" \
    || { fail orchestration preflight "docker compose v2 missing" "Install Docker Desktop >= 3.x"; return 1; }
  [ -f "$CI_DIR/.env" ] \
    && pass orchestration preflight ".env present" \
    || { fail orchestration preflight ".env missing" "cp .env.example .env and configure"; return 1; }
  local missing=""
  for f in certs/server.crt certs/server.key certs/ca.crt certs/keystore.p12; do
    [ -f "$CI_DIR/$f" ] || missing="$missing $f"
  done
  [ -z "$missing" ] \
    && pass orchestration preflight "TLS certs present" \
    || fail orchestration preflight "Missing TLS certs:$missing" "Run certs/generate-dev-certs.sh"
  for d in "$SCALA_DIR:scala" "$MGR_DIR:manager" "$MACHINES_DIR:machines" "$LAS_DIR:localai"; do
    local p="${d%%:*}" k="${d##*:}"
    [ -d "$p" ] && pass "$k" preflight "Sibling repo present: ${p##*/}" \
                || fail "$k" preflight "Sibling repo missing: ${p##*/}" "Clone it as a sibling of RealityEngine_CI"
  done
  if [ "$CREATE_ISSUES" = true ]; then
    gh_ready && ok "gh authenticated — issues will be filed on GitHub" \
             || warn "gh not authenticated/offline — failures will be written as drafts to $ISSUE_DIR"
  fi
  return 0
}

# =============================================================================
# Phase 1 · Full deploy (Docker AI path)
# =============================================================================
phase_deploy() {
  hdr "Phase 1 · Full deploy via startUniverse.sh${FRESH_LABEL}"
  local oc_flag=""
  case "$OPENCLAW" in yes) oc_flag="--openclaw" ;; no) oc_flag="--no-openclaw" ;; esac
  if [ "$DRY_RUN" = true ]; then
    info "Dry-run: ./startUniverse.sh --dry-run ${FRESH_FLAG:+$FRESH_FLAG }$oc_flag"
    ( cd "$CI_DIR" && bash ./startUniverse.sh --dry-run $FRESH_FLAG $oc_flag ) \
      && pass orchestration deploy "startUniverse dry-run plan coherent" \
      || fail orchestration deploy "startUniverse dry-run failed preflight" "See $RUN_LOG"
    return 0
  fi
  # startUniverse.sh's port-conflict preflight runs BEFORE its own orphan
  # cleanup, so a previously-running universe makes it die on the RE ports
  # (3001/3004/3005/5001/5173). Tear the existing DOCKER stack down first —
  # but Docker-natively.
  #
  # DO NOT use `stopUniverse.sh --all` here. It delegates to
  # RealityEngine_Manager/stop.sh and runs _sweep_native_ports, both of which
  # `kill -KILL` whatever holds ports 3001/5173/5001. When the containerized
  # stack is up, *all of those ports are bound by a single PID —
  # `com.docker.backend`*, Docker Desktop's port proxy. SIGKILLing it takes the
  # whole daemon down deterministically (this is why earlier --fresh runs died
  # with "Docker daemon not running" right after teardown). `docker compose
  # down` frees the ports by removing the containers and never touches the
  # Docker backend process.
  info "Pre-deploy teardown (docker compose down: CI, localAIStack, OpenClaw)..."
  ( cd "$CI_DIR" && docker compose down --remove-orphans ) >>"$RUN_LOG" 2>&1 || true
  if [ -f "$LAS_DIR/docker-compose.yml" ]; then
    ( cd "$LAS_DIR" && docker compose down --remove-orphans ) >>"$RUN_LOG" 2>&1 || true
  fi
  if [ -f "$OCS_DIR/docker-compose.yml" ]; then
    ( cd "$OCS_DIR" && docker compose down --remove-orphans ) >>"$RUN_LOG" 2>&1 || true
  fi
  sleep 2
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon healthy after teardown"
  else
    fail orchestration deploy "Docker daemon down after compose-down teardown" \
      "Unexpected — compose down should not affect the daemon; investigate Docker Desktop"
    return 1
  fi
  local args=( --warn-only )
  [ "$FRESH" = true ] && args+=( --fresh )
  [ -n "$oc_flag" ] && args+=( "$oc_flag" )
  info "Running: ./startUniverse.sh ${args[*]}"
  if ( cd "$CI_DIR" && bash ./startUniverse.sh "${args[@]}" ) >>"$RUN_LOG" 2>&1; then
    pass orchestration deploy "startUniverse.sh completed"
  else
    fail orchestration deploy "startUniverse.sh exited non-zero" "Inspect tail of $RUN_LOG"
    return 1
  fi
  # Surface any integration warnings the orchestrator recorded.
  if [ -f /tmp/universe-manifest.json ]; then
    local w; w="$(python3 -c "import json;print(json.load(open('/tmp/universe-manifest.json')).get('warns',0))" 2>/dev/null || echo 0)"
    [ "${w:-0}" -gt 0 ] && warn "startUniverse recorded $w integration warning(s) — see $RUN_LOG"
  fi
  return 0
}

# =============================================================================
# Phase 2 · Health gate — public Docker endpoints
# =============================================================================
phase_health() {
  hdr "Phase 2 · Health gate (public Docker endpoints)"
  poll "https://localhost:5001/api/health" "RE API (:5001)" 20      && pass reality-engine health "RE API healthy"          || fail reality-engine health "RE API unhealthy (:5001)" "docker logs reality-engine-app"
  poll "https://localhost:3004/api/health" "PE API (:3004)" 20      && pass manager health "PE API healthy"                 || fail manager health "PE API unhealthy (:3004)" "docker logs reality-engine-perception-backend"
  poll "http://localhost:3001/health" "Visualizer backend (:3001)" 15 && pass manager health "Visualizer backend healthy"  || fail manager health "Visualizer backend unhealthy (:3001)" "docker logs reality-engine-visualizer-backend"
  poll "http://localhost:5173/" "Visualizer UI (:5173)" 15         && pass manager health "Visualizer UI reachable"        || fail manager health "Visualizer UI unreachable (:5173)" "docker logs reality-engine-visualizer-frontend"
  poll "http://localhost:4000/health" "localAIStack API (:4000)" 15 && pass localai health "localAIStack API healthy"      || fail localai health "localAIStack API unhealthy (:4000)" "docker logs localai_api"
  poll "http://localhost:4333/collections" "Qdrant (:4333)" 15     && pass localai health "Qdrant reachable"               || fail localai health "Qdrant unreachable (:4333)" "docker logs localai_qdrant"
  if [ "$OPENCLAW" != "no" ]; then
    if curl -sf --max-time 4 "http://localhost:18789/healthz" >/dev/null 2>&1; then
      pass openclaw health "OpenClaw gateway healthy (:18789)"
    else
      [ "$OPENCLAW" = "yes" ] && fail openclaw health "OpenClaw gateway unhealthy (:18789)" "docker logs openclaw-gateway" \
                              || skip openclaw health "OpenClaw gateway" "not started (auto mode)"
    fi
  fi
}

# =============================================================================
# Phase 3 · Restart matrix — stop→start→re-health each deployable unit.
# Docker footprint: RE/Manager restart via compose service recreate; the
# localAIStack and OpenClaw repos restart via their own scripts/start.sh.
# =============================================================================
restart_compose_service() {  # <unit> <health-url> <label> <svc...>
  local unit="$1" url="$2" label="$3"; shift 3
  local svcs=( "$@" ) build=()
  [ "$FRESH" = true ] && build=( --build )
  info "Restarting $label (compose: ${svcs[*]})..."
  ( cd "$CI_DIR" && docker compose up -d --force-recreate --no-deps ${build[@]+"${build[@]}"} "${svcs[@]}" ) >>"$RUN_LOG" 2>&1 \
    || { fail "$unit" restart "$label recreate failed" "docker compose up ${svcs[*]}"; return 1; }
  poll "$url" "$label back up" 30 && pass "$unit" restart "$label restarted cleanly" \
                                  || fail "$unit" restart "$label did not return healthy after restart" "$url"
}

restart_repo_script() {  # <unit> <health-url> <label> <repo-dir>
  local unit="$1" url="$2" label="$3" dir="$4"
  if [ ! -x "$dir/scripts/start.sh" ]; then
    skip "$unit" restart "$label" "$dir/scripts/start.sh not found"; return 0
  fi
  info "Restarting $label via ${dir##*/}/scripts/start.sh..."
  [ -x "$dir/scripts/stop.sh" ] && ( cd "$dir" && bash scripts/stop.sh ) >>"$RUN_LOG" 2>&1 || true
  if ( cd "$dir" && bash scripts/start.sh ) >>"$RUN_LOG" 2>&1; then
    poll "$url" "$label back up" 30 && pass "$unit" restart "$label restarted cleanly" \
                                    || fail "$unit" restart "$label unhealthy after start.sh" "$url"
  else
    fail "$unit" restart "$label scripts/start.sh failed" "See $RUN_LOG"
  fi
}

phase_restart_matrix() {
  hdr "Phase 3 · Restart matrix — CONTAINERIZED lane (per-unit)"
  restart_compose_service reality-engine "https://localhost:5001/api/health" "RE API (Scala container)" reality-engine
  restart_compose_service manager "https://localhost:3004/api/health" "Manager PE+Visualizer containers" \
      perception-engine-backend perception-engine-frontend visualizer-backend visualizer-frontend
  restart_repo_script localai "http://localhost:4000/health" "localAIStack" "$LAS_DIR"
  if [ "$OPENCLAW" = "yes" ] || { [ "$OPENCLAW" = "auto" ] && curl -sf --max-time 3 http://localhost:18789/healthz >/dev/null 2>&1; }; then
    restart_repo_script openclaw "http://localhost:18789/healthz" "OpenClaw gateway" "$OCS_DIR"
  else
    skip openclaw restart "OpenClaw restart" "gateway not active"
  fi
}

# =============================================================================
# Phase 3N · Native runtime lane — local processes via each repo's start.sh.
# Validates start → health → restart-in-place → stop for the Scala/Manager/
# CPP/LSP runtimes. Runs on OFF-BAND ports + a dedicated "dv" instance id so it
# never collides with the Docker stack (RE :5001, Viz :3001/:5173).
# CPP/LSP have no container image — native is their only deployment lane.
# OpenClaw + localAIStack are intentionally excluded (containerized only).
# =============================================================================
have() { command -v "$1" >/dev/null 2>&1; }
resolve_sbt() {
  have sbt && { echo sbt; return 0; }
  local c
  for c in "$HOME/.sdkman/candidates/sbt/current/bin/sbt" /opt/homebrew/opt/sbt/bin/sbt; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}
node_ok() { have node && node -e 'process.exit(+process.versions.node.split(".")[0]>=25?0:1)' 2>/dev/null; }
prereq_scala() { resolve_sbt >/dev/null 2>&1; }
prereq_cpp()   { have make && { have c++ || have g++ || have clang++; }; }
prereq_lsp()   { have sbcl && { [ -f "$WS/RealityEngine_LSP/quicklisp/setup.lisp" ] || [ -f "$HOME/quicklisp/setup.lisp" ]; }; }

DV_INST="dv"   # validation instance id — keeps PID files off the canonical band

# native_runtime <unit> <repo-dir> <re-port> <pe-port> <prereq-fn> <label>
native_runtime() {
  local unit="$1" dir="$2" re_port="$3" pe_port="$4" prereq="$5" label="$6"
  [ -d "$dir" ] || { skip "$unit" native "$label" "repo not found at $dir"; return 0; }
  [ -x "$dir/start.sh" ] || { skip "$unit" native "$label" "start.sh missing"; return 0; }
  if ! "$prereq"; then skip "$unit" native "$label" "toolchain prerequisites not installed"; return 0; fi

  # Scala builds its jar via sbt; forward a resolved sbt path so start.sh finds it.
  local -a env_extra=()
  [ "$unit" = scala ] && env_extra=( "SBT=$(resolve_sbt 2>/dev/null || echo sbt)" )

  _native_start() {
    ( cd "$dir" && env INSTANCE_ID="$DV_INST" REALITY_ENGINE_PORT="$re_port" \
        PERCEPTION_ENGINE_PORT="$pe_port" RE_LOAD_MACHINES=1 ${env_extra[@]+"${env_extra[@]}"} \
        bash start.sh ) >>"$RUN_LOG" 2>&1
  }
  _native_stop() { ( cd "$dir" && bash stop.sh --instance="$DV_INST" ) >>"$RUN_LOG" 2>&1 || true; }

  info "Native $label: start on RE=:$re_port PE=:$pe_port (instance $DV_INST)..."
  _native_stop                       # clean any prior validation instance first
  _native_start || true              # some start.sh background the engine and return
  local re_ok=false pe_ok=false
  poll "http://localhost:$re_port/api/health" "$label RE (:$re_port)" 45 "-sf" && re_ok=true
  poll "http://localhost:$pe_port/api/health" "$label PE (:$pe_port)" 30 "-sf" && pe_ok=true

  if [ "$re_ok" = true ] && [ "$pe_ok" = true ]; then
    pass "$unit" native "$label native start + health OK"
    info "Native $label: restart-in-place check..."
    _native_stop
    if _native_start && poll "http://localhost:$re_port/api/health" "$label RE after restart" 45 "-sf"; then
      pass "$unit" native "$label native restart OK"
    else
      fail "$unit" native "$label failed to come back after restart" "see $RUN_LOG"
    fi
  else
    fail "$unit" native "$label native start failed (RE=$re_ok PE=$pe_ok)" "tail of $RUN_LOG"
  fi
  _native_stop                       # always tear the validation instance down
}

# Manager native is the Visualizer backend only; it has no RE/PE ports of its
# own — it points at the running RE/PE. Validate the backend on an off-band
# port with the frontend (hardcoded :5173) disabled so it coexists with Docker.
native_manager() {
  local unit="manager" dir="$MGR_DIR" port=3011
  local label="Manager Visualizer backend (native)"
  [ -d "$dir" ] || { skip "$unit" native "$label" "repo not found"; return 0; }
  [ -x "$dir/start.sh" ] || { skip "$unit" native "$label" "start.sh missing"; return 0; }
  if ! node_ok; then skip "$unit" native "$label" "node >= 25 not available (nvm/install)"; return 0; fi
  local re="https://localhost:5001" pe="https://localhost:3004"

  _mgr_start() {
    ( cd "$dir" && bash start.sh --port "$port" --no-frontend --no-seed --re "$re" --pe "$pe" ) >>"$RUN_LOG" 2>&1
  }
  _mgr_stop() { ( cd "$dir" && bash stop.sh ) >>"$RUN_LOG" 2>&1 || true; rm -f "$dir/.manager-pids" 2>/dev/null || true; }

  info "Native $label on :$port → RE $re  PE $pe ..."
  _mgr_stop
  if _mgr_start && poll "http://localhost:$port/health" "$label (:$port)" 30 "-sf"; then
    pass "$unit" native "$label native start + health OK"
    _mgr_stop
    if _mgr_start && poll "http://localhost:$port/health" "$label after restart" 30 "-sf"; then
      pass "$unit" native "$label native restart OK"
    else
      fail "$unit" native "$label failed to come back after restart" "see $RUN_LOG"
    fi
  else
    fail "$unit" native "$label native start failed" "tail of $RUN_LOG"
  fi
  _mgr_stop
}

phase_native_lane() {
  hdr "Phase 3N · Native runtime lane — LOCAL processes (off-band ports)"
  info "Native runtimes use off-band ports + instance '$DV_INST' to coexist with the Docker stack."
  native_runtime scala "$SCALA_DIR" 5101 5100 prereq_scala "Scala RE/PE (native)"
  native_manager
  native_runtime cpp "$CPP_DIR" 5301 5300 prereq_cpp "C++ RE/PE (native)"
  native_runtime lsp "$LSP_DIR" 5601 5600 prereq_lsp "LSP RE/PE (native)"
  info "CPP/LSP have no container image — native is their only deployment lane."
}

# =============================================================================
# Phase 4 · Operational tests (strict deployment gate)
# =============================================================================
phase_tests() {
  hdr "Phase 4 · Operational tests (run-all-tests.sh --deployment)"
  if [ "$DRY_RUN" = true ]; then
    ( cd "$CI_DIR" && bash scripts/run-all-tests.sh --list ) >>"$RUN_LOG" 2>&1 || true
    skip tests tests "Operational test gate" "dry-run — listed only"
    return 0
  fi
  if ( cd "$CI_DIR" && bash scripts/run-all-tests.sh --deployment ) >>"$RUN_LOG" 2>&1; then
    pass tests tests "Deployment test gate passed (unit + e2e, no skips)"
  else
    fail tests tests "Deployment test gate failed" "Inspect per-suite output in $RUN_LOG"
  fi
}

# =============================================================================
# Phase 5 · Summary + populated roadmap
# =============================================================================
phase_summary() {
  hdr "Phase 5 · Summary"
  local entry st ph lb own nt
  for entry in ${RESULTS[@]+"${RESULTS[@]}"}; do
    IFS='|' read -r st ph lb own nt <<< "$entry"
    case "$st" in
      PASS) ok   "[$ph] $lb" ;;
      FAIL) warn "[$ph] $lb  →  $own  ${nt:+($nt)}" ;;
      SKIP) info "[$ph] $lb  — $nt" ;;
    esac
  done
  _log "\n${BOLD}Totals:${NC} ${GREEN}${PASS_N} passed${NC}, ${RED}${FAIL_N} failed${NC}, ${YELLOW}${SKIP_N} skipped${NC}"

  # Write a populated roadmap-status table for the report.
  {
    echo "# RealityEngine Deployment Validation — Run Status"
    echo ""
    echo "- Run: \`$RUN_TS\`  ·  Footprint: \`$FOOTPRINT\`  ·  Fresh build: \`$FRESH\`  ·  OpenClaw: \`$OPENCLAW\`  ·  Dry-run: \`$DRY_RUN\`"
    echo "- Totals: **$PASS_N passed**, **$FAIL_N failed**, **$SKIP_N skipped**"
    echo ""
    echo "| Phase | Check | Status | Owner repo (on failure) | Note |"
    echo "|---|---|---|---|---|"
    for entry in ${RESULTS[@]+"${RESULTS[@]}"}; do
      IFS='|' read -r st ph lb own nt <<< "$entry"
      echo "| $ph | $lb | $st | ${own:-—} | ${nt:-} |"
    done
    echo ""
    if [ "$FAIL_N" -eq 0 ]; then
      echo "**Result: ✅ deployment validated — all phases nominal.**"
    else
      echo "**Result: ❌ $FAIL_N failing check(s).** Issues filed/drafted under \`$ISSUE_DIR\` (or GitHub when authenticated)."
    fi
  } > "$ROADMAP_OUT"
  ok "Roadmap status written: $ROADMAP_OUT"
  _log "Run log: $RUN_LOG"
}

run_cycle() {
  RESULTS=(); PASS_N=0; FAIL_N=0; SKIP_N=0
  phase_preflight || { phase_summary; return 1; }
  [ "$DO_DEPLOY" = true ] && phase_deploy
  # Health-gate the Docker public stack whenever the docker footprint is in play
  # (native Manager points at it too) or a deploy/restart just ran.
  if [ "$DRY_RUN" = false ] && { [ "$DO_DEPLOY" = true ] || [ "$RESTART_ONLY" = true ] || [ "$FOOTPRINT" != native ]; }; then
    phase_health
  fi
  if [ "$DRY_RUN" = false ]; then
    [ "$FOOTPRINT" != native ] && phase_restart_matrix    # containerized lane
    [ "$FOOTPRINT" != docker ] && phase_native_lane       # local-process lane
  fi
  [ "$DO_TESTS" = true ] && phase_tests
  phase_summary
  [ "$FAIL_N" -eq 0 ]
}

# ── Main loop ───────────────────────────────────────────────────────────────
overall_rc=0
for (( c=1; c<=CYCLES; c++ )); do
  [ "$CYCLES" -gt 1 ] && hdr "Cycle $c / $CYCLES"
  run_cycle || overall_rc=1
  if [ "$c" -lt "$CYCLES" ] && [ "$INTERVAL" -gt 0 ]; then
    info "Sleeping ${INTERVAL}s before next cycle..."
    sleep "$INTERVAL"
  fi
done
exit "$overall_rc"
