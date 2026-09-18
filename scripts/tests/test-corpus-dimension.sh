#!/usr/bin/env bash
# Unit tests for scripts/lib/corpus-dimension.sh.
#
# The sizing rule is the one thing standing between a launch and ~250 machines
# that cannot match and cannot say so. A wrong answer here is silent by
# construction (RealityEngine_CI#422), so every case below constructs a corpus
# whose requirement is known by hand and asserts the exact number.
#
# Usage: bash scripts/tests/test-corpus-dimension.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$CI_DIR/scripts/lib/corpus-dimension.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }

# eq <name> <expected> <actual>
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected $2, got $3"; fi
}

# machine <path> <in_off> <in_len> <out_off> <out_len>
machine() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<JSON
{"version":"1.0.0","machine":{"name":"$(basename "$1" .json)",
 "perceptualMapping":{"input":{"offset":$2,"length":$3},
                      "output":{"offset":$4,"length":$5}}}}
JSON
}

echo "lib/corpus-dimension.sh"

# ── the requirement is the furthest cell any machine declares ────────────────
C="$TMP/corpus"
machine "$C/a.json"          0    4   100   2
machine "$C/domains/b.json" 14364 20 14384 4
machine "$C/domains/c.json" 12    8    20   2
# The maximum is b's output: 14384 + 4. It is neither the first machine, the
# last, nor the one with the largest input — a rule that took any of those
# would pass a corpus laid out differently and fail this one.
eq "the furthest declared cell, across both regions and all subdirectories" \
   14388 "$(corpus_required_dimension "$C")"

# ── output can exceed input, and does in the real corpus ─────────────────────
C="$TMP/out-wins"; machine "$C/a.json" 0 4 9000 16
eq "an output region past every input still sets the requirement" \
   9016 "$(corpus_required_dimension "$C")"

# A corpus that fits inside the engine default, for the resolve cases below.
C="$TMP/fits"; machine "$C/a.json" 0 4 100 2

# ── a corpus that declares nothing is 0, not a default ───────────────────────
mkdir -p "$TMP/empty"
eq "an empty corpus requires 0" 0 "$(corpus_required_dimension "$TMP/empty")"
eq "an unreadable path requires 0" 0 "$(corpus_required_dimension "$TMP/nope")"

# ── malformed entries are skipped, never fatal, and never counted ────────────
C="$TMP/mixed"; machine "$C/good.json" 0 4 500 2
printf 'not json at all\n'                                  > "$C/broken.json"
printf '{"version":"1.0.0"}\n'                              > "$C/nomachine.json"
printf '{"machine":{"perceptualMapping":{"input":"x"}}}\n'   > "$C/badregion.json"
printf '{"machine":{"perceptualMapping":{"input":{"offset":"a","length":9}}}}\n' \
                                                             > "$C/badnumber.json"
eq "malformed machines are skipped, and the good one still counts" \
   502 "$(corpus_required_dimension "$C")"

# ── resolve: explicit always wins, and is never raised ───────────────────────
# The half that matters. An operator asking for a narrow space is entitled to
# one; silently widening it would hide the capacity question rather than answer
# it, and would make a deliberately narrow run impossible to perform.
#
# resolve_vector_dimension SETS its results rather than echoing them, so these
# call it directly. Calling it in a command substitution is the bug it was
# written with: the subshell takes the assignments with it, and the caller sees
# an unset CORPUS_REQUIRED_DIM.
C="$TMP/corpus"

VECTOR_DIMENSION=512 CORPUS_REQUIRED_DIM=""
resolve_vector_dimension "$C"
eq "an explicit VECTOR_DIMENSION below the requirement is left alone" \
   512 "$VECTOR_DIMENSION"
eq "and the requirement is still reported alongside it" \
   14388 "$CORPUS_REQUIRED_DIM"

VECTOR_DIMENSION=99999; resolve_vector_dimension "$C"
eq "an explicit VECTOR_DIMENSION above the requirement is left alone" \
   99999 "$VECTOR_DIMENSION"

# ── resolve: unset takes the engine default, raised to fit ───────────────────
unset VECTOR_DIMENSION; CORPUS_REQUIRED_DIM=""
resolve_vector_dimension "$C"
eq "unset, with a corpus that does not fit, takes the requirement" \
   14388 "$VECTOR_DIMENSION"
eq "CORPUS_REQUIRED_DIM is set alongside the resolved value" \
   14388 "$CORPUS_REQUIRED_DIM"

unset VECTOR_DIMENSION; resolve_vector_dimension "$TMP/fits"
eq "unset, with a corpus that fits, keeps the engine default" 7680 "$VECTOR_DIMENSION"
eq "and reports what that corpus actually asked for" 102 "$CORPUS_REQUIRED_DIM"

unset VECTOR_DIMENSION; resolve_vector_dimension "$TMP/empty"
eq "unset, with an empty corpus, keeps the engine default" 7680 "$VECTOR_DIMENSION"

unset VECTOR_DIMENSION; resolve_vector_dimension "$TMP/empty" 256
eq "the engine default is overridable" 256 "$VECTOR_DIMENSION"

# A caller that only knows the resolved value cannot say whether it was raised,
# and "running at 16944" is a different statement from "running at 16944
# because the corpus asked for it".
unset VECTOR_DIMENSION; CORPUS_REQUIRED_DIM=""
resolve_vector_dimension "$TMP/nope"
eq "an unreadable corpus reports 0, not a number that looks like a fact" \
   0 "$CORPUS_REQUIRED_DIM"
eq "and still launches at the engine default" 7680 "$VECTOR_DIMENSION"

# ── the real corpus ──────────────────────────────────────────────────────────
# Not an assertion on the number — the corpus grows — but the requirement must
# exceed the engine default, or this whole mechanism is measuring nothing and
# the tests above are exercising fixtures only.
REAL="${MACHINES_DIR:-$CI_DIR/../RealityEngine_Machines}/machines"
if [ -d "$REAL" ]; then
  real_dim="$(corpus_required_dimension "$REAL")"
  if [ "$real_dim" -gt 7680 ]; then
    ok "the live corpus requires $real_dim, above the 7680 engine default"
  else
    bad "the live corpus requires $real_dim — at or below the engine default, so nothing here is being exercised against reality"
  fi
else
  echo "  – skipped: no corpus at $REAL"
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "lib/corpus-dimension.sh: $PASS passed, $FAIL FAILED"
  exit 1
fi
echo "lib/corpus-dimension.sh: $PASS passed"
