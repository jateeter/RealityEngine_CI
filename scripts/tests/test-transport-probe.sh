#!/usr/bin/env bash
# Tests for scripts/transport-probe.py (RealityEngine_CI#728).
#
# Local only: it starts three loopback listeners of its own, under a throwaway
# CA in a temp directory, and probes them. It touches no lane PKI and no
# running universe.
#   A  openssl s_server: TLS 1.3, the profile's suites and groups, a client
#      certificate required. Served as the instance registry.
#   B  python http.server: plaintext, though the lane names it https. Served
#      as the OpenAPI portal.
#   C  openssl s_server: TLS 1.2 accepted. Served as Prometheus.
# The probe must call A compliant with mTLS, and fail naming B's plaintext and
# C's TLS 1.2; with only A it must pass.
#
# Needs OpenSSL 3.5+ (Homebrew openssl@3, or RE_OPENSSL). Skips with exit 0 and
# a reason when it is missing.
#
# Usage: bash scripts/tests/test-transport-probe.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$CI_DIR/scripts/transport-probe.py"
OPENSSL="${RE_OPENSSL:-}"
for c in "$OPENSSL" /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl)"; do
  [ -n "$c" ] && [ -x "$c" ] || continue
  if "$c" version | grep -qE '^OpenSSL 3\.([5-9]|[1-9][0-9])'; then OPENSSL="$c"; break; fi
done
if ! "$OPENSSL" version 2>/dev/null | grep -qE '^OpenSSL 3\.([5-9]|[1-9][0-9])'; then
  echo "SKIP transport probe: OpenSSL 3.5+ not found"
  exit 0
fi

TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]+"${PIDS[@]}"}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# A throwaway CA, a server certificate for 127.0.0.1 and a client certificate.
cd "$TMP" || exit 1
ec() { "$OPENSSL" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:secp384r1 -out "$1" 2>/dev/null; }
ec ca.key; ec srv.key; ec cli.key
"$OPENSSL" req -x509 -new -key ca.key -sha384 -days 1 -subj /CN=probe-test-ca -out ca.crt 2>/dev/null
"$OPENSSL" req -new -key srv.key -subj /CN=127.0.0.1 -out srv.csr 2>/dev/null
printf 'subjectAltName=IP:127.0.0.1\n' > srv.ext
"$OPENSSL" x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -sha384 -extfile srv.ext -out srv.crt 2>/dev/null
"$OPENSSL" req -new -key cli.key -subj /CN=harness -out cli.csr 2>/dev/null
"$OPENSSL" x509 -req -in cli.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -sha384 -out cli.crt 2>/dev/null

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PA=$(free_port); PB=$(free_port); PC=$(free_port); PD=$(free_port)
"$OPENSSL" s_server -accept "127.0.0.1:$PA" -tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256 \
  -groups X25519MLKEM768:X25519:secp384r1 -cert srv.crt -key srv.key -CAfile ca.crt -Verify 1 -www -quiet >/dev/null 2>&1 &
PIDS+=($!)
python3 -m http.server "$PB" --bind 127.0.0.1 --directory "$TMP" >/dev/null 2>&1 &
PIDS+=($!)
"$OPENSSL" s_server -accept "127.0.0.1:$PC" -cert srv.crt -key srv.key -www -quiet >/dev/null 2>&1 &
PIDS+=($!)
# D: TLS 1.2 only, an outside party below the profile.
"$OPENSSL" s_server -accept "127.0.0.1:$PD" -tls1_2 -cert srv.crt -key srv.key -www -quiet >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; [socket.create_connection(('127.0.0.1',p),1).close() for p in ($PA,$PB,$PC,$PD)]" 2>/dev/null && break
  sleep 0.1
done

printf '{"prometheus_url":"https://127.0.0.1:%s","prometheus_started":true,"openapi_swagger_url":"https://127.0.0.1:%s","openapi_swagger_started":true}\n' "$PC" "$PB" > bad-manifest.json
printf '{}\n' > empty-manifest.json
run() { # manifest report
  RE_REGISTRY_URL="https://127.0.0.1:$PA/re-registry.json" RE_OPENSSL="$OPENSSL" \
  RE_HARNESS_TLS_CA="$TMP/ca.crt" RE_HARNESS_TLS_CERT="$TMP/cli.crt" RE_HARNESS_TLS_KEY="$TMP/cli.key" \
    python3 "$PROBE" --lane native --manifest "$1" --integrations "$TMP/none.json" \
      --manager-backend '' --manager-frontend '' --manager-ts-pe '' --proxy-grafana '' --no-external --report "$2" 2>&1
}

echo "transport probe"
out=$(run bad-manifest.json bad.json); rc=$?
if [ "$rc" -ne 0 ]; then ok "plaintext and TLS 1.2 fail the probe"; else bad "expected a failure, got exit 0: $out"; fi
if [[ "$out" == *"browser-to-openapi-portal"*"plaintext answered"* ]]; then ok "names the plaintext listener"; else bad "plaintext not named: $out"; fi
if [[ "$out" == *"prometheus-scrape"*"TLS 1.2 accepted"* ]]; then ok "names the TLS 1.2 listener"; else bad "TLS 1.2 not named: $out"; fi
verdict=$(python3 -c "import json; r=json.load(open('$TMP/bad.json'))['links']['instance-registry']; print(r['verdict'], r['mtls'], r['endpoints'][0]['mtls'], r['endpoints'][0]['group'])")
if [ "$verdict" = "compliant True handshake X25519MLKEM768" ]; then ok "the profile listener is compliant, mTLS at the handshake"; else bad "registry verdict: $verdict"; fi

