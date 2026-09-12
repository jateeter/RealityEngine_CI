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
#
# MACHINES_REPO, not a corpus. This resolves repository-level artifacts —
# scripts/ and semantics/ — which a materialised corpus does not contain: it
# holds machines/ and a manifest, nothing else. Pointing this at a selected
# corpus breaks it outright.
#
# The distinction is documented in docs/MACHINES_DIR_SWEEP.md: MACHINES_DIR has
# meant the repo root, the machines/ directory, and localAIStack's own machines
# in different places, and four separate defects came out of it. MACHINES_DIR is
# still accepted here so existing callers and CI workflows keep working.
MACHINES_REPO="${MACHINES_REPO:-${MACHINES_DIR:-$(cd "$CI_DIR/.." && pwd)/RealityEngine_Machines}}"
MACHINES_DIR="$MACHINES_REPO"   # retained: existing references below
MACHINE_NAME="Fall Detection"
WARN_ONLY=false
# Runtimes outside the instance registry, as id=url. The TypeScript PE is the
# fourth implementation of this surface and is not registered as an engine
# instance, so it can only be reached by being named. Per the shaping recorded
# on RealityEngine_CI#327 it CONFORMS to the quorum rather than voting in it:
# quorum stays cpp + lsp + scala unanimous, and a conformer that disagrees is
# reported against that result.
EXTRA_RUNTIMES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --machine) MACHINE_NAME="$2"; shift 2 ;;
    --extra-runtime) EXTRA_RUNTIMES="$EXTRA_RUNTIMES $2"; shift 2 ;;
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
REGISTRY_JSON="$registry_json" CI_DIR="$CI_DIR" EXTRA_RUNTIMES="$EXTRA_RUNTIMES" python3 - "$MACHINE_NAME" "$MACHINES_DIR" <<'PYEOF'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.environ.get("CI_DIR", "."), "scripts", "lib"))
from re_tls import tls_context  # noqa: E402

_TLS = tls_context()

machine_name, machines_dir = sys.argv[1], sys.argv[2]
registry = json.loads(os.environ["REGISTRY_JSON"])
instances = registry.get("instances", [])
if not instances:
    print("semantic-parity: no registry instances")
    raise SystemExit(1)

