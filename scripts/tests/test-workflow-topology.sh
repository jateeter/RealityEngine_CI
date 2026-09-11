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

core="$(job_block multi-engine-and-parity-tests)"

grep -q '^    needs: \[shellcheck, scripts-unit-tests, dry-run-validate\]$' <<<"$core"
grep -q 'Run smoke tests against shared core' <<<"$core"
grep -q 'Run integration and e2e tests against shared core' <<<"$core"
grep -q 'Run all CI e2e specs against shared core' <<<"$core"
test "$(grep -c -- '--engines=cpp:2,scala:1,lsp:1' <<<"$core")" -eq 1
! grep -q '^  smoke-tests:' "$WORKFLOW"
! grep -q '^  e2e-tests:' "$WORKFLOW"

echo "workflow topology: all suites run in one registry-backed core job"