out=$(run empty-manifest.json good.json); rc=$?
if [ "$rc" -eq 0 ]; then ok "only the profile listener: the probe passes"; else bad "expected a pass: $out"; fi

# --write records the lane's probe, and moves status only when every lane of
# the link has one. A fixture: the committed inventory's instance-registry,
# unprobed and plaintext on all three lanes.
python3 - "$CI_DIR/config/transport-inventory.json" inv.json <<'PY'
import json, sys
i = json.load(open(sys.argv[1]))
for l in i["links"]:
    if l["id"] == "instance-registry":
        l.pop("probe", None); l["status"] = "plaintext"; l["mtls"] = False; l["lanes"] = ["native", "docker", "release"]
json.dump(i, open(sys.argv[2], "w"))
PY
RE_REGISTRY_URL="https://127.0.0.1:$PA/re-registry.json" RE_OPENSSL="$OPENSSL" \
RE_HARNESS_TLS_CA="$TMP/ca.crt" RE_HARNESS_TLS_CERT="$TMP/cli.crt" RE_HARNESS_TLS_KEY="$TMP/cli.key" \
  python3 "$PROBE" --lane native --manifest empty-manifest.json --integrations "$TMP/none.json" \
    --manager-backend '' --manager-frontend '' --manager-ts-pe '' --proxy-grafana '' --inventory inv.json --write >/dev/null 2>&1
