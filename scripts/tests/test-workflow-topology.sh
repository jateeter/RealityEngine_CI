#!/usr/bin/env bash
# Verify that independent hosted engine jobs are not serialized accidentally.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$CI_DIR/.github/workflows/e2e-tests.yml"

job_block() {
  local job="$1"
  awk -v job="$job" '
    $0 == "  " job ":" { in_job = 1 }
    in_job && $0 ~ /^  [A-Za-z0-9_-]+:/ && $0 != "  " job ":" { exit }
    in_job { print }
  ' "$WORKFLOW"
}

smoke="$(job_block smoke-tests)"
e2e="$(job_block e2e-tests)"

grep -q '^    needs: \[shellcheck, scripts-unit-tests, dry-run-validate\]$' <<<"$smoke"
grep -q '^    needs: \[shellcheck, scripts-unit-tests, dry-run-validate\]$' <<<"$e2e"
! grep -q '^    needs: smoke-tests$' <<<"$e2e"

echo "workflow topology: smoke-tests and e2e-tests share prerequisites without serializing"
