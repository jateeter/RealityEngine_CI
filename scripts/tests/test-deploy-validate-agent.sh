#!/usr/bin/env bash
# Unit tests for scripts/deploy-validate-agent.sh — no Docker, no gh, no engines.
#
# A deploy that tore the stacks down and then failed started nothing. The
# health phase used to probe every service anyway and file each one against
# its own repo: localOpenClawStack#39 (gateway :18789) and localAIStack#86
# (API :4000, Qdrant :4333) were that, in all three runs, not defects in those
# stacks. Recurrence comments also carried a literal "\n\n".
#
# The agent is not run: its deploy phase tears down live stacks. The phase
# functions are extracted and driven with every side effect stubbed.
#
# The stubs and variables below are read by the eval'd agent functions, which
# static analysis cannot see (SC2329, SC2034), and each check is a deferred
# expression evaluated by check(), so single quotes are intended (SC2016).
# shellcheck disable=SC2016,SC2034,SC2329
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
A="${1:-$CI_DIR/scripts/deploy-validate-agent.sh}"
extract() { sed -n "/^$1() {/,/^}/p" "$A"; }
eval "$(extract engine_pair_health)"
eval "$(extract phase_health)"
eval "$(extract skip_engine_restarts)"
eval "$(extract phase_deploy)"
eval "$(extract file_issue)"
eval "$(extract phase_restart_matrix)"
eval "$(extract stamped_agent_profile)"
eval "$(extract compose_passthrough_names)"
eval "$(extract deployed_passthrough_env)"

hdr() { :; }; info() { :; }; ok() { :; }; warn() { :; }; _log() { :; }
FAILS=(); SKIPS=(); PASSES=()
fail() { FAILS+=("$1:$3"); }
skip() { SKIPS+=("$1:$3"); }
pass() { PASSES+=("$1:$3"); }
poll() { return 1; }             # nothing answers
curl() { return 7; }             # gateway down
refuse_docker_lane() { :; }
DOCKER_LANE_BLOCKERS=""; OPENCLAW=yes; RUN_LOG=/dev/null
rc=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; rc=1; fi; }

# 1. The incident: deploy tore down, then startUniverse failed.
DEPLOY_FAILED=true; DEPLOY_TORE_DOWN=true; FAILS=(); SKIPS=()
phase_health
check "failed deploy files nothing in health" '[ ${#FAILS[@]} -eq 0 ]'
check "failed deploy skips all 10 probes" '[ ${#SKIPS[@]} -eq 10 ]'
check "each engine pair is skipped, against its runtime" 'for rt in scala cpp lsp; do printf "%s\n" "${SKIPS[@]}" | grep -q "^$rt:" || exit 1; done'
check "OpenClaw is skipped, not failed" 'printf "%s\n" "${SKIPS[@]}" | grep -q "^openclaw:"'

# 2. Healthy deploy path: a genuinely down gateway is still a finding.
DEPLOY_FAILED=false; DEPLOY_TORE_DOWN=true; FAILS=(); SKIPS=()
phase_health
check "successful deploy still files a down gateway" 'printf "%s\n" "${FAILS[@]}" | grep -q "^openclaw:OpenClaw gateway unhealthy"'
check "successful deploy still files localAI" 'printf "%s\n" "${FAILS[@]}" | grep -q "^localai:"'
check "a down engine container is filed against its runtime" '[ "$(printf "%s\n" "${FAILS[@]}" | grep -cE "^(scala|cpp|lsp):")" -eq 6 ]'

# 3. No deploy this cycle (--restart-only / --no-deploy): probes run as before.
DEPLOY_FAILED=false; DEPLOY_TORE_DOWN=false; FAILS=(); SKIPS=()
phase_health
check "no-deploy cycle still probes and files" '[ ${#FAILS[@]} -eq 13 ]'

# 4. Recurrence comment body: real newlines, no literal backslash-n.
phase=health; note="docker logs openclaw-gateway"
body="$(printf 'Recurred on %s (cycle phase %s).\n\n%s' "2026-09-26T00:00:00Z" "$phase" "$note")"
check "comment has real newlines" '[ "$(printf "%s" "$body" | wc -l | tr -d " ")" -eq 2 ]'
check "comment has no literal \\n" '! printf "%s" "$body" | grep -q "\\\\n"'
check "agent uses the printf form" 'grep -q "printf '"'"'Recurred on %s (cycle phase %s)" "$A"'

