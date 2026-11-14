#!/usr/bin/env bash
# Tests for scripts/lib/tls_proxy_lane_conf.py (RealityEngine_CI#732, #729).
#
# Offline: generates the docker lane's tls-proxy config from nginx/tls-proxy.conf
# into a temp directory and checks it. When Docker and the nginx:alpine image
# are present it also runs `nginx -t` on the result with throwaway certificates
# (no network, nothing left running); otherwise that check is skipped.
#
# Usage: bash scripts/tests/test-tls-proxy-lane-conf.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "tls-proxy lane config"
python3 "$CI_DIR/scripts/lib/tls_proxy_lane_conf.py" "$CI_DIR/nginx/tls-proxy.conf" "$TMP/lane.conf" \
  || { echo "generation failed"; exit 1; }

# The TypeScript PE's server, alone.
python3 - "$TMP/lane.conf" "$TMP/ts-pe.conf" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"server \{\n(?:(?!\n    server \{).)*?listen 3004 ssl;.*?\n    \}\n", text, flags=re.S)
open(sys.argv[2], "w").write(m.group(0) if m else "")
PY
ts="$(cat "$TMP/ts-pe.conf")"
if [[ "$ts" == *"ssl_verify_client      optional;"* && "$ts" == *"ssl_client_certificate /etc/nginx/lane/ca.crt;"* && "$ts" == *"ssl_crl                /etc/nginx/lane/ca.crl;"* ]]; then
  ok "3004 asks for the lane certificate, checked against the CA and CRL"
else
  bad "3004 client certificate directives: $ts"
fi
denies=$(grep -c 'if ($ssl_client_verify != SUCCESS) { return 403; }' "$TMP/ts-pe.conf")
if [ "$denies" -eq 2 ]; then ok "3004's / and /ws answer 403 without it"; else bad "expected 2 denials in 3004, found $denies"; fi
device="$(sed -n '/location \/api\/integrations\/healthkit\/ {/,/}/p' "$TMP/ts-pe.conf")"
if [ -n "$device" ] && [[ "$device" != *"return 403"* ]]; then ok "the HealthKit device routes take no client certificate"; else bad "device routes: $device"; fi
if [[ "$device" == *"proxy_set_header   X-Client-Certificate \$ssl_client_verify;"* ]]; then
  ok "the device routes tell the TypeScript PE what the proxy verified of the caller"
else
  bad "device routes do not forward X-Client-Certificate: $device"
fi
if [ "$(grep -c 'ssl_verify_client' "$TMP/lane.conf")" -eq 1 ]; then ok "no other server asks for a client certificate"; else bad "ssl_verify_client outside 3004"; fi

if grep -q 'proxy_pass         https://grafana:3443;' "$TMP/lane.conf"; then ok "Grafana is reached on its front's mTLS port"; else bad "Grafana upstream"; fi

if command -v docker >/dev/null 2>&1 && docker image inspect nginx:alpine >/dev/null 2>&1; then
  mkdir -p "$TMP/lane/instance"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes -days 1 -subj /CN=t \
    -keyout "$TMP/lane/instance/key.pem" -out "$TMP/lane/instance/chain.pem" 2>/dev/null
  cp "$TMP/lane/instance/chain.pem" "$TMP/lane/ca.crt"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes -days 1 -subj /CN=ca \
    -keyout "$TMP/ca.key" -out "$TMP/ca.pem" 2>/dev/null
  printf '' > "$TMP/index.txt"
  printf '[ca]\ndefault_ca=d\n[d]\ndatabase=%s/index.txt\ndefault_md=sha384\ndefault_crl_days=1\n' "$TMP" > "$TMP/ca.cnf"
  openssl ca -config "$TMP/ca.cnf" -gencrl -keyfile "$TMP/ca.key" -cert "$TMP/ca.pem" -out "$TMP/lane/ca.crl" 2>/dev/null
  cat "$TMP/ca.pem" >> "$TMP/lane/ca.crt"
  # Upstream names resolve only on the compose network; stand them in for the syntax check.
  hosts=()
  for h in perception-engine-backend reality-engine visualizer-backend visualizer-frontend \
           perception-engine-frontend grafana; do hosts+=(--add-host "$h:127.0.0.1"); done
  if out=$(docker run --rm --network none "${hosts[@]}" -v "$TMP/lane.conf:/etc/nginx/nginx.conf:ro" \
      -v "$TMP/lane:/etc/nginx/lane:ro" nginx:alpine nginx -t 2>&1); then
    ok "nginx -t accepts the lane config"
  else
    bad "nginx -t: $out"
  fi
else
  echo "  skip nginx -t: Docker or the nginx:alpine image is not available"
fi

echo "tls-proxy lane config: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
