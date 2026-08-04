#!/usr/bin/env bash
# Static analysis gate — run shellcheck on all CI-managed shell scripts.
# Exit non-zero if any target has an error. Warnings remain visible in output.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGETS=(
  "$CI_DIR/startUniverse.sh"
  "$CI_DIR/stopUniverse.sh"
  "$CI_DIR/statusUniverse.sh"
  "$CI_DIR/scripts/registry.sh"
  "$CI_DIR/scripts/allocate-ports.sh"
  "$CI_DIR/scripts/detect-host-ip.sh"
  "$CI_DIR/scripts/gen-nginx-upstreams.sh"
  "$CI_DIR/scripts/lib/ci-e2e-specs.sh"
  "$CI_DIR/scripts/tests/test-ci-e2e-specs.sh"
  "$CI_DIR/../RealityEngine_CPP/start.sh"
  "$CI_DIR/../RealityEngine_CPP/stop.sh"
  "$CI_DIR/../RealityEngine_LSP/start.sh"
  "$CI_DIR/../RealityEngine_LSP/stop.sh"
)

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found — install via: brew install shellcheck  or  apt-get install shellcheck" >&2
  exit 1
fi

PASS=0; FAIL=0
for target in "${TARGETS[@]}"; do
  if [ ! -f "$target" ]; then
    echo "SKIP (not found): $target"
    continue
  fi
  if shellcheck -S error --format=gcc "$target" 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi
done

echo ""
echo "shellcheck: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