# 5. phase_deploy itself marks the failure after its teardown (stubs only).
T="$(mktemp -d)"; mkdir -p "$T/ci" "$T/las" "$T/ocs"
printf 'exit 1\n' > "$T/ci/startUniverse.sh"
docker() { return 0; }; sleep() { :; }; rm() { :; }
CI_DIR="$T/ci"; LAS_DIR="$T/las"; OCS_DIR="$T/ocs"; DRY_RUN=false; FRESH=false; FRESH_LABEL=""; FRESH_FLAG=""
DEPLOY_FAILED=false; DEPLOY_TORE_DOWN=false; FAILS=()
phase_deploy
check "phase_deploy marks teardown" '[ "$DEPLOY_TORE_DOWN" = true ]'
check "phase_deploy marks the failed deploy" '[ "$DEPLOY_FAILED" = true ]'
check "the deploy failure is filed once, against orchestration" '[ "${FAILS[*]}" = "orchestration:startUniverse.sh exited non-zero" ]'

# 6. RealityEngine_CI#366: a native universe holds the TLS-proxy ports. The
#    deploy must refuse *before* its teardown (#446), so nothing it would have
#    stopped is misreported, and the collision is one orchestration finding.
eval "$(extract refuse_docker_lane)"
DOCKER_CALLS=0
docker() { DOCKER_CALLS=$((DOCKER_CALLS+1)); return 0; }
DOCKER_LANE_BLOCKERS="  :3001  pid 1  node  (/ws/RealityEngine_Manager/visualizer/backend)"
DOCKER_LANE_REFUSED=false; DEPLOY_FAILED=false; DEPLOY_TORE_DOWN=false; FAILS=(); SKIPS=()
phase_deploy; deploy_rc=$?
check "a held proxy port refuses the deploy" '[ "$deploy_rc" -ne 0 ]'
check "the refusal happens before any teardown" '[ "$DOCKER_CALLS" -eq 0 ] && [ "$DEPLOY_TORE_DOWN" = false ]'
check "the refusal is filed once, against orchestration" '[ ${#FAILS[@]} -eq 1 ] && [[ "${FAILS[0]}" == orchestration:* ]]'
# The refused deploy left localAI and OpenClaw running; they answer.
poll() { return 0; }; curl() { return 0; }; PASSES=()
phase_health
check "health does not re-file the refusal" '[ ${#FAILS[@]} -eq 1 ]'
check "health skips the four proxied probes" '[ ${#SKIPS[@]} -eq 4 ]'
check "engine containers sit off the proxy and are still probed" '[ "$(printf "%s\n" "${PASSES[@]}" | grep -cE "^(scala|cpp|lsp):")" -eq 6 ]'
check "stacks the deploy never touched are still probed" 'printf "%s\n" "${PASSES[@]}" | grep -q "^localai:" && printf "%s\n" "${PASSES[@]}" | grep -q "^openclaw:"'

# 7. The containerized restart after a torn-down, failed deploy cannot pass:
#    the tls-proxy's static upstreams are absent, so nginx will not start.
#    It is skipped; localAI and OpenClaw, which restart their own whole stacks
#    via scripts/start.sh, are still exercised.
RESTARTED=()
restart_compose_service() { RESTARTED+=("$1"); }
restart_repo_script() { RESTARTED+=("$1"); }
DOCKER_LANE_BLOCKERS=""; OPENCLAW=yes; SKIPS=(); FAILS=()
DEPLOY_FAILED=true; DEPLOY_TORE_DOWN=true
phase_restart_matrix
check "failed deploy skips the five compose restarts" '[ ${#SKIPS[@]} -eq 5 ] && [ ${#FAILS[@]} -eq 0 ]'
check "failed deploy still restarts localAI and OpenClaw" '[ "${RESTARTED[*]}" = "localai openclaw" ]'
DEPLOY_FAILED=false; RESTARTED=(); SKIPS=()
phase_restart_matrix
check "a successful deploy restarts all seven units" '[ "${RESTARTED[*]}" = "reality-engine manager scala cpp lsp localai openclaw" ] && [ ${#SKIPS[@]} -eq 0 ]'

