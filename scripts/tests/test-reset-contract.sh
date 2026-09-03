#!/usr/bin/env bash
# Unit tests for scripts/lib/reset_contract.py.
#
# `POST {pe}/api/reset` is layer-local: it resets the Perception Engine and does
# not clear the Reality Engine's CES activation, its ISRE/OSRE histories or its
# step counter (SURFACE_SPEC.md, "Reset is layer-local"). A defined starting
# point therefore costs two calls, and the obligation is the caller's.
#
# Getting that wrong is expensive in both directions and both have happened. A
# PE-only reset produced an apparent 6-event step-0 divergence across three
# runtimes that was entirely residue; the mirror case — resetting the RE and
# leaving PE run state — was live in two regression stages, and put the three
# runtimes into a comparison at globalStep 12, 12 and 17
# (jateeter/RealityEngine_CI#211).
#
# These pin the property that fixes it: one call resets both halves, every
# failure is reported rather than the first one short-circuiting the rest, and a
# missing url is a failure rather than a silent skip.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A recording poster stands in for the network: it records every url in call
# order and answers with whatever status the scenario names for that url.
cat > "$TMP/harness.py" <<'PYEOF'
import json, sys
sys.path.insert(0, sys.argv[1])
from reset_contract import reset_pair, reset_instances

mode = sys.argv[2]
calls = []

def poster(statuses):
    def post(url, body):
        calls.append(url)
        for fragment, status in statuses.items():
            if fragment in url:
                return status, {}
        return 200, {}
    return post

if mode == "pair-ok":
    f = reset_pair(poster({}), "http://re", "http://pe", "cpp-1")
    print(json.dumps({"failures": f, "calls": calls}))
elif mode == "pair-re-fails":
    f = reset_pair(poster({"engine/reset": 500}), "http://re", "http://pe", "cpp-1")
    print(json.dumps({"failures": f, "calls": calls}))
elif mode == "pair-both-fail":
    f = reset_pair(poster({"engine/reset": 500, "http://pe": 503}), "http://re", "http://pe", "cpp-1")
    print(json.dumps({"failures": f, "calls": calls}))
elif mode == "pair-no-pe":
    f = reset_pair(poster({}), "http://re", None, "cpp-1")
    print(json.dumps({"failures": f, "calls": calls}))
elif mode == "pair-no-re":
    f = reset_pair(poster({}), "", "http://pe", "cpp-1")
    print(json.dumps({"failures": f, "calls": calls}))
elif mode == "instances":
    insts = [{"id": "cpp-1", "re": "http://re1", "pe": "http://pe1"},
             {"id": "lsp-1", "re": "http://re2", "pe": "http://pe2"}]
    f = reset_instances(poster({}), insts)
    print(json.dumps({"failures": f, "calls": calls}))
elif mode == "instances-url-keys":
    insts = [{"id": "cpp-1", "re_url": "http://re1", "pe_url": "http://pe1"}]
    f = reset_instances(poster({}), insts, re_key="re_url", pe_key="pe_url")
    print(json.dumps({"failures": f, "calls": calls}))
PYEOF
run() { python3 "$TMP/harness.py" "$CI_DIR/scripts/lib" "$1"; }

echo "== reset_contract =="

# The property the whole contract rests on: one call, both halves.
assert_eq "$(run pair-ok | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d["calls"]))')" \
  '["http://re/api/engine/reset", "http://pe/api/reset"]' \
  "one call resets both halves — RE engine state and PE run state"

assert_eq "$(run pair-ok | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["failures"]))')" \
  "0" \
  "both halves accepted -> no failures"

# A failed RE reset must not skip the PE. Stopping early would leave the caller
# unable to tell "the RE refused" from "both refused", and would silently leave
# the PE half undone on top of it.
assert_eq "$(run pair-re-fails | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["calls"]))')" \
  '["http://re/api/engine/reset", "http://pe/api/reset"]' \
  "RE reset fails -> PE half still attempted"

assert_eq "$(run pair-re-fails | python3 -c 'import json,sys; print(json.load(sys.stdin)["failures"][0])')" \
  "cpp-1: POST /api/engine/reset returned 500" \
  "RE failure names the route and the status"

assert_eq "$(run pair-both-fail | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["failures"]))')" \
  "2" \
  "both halves refuse -> both reported, not just the first"

# A missing url is the failure this module exists to prevent: a stage that
# believes it reset and did not.
assert_eq "$(run pair-no-pe | python3 -c 'import json,sys; print(json.load(sys.stdin)["failures"][0])')" \
  "cpp-1: no pe_url — PE run state was not reset" \
  "absent PE url -> reported, never a silent skip"

assert_eq "$(run pair-no-re | python3 -c 'import json,sys; print(json.load(sys.stdin)["failures"][0])')" \
  "cpp-1: no re_url — RE state was not reset" \
  "empty RE url -> reported, never a silent skip"

assert_eq "$(run instances | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["calls"]))')" \
  '["http://re1/api/engine/reset", "http://pe1/api/reset", "http://re2/api/engine/reset", "http://pe2/api/reset"]' \
  "every instance gets both halves, in registry order"

# The stages disagree on key names — the registry writes re_url/pe_url, the
# parity modules carry re/pe — so both spellings have to work.
assert_eq "$(run instances-url-keys | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["calls"]))')" \
  '["http://re1/api/engine/reset", "http://pe1/api/reset"]' \
  "re_url/pe_url key spelling is supported"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
