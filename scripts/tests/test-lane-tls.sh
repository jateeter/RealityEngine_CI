#!/usr/bin/env bash
# Unit tests for scripts/lib/lane-tls.sh (RealityEngine_CI#668, #732).
#
# Uses a temporary RE_PKI_DIR, never ~/.reality-engine. Starts one process, an
# `openssl s_server` on a loopback port requiring a client certificate, and
# stops it on exit. Run it under bash 5 and under macOS /bin/bash 3.2:
# startUniverse.sh sources the library from /bin/bash.
#
# Usage: bash scripts/tests/test-lane-tls.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
export RE_PKI_DIR="$TMP/pki"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
UUID=0192f5c4-7e1a-7b3c-9d2e-4f5a6b7c8d9e

# shellcheck source=../lib/lane-tls.sh
. "$CI_DIR/scripts/lib/lane-tls.sh"
echo "lane-tls (bash ${BASH_VERSION})"

# --- the lane off -------------------------------------------------------------
RE_TLS=off
lane_tls_init native 2>/dev/null && [ "$LANE_TLS_READY" = 1 ] && ok "off: the PKI is prepared anyway" || bad "off: init"
[ "$(lane_tls_scheme)" = http ] && ok "off: scheme is http" || bad "off: scheme"
lane_tls_issue_instance cpp-1 "$UUID" 192.0.2.10
[ -z "$INST_TLS_CERT$INST_TLS_KEY$INST_TLS_CA$INST_TLS_CRL" ] && ok "off: no RE_TLS_* reaches a service" || bad "off: INST_TLS_* set: $INST_TLS_CERT"
[ -f "$RE_PKI_DIR/issued/cpp-1/cert.pem" ] && ok "off: the instance certificate is issued anyway" || bad "off: not issued"

# --- the lane on --------------------------------------------------------------
RE_TLS=on
lane_tls_init native 2>/dev/null && ok "on: init" || bad "on: init"
[ "$(lane_tls_scheme)" = https ] && ok "on: scheme is https" || bad "on: scheme"
lane_tls_issue_instance cpp-1 "$UUID" 192.0.2.10
[ -n "$INST_TLS_CERT" ] && [ -f "$INST_TLS_CERT" ] && [ -f "$INST_TLS_KEY" ] && [ -f "$INST_TLS_CA" ] && [ -f "$INST_TLS_CRL" ] \
  && ok "on: RE_TLS_CERT/KEY/CA/CRL are real files" || bad "on: INST_TLS_* missing"
text=$(openssl x509 -in "$RE_PKI_DIR/issued/cpp-1/cert.pem" -noout -text)
case "$text" in *"URI:urn:uuid:$UUID"*) ok "on: the instance certificate carries urn:uuid:<instance_uuid>";; *) bad "on: uuid SAN";; esac
case "$text" in *"IP Address:192.0.2.10"*) ok "on: the certificate covers HOST_IP";; *) bad "on: HOST_IP SAN";; esac
case "$text" in *"DNS:cpp-1.localhost"*) ok "on: the certificate covers <id>.localhost";; *) bad "on: id SAN";; esac

c=$(lane_curl) && ! "$c" -V | head -1 | grep -q SecureTransport && ok "lane_curl is TLS 1.3-capable ($c)" || bad "lane_curl: $c"

# A real GET through lane_curl_get against a server that requires the
# harness's client certificate.
GROUP=X25519MLKEM768
openssl list -tls-groups 2>/dev/null | grep -q X25519MLKEM768 || GROUP=X25519
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
openssl s_server -quiet -www -accept "127.0.0.1:$port" -tls1_3 -groups "$GROUP" \
  -cert "$RE_PKI_DIR/issued/cpp-1/chain.pem" -key "$RE_PKI_DIR/issued/cpp-1/key.pem" \
  -CAfile "$LANE_TLS_CA" -Verify 1 -verify_return_error >/dev/null 2>&1 &
SERVER_PID=$!
i=0; while [ $i -lt 100 ]; do python3 -c 'import socket,sys;s=socket.socket();s.settimeout(0.1);sys.exit(s.connect_ex(("127.0.0.1",int(sys.argv[1]))))' "$port" && break; i=$((i+1)); sleep 0.1; done
out=$(lane_curl_get "https://cpp-1.localhost:$port/" -s --max-time 5 --resolve "cpp-1.localhost:$port:127.0.0.1" 2>&1)
case "$out" in *"TLSv1.3"*) ok "lane_curl_get completes an mTLS GET over TLS 1.3";; *) bad "mTLS GET: $(echo "$out" | head -3)";; esac
noclient=$("$c" -s --max-time 5 --tlsv1.3 --cacert "$LANE_TLS_CA" --resolve "cpp-1.localhost:$port:127.0.0.1" "https://cpp-1.localhost:$port/" 2>&1; echo "exit=$?")
case "$noclient" in *"TLSv1.3"*) bad "a client without the harness certificate got through";; *) ok "without the harness certificate the server refuses";; esac
kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""

# --- a broken PKI -------------------------------------------------------------
# shellcheck disable=SC2034  # read by the sourced library
RE_TLS=off LANE_TLS_PKI=/nonexistent/re_pki.py
lane_tls_init native 2>/dev/null; rc=$?
[ $rc -eq 0 ] && [ "$LANE_TLS_READY" = 0 ] && ok "off + broken PKI: a warning, the lane stays plaintext" || bad "off + broken PKI: rc=$rc ready=$LANE_TLS_READY"
# shellcheck disable=SC2034  # read by the sourced library
RE_TLS=on
lane_tls_init native 2>/dev/null && bad "on + broken PKI accepted" || ok "on + broken PKI: refused"
lane_tls_issue_instance cpp-1 "$UUID" 2>/dev/null && bad "on + broken PKI: instance issued" || ok "on + broken PKI: no instance certificate"

echo "lane-tls: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
