#!/bin/bash
# =============================================================================
# verify-semantic-parity.sh
#
# Cross-engine OWL semantic-equivalence check (roadmap milestone M4).
#
# For every RE instance in the runtime registry, fetches
#   GET /api/machines/semantics/<machine>
# and compares semanticsIri/semanticsHash across engines and (when the
# corpus is present as a sibling) against the authoritative
# RealityEngine_Machines semantics/abox-manifest.json.
#
# Semantic equivalence is a distinct verification class from byte
# equivalence — engines may drift in serialized payloads while still
# agreeing on machine semantics, and vice versa. Keep the results separate.
#
# Usage:
#   ./scripts/verify-semantic-parity.sh [--machine "Fall Detection"] [--warn-only]
#
# Env:
#   RE_REGISTRY_URL   registry endpoint (default http://127.0.0.1:5999/re-registry.json)
#   MACHINES_DIR      corpus checkout (default sibling RealityEngine_Machines)
#
# Exit: 0 parity (or skipped with --warn-only), 1 mismatch/unreachable.
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
    --help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

fail() {
  if [ "$WARN_ONLY" = true ]; then
    echo "semantic-parity: WARN $1"
    exit 0
  fi
  echo "semantic-parity: FAIL $1" >&2
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
import urllib.parse
import urllib.request

machine_name, machines_dir = sys.argv[1], sys.argv[2]
registry = json.loads(os.environ["REGISTRY_JSON"])
instances = registry.get("instances", [])
if not instances:
    print("semantic-parity: no registry instances")
    raise SystemExit(1)

encoded = urllib.parse.quote(machine_name)
identities = {}
for inst in instances:
    re_url = inst.get("re_url")
    label = inst.get("id") or inst.get("engine") or re_url
    if not re_url:
        continue
    try:
        with urllib.request.urlopen(f"{re_url}/api/machines/semantics/{encoded}", timeout=5) as resp:
            doc = json.loads(resp.read())
        identities[label] = (doc.get("semanticsIri"), doc.get("semanticsHash"))
    except Exception as exc:  # noqa: BLE001 — engine down or endpoint missing
        identities[label] = ("<error>", str(exc))

print(f"semantic-parity: '{machine_name}' across {len(identities)} engine(s):")
for label, (iri, digest) in sorted(identities.items()):
    print(f"  {label}: {digest}")

values = set(identities.values())
if len(values) != 1 or "<error>" in next(iter(values))[0]:
    print("semantic-parity: MISMATCH across engines")
    raise SystemExit(1)

manifest_path = os.path.join(machines_dir, "semantics", "abox-manifest.json")
if os.path.exists(manifest_path):
    with open(manifest_path) as handle:
        manifest = json.load(handle)
    expected = next(
        ((e.get("iri"), e.get("sha256")) for e in manifest.get("machines", {}).values()
         if e.get("name") == machine_name),
        None,
    )
    if expected is None:
        print(f"semantic-parity: '{machine_name}' not in corpus manifest")
        raise SystemExit(1)
    if expected != next(iter(values)):
        print("semantic-parity: engines disagree with the corpus manifest")
        raise SystemExit(1)
    print("semantic-parity: OK (engines agree with each other and the corpus manifest)")
else:
    print("semantic-parity: OK (engines agree; corpus manifest not found for authority check)")
PYEOF
status=$?
set -e
if [ $status -ne 0 ]; then
  fail "semantic identity mismatch (see output above)"
fi
