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
PA=$(free_port); PB=$(free_port); PC=$(free_port)
"$OPENSSL" s_server -accept "127.0.0.1:$PA" -tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256 \
  -groups X25519MLKEM768:X25519:secp384r1 -cert srv.crt -key srv.key -CAfile ca.crt -Verify 1 -www -quiet >/dev/null 2>&1 &
PIDS+=($!)
python3 -m http.server "$PB" --bind 127.0.0.1 --directory "$TMP" >/dev/null 2>&1 &
PIDS+=($!)
"$OPENSSL" s_server -accept "127.0.0.1:$PC" -cert srv.crt -key srv.key -www -quiet >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; [socket.create_connection(('127.0.0.1',p),1).close() for p in ($PA,$PB,$PC)]" 2>/dev/null && break
  sleep 0.1
done

printf '{"prometheus_url":"https://127.0.0.1:%s","prometheus_started":true,"openapi_swagger_url":"https://127.0.0.1:%s","openapi_swagger_started":true}\n' "$PC" "$PB" > bad-manifest.json
printf '{}\n' > empty-manifest.json
run() { # manifest report
  RE_REGISTRY_URL="https://127.0.0.1:$PA/re-registry.json" RE_OPENSSL="$OPENSSL" \
  RE_HARNESS_TLS_CA="$TMP/ca.crt" RE_HARNESS_TLS_CERT="$TMP/cli.crt" RE_HARNESS_TLS_KEY="$TMP/cli.key" \
    python3 "$PROBE" --lane native --manifest "$1" --integrations "$TMP/none.json" \
      --manager-backend '' --manager-frontend '' --report "$2" 2>&1
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
# the link has one.
cp "$CI_DIR/config/transport-inventory.json" inv.json
RE_REGISTRY_URL="https://127.0.0.1:$PA/re-registry.json" RE_OPENSSL="$OPENSSL" \
RE_HARNESS_TLS_CA="$TMP/ca.crt" RE_HARNESS_TLS_CERT="$TMP/cli.crt" RE_HARNESS_TLS_KEY="$TMP/cli.key" \
  python3 "$PROBE" --lane native --manifest empty-manifest.json --integrations "$TMP/none.json" \
    --manager-backend '' --manager-frontend '' --inventory inv.json --write >/dev/null 2>&1
got=$(python3 -c "
import json; l=[x for x in json.load(open('inv.json'))['links'] if x['id']=='instance-registry'][0]
print(l['probe']['native']['verdict'], l['status'], l['mtls'])")
if [ "$got" = "compliant plaintext False" ]; then ok "--write records the probe; status waits for the docker and release lanes"; else bad "--write: $got"; fi

echo "transport probe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
