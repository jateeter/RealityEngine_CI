#!/usr/bin/env bash
# Assert the surface specification exists once and is not forked into copies.
#
# It used to exist as a canonical copy in RealityEngine_CPP plus byte-identical
# duplicates in LSP, Scala and Manager, and this script diffed the four. Four
# copies of one contract is a contract that drifts: on 2026-08-27 two correct
# changes landed in parallel documenting the same POST /api/reset post-state in
# different words, the diff failed, and main went red on a disagreement that
# was purely editorial.
#
# The master now lives in RealityEngine_CI and each runtime repository holds a
# pointer to it. This script checks that the pointers are still pointers.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$CI_DIR/.." && pwd)"

# Every governance contract that more than one repository implements lives in
# RealityEngine_CI and is pointed at from wherever it used to live. Adding a
# contract here is what keeps it from quietly re-forking.
#
#   master|pointer|pointer|...
CONTRACTS=(
  "SURFACE_SPEC.md|$ROOT_DIR/RealityEngine_CPP/SURFACE_SPEC.md|$ROOT_DIR/RealityEngine_LSP/SURFACE_SPEC.md|$ROOT_DIR/RealityEngine_Scala/SURFACE_SPEC.md|$ROOT_DIR/RealityEngine_Manager/SURFACE_SPEC.md"
  "docs/ARBITER_CONTRACT.md|$ROOT_DIR/RealityEngine_Machines/docs/ARBITER_CONTRACT.md"
  "docs/PE_METRICS_CONTRACT.md|$ROOT_DIR/RealityEngine_Machines/docs/PE_METRICS_CONTRACT.md"
  "docs/SEMANTIC_AUDIT_CONTRACT.md|$ROOT_DIR/RealityEngine_Machines/docs/SEMANTIC_AUDIT_CONTRACT.md"
  "docs/SEMANTIC_GUARDRAIL_CONTRACT.md|$ROOT_DIR/RealityEngine_Machines/docs/SEMANTIC_GUARDRAIL_CONTRACT.md"
)

# A pointer is short and says where the master is. A fork is neither. The size
# bound is the cheap half of the test and catches the failure that actually
# happens — somebody restores the full document into a runtime repo — while the
# marker check catches a file that is short but says nothing useful.
POINTER_MAX_BYTES=4096
MARKER='RealityEngine_CI/SURFACE_SPEC.md'

fail=0
checked=0

for entry in "${CONTRACTS[@]}"; do
  IFS='|' read -r rel_master rest <<<"$entry"
  master="$CI_DIR/$rel_master"
  name="$(basename "$rel_master")"

  if [ ! -f "$master" ]; then
    echo "FAIL missing master: $master" >&2
    echo "  $name lives in RealityEngine_CI and nowhere else" >&2
    fail=1
    continue
  fi

  IFS='|' read -ra pointers <<<"$rest"
  for pointer in "${pointers[@]}"; do
    [ -n "$pointer" ] || continue
    repo="$(basename "$(dirname "$(dirname "$pointer")")")"
    case "$pointer" in */docs/*) : ;; *) repo="$(basename "$(dirname "$pointer")")" ;; esac
    checked=$((checked + 1))

    if [ ! -f "$pointer" ]; then
      echo "FAIL $repo/$name: missing pointer" >&2
      echo "  every repo that used to hold it carries a pointer so a reader lands somewhere" >&2
      fail=1
      continue
    fi

    bytes="$(wc -c < "$pointer" | tr -d ' ')"
    if [ "$bytes" -gt "$POINTER_MAX_BYTES" ]; then
      echo "FAIL $repo/$name: ${bytes} bytes, over the ${POINTER_MAX_BYTES}-byte pointer limit" >&2
      echo "  this looks like a copy of the contract, not a pointer to it." >&2
      echo "  edit $master instead, and restore the pointer here." >&2
      fail=1
      continue
    fi

    if ! grep -qF "RealityEngine_CI/$rel_master" "$pointer"; then
      echo "FAIL $repo/$name: does not name the master" >&2
      echo "  expected it to contain: RealityEngine_CI/$rel_master" >&2
      fail=1
      continue
    fi

    echo "OK   $repo/$name: points at the master"
  done
done

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "Governance contracts have one home: RealityEngine_CI" >&2
  exit 1
fi

echo "governance: ${#CONTRACTS[@]} master(s) in RealityEngine_CI, ${checked} pointer(s) intact"
