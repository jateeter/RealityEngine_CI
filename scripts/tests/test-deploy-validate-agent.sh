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
eval "$(extract phase_health)"
eval "$(extract phase_deploy)"
eval "$(extract file_issue)"

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
check "failed deploy skips all 7 probes" '[ ${#SKIPS[@]} -eq 7 ]'
check "OpenClaw is skipped, not failed" 'printf "%s\n" "${SKIPS[@]}" | grep -q "^openclaw:"'

# 2. Healthy deploy path: a genuinely down gateway is still a finding.
DEPLOY_FAILED=false; DEPLOY_TORE_DOWN=true; FAILS=(); SKIPS=()
phase_health
check "successful deploy still files a down gateway" 'printf "%s\n" "${FAILS[@]}" | grep -q "^openclaw:OpenClaw gateway unhealthy"'
check "successful deploy still files localAI" 'printf "%s\n" "${FAILS[@]}" | grep -q "^localai:"'

# 3. No deploy this cycle (--restart-only / --no-deploy): probes run as before.
DEPLOY_FAILED=false; DEPLOY_TORE_DOWN=false; FAILS=(); SKIPS=()
phase_health
check "no-deploy cycle still probes and files" '[ ${#FAILS[@]} -eq 7 ]'

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
unset -f rm
exit $rc
