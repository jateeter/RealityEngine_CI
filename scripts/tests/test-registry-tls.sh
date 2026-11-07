#!/usr/bin/env bash
# Unit tests for the instance registry over TLS and re_tls.py's lane path
# (RealityEngine_CI#668, #732).
#
# Uses a temporary RE_PKI_DIR and a temporary instance registry file, pid file
# and log, never ~/.reality-engine or /tmp/re-registry. Starts one process, the
# registry shim (scripts/lib/re_tls_server.py) on a free loopback port, and
# stops it on exit. Run it under bash 5 and macOS /bin/bash 3.2.
#
# Usage: bash scripts/tests/test-registry-tls.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'registry_stop_server 2>/dev/null; rm -rf "$TMP"' EXIT
export RE_PKI_DIR="$TMP/pki"
export RE_REGISTRY_FILE="$TMP/registry/re-registry.json"
export RE_REGISTRY_PID_FILE="$TMP/registry.pid"
export RE_REGISTRY_LOG="$TMP/registry.log"
export RE_REGISTRY_PORT
RE_REGISTRY_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip %s\n' "$1"; }

# shellcheck source=../lib/lane-tls.sh
. "$CI_DIR/scripts/lib/lane-tls.sh"
# shellcheck source=../registry.sh
. "$CI_DIR/scripts/registry.sh"
echo "registry-tls (bash ${BASH_VERSION})"
URL="https://127.0.0.1:$RE_REGISTRY_PORT/re-registry.json"
HOST="127.0.0.1:$RE_REGISTRY_PORT"

# --- the lane off: plaintext, and no harness trust exported -------------------
RE_TLS=off
export RE_HARNESS_TLS_CA=stale
lane_tls_init native 2>/dev/null
[ -z "${RE_HARNESS_TLS_CA:-}" ] && ok "off: no RE_HARNESS_TLS_* exported" || bad "off: RE_HARNESS_TLS_CA=$RE_HARNESS_TLS_CA"
lane_tls_issue_service registry 192.0.2.10
[ -z "$SVC_TLS_CERT$SVC_TLS_KEY" ] && ok "off: no registry certificate handed out" || bad "off: SVC_TLS_CERT=$SVC_TLS_CERT"

# --- the lane on ---------------------------------------------------------------
export RE_TLS=on
lane_tls_init native 2>/dev/null || bad "on: init"
[ "${RE_HARNESS_TLS_CA:-}" = "$LANE_TLS_CA" ] && [ -f "$RE_HARNESS_TLS_CERT" ] && [ -f "$RE_HARNESS_TLS_KEY" ] \
  && ok "on: RE_HARNESS_TLS_CA/CERT/KEY exported" || bad "on: harness trust not exported"
env | grep -q '^RE_TLS_CERT=' && bad "on: RE_TLS_CERT leaked into the harness environment" || ok "on: the services' RE_TLS_* stay out of the harness environment"
lane_tls_issue_service registry 192.0.2.10 && [ -f "$SVC_TLS_CERT" ] && [ -f "$SVC_TLS_KEY" ] \
  && ok "on: the registry gets a server certificate" || bad "on: registry certificate"
text=$(openssl x509 -in "$RE_PKI_DIR/issued/registry/cert.pem" -noout -text)
case "$text" in *"IP Address:192.0.2.10"*) ok "on: it covers HOST_IP";; *) bad "on: HOST_IP SAN";; esac
case "$text" in *"TLS Web Server Authentication"*) ok "on: serverAuth";; *) bad "on: EKU";; esac

# shellcheck disable=SC2034  # read by registry_start_server
REGISTRY_TLS_CERT="$SVC_TLS_CERT" REGISTRY_TLS_KEY="$SVC_TLS_KEY" REGISTRY_TLS_CA="$LANE_TLS_CA" REGISTRY_TLS_CRL="$LANE_TLS_CRL"
mkdir -p "$(dirname "$RE_REGISTRY_FILE")"
registry_start_server
i=0; while [ $i -lt 100 ]; do lane_curl_get "$URL" -sf -o /dev/null >/dev/null 2>&1 && break; i=$((i+1)); sleep 0.1; done

out=$(lane_curl_get "$URL" -sf --max-time 5 2>&1)
case "$out" in *'"instances"'*) ok "lane_curl_get reads the registry over mTLS";; *) bad "mTLS GET: $(head -3 "$RE_REGISTRY_LOG"; echo "$out" | head -3)";; esac

c=$(lane_curl)
"$c" -s --max-time 5 --tlsv1.3 --cacert "$LANE_TLS_CA" "$URL" >/dev/null 2>&1 \
  && bad "a client without a certificate was served" || ok "a client without a certificate is refused"
