#!/usr/bin/env bash
# Scheduled wrapper for deploy-validate-agent.sh — §4 step 4 of
# DEPLOYMENT_VALIDATION_ROADMAP.md.
#
# Deliberately NOT --fresh. The recurring form restarts services; it does not
# tear the universe down and rebuild every image, which on a 6-hourly cadence
# would mean the machine is never not rebuilding.
#
# Baseline at the time of scheduling (2026-09-10, on merged main):
#   agent level   28 passed / 1 failed
#   gate internal 25 passed / 9 failed across 6 suites, all characterised in
#                 docs/DEPLOYMENT_FAILURE_TRIAGE.md
#
# So a run reporting 28/1 is the expected floor and is NOT news. What is news is
# any *new* failing unit, or the floor moving. Read the diff against the previous
# run, not the absolute count.
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$CI_DIR/.deploy-validate/scheduled"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$OUT_DIR/run-$STAMP.log"
mkdir -p "$OUT_DIR"

{
  echo "=== scheduled deploy-validate $STAMP ==="
  echo "host: $(hostname)  pwd: $CI_DIR"
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
