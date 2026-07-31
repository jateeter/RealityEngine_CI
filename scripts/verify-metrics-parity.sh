#!/bin/bash
# =============================================================================
# verify-metrics-parity.sh
#
# Byte-equivalence check for the Perception Engine metrics exposition
# (RealityEngine_Machines docs/PE_METRICS_CONTRACT.md).
#
# Every PE in the runtime registry must serve GET /api/metrics, and the
# semantic_* block must be byte-identical across runtimes once the runtime
# label is normalized. Sample values are dropped before comparison because
# engines legitimately differ in state (source counts, step counters); what
# must match is the structure: metric names, HELP/TYPE wording, label sets,
# label ordering, and series ordering.
#
# Usage:
#   ./scripts/verify-metrics-parity.sh [--with-values] [--warn-only]
#
#   --with-values  also require sample values to match (only meaningful when
#                  engines are known to be in identical state, e.g. freshly
#                  started with no pushes)
#
# Env:
#   RE_REGISTRY_URL   registry endpoint (default http://127.0.0.1:5999/re-registry.json)
#
# Exit: 0 parity (or skipped with --warn-only), 1 drift.
# =============================================================================
set -euo pipefail

REGISTRY_URL="${RE_REGISTRY_URL:-http://127.0.0.1:5999/re-registry.json}"
WARN_ONLY=false
WITH_VALUES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --warn-only) WARN_ONLY=true; shift ;;
    --with-values) WITH_VALUES=true; shift ;;
    --help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

fail() {
  if [ "$WARN_ONLY" = true ]; then
    echo "metrics-parity: WARN $1"
    exit 0
  fi
  echo "metrics-parity: FAIL $1" >&2
  exit 1
}

registry_json="$(curl -sf --max-time 5 "$REGISTRY_URL" || true)"
if [ -z "$registry_json" ]; then
  fail "registry unreachable at $REGISTRY_URL"
fi

set +e
REGISTRY_JSON="$registry_json" WITH_VALUES="$WITH_VALUES" python3 <<'PYEOF'
import difflib
import json
import os
import re
import urllib.error
import urllib.request

RUNTIME = re.compile(r'runtime="[^"]*"')
SEMANTIC_REQUIRED = [
    "semantic_manifest_available",
    "semantic_manifest_machines",
    "semantic_audit_buffer_records",
    "semantic_dispatch_records_total",
    "semantic_dispatch_records_iri_joined_total",
]

registry = json.loads(os.environ["REGISTRY_JSON"])
with_values = os.environ.get("WITH_VALUES") == "true"
instances = [i for i in registry.get("instances", []) if i.get("pe_url")]
if not instances:
    print("metrics-parity: no PE instances in the registry")
    raise SystemExit(1)


def normalize(text):
    out = []
    for line in text.splitlines():
        line = RUNTIME.sub('runtime="RT"', line)
        if not with_values and not line.startswith("#"):
            line = line.rsplit(" ", 1)[0]
        out.append(line)
    return out


blocks, failures = {}, []
for inst in instances:
    label = inst.get("id") or inst.get("runtime") or inst["pe_url"]
    url = inst["pe_url"].rstrip("/") + "/api/metrics"
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            body = resp.read().decode()
    except (urllib.error.URLError, OSError) as exc:
        failures.append(f"{label}: /api/metrics unreachable ({exc})")
        continue
    missing = [m for m in SEMANTIC_REQUIRED if f"# TYPE {m} " not in body]
    if missing:
        failures.append(f"{label}: missing required metrics: {', '.join(missing)}")
        continue
    blocks[label] = normalize(body)
    print(f"metrics-parity: {label}: {len(body)} bytes, "
          f"{sum(1 for l in body.splitlines() if l.startswith('# TYPE'))} metric(s)")

if len(blocks) >= 2:
    names = sorted(blocks)
    ref = names[0]
    for other in names[1:]:
        if blocks[ref] != blocks[other]:
            failures.append(f"{ref} != {other}: exposition differs")
            diff = list(difflib.unified_diff(blocks[ref], blocks[other], ref, other, lineterm=""))
            for line in diff[:20]:
                print("   ", line)

if failures:
    for line in failures:
        print(f"metrics-parity: {line}")
    raise SystemExit(1)
if len(blocks) < 2:
    print("metrics-parity: only one PE reachable — nothing to compare")
    raise SystemExit(1)
print(f"metrics-parity: OK ({len(blocks)} PEs byte-identical after runtime-label "
      f"normalization{'' if with_values else '; values excluded'})")
PYEOF
status=$?
set -e
if [ $status -ne 0 ]; then
  fail "metrics exposition drift (see output above)"
fi
