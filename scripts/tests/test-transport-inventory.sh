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

# A repository name may hold hyphens and dots (PIM's does); it is still <repo>#<n>.
mutate hyphen inventory 'i["links"][0]["issue"]="OpenCommons-Health---Personal-Information-Management#86"'
if python3 "$CHECK" --profile "$TMP/hyphen/profile.json" --inventory "$TMP/hyphen/inventory.json" >/dev/null 2>&1; then
  ok "issue in a hyphenated repository is accepted"
else
  bad "issue in a hyphenated repository is accepted"
fi
mutate issuespace inventory 'i["links"][0]["issue"]="Some Repo#86"'
expect_fail issuespace 'issue must be written'

mutate claim inventory 'next(l for l in i["links"] if "probe" not in l)["status"]="compliant"'
expect_fail claim 'without a probe record'

mutate mtlsclaim inventory 'next(l for l in i["links"] if "probe" not in l)["mtls"]=True'
expect_fail mtlsclaim 'without a probe record'

# A probe on one lane does not back a claim for the link's other lanes.
mutate onelane inventory 'l=next(x for x in i["links"] if len(x["lanes"])>1); l["status"]="compliant"; l["probe"]={l["lanes"][0]: {"verdict":"compliant","mtls":True}}'
expect_fail onelane 'without a probe record on'

mutate disagrees inventory 'l=next(x for x in i["links"] if len(x["lanes"])>1); l["status"]="compliant"; l["mtls"]=True; l["probe"]={ln: {"verdict":"tls","mtls":True} for ln in l["lanes"]}'
expect_fail disagrees 'probe found'

mutate srcnotplain inventory 'l=next(x for x in i["links"] if x["id"]=="pe-to-openclaw"); l["deficiency"]["sources"]=[{"file":"localOpenClawStack/x.conf","pattern":"plaintext-url","count":1}]'
expect_fail srcnotplain 'only for a link allowed to be plaintext'

mutate srcshape inventory 'l=next(x for x in i["links"] if x["id"]=="browser-cdp-proxy-to-chromium"); l["deficiency"]["sources"]=[{"file":"x.conf","pattern":"plaintext-url","count":0}]'
expect_fail srcshape 'deficiency.sources must list'

mutate srcpattern inventory 'l=next(x for x in i["links"] if x["id"]=="browser-cdp-proxy-to-chromium"); l["deficiency"]["sources"][0]["pattern"]="anything-goes"'
expect_fail srcpattern 'deficiency.sources must list'

mutate defnoowner inventory 'next(l for l in i["links"] if l.get("deficiency"))["deficiency"]["accepted"]="a contributor"'
expect_fail defnoowner 'accepted only by the owner'

mutate defallows inventory 'next(l for l in i["links"] if l.get("deficiency"))["deficiency"]["allows"]={"probe":False}'
expect_fail defallows 'allows must name only'

mutate defmissing inventory 'del next(l for l in i["links"] if l.get("deficiency"))["deficiency"]["remedy"]'
expect_fail defmissing 'deficiency.remedy is required'

# probeAccepts may name only findings from the fixed set; plaintext is never one.
mutate accepts inventory 'next(l for l in i["links"] if l.get("deficiency"))["deficiency"]["probeAccepts"]=["plaintext answered"]'
expect_fail accepts 'probeAccepts must list'

# clientAuthentication: owner-accepted token authentication stands in for mTLS.
mutate badauth inventory 'next(l for l in i["links"] if l.get("clientAuthentication"))["clientAuthentication"]["method"]="password"'
expect_fail badauth 'clientAuthentication must name'
mutate authowner inventory 'next(l for l in i["links"] if l.get("clientAuthentication"))["clientAuthentication"]["accepted"]="a contributor"'
expect_fail authowner 'clientAuthentication is accepted only by the owner'
mutate tokengate inventory '
for l in i["links"]:
    l["status"]="compliant"; l["mtls"]=l.get("audience","service")=="service" and not l.get("clientAuthentication"); l["probe"]={ln: {"verdict": "compliant", "mtls": l["mtls"]} for ln in l["lanes"]}'
out=$(python3 "$CHECK" --profile "$TMP/tokengate/profile.json" --inventory "$TMP/tokengate/inventory.json" --require-compliant 2>&1)
if [[ $? -eq 0 && "$out" == *"release gate passes"* ]]; then ok "gate passes a token-authenticated service link without mTLS"; else bad "tokengate: $out"; fi

# The gate honours a deficiency exactly as far as it allows, and no further.
mutate gatedef inventory '
for l in i["links"]:
    allows = (l.get("deficiency") or {}).get("allows", {})
    l["status"] = allows.get("status", "compliant"); l["mtls"] = allows.get("mtls", True); l["probe"] = {ln: {"verdict": l["status"], "mtls": l["mtls"]} for ln in l["lanes"]}'
