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
  # Two passes. The first is everything shellcheck rates as an error.
  #
  # The second promotes SC2154 — "referenced but not assigned" — which
  # shellcheck rates a warning and `-S error` therefore discards. That gap let
  # a real break reach main: a partially applied edit added `run_cmd "$label"`
  # to regression-test.sh without the `local label=` that defines it, this gate
  # passed, and the hosted regression lane died at cold-start with
  # "line 940: label: unbound variable" (#202). Every script here runs under
  # `set -u`, so an unassigned reference is not a style question — it is a
  # guaranteed runtime abort on the line that touches it.
  #
  # --include limits the pass to that one check rather than admitting all
  # warnings, which would be a much larger and unrelated change.
  ok=true
  shellcheck -S error --format=gcc "$target" 2>&1 || ok=false
  shellcheck -S warning --include=SC2154 --format=gcc "$target" 2>&1 || ok=false
  if [ "$ok" = true ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi
done

echo ""
echo "shellcheck: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