# Plaintext: a cleartext request on the raw socket gets no HTTP answer.
python3 - "$RE_REGISTRY_PORT" <<'EOF' && ok "plaintext is refused" || bad "plaintext was answered"
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(b"GET /re-registry.json HTTP/1.0\r\nHost: localhost\r\n\r\n")
try:
    data = s.recv(4096)
except OSError:
    data = b""
sys.exit(1 if data.startswith(b"HTTP/") else 0)
EOF
"$c" -s --max-time 5 --tlsv1.3 "$URL" >/dev/null 2>&1 \
  && bad "verified without the lane CA" || ok "a client that does not trust the lane CA cannot verify it"

sc() { # s_client args...: one handshake with the harness certificate, its output
  openssl s_client -connect "$HOST" -servername localhost -CAfile "$LANE_TLS_CA" \
    -cert "$LANE_TLS_HARNESS_CERT" -key "$LANE_TLS_HARNESS_KEY" "$@" </dev/null 2>&1
}
out=$(sc -tls1_2)
case "$out" in *"Cipher is (NONE)"*|*"alert protocol version"*|*"no protocols available"*|*"handshake failure"*) ok "TLS 1.2 is refused";; *) bad "TLS 1.2: $(echo "$out" | grep -E 'Protocol|Cipher' | head -2)";; esac
out=$(sc -tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256)
case "$out" in *"Cipher is (NONE)"*|*"handshake failure"*|*"alert"*) ok "a suite outside the profile (AES-128-GCM) is refused";; *) bad "AES-128: $(echo "$out" | grep -E 'Cipher' | head -2)";; esac
out=$(sc -tls1_3)
case "$out" in *"TLS_AES_256_GCM_SHA384"*|*"TLS_CHACHA20_POLY1305_SHA256"*) ok "the negotiated suite is in the profile";; *) bad "suite: $(echo "$out" | grep -E 'Cipher' | head -2)";; esac
if python3 -c 'import ssl,sys; sys.exit(0 if ssl.OPENSSL_VERSION_INFO[:2] >= (3,5) else 1)' && openssl list -tls-groups 2>/dev/null | grep -q X25519MLKEM768; then
  case "$out" in *"X25519MLKEM768"*) ok "the PQ hybrid group X25519MLKEM768 is negotiated";; *) bad "group: $(echo "$out" | grep -iE 'temp key|group' | head -2)";; esac
else
  skip "X25519MLKEM768 (this OpenSSL predates 3.5; a fallback group is negotiated)"
fi

# --- re_tls.py ------------------------------------------------------------------
py() { python3 - "$URL" "$CI_DIR/scripts/lib" <<'EOF'
import sys, urllib.request
sys.path.insert(0, sys.argv[2])
import re_tls
try:
    body = urllib.request.urlopen(sys.argv[1], context=re_tls.tls_context(), timeout=5).read().decode()
    print("OK" if '"instances"' in body else "BODY " + body[:80])
except re_tls.LaneTlsError as e:
    print("LANE", e)
except Exception as e:  # noqa: BLE001
    print("ERR", type(e).__name__, e)
EOF
}
out=$(py 2>&1)
[ "$out" = OK ] && ok "re_tls: on, the lane CA and harness certificate read the registry" || bad "re_tls on: $out"
out=$(RE_HARNESS_TLS_KEY="$TMP/missing.pem" py 2>&1)
case "$out" in LANE*) ok "re_tls: on with a missing file raises, no unverified fallback";; *) bad "re_tls missing: $out";; esac
out=$(RE_TLS=off RE_CA_CERT="$LANE_TLS_CA" py 2>&1)
case "$out" in ERR*) ok "re_tls: off presents no client certificate, so mTLS refuses it";; *) bad "re_tls off: $out";; esac

# install_lane_opener: a stage's plain urlopen (no context) gets the lane trust.
plain() { python3 - "$URL" "$CI_DIR/scripts/lib" <<'EOF'
import sys, urllib.request
sys.path.insert(0, sys.argv[2])
import re_tls
installed = re_tls.install_lane_opener()
try:
    body = urllib.request.urlopen(sys.argv[1], timeout=5).read().decode()
    print(("OK" if '"instances"' in body else "BODY") + (" installed" if installed else " not-installed"))
except Exception as e:  # noqa: BLE001
    print("ERR", "installed" if installed else "not-installed", type(e).__name__)
EOF
}
out=$(plain 2>&1)
[ "$out" = "OK installed" ] && ok "install_lane_opener: a plain urlopen reads the registry over mTLS" || bad "install_lane_opener on: $out"
out=$(RE_TLS=off plain 2>&1)
case "$out" in "ERR not-installed"*) ok "install_lane_opener: off installs nothing (urllib's defaults stand)";; *) bad "install_lane_opener off: $out";; esac

{ registry_stop_server; wait; } 2>/dev/null
echo "registry-tls: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
