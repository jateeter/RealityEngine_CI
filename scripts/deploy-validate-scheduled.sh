#!/usr/bin/env bash
# Scheduled wrapper for deploy-validate-agent.sh — §4 step 4 of
# DEPLOYMENT_VALIDATION_ROADMAP.md.
#
# Deliberately NOT --fresh. The recurring form restarts services; it does not
# tear the universe down and rebuild every image, which on a 6-hourly cadence
# would mean the machine is never not rebuilding.
#
# Baseline at the time of scheduling (2026-09-12, on merged main):
#   agent level   28 passed / 1 failed
#   the 1 is the deployment test gate (RealityEngine_Machines#126)
#
# So a run reporting 28/1 is the expected floor and is NOT news. What is news is
# any *new* failing unit, or the floor moving. Read the diff against the previous
# run, not the absolute count.
#
# The floor was 28/13 that morning. Two defects accounted for all of it, neither
# in an engine: an undetectably-absent Loki logging plugin (#362) and a
# healthcheck whose binary the eclipse-temurin:25 bump removed (ed2cdd6).
#
# What survives inside the gate is two real sub-failures, not the six it used to
# report: cesgen_contracts_parity is retired with its oracle (#327), and the
# three semantic/parity suites that used to be scored as failures for not running
# now genuinely run (#363). Their first honest output has not been triaged yet —
# a red there is new information, not the known floor.
#
# The runtime is pinned here, not inherited. launchd starts this through a
# login shell (`/bin/bash -lc`), and macOS /etc/profile runs path_helper, which
# moves the system paths ahead of the PATH the plist supplies. That put
# /usr/local/bin/node (v22.17.0) in front of nvm's Node 26, so every scheduled
# run from 2026-09-12 on skipped the Manager, Machines, OpenClaw adapter and
# filer suites as "Node 22.17.0 too old" — and deployment mode scores a skip as
# a failure, so six of RealityEngine_Machines#126's sixteen were this.

# bash 5, per the engineering contract; /bin/bash on macOS is 3.2.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -x /opt/homebrew/bin/bash ]; then
  exec /opt/homebrew/bin/bash "$0" "$@"
fi
set -uo pipefail

# Node: the newest installed release of this major. Manager needs >=26, the
# other suites >=25.5. nvm.sh is not safe under `set -u`.
NODE_MAJOR="${DEPLOY_VALIDATE_NODE_MAJOR:-26}"
if [ -s "$HOME/.nvm/nvm.sh" ]; then
  set +u
  # shellcheck source=/dev/null
  . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
  nvm use "$NODE_MAJOR" >/dev/null 2>&1
  set -u
fi
NODE_FOUND="$(node --version 2>/dev/null || echo none)"

if [ "${DEPLOY_VALIDATE_PRELUDE_ONLY:-0}" = 1 ]; then
  echo "bash=${BASH_VERSION} node=${NODE_FOUND} node_path=$(command -v node || echo none)"
  exit 0
fi

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$CI_DIR/.deploy-validate/scheduled"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$OUT_DIR/run-$STAMP.log"
mkdir -p "$OUT_DIR"

{
  echo "=== scheduled deploy-validate $STAMP ==="
  echo "host: $(hostname)  pwd: $CI_DIR"
  echo "runtime: bash ${BASH_VERSION}  node ${NODE_FOUND} (want v${NODE_MAJOR}.x)"
  case "$NODE_FOUND" in
    "v${NODE_MAJOR}."*) ;;
    *) echo "WARNING: Node ${NODE_FOUND} is not v${NODE_MAJOR}.x; Node suites will skip, and deployment mode scores a skip as a failure." ;;
  esac
  if ! docker info >/dev/null 2>&1; then
    echo "SKIP: Docker daemon not reachable — nothing to validate."
    echo "This is a legitimate non-participation state, not a failure: the"
    echo "laptop is asleep, travelling, or Docker is simply not running."
    exit 0
  fi
  bash "$CI_DIR/scripts/deploy-validate-agent.sh" --create-issues
  echo "exit=$?"
} >"$LOG" 2>&1

# Keep the last 40 runs; older ones are noise.
ls -1t "$OUT_DIR"/run-*.log 2>/dev/null | tail -n +41 | xargs -r rm -f
