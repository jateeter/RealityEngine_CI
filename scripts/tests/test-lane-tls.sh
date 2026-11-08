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

# --- the docker lane ------------------------------------------------------------
# Its own PKI and instance state, both temporary. Docker itself is not used here:
# the links are what docker-compose.yml mounts.
export RE_INSTANCE_STATE_DIR="$TMP/state"
SAVED_PKI_DIR="$RE_PKI_DIR"; export RE_PKI_DIR="$TMP/pki-docker"
T="$RE_INSTANCE_STATE_DIR/docker/tls"
RE_TLS=off
mkdir -p "$T/cpp-1"   # what Docker leaves when it bind-mounts a missing source
lane_tls_init docker 2>/dev/null && lane_tls_docker_instance cpp-1 cpp "$UUID" 192.0.2.10 \
  && ok "docker off: issued" || bad "docker off: issue"
[ -L "$T/cpp-1" ] && [ -f "$T/cpp-1/key.pem" ] && [ -f "$T/cpp-1/chain.pem" ] && ok "docker: tls/<id> links to the instance's issued directory (an empty Docker-made directory is replaced)" || bad "docker: tls/cpp-1 link"
[ -L "$T/ca.crt" ] && [ "$(readlink "$T/ca.crt")" = "$LANE_TLS_CA" ] && [ -L "$T/ca.crl" ] && ok "docker: tls/ca.crt and ca.crl link to the lane CA and CRL" || bad "docker: CA links"
[ ! -e "$T/ca.key" ] && [ ! -e "$T/cpp-1/ca.key" ] && ok "docker: the CA key is not linked" || bad "docker: CA key exposed"
grep -q '^RE_TLS_' "$RE_INSTANCE_STATE_DIR/docker/cpp-1.tls.env" && bad "docker off: RE_TLS_* in the env file" || ok "docker off: the env file carries no RE_TLS_*"
text=$(openssl x509 -in "$T/cpp-1/cert.pem" -noout -text)
for want in "DNS:engine-cpp-re" "DNS:engine-cpp-pe" "DNS:host.docker.internal" "IP Address:192.0.2.10" "URI:urn:uuid:$UUID"; do
  case "$text" in *"$want"*) ok "docker: the certificate covers $want";; *) bad "docker: SAN $want";; esac
done
[ "$(openssl verify -CAfile "$T/ca.crt" "$T/cpp-1/cert.pem" 2>&1)" = "$T/cpp-1/cert.pem: OK" ] \
  && ok "docker: issued by the docker lane CA" || bad "docker: not verified by its lane CA"
[ "$(openssl x509 -in "$T/ca.crt" -noout -fingerprint)" != "$(openssl x509 -in "$SAVED_PKI_DIR/ca/ca.crt" -noout -fingerprint)" ] \
  && ok "docker: its CA is not the native lane's" || bad "docker: shares the native CA"
RE_TLS=on
lane_tls_init docker 2>/dev/null && lane_tls_docker_instance cpp-1 cpp "$UUID" 192.0.2.10 && ok "docker on: issued" || bad "docker on: issue"
env_text=$(cat "$RE_INSTANCE_STATE_DIR/docker/cpp-1.tls.env")
case "$env_text" in *"RE_TLS_CERT=/run/re-tls/instance/chain.pem"*"RE_TLS_KEY=/run/re-tls/instance/key.pem"*"RE_TLS_CA=/run/re-tls/ca.crt"*"RE_TLS_CRL=/run/re-tls/ca.crl"*)
  ok "docker on: the env file carries RE_TLS_* as container paths";; *) bad "docker on: env file: $env_text";; esac
rm -f "$T/ca.crl"; echo not-a-link > "$T/ca.crl"
lane_tls_docker_instance cpp-1 cpp "$UUID" 192.0.2.10 2>/dev/null && bad "docker on: a file in a link's place was overwritten" || ok "docker on: a file in a link's place is refused, not overwritten"
export RE_PKI_DIR="$SAVED_PKI_DIR"; unset RE_INSTANCE_STATE_DIR

# --- localAIStack's overlay and Ollama's front (localAIStack#172) --------------
export RE_INSTANCE_STATE_DIR="$TMP/state-localai"
L="$RE_INSTANCE_STATE_DIR/localai/tls"
RE_TLS=off
lane_tls_init native 2>/dev/null
lane_tls_localai 192.0.2.10 && [ -z "$LANE_TLS_LOCALAI_DIR" ] && [ ! -e "$L" ] && ok "localai off: nothing issued or linked" || bad "localai off: dir=$LANE_TLS_LOCALAI_DIR"
[ "$(lane_ollama_url host)" = "$(lane_tls_scheme)://localhost:11434" ] && [ "$(lane_ollama_url docker)" = "$(lane_tls_scheme)://host.docker.internal:11434" ] \
  && [ "$(lane_tls_scheme)" = http ] && ok "ollama off: Ollama itself" || bad "ollama off: $(lane_ollama_url host) $(lane_ollama_url docker)"
RE_TLS=on
lane_tls_init native 2>/dev/null
lane_tls_localai 192.0.2.10 && [ "$LANE_TLS_LOCALAI_DIR" = "$L" ] && ok "localai on: issued" || bad "localai on: issue"
for svc in api qdrant redis; do
  [ -L "$L/$svc" ] && [ -f "$L/$svc/chain.pem" ] && [ -f "$L/$svc/key.pem" ] && ok "localai on: $svc/ links to its certificate" || bad "localai on: $svc/"
done
[ -L "$L/ca.crt" ] && [ -L "$L/ca.crl" ] && ok "localai on: CA and CRL linked" || bad "localai on: CA/CRL"
[ -e "$L/ca.key" ] || [ -e "$L/ca" ] && bad "localai on: the CA directory is exposed" || ok "localai on: no CA key in the overlay directory"
sans=$(openssl x509 -in "$L/api/cert.pem" -noout -ext subjectAltName 2>/dev/null)
case "$sans" in *"DNS:api"*"DNS:localai_api"*"DNS:host.docker.internal"*"IP Address:192.0.2.10"*) ok "localai on: the API certificate names its compose, container and host addresses" ;; *) bad "localai on: API SANs: $sans" ;; esac
openssl x509 -in "$L/redis/cert.pem" -noout -ext extendedKeyUsage 2>/dev/null | grep -q "TLS Web Client Authentication" \
  && ok "localai on: service certificates also call (their own healthchecks)" || bad "localai on: redis certificate lacks clientAuth"
[ "$(lane_ollama_url host)" = https://localhost:11443 ] && [ "$(lane_ollama_url docker)" = https://host.docker.internal:11443 ] \
  && ok "ollama on: the front" || bad "ollama on: $(lane_ollama_url host) $(lane_ollama_url docker)"
lane_tls_ollama_front_start "$TMP/no-localaistack" 2>/dev/null && bad "front: started without its script" || ok "front: a missing localAIStack is refused"
LANE_OLLAMA_FRONT_PID_FILE="$TMP/front.pid"; echo $$ > "$LANE_OLLAMA_FRONT_PID_FILE"
lane_tls_ollama_front_stop; kill -0 $$ 2>/dev/null && [ ! -e "$LANE_OLLAMA_FRONT_PID_FILE" ] \
  && ok "front stop: a pid file naming another process kills nothing" || bad "front stop"
unset RE_INSTANCE_STATE_DIR

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
