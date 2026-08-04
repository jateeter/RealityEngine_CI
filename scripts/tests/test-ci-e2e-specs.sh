#!/usr/bin/env bash
# Unit tests for scripts/lib/ci-e2e-specs.sh — no stack, no Docker, no engines.
#
# Guards the invariant behind RealityEngine_CI#78: a multi-engine run executes a
# subset of e2e/tests/, and every spec it does not run must be accounted for.
# If those two lists stop covering the directory, coverage silently shrinks.
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0; FAIL=0

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $label"
    echo "        expected: '$expected'"
    echo "        actual:   '$actual'"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) echo "  PASS: $label"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL: $label"; echo "        '$needle' not found in: $haystack"; FAIL=$((FAIL+1)) ;;
  esac
}

# shellcheck source=../lib/ci-e2e-specs.sh
. "$CI_DIR/scripts/lib/ci-e2e-specs.sh"

echo "=== test-ci-e2e-specs.sh ==="

# ── T1: the allowlist names specs that actually exist ────────────────────────
for spec in $CI_E2E_MULTI_ENGINE_SPECS; do
  if [ -f "$CI_DIR/$spec" ]; then
    echo "  PASS: allowlisted spec exists: $spec"
    PASS=$((PASS+1))
  else
    echo "  FAIL: allowlisted spec missing: $spec"
    FAIL=$((FAIL+1))
  fi
done

# ── T2: run + skip partition the directory exactly ───────────────────────────
# The bug in #78 was a narrowed run with no record of what it dropped. If these
# do not reconcile, some spec is running nowhere and being reported nowhere.
all_count=$(ci_e2e_all_specs "$CI_DIR" | grep -c .)
run_count=$(ci_e2e_specs_for_mode multi-engine "$CI_DIR" | grep -c .)
skip_count=$(ci_e2e_single_engine_specs "$CI_DIR" | grep -c .)
assert_eq "$(( run_count + skip_count ))" "$all_count" \
  "multi-engine run + skip lists account for all $all_count specs"

# ── T3: the two lists are disjoint ───────────────────────────────────────────
overlap=$(comm -12 \
  <(ci_e2e_specs_for_mode multi-engine "$CI_DIR" | sort) \
  <(ci_e2e_single_engine_specs "$CI_DIR" | sort) | grep -c . || true)
assert_eq "$overlap" "0" "no spec is both run and skipped"

# ── T4: single-engine mode runs everything ───────────────────────────────────
single_count=$(ci_e2e_specs_for_mode single-engine "$CI_DIR" | grep -c .)
assert_eq "$single_count" "$all_count" "single-engine mode runs all $all_count specs"

# ── T5: the registry-aware spec is the one that runs multi-engine ────────────
assert_contains "$(ci_e2e_specs_for_mode multi-engine "$CI_DIR")" \
  "tree-to-pe-manager-equivalence.spec.ts" \
  "multi-engine runs the registry-aware equivalence spec"

# ── T6: specs with hardcoded Docker endpoints are not in the multi-engine set ─
# Direct check of the property the allowlist encodes, so a spec cannot be
# promoted while still pinning Docker-only URLs.
for spec in $(ci_e2e_specs_for_mode multi-engine "$CI_DIR"); do
  if grep -qE "https://localhost:(5001|3004)" "$CI_DIR/$spec" 2>/dev/null; then
    echo "  FAIL: $spec is allowlisted for multi-engine but hardcodes Docker endpoints"
    FAIL=$((FAIL+1))
  else
    echo "  PASS: $spec has no hardcoded Docker endpoints"
    PASS=$((PASS+1))
  fi
done

# ── T7: unknown mode is rejected ─────────────────────────────────────────────
ci_e2e_specs_for_mode bogus "$CI_DIR" >/dev/null 2>&1
assert_eq "$?" "2" "unknown mode exits 2"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