got=$(python3 -c "
import json; l=[x for x in json.load(open('inv.json'))['links'] if x['id']=='instance-registry'][0]
print(l['probe']['native']['verdict'], l['status'], l['mtls'])")
if [ "$got" = "compliant plaintext False" ]; then ok "--write records the probe; status waits for the docker and release lanes"; else bad "--write: $got"; fi

# An external party: a profile client verified against the system store
# (RE_SYSTEM_CA, here the throwaway CA). A (profile) is compliant; D (TLS 1.2
# only) is `tls`, recorded and not failed: the release gate holds it.
python3 - "$CI_DIR/config/transport-inventory.json" ext.json "$PA" "$PD" <<'PY'
import json, sys
i = json.load(open(sys.argv[1]))
for l in i["links"]:
    l.pop("probeTargets", None)
    if l["id"] == "pe-to-openai":
        l["probeTargets"] = [{"host": "127.0.0.1", "port": int(sys.argv[3]), "path": "/"}]
    if l["id"] == "pim-to-epic":
        l["probeTargets"] = [{"host": "127.0.0.1", "port": int(sys.argv[4]), "path": "/"}]
i["links"] = [l for l in i["links"] if l.get("probeTargets") or l.get("audience") != "external"]
json.dump(i, open(sys.argv[2], "w"))
PY
out=$(RE_OPENSSL="$OPENSSL" RE_SYSTEM_CA="$TMP/ca.crt" \
  RE_HARNESS_TLS_CA="$TMP/ca.crt" RE_HARNESS_TLS_CERT="$TMP/cli.crt" RE_HARNESS_TLS_KEY="$TMP/cli.key" \
  python3 "$PROBE" --lane native --external-only --inventory ext.json --report ext-report.json 2>&1); rc=$?
got=$(python3 -c "import json; r=json.load(open('$TMP/ext-report.json'))['links']; print(r['pe-to-openai']['verdict'], r['pim-to-epic']['verdict'], len(r))")
if [ "$rc" -eq 0 ] && [ "$got" = "compliant tls 2" ]; then ok "external parties: profile client compliant, TLS 1.2-only party tls, not a stage failure"; else bad "external: rc=$rc $got $out"; fi

# --endpoints with --only-endpoints probes only those listeners, each against
# the CA its entry names (the asset stack's own CA).
printf '{"localai-to-redis": [{"url": "https://127.0.0.1:%s", "path": "/", "ca": "%s"}]}\n' "$PA" "$TMP/ca.crt" > eps.json
out=$(RE_OPENSSL="$OPENSSL" RE_HARNESS_TLS_CA="$TMP/cli.crt" RE_HARNESS_TLS_CERT="$TMP/cli.crt" RE_HARNESS_TLS_KEY="$TMP/cli.key" \
  python3 "$PROBE" --lane native --only-endpoints --endpoints eps.json --report eps-report.json 2>&1); rc=$?
got=$(python3 -c "import json; r=json.load(open('$TMP/eps-report.json'))['links']; print(list(r), r['localai-to-redis']['verdict'])")
if [ "$rc" -eq 0 ] && [ "$got" = "['localai-to-redis'] compliant" ]; then ok "--only-endpoints probes only its listeners, verified by the entry's CA"; else bad "endpoints: rc=$rc $got $out"; fi

# --apply records a report in the inventory, as --write would have.
cp inv.json inv-apply.json
python3 "$PROBE" --apply bad.json --inventory inv-apply.json >/dev/null 2>&1
got=$(python3 -c "
import json; l=[x for x in json.load(open('inv-apply.json'))['links'] if x['id']=='instance-registry'][0]
print(l['probe']['native']['verdict'], l['status'])")
if [ "$got" = "compliant plaintext" ]; then ok "--apply records a report's probes"; else bad "--apply: $got"; fi

# A deficiency's probeAccepts turns a named finding from a failure into a record.
python3 - "$CI_DIR/config/transport-inventory.json" acc.json <<'PY'
import json, sys
i = json.load(open(sys.argv[1]))
for l in i["links"]:
    if l["id"] == "prometheus-scrape":
        l["deficiency"]["probeAccepts"] = ["TLS 1.2 accepted", "a suite outside the profile accepted"]
json.dump(i, open(sys.argv[2], "w"))
PY
printf '{"prometheus_url":"https://127.0.0.1:%s","prometheus_started":true}\n' "$PC" > prom-manifest.json
out=$(RE_REGISTRY_URL="https://127.0.0.1:$PA/re-registry.json" RE_OPENSSL="$OPENSSL" \
  RE_HARNESS_TLS_CA="$TMP/ca.crt" RE_HARNESS_TLS_CERT="$TMP/cli.crt" RE_HARNESS_TLS_KEY="$TMP/cli.key" \
  python3 "$PROBE" --lane native --manifest prom-manifest.json --integrations "$TMP/none.json" \
    --manager-backend '' --manager-frontend '' --manager-ts-pe '' --proxy-grafana '' --no-external --inventory acc.json 2>&1); rc=$?
if [[ "$out" != *"prometheus-scrape (127"* && "$out" == *"grafana-to-sources (127"*"TLS 1.2 accepted"* ]]; then
  ok "a finding the deficiency accepts is recorded, not failed; the same finding on another link still fails"
else
  bad "probeAccepts: $out"
fi

# A route with its own authentication answers 401 with or without the client
# certificate (PIM's bearer token): that is not mTLS.
PE_=$(free_port)
python3 - "$PE_" "$TMP" <<'PY' >/dev/null 2>&1 &
import http.server, ssl, sys
port, d = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.load_cert_chain(f"{d}/srv.crt", f"{d}/srv.key"); ctx.load_verify_locations(f"{d}/ca.crt"); ctx.verify_mode = ssl.CERT_OPTIONAL
s = http.server.HTTPServer(("127.0.0.1", port), H); s.socket = ctx.wrap_socket(s.socket, server_side=True); s.serve_forever()
PY
PIDS+=($!)
for _ in $(seq 1 50); do python3 -c "import socket; socket.create_connection(('127.0.0.1',$PE_),1).close()" 2>/dev/null && break; sleep 0.1; done
printf '{"healthkit-to-pim": [{"url": "https://127.0.0.1:%s", "path": "/"}]}\n' "$PE_" > eps401.json
RE_OPENSSL="$OPENSSL" RE_HARNESS_TLS_CA="$TMP/ca.crt" RE_HARNESS_TLS_CERT="$TMP/cli.crt" RE_HARNESS_TLS_KEY="$TMP/cli.key" \
  python3 "$PROBE" --lane native --only-endpoints --endpoints eps401.json --report r401.json >/dev/null 2>&1
got=$(python3 -c "import json; print(json.load(open('$TMP/r401.json'))['links']['healthkit-to-pim']['endpoints'][0]['mtls'])")
if [ "$got" = "none" ]; then ok "a 401 with and without the certificate is the route's own authentication, not mTLS"; else bad "401 route: mtls=$got"; fi

# The release lane's endpoints come from the install's own .env.
mkdir -p inst
printf 'COMPOSE_PROJECT_NAME=re-regression\nRE_TLS=on\nRE_PORT_QDRANT=14333\nRE_IMAGE_LOCALAI_API=ghcr.io/x/re-localai-api:t1\n' > inst/.env
mapfile -t meta < <(python3 "$CI_DIR/scripts/lib/release_probe_endpoints.py" inst eps-out)
got=$(python3 -c "import json; h=json.load(open('eps-out/host.json')); n=json.load(open('eps-out/network.json')); print(h['localai-to-qdrant'][0]['url'], h['prometheus-scrape'][0]['url'], n['localai-to-redis'][0]['protocol'])")
if [ "${meta[*]}" = "re-regression ghcr.io/x/re-localai-api:t1" ] && [ "$got" = "https://127.0.0.1:14333 https://127.0.0.1:9090 redis" ]; then
  ok "release endpoints: the install's ports, network and probe image"
else
  bad "release endpoints: ${meta[*]} / $got"
fi
printf 'RE_TLS=off\n' > inst/.env
if ! python3 "$CI_DIR/scripts/lib/release_probe_endpoints.py" inst eps-off >/dev/null 2>&1; then ok "release endpoints: an install with TLS off has nothing to probe"; else bad "release endpoints with RE_TLS=off"; fi

echo "transport probe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