encoded = urllib.parse.quote(machine_name)
identities = {}
conformers = {}
unmeasurable = {}
not_implemented = {}
for inst in instances:
    re_url = inst.get("re_url")
    label = inst.get("id") or inst.get("engine") or re_url
    if not re_url:
        continue
    try:
        with urllib.request.urlopen(
            f"{re_url}/api/machines/semantics/{encoded}", timeout=5, context=_TLS
        ) as resp:
            doc = json.loads(resp.read())
        identities[label] = (doc.get("semanticsIri"), doc.get("semanticsHash"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            # A declared absence, not a failure to reach. The engine answered:
            # it does not serve this surface. That is M4 of
            # SEMANTIC_OWL_ROADMAP.md pending on that runtime, and #327's
            # shaping is explicit that `missing` and a declared
            # non-participation must never collapse into one another.
            not_implemented[label] = f"HTTP 404 {re_url}/api/machines/semantics/"
        else:
            unmeasurable[label] = f"HTTP {exc.code}"
    except Exception as exc:  # noqa: BLE001 — engine down or transport failure
        # NOT an identity. An engine that did not answer has told us nothing
        # about its semantics, and recording the error in the same dict as a
        # real hash is what made "could not reach it" read as "they disagree".
        unmeasurable[label] = str(exc)

# Conformers: named runtimes outside the instance registry. Fetched the same
# way, kept in a separate dict so they cannot change the quorum verdict.
for spec in os.environ.get("EXTRA_RUNTIMES", "").split():
    if "=" not in spec:
        continue
    clabel, curl = spec.split("=", 1)
    try:
        with urllib.request.urlopen(
            f"{curl.rstrip('/')}/api/machines/semantics/{encoded}", timeout=5, context=_TLS
        ) as resp:
            cdoc = json.loads(resp.read())
        conformers[clabel] = (cdoc.get("semanticsIri"), cdoc.get("semanticsHash"))
    except Exception as exc:  # noqa: BLE001
        conformers[clabel] = ("<unmeasurable>", str(exc))

print(f"semantic-parity: '{machine_name}' — {len(identities)} engine(s) answered, "
      f"{len(unmeasurable)} unmeasurable")
for label, (iri, digest) in sorted(identities.items()):
    print(f"  {label}: {digest}")
for label, err in sorted(unmeasurable.items()):
    print(f"  {label}: UNMEASURABLE — {err}")

# A runtime that does not answer is not agreement, and it is not disagreement
# either (docs/QUORUM_CONTRACT.md). It is an absence of evidence, reported as
# its own verdict so nobody reads it as a semantic finding.
for label, why in sorted(not_implemented.items()):
    print(f"  {label}: NOT-IMPLEMENTED — {why}")

# The surface is M4 of RealityEngine_Machines/docs/SEMANTIC_OWL_ROADMAP.md.
# Until a runtime serves it there is nothing to compare, and saying so by name
# is more useful than a mismatch against engines that never claimed to have it.
if not_implemented and not identities:
    print("semantic-parity: NOT-IMPLEMENTED — "
          f"{', '.join(sorted(not_implemented))} do not serve "
          "/api/machines/semantics/:name. This is SEMANTIC_OWL_ROADMAP M4 "
          "pending, not a semantic divergence.")
    raise SystemExit(1)

if unmeasurable:
    print("semantic-parity: UNMEASURABLE — "
          f"{', '.join(sorted(unmeasurable))} did not answer; no parity verdict "
          "can be formed. This is a harness or availability finding, not a "
          "semantic one.")
    raise SystemExit(1)

# Comparison needs at least two participants. One engine is a declared
# non-participation state for a CROSS-engine check, not a pass and not a
# mismatch — the single-engine Docker lane reaches exactly this.
if len(identities) < 2:
    only = next(iter(identities), "none")
    print(f"semantic-parity: NOT-APPLICABLE — only {only} is registered; a "
          "cross-engine comparison needs at least two runtimes. Run the "
          "multi-engine lane (--engines=cpp:1,lsp:1,scala:1) to form a quorum.")
    raise SystemExit(0)

if len(set(identities.values())) != 1:
    print("semantic-parity: MISMATCH across engines")
    raise SystemExit(1)

def _check_conformers(agreed):
    """A conformer must match the settled result; it never forms it."""
    if not conformers:
        return
    bad = []
    for clabel, got in sorted(conformers.items()):
        if got[0] == "<unmeasurable>":
            print(f"semantic-parity: conformer {clabel}: UNMEASURABLE — {got[1]}")
            bad.append(clabel)
        elif got != agreed:
            print(f"semantic-parity: conformer {clabel}: DIVERGES — {got[1]}")
            bad.append(clabel)
        else:
            print(f"semantic-parity: conformer {clabel}: conforms ({got[1]})")
    if bad:
        print(f"semantic-parity: CONFORMANCE FAILURE — {', '.join(bad)} do not match "
              "the agreed identity. The quorum verdict above stands; this is a "
              "separate finding against the conformer.")
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
    if expected != next(iter(set(identities.values()))):
        print("semantic-parity: engines disagree with the corpus manifest")
        raise SystemExit(1)
    print("semantic-parity: OK (engines agree with each other and the corpus manifest)")
    _check_conformers(expected)
else:
    print("semantic-parity: OK (engines agree; corpus manifest not found for authority check)")
    _check_conformers(next(iter(set(identities.values()))))
PYEOF
status=$?
set -e
if [ $status -ne 0 ]; then
  fail "semantic parity not established — see the verdict above (MISMATCH, UNMEASURABLE or NOT-IMPLEMENTED are different findings)"
fi
