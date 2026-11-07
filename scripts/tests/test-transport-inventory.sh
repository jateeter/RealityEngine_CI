#!/usr/bin/env bash
# Unit tests for scripts/check-transport-inventory.py (RealityEngine_CI#668, #725).
#
# Offline: reads the committed profile and inventory, and fixtures in a temp
# directory. Starts nothing.
#
# Each failure case takes a valid document, breaks one thing, and asserts the
# checker goes red and names it, so a checker that passes everything can't
# hide behind the green case.
#
# Usage: bash scripts/tests/test-transport-inventory.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$CI_DIR/scripts/check-transport-inventory.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# mutate <name> <python expression on d (profile) or i (inventory)>
mutate() {
  python3 - "$CI_DIR" "$TMP/$1" "$2" "$3" <<'PY'
import json, sys, pathlib
ci, out, which, expr = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
out.mkdir(parents=True, exist_ok=True)
d = json.load(open(f"{ci}/config/transport-profile.json"))
i = json.load(open(f"{ci}/config/transport-inventory.json"))
exec(expr)
json.dump(d, open(out / "profile.json", "w"))
json.dump(i, open(out / "inventory.json", "w"))
PY
}

expect_fail() { # name needle [extra args]
  local name=$1 needle=$2; shift 2
  local out
  out=$(python3 "$CHECK" --profile "$TMP/$name/profile.json" --inventory "$TMP/$name/inventory.json" "$@" 2>&1)
  if [[ $? -ne 0 && "$out" == *"$needle"* ]]; then ok "$name"; else bad "$name: expected failure naming '$needle', got: $out"; fi
}

echo "transport inventory"

if python3 "$CHECK" >/dev/null 2>&1; then ok "committed profile and inventory pass"; else bad "committed profile and inventory pass"; fi

out=$(python3 "$CHECK" --require-compliant 2>&1)
if [[ $? -ne 0 && "$out" == *"release gate FAILS"* ]]; then ok "release gate fails while links are not compliant"; else bad "release gate: $out"; fi

mutate tls12 profile 'd["tls"]["versions"]=["TLSv1.2","TLSv1.3"]'
expect_fail tls12 'tls.versions must be exactly'

mutate cbc profile 'd["tls"]["cipherSuites"].append("TLS_RSA_WITH_AES_128_CBC_SHA")'
expect_fail cbc 'AEAD suites'

mutate nopq profile 'd["tls"]["keyExchangeGroups"]["preferred"]=["X25519"]'
expect_fail nopq 'post-quantum hybrid'

mutate dup inventory 'i["links"].append(dict(i["links"][0]))'
expect_fail dup 'duplicate link id'

mutate status inventory 'i["links"][0]["status"]="encrypted"'
expect_fail status 'is not one of'

mutate lane inventory 'i["links"][0]["lanes"]=["staging"]'
expect_fail lane 'lanes must be'

mutate owner inventory 'i["links"][0]["owner"]="RealityEngine_AI"'
expect_fail owner 'not a focus-set repository'

mutate issue inventory 'i["links"][0]["issue"]="#193"'
expect_fail issue 'issue must be written'

mutate claim inventory 'i["links"][0]["status"]="compliant"'
expect_fail claim 'without a probe record'

mutate mtlsclaim inventory 'i["links"][0]["mtls"]=True'
expect_fail mtlsclaim 'without a probe record'

mutate allgood inventory '
for l in i["links"]:
    l["status"]="compliant"; l["mtls"]=True; l["probe"]={"tls":"TLSv1.3"}'
out=$(python3 "$CHECK" --profile "$TMP/allgood/profile.json" --inventory "$TMP/allgood/inventory.json" --require-compliant 2>&1)
if [[ $? -eq 0 && "$out" == *"release gate passes"* ]]; then ok "release gate passes when every link is compliant with mTLS"; else bad "allgood: $out"; fi

echo "transport-inventory: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
