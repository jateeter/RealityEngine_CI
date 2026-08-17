#!/usr/bin/env bash
# Unit tests for the fixture-status derivation in scripts/regression-arbiter.py.
#
# The stage used to hardcode `9a: asserted` and set `9b: asserted` whenever the
# replay loop had run, regardless of whether anything was measured. Run
# 20260817T035849Z reported both as asserted while one runtime emitted no
# arbitration records at all and no 9b contribution landed on any runtime
# (jateeter/RealityEngine_CI#135). These tests pin the rule that an empty result
# set can never be reported as asserted.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/regression-arbiter.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

echo "== fixture_status: observation, not attempt =="

run_py() { python3 - "$TOOL" "$@"; }

status_of() {
  run_py <<'PYEOF' "$1" "$2"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("arb", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(mod.fixture_status(int(sys.argv[2]), int(sys.argv[3])))
PYEOF
}

assert_eq "$(status_of 3 3)" "asserted" "every reachable runtime observed -> asserted"
assert_eq "$(status_of 2 3)" "partial"  "some runtimes observed -> partial"
assert_eq "$(status_of 0 3)" "not-run"  "no runtime observed -> not-run, never asserted"
assert_eq "$(status_of 0 0)" "not-run"  "no reachable runtimes -> not-run"
assert_eq "$(status_of 4 3)" "asserted" "more observations than expected still asserted"

echo
echo "== observed_counts: what counts as an observation =="

# The instance list arrives on stdin, so this helper cannot itself be a heredoc
# — the heredoc would be stdin and the JSON would never reach it.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/counts.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("arb", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(json.dumps(mod.observed_counts(json.load(sys.stdin)), sort_keys=True))
PYEOF

counts() { python3 "$TMP/counts.py" "$TOOL"; }

# The shape observed in run 20260817T035849Z: 9a on two of three runtimes, and
# 9b executed everywhere but landing no cells anywhere.
REAL_SHAPE='[
  {"instance":"cpp:cpp-1","reachable":true,"fixture9a":{},
   "fixture9b":[{"cells":{},"provider":"acp"}]},
  {"instance":"lsp:lsp-1","reachable":true,"fixture9a":{"16930":0,"16931":0},
   "fixture9b":[{"cells":{},"provider":"acp"}]},
  {"instance":"scala:scala-1","reachable":true,"fixture9a":{"16930":0,"16931":0},
   "fixture9b":[{"provider":"acp","status":"unavailable"}]}
]'
assert_eq "$(printf '%s' "$REAL_SHAPE" | counts)" \
  '{"9a": 2, "9b": 0, "reachable": 3}' \
  "the reported run: 9a seen twice, 9b never, three reachable"

# An unreachable instance is not part of the denominator: a runtime that never
# answered cannot make a fixture look partial.
UNREACHABLE='[
  {"instance":"cpp:cpp-1","reachable":false},
  {"instance":"lsp:lsp-1","reachable":true,"fixture9a":{"16930":0},
   "fixture9b":[{"cells":{"16936":1},"provider":"acp"}]}
]'
assert_eq "$(printf '%s' "$UNREACHABLE" | counts)" \
  '{"9a": 1, "9b": 1, "reachable": 1}' \
  "unreachable instances are excluded from the denominator"

# A populated cell is the observation. An empty dict is not.
POPULATED='[
  {"instance":"a","reachable":true,"fixture9a":{"16930":0},
   "fixture9b":[{"cells":{},"provider":"acp"},{"cells":{"16936":0},"provider":"acp"}]}
]'
assert_eq "$(printf '%s' "$POPULATED" | counts)" \
  '{"9a": 1, "9b": 1, "reachable": 1}' \
  "one populated case is enough for 9b to count as observed"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
