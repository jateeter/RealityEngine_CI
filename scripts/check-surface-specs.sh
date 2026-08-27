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

master="$CI_DIR/SURFACE_SPEC.md"
pointers=(
  "$ROOT_DIR/RealityEngine_CPP/SURFACE_SPEC.md"
  "$ROOT_DIR/RealityEngine_LSP/SURFACE_SPEC.md"
  "$ROOT_DIR/RealityEngine_Scala/SURFACE_SPEC.md"
  "$ROOT_DIR/RealityEngine_Manager/SURFACE_SPEC.md"
)

# A pointer is short and says where the master is. A fork is neither. The size
# bound is the cheap half of the test and catches the failure that actually
# happens — somebody restores the full document into a runtime repo — while the
# marker check catches a file that is short but says nothing useful.
POINTER_MAX_BYTES=4096
MARKER='RealityEngine_CI/SURFACE_SPEC.md'

fail=0

if [ ! -f "$master" ]; then
  echo "missing master surface spec: $master" >&2
  echo "  the specification lives in RealityEngine_CI and nowhere else" >&2
  exit 1
fi

for pointer in "${pointers[@]}"; do
  repo="$(basename "$(dirname "$pointer")")"

  if [ ! -f "$pointer" ]; then
    echo "FAIL $repo: missing SURFACE_SPEC.md pointer" >&2
    echo "  every runtime repo carries a pointer so a reader lands somewhere" >&2
    fail=1
    continue
  fi

  bytes="$(wc -c < "$pointer" | tr -d ' ')"
  if [ "$bytes" -gt "$POINTER_MAX_BYTES" ]; then
    echo "FAIL $repo: SURFACE_SPEC.md is ${bytes} bytes, over the ${POINTER_MAX_BYTES}-byte pointer limit" >&2
    echo "  this looks like a copy of the specification, not a pointer to it." >&2
    echo "  edit $master instead, and restore the pointer here." >&2
    fail=1
    continue
  fi

  if ! grep -qF "$MARKER" "$pointer"; then
    echo "FAIL $repo: SURFACE_SPEC.md does not name the master" >&2
    echo "  expected it to contain: $MARKER" >&2
    fail=1
    continue
  fi

  echo "OK   $repo: points at the master"
done

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "The surface specification has one home: RealityEngine_CI/SURFACE_SPEC.md" >&2
  exit 1
fi

echo "SURFACE_SPEC: one master at $master, ${#pointers[@]} pointers intact"
