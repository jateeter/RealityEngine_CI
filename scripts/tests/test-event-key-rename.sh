#!/usr/bin/env bash
# Unit tests for canonical_event_keys in scripts/lib/parity_identity.py.
#
# The Reality Event rename, response-key layer (jateeter/RealityEngine_CI#220
# layer 2). These keys sit on byte-equivalence surfaces, so a runtime that
# renames while its peers have not is reported as divergence by the parity gate.
#
# Without normalisation the rename would have to land in four repositories at
# once — C++, LSP, Scala and the TypeScript PE — with the Manager UI, the CI
# stages and the MCP tools following in the same window, or every parity run
# between the first merge and the last is red for a reason that is not a defect.
#
# These pin the property that removes that constraint: a migrated runtime and an
# unmigrated one compare equal, while a real divergence still fails.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/rename.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("pi", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

MIGRATED   = {"success": True, "inputEvent": [1, 0], "activeEvents": 3, "eventDimension": 7680}
UNMIGRATED = {"success": True, "inputVector": [1, 0], "activeVectors": 3, "vectorDimension": 7680}

what = sys.argv[2]
if what == "map":
    print(json.dumps(m.EVENT_KEY_RENAME, sort_keys=True))
elif what == "canonical":
    print(json.dumps(m.canonical_event_keys(json.load(sys.stdin)), sort_keys=True))
elif what == "mixed-fleet-violations":
    payloads = {"lsp-1": MIGRATED, "cpp-1": UNMIGRATED, "scala-1": dict(UNMIGRATED)}
    print(json.dumps(m.uniformity_violations(payloads)))
elif what == "mixed-fleet-agree":
    payloads = {"lsp-1": MIGRATED, "cpp-1": UNMIGRATED, "scala-1": dict(UNMIGRATED)}
    keys = m.shared_keys(payloads)
    sigs = {json.dumps(m.parity_signature(p, keys), sort_keys=True) for p in payloads.values()}
    print("agree" if len(sigs) == 1 else f"SPLIT into {len(sigs)}")
elif what == "mixed-fleet-shared":
    payloads = {"lsp-1": MIGRATED, "cpp-1": UNMIGRATED, "scala-1": dict(UNMIGRATED)}
    print(json.dumps(sorted(m.shared_keys(payloads))))
elif what == "real-divergence":
    bad = dict(UNMIGRATED); bad["activeVectors"] = 99
    payloads = {"lsp-1": MIGRATED, "cpp-1": bad, "scala-1": dict(UNMIGRATED)}
    keys = m.shared_keys(payloads)
    sigs = {json.dumps(m.parity_signature(p, keys), sort_keys=True) for p in payloads.values()}
    print("detected" if len(sigs) > 1 else "MISSED")
PYEOF
rename() { python3 "$TMP/rename.py" "$CI_DIR/scripts/lib/parity_identity.py" "$1"; }

echo "== canonical_event_keys =="

assert_eq "$(rename map)" \
  '{"activatedVectors": "activatedEvents", "activeVectors": "activeEvents", "initialVectorIds": "initialEventIds", "inputVector": "inputEvent", "matchedVectors": "matchedEvents", "totalVectors": "totalEvents", "vectorDimension": "eventDimension"}' \
  "the map covers exactly #220's seven response-body keys"

assert_eq "$(printf '%s' '{"inputVector":[1,0],"success":true}' | rename canonical)" \
  '{"inputEvent": [1, 0], "success": true}' \
  "an old spelling is rewritten; unrelated keys are untouched"

# Nested and inside lists: these keys appear on machine results and merge
# entries, not only at the top level.
assert_eq "$(printf '%s' '{"a":[{"vectorDimension":1},{"totalVectors":2}]}' | rename canonical)" \
  '{"a": [{"eventDimension": 1}, {"totalEvents": 2}]}' \
  "renaming reaches into nested objects and lists"

# A runtime emitting both during its own transition. The new value is what
# migrated consumers will read, so it must win — in either key order.
assert_eq "$(printf '%s' '{"inputVector":"OLD","inputEvent":"NEW"}' | rename canonical)" \
  '{"inputEvent": "NEW"}' \
  "both spellings present -> the new one wins (old first)"

assert_eq "$(printf '%s' '{"inputEvent":"NEW","inputVector":"OLD"}' | rename canonical)" \
  '{"inputEvent": "NEW"}' \
  "both spellings present -> the new one wins (new first)"

echo
echo "== a mixed fleet mid-migration =="

# The whole point: one runtime renamed, two not, and the gate keeps measuring
# behaviour rather than reporting the migration.
assert_eq "$(rename mixed-fleet-violations)" \
  '[]' \
  "a part-migrated fleet raises no uniformity violation"

assert_eq "$(rename mixed-fleet-shared)" \
  '["activeEvents", "eventDimension", "inputEvent", "success"]' \
  "shared keys are reported in the canonical spelling"

assert_eq "$(rename mixed-fleet-agree)" \
  "agree" \
  "migrated and unmigrated runtimes compare equal"

# Normalisation must not become a blindfold.
assert_eq "$(rename real-divergence)" \
  "detected" \
  "a real value divergence is still caught through the normalisation"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
