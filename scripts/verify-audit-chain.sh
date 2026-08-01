#!/bin/bash
# =============================================================================
# verify-audit-chain.sh
#
# PE->RE->PE semantic audit-chain e2e (roadmap milestone M5).
#
# Drives the Fall Detection confirmed-fall input sequence through every RE
# instance in the runtime registry and asserts the emitted
# re:SequenceObservation records join back to the corpus ABox IRIs with no
# name matching, per RealityEngine_Machines docs/SEMANTIC_AUDIT_CONTRACT.md:
#
#   1. a completed observation for fall-confirmed exists, ending at
#      #step-fall-conf-v6 / #out-fall-conf-out with actionCode
#      emergency-dispatch
#   2. every IRI on that record shares the machine's ABox base
#   3. no escalation action is dispatched from a determination that
#      contradicts re:EscalationDetermination (explicit non-RED status;
#      an unstated status is open-world consistent and only counted)
#
# Uses the dense `vector` input form — the one shape accepted by every
# engine (see RealityEngine_LSP#18 for the sparse/domain-vector gap).
#
# Usage:
#   ./scripts/verify-audit-chain.sh [--machine "Fall Detection"] [--warn-only]
#
# Env:
#   RE_REGISTRY_URL   registry endpoint (default http://127.0.0.1:5999/re-registry.json)
#   MACHINES_DIR      corpus checkout (default sibling RealityEngine_Machines)
#   FALL_INPUT_OFFSET input region offset (default 3813 — Fall Detection)
#   VECTOR_DIMENSION  dense vector length (default 7680)
#
# Exit: 0 chain verified (or skipped with --warn-only), 1 broken chain.
# =============================================================================
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY_URL="${RE_REGISTRY_URL:-http://127.0.0.1:5999/re-registry.json}"
MACHINES_DIR="${MACHINES_DIR:-$(cd "$CI_DIR/.." && pwd)/RealityEngine_Machines}"
MACHINE_NAME="Fall Detection"
WARN_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --machine) MACHINE_NAME="$2"; shift 2 ;;
    --warn-only) WARN_ONLY=true; shift ;;
    --help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

fail() {
  if [ "$WARN_ONLY" = true ]; then
    echo "audit-chain: WARN $1"
    exit 0
  fi
  echo "audit-chain: FAIL $1" >&2
  exit 1
}

registry_json="$(curl -sf --max-time 5 "$REGISTRY_URL" || true)"
if [ -z "$registry_json" ]; then
  fail "registry unreachable at $REGISTRY_URL"
fi

set +e
REGISTRY_JSON="$registry_json" python3 - "$MACHINE_NAME" "$MACHINES_DIR" <<'PYEOF'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

machine_name, machines_dir = sys.argv[1], sys.argv[2]
registry = json.loads(os.environ["REGISTRY_JSON"])
instances = [i for i in registry.get("instances", []) if i.get("re_url")]
if not instances:
    print("audit-chain: no registry instances")
    raise SystemExit(1)

offset = int(os.environ.get("FALL_INPUT_OFFSET", "3813"))
dimension = int(os.environ.get("VECTOR_DIMENSION", "7680"))
# Confirmed fall: motion onset -> sustained -> severe -> post-impact stillness
# onset -> sustained -> very-sustained.
TICKS = [(0, 0), (1, 0), (2, 0), (3, 0), (3, 1), (3, 2), (3, 3)]
ESCALATION_ACTIONS = {"emergency-dispatch", "urgent-intervention"}


def call(url, payload=None, timeout=120):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


expected = None
manifest_path = os.path.join(machines_dir, "semantics", "abox-manifest.json")
if os.path.exists(manifest_path):
    with open(manifest_path) as handle:
        manifest = json.load(handle)
    for entry in manifest.get("machines", {}).values():
        if entry.get("name") == machine_name:
            expected = str(entry.get("iri", "")).split("#")[0]
            break

failures = []
for inst in instances:
    label = inst.get("id") or inst.get("engine") or inst["re_url"]
    re_url = inst["re_url"].rstrip("/")
    try:
        for motion, stillness in TICKS:
            vector = [0.0] * dimension
            vector[offset] = float(motion)
            vector[offset + 1] = float(stillness)
            call(f"{re_url}/api/perceive", {
                "vector": vector,
                "matchAlgorithm": "equals",
                "includeMachineResults": False,
                "includePerceptualSpace": False,
            })
        audit = call(f"{re_url}/api/audit/semantics?limit=1000")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        failures.append(f"{label}: audit surface unreachable ({exc})")
        continue

    records = audit.get("records", [])
    mine = [r for r in records if r.get("machineName") == machine_name]
    completed = [r for r in mine
                 if r.get("completed") in (True, "true")
                 and r.get("sequenceId") == "fall-confirmed"]
    if not completed:
        failures.append(f"{label}: no completed fall-confirmed observation "
                        f"({len(mine)} records for '{machine_name}')")
        continue
    rec = completed[-1]

    # Invariant 1 — the chain terminates at the corpus's confirmed-fall step.
    if not str(rec.get("stepIri")).endswith("#step-fall-conf-v6"):
        failures.append(f"{label}: terminal stepIri is {rec.get('stepIri')}")
    if not str(rec.get("determinationIri")).endswith("#out-fall-conf-out"):
        failures.append(f"{label}: determinationIri is {rec.get('determinationIri')}")
    if rec.get("actionCode") != "emergency-dispatch":
        failures.append(f"{label}: actionCode is {rec.get('actionCode')}")

    # Invariant 2 — every IRI on the record shares the machine's ABox base.
    bases = {str(rec.get(key)).split("#")[0]
             for key in ("machineIri", "sequenceIri", "stepIri", "determinationIri")}
    if len(bases) != 1:
        failures.append(f"{label}: IRI bases disagree: {sorted(bases)}")
    elif expected and bases != {expected}:
        failures.append(f"{label}: IRI base {bases.pop()} != corpus manifest {expected}")

    # Invariant 3 — no escalation action is dispatched from a determination
    # that contradicts re:EscalationDetermination.  The axiom is open-world:
    # an unstated RAG status is not a contradiction (a reasoner infers RED),
    # so only an explicit non-RED value is a violation.  Unstated statuses are
    # reported as a data-quality count, not a failure.
    unstated = 0
    for r in records:
        if r.get("actionCode") not in ESCALATION_ACTIONS:
            continue
        rag = r.get("ragStatus")
        if rag is None or rag == "":
            unstated += 1
        elif rag != "RED":
            failures.append(f"{label}: {r.get('actionCode')} dispatched from "
                            f"ragStatus={rag} "
                            f"({r.get('machineName')}/{r.get('sequenceId')})")
            break

    steps = [r["stepId"] for r in mine if r.get("sequenceId") == "fall-confirmed"]
    note = f"; {unstated} escalation determination(s) with no stated RAG status" if unstated else ""
    print(f"audit-chain: {label}: {len(mine)} observation(s); "
          f"confirmed-fall path {' -> '.join(steps)}{note}")

if failures:
    for line in failures:
        print(f"audit-chain: {line}")
    raise SystemExit(1)
print(f"audit-chain: OK ({len(instances)} engine(s) produced a complete, "
      f"corpus-joined evidence chain)")
PYEOF
status=$?
set -e
if [ $status -ne 0 ]; then
  fail "audit chain incomplete (see output above)"
fi
