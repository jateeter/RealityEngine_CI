#!/usr/bin/env bash
# Unit tests for scripts/corpus-parity-checkpoint.py.
#
# The loop's `--resume` reuses a *running* universe. That is no help in the case
# that matters: jateeter/RealityEngine_CI#167 halted at iteration 862 after
# 6h27m, and reaching that state again meant replaying ~808 incremental API
# loads — roughly six and a half hours per attempt, which is why the issue says
# any serious attempt needs a checkpoint mechanism first.
#
# The investigation got there by reconstructing the resident manifest from the
# run log by hand and boot-loading it; that reproduction ran in minutes and
# exonerated the machine originally suspected. This tool automates that
# reconstruction, so these pin the two ways it could quietly lie: including a
# machine the run never loaded, or building a manifest from a mode where the
# corpus never existed all at once.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/corpus-parity-checkpoint.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}
assert_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected to contain: $2"; echo "        actual: $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A cumulative run: 8 iterations, one skipped (machine never loaded), one
# failure, and a truncated final line as a killed run leaves behind.
python3 - "$TMP/run.jsonl" <<'PYEOF'
import json, sys
out = []
for i in range(1, 9):
    status = "skipped" if i == 4 else ("fail" if i == 6 else "pass")
    out.append(json.dumps({
        "index": i, "machineFile": f"domains/d/M{i:03d}.json", "status": status,
        "mode": "cumulative",
        "trajectoryParity": {"ok": status != "fail",
                             "failures": ["isre diverges at step 2 cell 40"] if status == "fail" else []},
    }, sort_keys=True))
with open(sys.argv[1], "w") as fh:
    fh.write("\n".join(out) + "\n")
    fh.write('{"index": 9, "machineFi')   # interrupted mid-write
PYEOF

machines() { python3 "$TOOL" manifest --results "$TMP/run.jsonl" "$@" 2>/dev/null | grep -v '^#'; }

echo "== manifest reconstruction =="

# --before is exclusive: the failing iteration's own machine is not resident in
# the state it failed *from*, which is the state worth reproducing.
assert_eq "$(machines --before 6 | tr '\n' ' ')" \
  "domains/d/M001.json domains/d/M002.json domains/d/M003.json domains/d/M005.json " \
  "--before is exclusive and omits the failing iteration's machine"

# The trap this tool exists to avoid, one level down: a skipped iteration never
# loaded its machine, so including it manufactures a corpus the run never had.
assert_eq "$(machines --before 6 | grep -c 'M004')" \
  "0" \
  "a skipped iteration's machine is never resident"

assert_eq "$(machines | wc -l | tr -d ' ')" \
  "7" \
  "omitting --before reconstructs the corpus at end of run"

# Load order is the one thing a boot-load cannot reproduce; keeping it makes the
# manifest diffable against the run log.
assert_eq "$(machines --before 4 | head -1)" \
  "domains/d/M001.json" \
  "load order is preserved"

echo
echo "== guards =="

# A manifest from an isolated-mode run describes a corpus that never existed at
# once. Refused rather than silently wrong.
python3 - "$TMP/iso.jsonl" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w") as fh:
    for i in (1, 2, 3):
        fh.write(json.dumps({"index": i, "machineFile": f"m{i}.json",
                             "status": "pass", "mode": "isolated"}) + "\n")
PYEOF

ISO_ERR="$(python3 "$TOOL" manifest --results "$TMP/iso.jsonl" --before 3 2>&1 || true)"
assert_contains "$ISO_ERR" "isolated" \
  "an isolated-mode run is refused rather than reconstructed"

assert_eq "$(python3 "$TOOL" manifest --results "$TMP/iso.jsonl" --before 3 --force 2>/dev/null | grep -vc '^#')" \
  "2" \
  "--force overrides the isolated-mode refusal"

# A run killed mid-write is the normal shape of the file this is pointed at, so
# the partial line must not be treated as corruption.
assert_eq "$(machines --before 9 | wc -l | tr -d ' ')" \
  "7" \
  "a truncated final line is skipped, not fatal"

MISSING="$(python3 "$TOOL" summary --results "$TMP/nope.jsonl" 2>&1 || true)"
assert_contains "$MISSING" "no results file" \
  "a missing results file names the path"

echo
echo "== summary and command =="

SUMMARY="$(python3 "$TOOL" summary --results "$TMP/run.jsonl" 2>/dev/null)"
assert_contains "$SUMMARY" "first failure   iteration 6" \
  "summary names the first failing iteration"
assert_contains "$SUMMARY" "isre diverges at step 2 cell 40" \
  "summary surfaces the failure detail"

CMD="$(python3 "$TOOL" command --results "$TMP/run.jsonl" --before 6 --out repro.txt 2>/dev/null)"
assert_contains "$CMD" "--machine-corpus-manifest=repro.txt" \
  "command wires the manifest into startUniverse"
# Without this the reproduction picks up ten localai/* machines the original run
# never had and reproduces RealityEngine_Scala#54 instead — which is exactly how
# #167's first attempt was lost.
assert_contains "$CMD" "--no-local-ai" \
  "command excludes localAI, as #167's contaminated first attempt requires"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
