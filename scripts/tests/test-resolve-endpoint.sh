#!/usr/bin/env bash
# Unit tests for scripts/lib/resolve-endpoint.sh (RealityEngine_CI#278).
#
# Fixture-driven: no universe required, so this runs in the same gate as the
# other scripts unit tests rather than only where a registry happens to exist.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

FIXTURE="$(mktemp -d)/re-registry.json"
cat > "$FIXTURE" <<'JSON'
{
  "host": "10.0.0.9",
  "instances": [
    {"id": "cpp-1",   "runtime": "cpp",   "re_url": "http://10.0.0.9:5301", "pe_url": "http://10.0.0.9:5300"},
    {"id": "cpp-2",   "runtime": "cpp",   "re_url": "http://10.0.0.9:5401", "pe_url": "http://10.0.0.9:5400"},
    {"id": "scala-1", "runtime": "scala", "re_url": "http://10.0.0.9:5101", "pe_url": "http://10.0.0.9:5100"}
  ],
  "services": {
    "registry":        {"url": "http://10.0.0.9:5999", "port": 5999},
    "manager_backend": {"url": "http://10.0.0.9:3001", "port": 3001}
  }
}
JSON

RE_REGISTRY_FILE="$FIXTURE"
export RE_REGISTRY_FILE
# shellcheck source=/dev/null
. "$CI_DIR/scripts/lib/resolve-endpoint.sh"

echo "== resolve-endpoint =="

assert_eq "$(re_endpoint cpp-1)" "http://10.0.0.9:5301" "re_endpoint resolves by id"
assert_eq "$(pe_endpoint scala-1)" "http://10.0.0.9:5100" "pe_endpoint resolves by id"

# The doubled family is the case positional selection gets wrong: cpp-1 and
# cpp-2 are the same runtime at different ports, and an index cannot tell a
# caller which one it got (RealityEngine_CI#274).
assert_eq "$(re_endpoint cpp-2)" "http://10.0.0.9:5401" "the second instance of a runtime is addressable"
[ "$(re_endpoint cpp-1)" != "$(re_endpoint cpp-2)" ] \
  && { echo "  PASS: doubled family resolves to distinct endpoints"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: doubled family resolves to distinct endpoints"; FAIL=$((FAIL+1)); }

assert_eq "$(service_endpoint registry)" "http://10.0.0.9:5999" "service_endpoint resolves a service"
assert_eq "$(registry_instance_ids | tr '\n' ' ')" "cpp-1 cpp-2 scala-1 " "instance ids in registry order"

# Absence is an exit code, not an empty string that a caller silently uses as a URL.
if re_endpoint no-such-engine >/dev/null 2>&1; then
  echo "  FAIL: unknown instance exits non-zero"; FAIL=$((FAIL+1))
else
  echo "  PASS: unknown instance exits non-zero"; PASS=$((PASS+1))
fi
if service_endpoint no-such-service >/dev/null 2>&1; then
  echo "  FAIL: unknown service exits non-zero"; FAIL=$((FAIL+1))
else
  echo "  PASS: unknown service exits non-zero"; PASS=$((PASS+1))
fi

# A registry from before the services block existed must resolve to "not found"
# rather than faulting — that is the upgrade path this lands on.
LEGACY="$(mktemp -d)/re-registry.json"
printf '{"host":"10.0.0.9","instances":[{"id":"cpp-1","runtime":"cpp","re_url":"http://10.0.0.9:5301","pe_url":"http://10.0.0.9:5300"}]}\n' > "$LEGACY"
RE_REGISTRY_FILE="$LEGACY" bash -c ". '$CI_DIR/scripts/lib/resolve-endpoint.sh'; re_endpoint cpp-1" >/dev/null 2>&1 \
  && { echo "  PASS: instances still resolve without a services block"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: instances still resolve without a services block"; FAIL=$((FAIL+1)); }
RE_REGISTRY_FILE="$LEGACY" bash -c ". '$CI_DIR/scripts/lib/resolve-endpoint.sh'; service_endpoint registry" >/dev/null 2>&1 \
  && { echo "  FAIL: missing services block is not-found, not a fault"; FAIL=$((FAIL+1)); } \
  || { echo "  PASS: missing services block is not-found, not a fault"; PASS=$((PASS+1)); }

# ── allocation template ───────────────────────────────────────────────────
# The registry must record how the ports were decided, and must not claim the
# nominal template when the runtime departed from it. On macOS AirPlay Receiver
# holds 5000, so Scala comes up on 5100/5101 — routine, and exactly the case a
# template-only record would misreport.
ALLOC="$(mktemp -d)/re-registry.json"
cat > "$ALLOC" <<'JSON'
{
  "host": "10.0.0.9",
  "instances": [
    {"id": "cpp-1",   "runtime": "cpp",   "re_url": "http://10.0.0.9:5301", "pe_url": "http://10.0.0.9:5300", "re_port": 5301, "pe_port": 5300},
    {"id": "scala-1", "runtime": "scala", "re_url": "http://10.0.0.9:5101", "pe_url": "http://10.0.0.9:5100", "re_port": 5101, "pe_port": 5100}
  ]
}
JSON
RE_REGISTRY_FILE="$ALLOC" bash -c ". '$CI_DIR/scripts/registry.sh'; registry_set_allocation deterministic 100" >/dev/null 2>&1
alloc_json="$(RE_REGISTRY_FILE="$ALLOC" bash -c ". '$CI_DIR/scripts/registry.sh'; registry_allocation")"
field() { echo "$alloc_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())$1)"; }

assert_eq "$(field "['mode']")" "deterministic" "allocation mode is recorded"
assert_eq "$(field "['templates']['scala']['re_base']")" "5001" "nominal template is recorded"
assert_eq "$(field "['effective']['scala']['re_base']")" "5101" "effective base reflects the shifted port"
assert_eq "$(field "['shifted']")" "['scala']" "the shifted runtime is named"
assert_eq "$(field "['effective']['cpp']['re_base']")" "5301" "an unshifted runtime matches its template"

# A runtime that did not shift must not be reported as shifted, or the marker
# means nothing.
if echo "$alloc_json" | grep -q '"cpp"' && [ "$(field "['shifted']")" = "['scala']" ]; then
  echo "  PASS: only the shifted runtime is listed"; PASS=$((PASS+1))
else
  echo "  FAIL: only the shifted runtime is listed"; FAIL=$((FAIL+1))
fi

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
