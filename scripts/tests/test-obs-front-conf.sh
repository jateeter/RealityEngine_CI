#!/usr/bin/env bash
# Tests for scripts/lib/obs_front_conf.py (RealityEngine_CI#729): the OpenSSL
# fronts of Loki, Prometheus and Grafana.
#
# Offline: generates the three configurations into a temp directory and checks
# them against config/transport-profile.json. When Docker and the release's
# nginx image are present it also runs `nginx -t` on each with throwaway
# certificates (--network none, nothing left running); otherwise that check is
# skipped.
#
# Usage: bash scripts/tests/test-obs-front-conf.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
NGINX="nginx:1.29-alpine@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de"

echo "observability fronts"
python3 "$CI_DIR/scripts/lib/obs_front_conf.py" "$TMP/fronts" || { echo "generation failed"; exit 1; }
suites=$(python3 -c "import json; print(':'.join(json.load(open('$CI_DIR/config/transport-profile.json'))['tls']['cipherSuites']))")

for svc in loki prometheus grafana; do
  f="$TMP/fronts/$svc.conf"
  if [ -f "$f" ] && grep -q "ssl_protocols       TLSv1.3;" "$f" && grep -q "Ciphersuites $suites;" "$f" \
     && grep -q "proxy_ssl_conf_command        Ciphersuites $suites;" "$f"; then
    ok "$svc: TLS 1.3 at the profile's suites, toward the client and toward $svc"
  else
    bad "$svc: profile directives missing in $f"
  fi
done
mtls() { grep -c "ssl_verify_client      on;" "$TMP/fronts/$1.conf"; }
if [ "$(mtls loki)" -eq 1 ] && [ "$(mtls prometheus)" -eq 1 ]; then ok "Loki and Prometheus require the lane certificate"; else bad "Loki/Prometheus mTLS"; fi
if [ "$(mtls grafana)" -eq 1 ] && grep -q "listen 3000 ssl;" "$TMP/fronts/grafana.conf" && grep -q "listen 3443 ssl;" "$TMP/fronts/grafana.conf"; then
  ok "Grafana: 3000 for browsers (server TLS), 3443 with mTLS"
else
  bad "Grafana listeners"
fi
if grep -q "proxy_pass                    https://127.0.0.1:3101;" "$TMP/fronts/loki.conf"; then ok "Loki's front reaches it on the container's loopback over TLS"; else bad "Loki upstream"; fi

if command -v docker >/dev/null 2>&1 && docker image inspect "$NGINX" >/dev/null 2>&1; then
  mkdir -p "$TMP/tls/service"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes -days 1 -subj /CN=ca \
    -keyout "$TMP/ca.key" -out "$TMP/tls/ca.crt" 2>/dev/null
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes -days 1 -subj /CN=svc \
    -keyout "$TMP/tls/service/key.pem" -out "$TMP/tls/service/chain.pem" 2>/dev/null
  printf '' > "$TMP/index.txt"
  printf '[ca]\ndefault_ca=d\n[d]\ndatabase=%s/index.txt\ndefault_md=sha384\ndefault_crl_days=1\n' "$TMP" > "$TMP/ca.cnf"
  openssl ca -config "$TMP/ca.cnf" -gencrl -keyfile "$TMP/ca.key" -cert "$TMP/tls/ca.crt" -out "$TMP/tls/ca.crl" 2>/dev/null
  for svc in loki prometheus grafana; do
    if out=$(docker run --rm --network none -v "$TMP/fronts/$svc.conf:/etc/nginx/nginx.conf:ro" \
        -v "$TMP/tls:/run/re-tls:ro" "$NGINX" nginx -t 2>&1); then
      ok "nginx -t accepts $svc's front"
    else
      bad "nginx -t $svc: $out"
    fi
  done
else
  echo "  skip nginx -t: Docker or $NGINX is not available"
fi

echo "observability fronts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