out=$(python3 "$CHECK" --profile "$TMP/gatedef/profile.json" --inventory "$TMP/gatedef/inventory.json" --require-compliant 2>&1)
if [[ $? -eq 0 && "$out" == *"accepted deficiency"* && "$out" == *"release gate passes"* ]]; then ok "gate passes a link within its accepted deficiency, and lists it"; else bad "gatedef: $out"; fi

mutate gatebeyond inventory '
for l in i["links"]:
    allows = (l.get("deficiency") or {}).get("allows", {})
    l["status"] = allows.get("status", "compliant"); l["mtls"] = allows.get("mtls", True); l["probe"] = {ln: {"verdict": l["status"], "mtls": l["mtls"]} for ln in l["lanes"]}
next(l for l in i["links"] if l["id"] == "lifecycle-to-assets-css")["status"] = "plaintext"'
out=$(python3 "$CHECK" --profile "$TMP/gatebeyond/profile.json" --inventory "$TMP/gatebeyond/inventory.json" --require-compliant 2>&1)
if [[ $? -ne 0 && "$out" == *"lifecycle-to-assets-css: plaintext"* ]]; then ok "gate fails a deficient link beyond what it allows"; else bad "gatebeyond: $out"; fi

mutate allgood inventory '
for l in i["links"]:
    l["status"]="compliant"; l["mtls"]=True; l["probe"]={ln: {"verdict": "compliant", "mtls": True} for ln in l["lanes"]}'
out=$(python3 "$CHECK" --profile "$TMP/allgood/profile.json" --inventory "$TMP/allgood/inventory.json" --require-compliant 2>&1)
if [[ $? -eq 0 && "$out" == *"release gate passes"* ]]; then ok "release gate passes when every link is compliant with mTLS"; else bad "allgood: $out"; fi

# audience (owner, 2026-11-12): user-facing and external links expose TLS only.
mutate badaudience inventory 'i["links"][0]["audience"]="public"'
expect_fail badaudience 'audience'

ALLGOOD_NO_MTLS='
for l in i["links"]:
    l["status"]="compliant"; l["mtls"]=l.get("audience","service")=="service"; l["probe"]={ln: {"verdict": "compliant", "mtls": l["mtls"]} for ln in l["lanes"]}'
mutate tlsonly inventory "$ALLGOOD_NO_MTLS"
out=$(python3 "$CHECK" --profile "$TMP/tlsonly/profile.json" --inventory "$TMP/tlsonly/inventory.json" --require-compliant 2>&1)
if [[ $? -eq 0 && "$out" == *"release gate passes"* ]]; then ok "gate passes user-facing and external links on TLS without mTLS"; else bad "tlsonly: $out"; fi

mutate svcnomtls inventory "$ALLGOOD_NO_MTLS
l=next(x for x in i['links'] if x['id']=='instance-registry'); l['mtls']=False; l['probe']={ln: {'verdict': 'compliant', 'mtls': False} for ln in l['lanes']}"
out=$(python3 "$CHECK" --profile "$TMP/svcnomtls/profile.json" --inventory "$TMP/svcnomtls/inventory.json" --require-compliant 2>&1)
if [[ $? -ne 0 && "$out" == *"instance-registry: compliant, no mTLS"* ]]; then ok "gate still demands mTLS between services"; else bad "svcnomtls: $out"; fi

for aud in user external; do
  mutate "plain$aud" inventory "$ALLGOOD_NO_MTLS
l=next(x for x in i['links'] if x.get('audience')=='$aud' and not x.get('deficiency')); l['status']='plaintext'; l.pop('probe')"
  out=$(python3 "$CHECK" --profile "$TMP/plain$aud/profile.json" --inventory "$TMP/plain$aud/inventory.json" --require-compliant 2>&1)
  if [[ $? -ne 0 && "$out" == *"plaintext, $aud: TLS only"* ]]; then ok "gate fails a plaintext $aud link without a deficiency"; else bad "plain$aud: $out"; fi
  mutate "unver$aud" inventory "$ALLGOOD_NO_MTLS
l=next(x for x in i['links'] if x.get('audience')=='$aud' and not x.get('deficiency')); l['status']='tls'; l.pop('probe')"
  out=$(python3 "$CHECK" --profile "$TMP/unver$aud/profile.json" --inventory "$TMP/unver$aud/inventory.json" --require-compliant 2>&1)
  if [[ $? -ne 0 && "$out" == *"tls, $aud: TLS only"* ]]; then ok "gate fails a $aud link whose TLS is not verified at the profile"; else bad "unver$aud: $out"; fi
done

echo "transport-inventory: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
