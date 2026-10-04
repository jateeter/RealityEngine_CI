#!/usr/bin/env bash
# validate-machines-complete.sh — run RealityEngine_Machines' corpus validation
# with every check it contains actually executed.
#
#   scripts/validate-machines-complete.sh <path-to-RealityEngine_Machines>
#
# validate-corpus.sh degrades gracefully: when a tool or input is missing it
# prints "<check>: SKIPPED (...)" and exits 0, so a laptop run still does
# something useful. In the regression harness that is the wrong default. The
# hosted nightly reported validate-machines passed while skipping four of its
# checks (JSON schemas, guardrails, QUDT units, OWL reasoning), and the
# cold-start lane skipped the QUDT check because its input, .qudt-cache, is
# gitignored and so absent from every fresh worktree (#517 follow-ups).
#
# This wrapper supplies what the checks need and then refuses any skip, the
# same rule .github/workflows/full-corpus-cycle.yml applies to its sweep:
#
#   - ajv: npm ci in the checkout.
#   - QUDT vocabulary: a host cache keyed by the pinned QUDT_VERSION, fetched
#     on a miss and refused if the fetch lands nothing. The key carries the
#     version because bumping it is a contract change; a fixed key would serve
#     the old vocabulary to a corpus validated against the new one. It is
#     copied in, not linked: Machines ignores ".qudt-cache/", which matches a
#     directory but not a symlink. An existing .qudt-cache in the checkout is
#     used as is, never replaced.
#   - rdflib / pyshacl / ROBOT: provided by the caller (PYSHACL_PYTHON,
#     QUDT_PYTHON, ROBOT_BIN or PATH). A missing one surfaces as a SKIPPED line
#     and fails the stage, naming the check.
#
# Env: RE_QUDT_CACHE_DIR overrides the cache root
#      (default ${XDG_CACHE_HOME:-$HOME/.cache}/reality-engine/qudt).
set -euo pipefail

machines="${1:?usage: validate-machines-complete.sh <RealityEngine_Machines dir>}"
cd "$machines"

npm ci --no-audit --no-fund

version="$(sed -n 's/^QUDT_VERSION = "\([^"]*\)".*/\1/p' scripts/extract-qudt-subset.py)"
if [ -z "$version" ]; then
  echo "validate-machines: could not read QUDT_VERSION from scripts/extract-qudt-subset.py" >&2
  exit 1
fi

if [ -e .qudt-cache ]; then
  echo "validate-machines: using the checkout's own .qudt-cache"
else
  cache="${RE_QUDT_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/reality-engine/qudt}/$version"
  if [ -z "$(ls -A "$cache" 2>/dev/null)" ]; then
    echo "validate-machines: fetching QUDT $version into $cache"
    # --download reports a failed fetch as SKIPPED and exits 0; the emptiness
    # check below is what makes a failed fetch fatal.
    bash scripts/extract-qudt-subset.sh --source "$cache" --download
  fi
  if [ -z "$(ls -A "$cache" 2>/dev/null)" ]; then
    echo "validate-machines: QUDT fetch produced nothing in $cache; the unit-vocabulary check would skip (is rdflib available to QUDT_PYTHON / PYSHACL_PYTHON / python3?)" >&2
    exit 1
  fi
  cp -R "$cache" .qudt-cache
  echo "validate-machines: .qudt-cache copied from $cache"
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
bash scripts/validate-corpus.sh 2>&1 | tee "$log"

if grep -q "SKIPPED" "$log"; then
  echo "validate-machines: corpus validation skipped checks; it did not cover what it reports:" >&2
  grep "SKIPPED" "$log" >&2
  exit 1
fi
echo "validate-machines: no checks skipped."
