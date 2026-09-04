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
  # Pointed at from all four runtimes it binds, not only from the corpus repo it
  # used to live in. Its header names them — "Applies to: RealityEngine_CPP,
  # RealityEngine_LSP, RealityEngine_Scala, RealityEngine_Manager (TypeScript
  # PE)" — and §8 makes byte equivalence across them the acceptance test, so a
  # runtime with no local sign of the contract is a runtime whose next arbiter
  # question gets answered in a file of its own.
  "docs/ARBITER_CONTRACT.md|$ROOT_DIR/RealityEngine_Machines/docs/ARBITER_CONTRACT.md|$ROOT_DIR/RealityEngine_CPP/docs/ARBITER_CONTRACT.md|$ROOT_DIR/RealityEngine_LSP/docs/ARBITER_CONTRACT.md|$ROOT_DIR/RealityEngine_Scala/docs/ARBITER_CONTRACT.md|$ROOT_DIR/RealityEngine_Manager/docs/ARBITER_CONTRACT.md"
  "docs/PE_METRICS_CONTRACT.md|$ROOT_DIR/RealityEngine_Machines/docs/PE_METRICS_CONTRACT.md"
  "docs/SEMANTIC_AUDIT_CONTRACT.md|$ROOT_DIR/RealityEngine_Machines/docs/SEMANTIC_AUDIT_CONTRACT.md"
  "docs/SEMANTIC_GUARDRAIL_CONTRACT.md|$ROOT_DIR/RealityEngine_Machines/docs/SEMANTIC_GUARDRAIL_CONTRACT.md"
  # Three separate things in this system are called "arbitration" —
  # outputMergeTransformation, arbiterRule, and the cell arbitration registry —
  # and this is the document that tells them apart, so it has to say the same
  # thing to every runtime. It was a master with no pointers, which is the
  # failure one step before drift: nothing in an engine repository named it, and
  # the natural repair for "I need to describe the arbiter here" is a local
  # description that becomes a second master. (A duplicate exists in a
  # deprecated prototype outside the focus set.)
  "ARBITER_ARCHITECTURE.md|$ROOT_DIR/RealityEngine_CPP/ARBITER_ARCHITECTURE.md|$ROOT_DIR/RealityEngine_LSP/ARBITER_ARCHITECTURE.md|$ROOT_DIR/RealityEngine_Scala/ARBITER_ARCHITECTURE.md"
  "MACHINE_CONCEPT.md|$ROOT_DIR/RealityEngine_CPP/MACHINE_CONCEPT.md|$ROOT_DIR/RealityEngine_LSP/MACHINE_CONCEPT.md|$ROOT_DIR/RealityEngine_Scala/MACHINE_CONCEPT.md"
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

  # A master may legitimately have no pointers — nothing outside RealityEngine_CI
  # describes it. Declaring the array is not enough: bash 3.2, which is what
  # /bin/bash is on macOS, treats "${arr[@]}" as unbound under `set -u` even for
  # a declared-empty array. The ${arr[@]+...} guard is the portable form.
  pointers=()
  [ -n "$rest" ] && IFS='|' read -ra pointers <<<"$rest"
  for pointer in ${pointers[@]+"${pointers[@]}"}; do
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