# 8. OpenClaw restarts with the agent profile the deploy resolved. A bare
#    start.sh defaults to `full`, so a regression deploy (15 agents) came back
#    with 1,322 and its security audit outran the budget (localOpenClawStack#51).
STAMP_DIR="$(mktemp -d)"; REAL_CI_DIR="$CI_DIR"; CI_DIR="$STAMP_DIR"
OC_ARGS="unset"
restart_repo_script() { [ "$1" = openclaw ] && OC_ARGS="${*:5}"; return 0; }
printf 'MACHINE_CORPUS=regression\nAGENT_PROFILE=regression\n' > "$STAMP_DIR/.universe-engine-selection"
DEPLOY_FAILED=false; DEPLOY_TORE_DOWN=false; SKIPS=(); FAILS=()
phase_restart_matrix
check "OpenClaw restarts with the stamped agent profile" '[ "$OC_ARGS" = "--agent-profile=regression" ]'
printf 'MACHINE_CORPUS=full\nAGENT_PROFILE=full\n' > "$STAMP_DIR/.universe-engine-selection"
OC_ARGS="unset"; phase_restart_matrix
check "a full-corpus deploy restarts OpenClaw with the full profile" '[ "$OC_ARGS" = "--agent-profile=full" ]'
command rm -f "$STAMP_DIR/.universe-engine-selection"
OC_ARGS="unset"; phase_restart_matrix
check "with nothing stamped, start.sh gets no profile flag" '[ -z "$OC_ARGS" ]'
check "startUniverse.sh stamps the resolved profile" 'command grep -qF "AGENT_PROFILE=\$AGENT_PROFILE" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/startUniverse.sh"'
CI_DIR="$REAL_CI_DIR"; command rm -rf "$STAMP_DIR"

# 9. A containerized restart keeps what the deployment gave each service.
#    startUniverse.sh exports TRIGGERS_ENABLED and the ACP_* defaults in its own
#    shell; the recreate ran without them and brought the PE back with trigger
#    dispatch off, so Phase 4's dispatch suites failed against a PE that could
#    not dispatch (RealityEngine_Machines#126).
# CI_DIR was pointed at scratch directories above; resolve the repo from here.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
names="$(compose_passthrough_names perception-engine-backend "$REPO_DIR/docker-compose.yml")"
check "the PE's pass-through names include trigger dispatch" 'printf "%s\n" "$names" | command grep -qx TRIGGERS_ENABLED'
check "the PE's pass-through names include the ACP gateway" 'printf "%s\n" "$names" | command grep -qx ACP_GATEWAY_URL'
check "values the file sets are not pass-through" '! printf "%s\n" "$names" | command grep -qx INTEGRATIONS_CONFIG'
check "another service's variables are not the PE's" '! printf "%s\n" "$names" | command grep -qx VIZ_PORT'
docker() {
  case "$1 $2" in
    "compose ps") echo cid-pe ;;
    "inspect cid-pe") printf 'TRIGGERS_ENABLED=true\nACP_GATEWAY_URL=ws://127.0.0.1:18789\nINTEGRATIONS_CONFIG=/app/config/integrations.json\nPATH=/usr/bin\n' ;;
  esac
}
SAVED_CI_DIR="$CI_DIR"; CI_DIR="$REPO_DIR"
carried="$(deployed_passthrough_env perception-engine-backend)"
check "a restart carries the deployed trigger switch" 'printf "%s\n" "$carried" | command grep -qx TRIGGERS_ENABLED=true'
check "a restart carries the deployed ACP gateway" 'printf "%s\n" "$carried" | command grep -qx "ACP_GATEWAY_URL=ws://127.0.0.1:18789"'
check "a restart carries nothing the file or image sets" '! printf "%s\n" "$carried" | command grep -qE "^(INTEGRATIONS_CONFIG|PATH)="'
docker() { return 1; }
check "a service with no container carries nothing" '[ -z "$(deployed_passthrough_env perception-engine-backend)" ]'
CI_DIR="$SAVED_CI_DIR"; unset -f docker
unset -f rm
exit $rc
