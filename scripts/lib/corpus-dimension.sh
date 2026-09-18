#!/usr/bin/env bash
# corpus-dimension.sh — how wide the perceptual space must be for a corpus.
#
# A machine's regions are absolute offsets into the space. A space narrower than
# a machine's declared region does not make that machine fail: its input region
# simply is not there, so it can never match, and the runtime reports that
# identically to a machine that matched nothing. No error, no warning, no count
# that differs from a universe where the machine is present and quiet.
#
# That is the whole reason this is computed rather than defaulted. All three
# engines default to 7680; the corpus maps up to 16944, and ~250 machines sit
# above the default. Booting at 7680 makes every one of them inert and makes the
# resulting mess read as an engine disagreement — which is exactly how it was
# read, on `Digital Logic DLX-021-030 Interconnect` (RealityEngine_CI#422).
#
# It lives here because `test-corpus-parity-loop.sh` already did this correctly
# and `startUniverse.sh` — the canonical entrypoint — did not. Two copies of a
# sizing rule drift, and the drift is invisible for the same reason the defect
# was: an undersized space is silent.
#
#   source scripts/lib/corpus-dimension.sh
#   corpus_required_dimension /path/to/machines    # prints the requirement
#   resolve_vector_dimension  /path/to/machines    # SETS VECTOR_DIMENSION and
#                                                  # CORPUS_REQUIRED_DIM

# The furthest cell any machine in the corpus declares, across both regions.
# Prints 0 for a corpus it cannot read — the caller decides what to do with
# that, rather than this silently returning a number that looks like a fact.
corpus_required_dimension() {
  python3 - "$1" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
required = 0
for path in root.rglob('*.json'):
    try:
        machine = json.loads(path.read_text(encoding='utf-8')).get('machine') or {}
    except (OSError, ValueError, AttributeError):
        continue
    mapping = machine.get('perceptualMapping') or {}
    for key in ('input', 'output'):
        region = mapping.get(key)
        if isinstance(region, dict):
            try:
                required = max(required, int(region['offset']) + int(region['length']))
            except (KeyError, TypeError, ValueError):
                pass
print(required)
PY
}

# Resolve the dimension to launch at. **Sets** two variables rather than
# echoing one:
#
#   VECTOR_DIMENSION      the width to launch at
#   CORPUS_REQUIRED_DIM   what the corpus asked for
#
# Setting rather than echoing is deliberate, and was a bug first: the function
# echoed the width and set the requirement as a side effect, so every caller
# wrote `VECTOR_DIMENSION="$(resolve_vector_dimension …)"` — a command
# substitution, a subshell, and the side effect died with it. startUniverse.sh
# then read an unset CORPUS_REQUIRED_DIM and took its "could not read the
# corpus" branch on every launch. A function whose contract needs two values
# should not pretend to return one.
#
# An explicit VECTOR_DIMENSION always wins and is never raised — an operator
# asking for a narrow space is entitled to one, and silently widening it would
# hide the capacity question rather than answer it. Otherwise the engine
# default, raised to fit the corpus.
#
# The caller reports the two numbers separately, because "running at 16944" is
# a different statement from "running at 16944 because the corpus asked for it".
resolve_vector_dimension() {
  local machines_dir="$1" engine_default="${2:-7680}"
  CORPUS_REQUIRED_DIM="$(corpus_required_dimension "$machines_dir")"
  [ -n "${CORPUS_REQUIRED_DIM:-}" ] || CORPUS_REQUIRED_DIM=0
  if [ -n "${VECTOR_DIMENSION:-}" ]; then
    return 0
  fi
  if [ "$CORPUS_REQUIRED_DIM" -gt "$engine_default" ] 2>/dev/null; then
    VECTOR_DIMENSION="$CORPUS_REQUIRED_DIM"
  else
    VECTOR_DIMENSION="$engine_default"
  fi
}
