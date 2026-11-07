#!/usr/bin/env bash
# Unit tests for scripts/lib/re_pki.py, the system PKI (RealityEngine_CI#668, #726).
#
# Uses a temporary RE_PKI_DIR, never ~/.reality-engine. Starts one process, an
# `openssl s_server` on a loopback port, for the handshake test, and stops it
# on exit. Needs openssl 3.5 or newer for the post-quantum hybrid group.
#
# Usage: bash scripts/tests/test-re-pki.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKI="$CI_DIR/scripts/lib/re_pki.py"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
export RE_PKI_DIR="$TMP/pki"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
pki() { python3 "$PKI" "$@"; }
UUID=0192f5c4-7e1a-7b3c-9d2e-4f5a6b7c8d9e

echo "re_pki"

pki init >/dev/null && ok "init creates the CA" || bad "init"
first=$(openssl x509 -in "$RE_PKI_DIR/ca/ca.crt" -noout -fingerprint -sha256)
pki init >/dev/null
[[ "$(openssl x509 -in "$RE_PKI_DIR/ca/ca.crt" -noout -fingerprint -sha256)" == "$first" ]] && ok "init never replaces an existing CA" || bad "init replaced the CA"
[[ "$(stat -f %Lp "$RE_PKI_DIR/ca/ca.key" 2>/dev/null || stat -c %a "$RE_PKI_DIR/ca/ca.key")" == 600 ]] && ok "CA key is 0600" || bad "CA key mode"
openssl x509 -in "$RE_PKI_DIR/ca/ca.crt" -noout -text | grep -q "NIST CURVE: P-384" && ok "CA key is ECDSA P-384" || bad "CA curve"

pki issue cpp-1 --kind both --dns cpp-1.localhost --ip 127.0.0.1 --instance-uuid "$UUID" >/dev/null && ok "issue an instance certificate" || bad "issue"
cert="$RE_PKI_DIR/issued/cpp-1/cert.pem"
text=$(openssl x509 -in "$cert" -noout -text)
[[ "$text" == *"URI:urn:uuid:$UUID"* ]] && ok "instance certificate carries urn:uuid:<instance_uuid>" || bad "instance uuid SAN"
[[ "$text" == *"TLS Web Server Authentication, TLS Web Client Authentication"* ]] && ok "kind both has server and client auth" || bad "EKU"
[[ "$text" == *"ecdsa-with-SHA384"* && "$text" == *"P-384"* ]] && ok "leaf is ECDSA P-384 / SHA-384" || bad "leaf algorithms"
pki verify cpp-1 >/dev/null && ok "verify against CA and CRL" || bad "verify"

s1=$(openssl x509 -in "$cert" -noout -serial)
pki issue cpp-1 --kind both --dns cpp-1.localhost --ip 127.0.0.1 --instance-uuid "$UUID" | grep -q kept && ok "re-issue with the same SANs keeps a current certificate" || bad "idempotent issue"
[[ "$(openssl x509 -in "$cert" -noout -serial)" == "$s1" ]] && ok "kept certificate has the same serial" || bad "serial changed"

old="$TMP/old.pem"; cp "$cert" "$old"
pki issue cpp-1 --kind both --dns cpp-1.localhost --dns cpp-1.internal --ip 127.0.0.1 --instance-uuid "$UUID" | grep -q issued && ok "changed SANs re-issue" || bad "SAN change"
if openssl verify -crl_check -CAfile "$RE_PKI_DIR/ca/ca.crt" -CRLfile "$RE_PKI_DIR/ca/ca.crl" "$old" >/dev/null 2>&1; then bad "superseded certificate still verifies"; else ok "superseded certificate is revoked"; fi

pki issue client-a --kind client >/dev/null && ok "a client-only certificate needs no SANs" || bad "client issue"
pki issue nosan --kind server >/dev/null 2>&1 && bad "server without SANs accepted" || ok "a server certificate needs a SAN"
pki issue BadName --kind client >/dev/null 2>&1 && bad "invalid name accepted" || ok "invalid names are refused"
pki issue x --kind client --instance-uuid NOT-A-UUID >/dev/null 2>&1 && bad "invalid uuid accepted" || ok "invalid instance uuids are refused"

RE_PKI_LEAF_DAYS=10 pki issue short --kind server --dns short.localhost >/dev/null
pki renew | grep -q "issued short" && ok "renew re-issues inside the renewal window" || bad "renew"

pki revoke client-a >/dev/null
pki verify client-a >/dev/null 2>&1 && bad "revoked certificate verifies" || ok "revoked certificate fails verification"

# A real handshake under the profile: TLS 1.3 only, the profile's suites, the
# post-quantum hybrid group, and mutual authentication.
# The post-quantum hybrid group needs OpenSSL 3.5+. An older OpenSSL (the hosted
# ubuntu-24.04 runner ships 3.0) still checks TLS 1.3 and mTLS with X25519, and
# reports the post-quantum check as skipped, with the reason.
GROUP=X25519MLKEM768
if ! openssl list -tls-groups 2>/dev/null | grep -q X25519MLKEM768; then
  GROUP=X25519
  echo "  skip handshake with X25519MLKEM768: $(openssl version) has no post-quantum hybrid group; using X25519"
fi
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
pki issue client-b --kind client >/dev/null
d="$RE_PKI_DIR/issued"
openssl s_server -quiet -accept "127.0.0.1:$port" -tls1_3 \
  -ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256 -groups $GROUP \
  -cert "$d/cpp-1/cert.pem" -key "$d/cpp-1/key.pem" -CAfile "$RE_PKI_DIR/ca/ca.crt" -Verify 1 -verify_return_error \
  >/dev/null 2>&1 &
SERVER_PID=$!
# Wait until the server accepts connections (up to 10 s) rather than sleeping a guess.
for _ in $(seq 1 100); do
  python3 -c 'import socket,sys;s=socket.socket();s.settimeout(0.1);sys.exit(s.connect_ex(("127.0.0.1",int(sys.argv[1]))))' "$port" && break
  sleep 0.1
done
hs=$(echo Q | openssl s_client -connect "127.0.0.1:$port" -servername cpp-1.localhost -verify_hostname cpp-1.localhost \
  -tls1_3 -groups $GROUP -CAfile "$RE_PKI_DIR/ca/ca.crt" -verify_return_error \
  -cert "$d/client-b/cert.pem" -key "$d/client-b/key.pem" 2>&1)
[[ "$hs" == *"TLSv1.3"* ]] && ok "handshake negotiates TLS 1.3" || bad "TLS 1.3: $(echo "$hs" | tail -3)"
if [[ "$GROUP" == X25519MLKEM768 ]]; then
  [[ "$hs" == *"X25519MLKEM768"* ]] && ok "handshake uses X25519MLKEM768" || bad "PQ group: $(echo "$hs" | grep -i -E 'group|temp key' | head -2)"
fi
[[ "$hs" == *"Verify return code: 0 (ok)"* ]] && ok "client verifies the server's chain and hostname" || bad "server verification"
# In TLS 1.3 the server refuses a missing client certificate after the handshake,
# so the client must stay to read the alert: wait before sending, then look for it.
noclient=$( (sleep 1; echo Q) | openssl s_client -connect "127.0.0.1:$port" -tls1_3 -groups $GROUP -CAfile "$RE_PKI_DIR/ca/ca.crt" 2>&1)
if [[ "$noclient" == *"certificate required"* ]]; then ok "server refuses a client without a certificate (mTLS)"; else bad "mTLS not enforced: $(echo "$noclient" | grep -i -E 'alert|error' | head -2)"; fi
kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""

echo "re_pki: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
