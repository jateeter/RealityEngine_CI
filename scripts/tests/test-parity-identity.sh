#!/usr/bin/env bash
# Unit tests for scripts/lib/parity_identity.py (RealityEngine_CI#146).
#
# Every probe point is an API: an observer must see the same thing whichever
# engine answered. The parity stage used to compare `machineId`, which the
# corpus does not declare and each runtime therefore mints for itself —
#   cpp    machine-1787062353690-303854695
#   lsp    machine-1U358SX-92K0WAA239X2
#   scala  machine-1787062353802-dad8e19e
# — so every event carrying a non-empty activeRegions split three ways
# unconditionally, and every event carrying none fell through to
# {"success": true} and passed trivially.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

run() { python3 - "$CI_DIR" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("pi", f"{sys.argv[1]}/scripts/lib/parity_identity.py")
pi = importlib.util.module_from_spec(spec); spec.loader.exec_module(pi)
out = []

# Depth (RealityEngine_CI#281). The filters were applied only to the payload's
# top level, but the augmentation they exist to exclude sits at
# `.step.mergeBatch[].valuesPacked` — one level below where they looked. Five
# parity failures per run, on a route where all three runtimes agreed.
#
# The bug was invisible by inspection: the key sets were right, the recursive
# walk was right, and only their composition was wrong. So the test drives the
# real shape rather than a flat record.
def _payload(packed):
    entry = {"cell": 4, "values": [0, 1]}
    if packed:
        entry["valuesPacked"] = {"base64": "QA==", "bitsPerElement": 1, "length": 2}
    return {"success": True, "step": {"mergeBatch": [entry]}}

three = {"cpp-1": _payload(False), "lsp-1": _payload(True), "scala-1": _payload(False)}
sigs = {n: json.dumps(pi.parity_signature(v, pi.shared_keys(three)), sort_keys=True)
        for n, v in three.items()}
out.append(("nested augmentation does not split the signature", len(set(sigs.values())) == 1))

# ...and the values it packs are still compared, so this is a filter and not a
# hole: flip one and the runtimes must disagree again.
diverged = {"cpp-1": _payload(False), "lsp-1": _payload(True), "scala-1": _payload(False)}
diverged["scala-1"]["step"]["mergeBatch"][0]["values"] = [1, 1]
dsigs = {n: json.dumps(pi.parity_signature(v, pi.shared_keys(diverged)), sort_keys=True)
         for n, v in diverged.items()}
out.append(("a real value difference still splits it", len(set(dsigs.values())) == 2))

# Reported, never compared — SURFACE_SPEC.md, "The observable boundary". The
# document already claimed this was reported; it was reported nowhere, because
# shape_only_keys was also top-level-only.
shape = pi.shape_only_keys(three)
out.append(("nested extra is reported at its path",
            shape.get("lsp-1") == [".step.mergeBatch[].valuesPacked"]))

# Permitted augmentation is not a contract violation, or fixing the report
# would just trade one false finding for another.
out.append(("permitted augmentation raises no violation",
            pi.uniformity_violations(three) == []))

# A genuinely asymmetric key still does.
asym = {"cpp-1": {"success": True, "step": {"a": 1, "extra": 2}},
        "lsp-1": {"success": True, "step": {"a": 1}}}
out.append(("an asymmetric nested key is still reported",
            pi.shape_only_keys(asym).get("cpp-1") == [".step.extra"]))


# Engine-minted identity is filtered; corpus-declared identity is kept.
rec = {"machineId": "machine-1U358SX-92K0", "machineName": "Thermal",
       "sequenceId": "agx-001-urgent", "vectorId": "agx-001-normal",
       "timestamp": 1787, "globalStep": 42, "offset": 52, "length": 8}
kept = pi.strip_engine_identity(rec)
out.append(("machineId filtered", "machineId" not in kept))
out.append(("machineName kept", kept.get("machineName") == "Thermal"))
out.append(("corpus sequenceId kept", kept.get("sequenceId") == "agx-001-urgent"))
out.append(("corpus vectorId kept", kept.get("vectorId") == "agx-001-normal"))
out.append(("timestamp filtered", "timestamp" not in kept))
out.append(("per-engine globalStep filtered", "globalStep" not in kept))

# Units of measure are never filtered — cells against bytes is a divergence,
# not a naming difference.
out.append(("offset kept (unit-bearing)", kept.get("offset") == 52))
out.append(("length kept (unit-bearing)", kept.get("length") == 8))

# Ordering is the schema's to define. Nothing here sorts: a runtime presenting
# the same information in a different order has broken the contract.
a = {"regions": [{"offset": 52}, {"offset": 190}]}
b = {"regions": [{"offset": 190}, {"offset": 52}]}
out.append(("ordering divergence is preserved, not normalized",
            pi.strip_engine_identity(a) != pi.strip_engine_identity(b)))

# Arbiter internals are excluded; their effect shows up in the vectors.
out.append(("mergeBatch excluded as intermediate",
            "mergeBatch" not in pi.parity_signature({"mergeBatch": [1], "perceptualSpace": [0]})))
out.append(("perceptualSpace retained",
            "perceptualSpace" in pi.parity_signature({"mergeBatch": [1], "perceptualSpace": [0]})))

# A key only some engines emit is a violation, not something to drop quietly.
payloads = {"cpp-1": {"step": 1, "dispatch": {}}, "lsp-1": {"step": 1}, "scala-1": {"step": 1}}
v = pi.uniformity_violations(payloads)
out.append(("asymmetric key reported as a violation", len(v) == 1 and "dispatch" in v[0]))
out.append(("violation names the engines it is absent from", "lsp-1" in v[0] and "scala-1" in v[0]))
out.append(("uniform payloads yield no violations",
            pi.uniformity_violations({"a": {"x": 1}, "b": {"x": 2}}) == []))

# Machine validation is a corpus question: domains and counts, never ids.
counts = pi.machine_domains(["core/a.json", "domains/energy/b.json", "domains/energy/c.json"])
out.append(("domain counts derived by path", counts == {"core": 1, "energy": 2}))

print(json.dumps(out))
PYEOF
}

echo "== parity_identity =="
RESULTS="$(run)"
COUNT=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$RESULTS")
for i in $(seq 0 $((COUNT-1))); do
  label=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])][0])" "$RESULTS" "$i")
  okv=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])][1])" "$RESULTS" "$i")
  assert_eq "$okv" "True" "$label"
done

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
