#!/usr/bin/env bash
# corpus-dimension.sh — how wide a corpus asks the perceptual space to be.
#
# **This computes a seed, not a limit.** Every engine is required to grow the
# Reality Event length during machine loading to fit each machine's declared
# mapping, and all three do — C++ in `PerceptualSpaceRuntime::add_machine`, LSP
# in `ensure-space-length`, Scala in its space runtime. A universe seeded at
# 7680 against a corpus mapping to 16944 ends up with a space of 16944 and every
# machine resident and live.
#
# An earlier revision of this file said the opposite: that a space narrower than
# a machine's region left that machine unable to match, so booting at 7680 made
# ~250 machines inert. That was wrong, and wrong in a way worth keeping on the
# record, because the evidence for it was a **misreport**. `GET /api/config`
# returned the launch seed rather than the grown space on C++ and Scala, and the
# grown space on LSP, so a default launch read `cpp=7680, scala=7680,
# lsp=16944`. That 2-1 split was investigated as an engine disagreement about a
# machine mapped at [14364:14384] — resident and live throughout — and then very
# nearly answered by this file (RealityEngine_CI#422).
#
# So what is this still for? Seeding the space at the width it will reach anyway
# avoids a pile of reallocations during a 1328-machine load, and gives the
# harness a number to state up front. Both are conveniences. Neither is a
# correctness requirement, and nothing here should ever be described as
# preventing a machine from working — if a machine mapped beyond the seed does
# not work, the defect is that an engine failed to grow, and this file is not
# the place it gets fixed.
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
