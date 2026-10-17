#!/usr/bin/env bash
# Unit tests for release/init/reinit.py (ReleaseRoadmap C1, C2) — no Docker, no
# network. Runs `configure` against a scratch install directory, with the files
# the re-init image carries laid out from this checkout. OpenClaw's step runs
# localOpenClawStack's scripts and is skipped here (--skip-openclaw); the live
# install test covers it.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0

assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3 (expected $2, got $1)"; FAIL=$((FAIL+1)); fi
}
assert_contains() {
  case "$1" in *"$2"*) echo "  PASS: $3"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL: $3"; echo "        expected to contain: $2"; echo "        actual: $(echo "$1" | head -c 300)"; FAIL=$((FAIL+1)) ;; esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The image's /opt, from this checkout (release/init/Dockerfile).
OPT="$TMP/opt"
mkdir -p "$OPT/release/config" "$OPT/ci/scripts/lib" "$OPT/ci/config"
cp "$CI_DIR/release/compose.yml" "$CI_DIR/release/images.json" "$OPT/release/"
cp "$CI_DIR"/release/config/* "$OPT/release/config/"
cp "$CI_DIR/scripts/lib/instance_uuids.py" "$OPT/ci/scripts/lib/"
cp "$CI_DIR"/config/{integrations.example.json,loki-config.yml,grafana-datasources.yml,grafana-dashboards.yml} "$OPT/ci/config/"
cp -R "$CI_DIR/config/dashboards" "$OPT/ci/config/dashboards"

INSTALL="$TMP/install"
reinit() {
  set +e
  OUT="$(REINIT_OPT="$OPT" HOST_IP=192.0.2.10 python3 "$CI_DIR/release/init/reinit.py" "$@" 2>&1)"
  RC=$?
  set -e
}
json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$@"; }

echo "a multi-instance spec"
reinit configure --install "$INSTALL" --engines cpp:2,lsp:1,scala:1 --version dev --skip-openclaw
assert_eq "$RC" 0 "configure exits 0"
for f in compose.yml compose.engines.yml .env release.json registry/re-registry.json \
         registry/re-registry.internal.json config/integrations.json config/prometheus.yml \
         config/file_sd/reality-engine-targets.json certs/ca.crt certs/server.crt state/secrets.json \
         engines/cpp-1.env engines/cpp-2.env engines/lsp-1.env engines/scala-1.env; do
  [ -f "$INSTALL/$f" ] && { PASS=$((PASS+1)); } || { echo "  FAIL: $f was not written"; FAIL=$((FAIL+1)); }
done
echo "  PASS: every install file was written"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "[i['id'] for i in d['instances']]")" \
  "['scala-1', 'cpp-1', 'cpp-2', 'lsp-1']" "the instance registry lists every instance, in band order"

echo "ports: a band per engine type, a stride of 10 per instance, PE then RE"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "[(i['id'],i['pe_port'],i['re_port']) for i in d['instances']]")" \
  "[('scala-1', 6100, 6101), ('cpp-1', 6300, 6301), ('cpp-2', 6310, 6311), ('lsp-1', 6600, 6601)]" "host ports"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "d['instances'][2]['pe_url']")" "http://localhost:6310" "host view: localhost addresses"
assert_eq "$(json "$INSTALL/registry/re-registry.internal.json" "d['instances'][2]['pe_url']")" "http://engine-cpp-2-pe:3004" "internal view: container addresses"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "d['host']")" "192.0.2.10" "the registry's host is the Mac's LAN address"

echo "instance UUIDs (#296)"
U1="$(json "$INSTALL/registry/re-registry.json" "[i['instance_uuid'] for i in d['instances']]")"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "len(set(i['instance_uuid'] for i in d['instances']))")" 4 "four instances, four UUIDs"
assert_contains "$(cat "$INSTALL/engines/cpp-2.env")" "INSTANCE_CLOCK_DIR=/var/lib/reality-engine/clock" "the env file names the clock"
CPP2="$(json "$INSTALL/registry/re-registry.json" "d['instances'][2]['instance_uuid']")"
assert_contains "$(cat "$INSTALL/engines/cpp-2.env")" "INSTANCE_UUID=$CPP2" "and the instance's UUID"
reinit configure --install "$INSTALL" --engines cpp:2,lsp:1,scala:1 --version dev --skip-openclaw
assert_eq "$(json "$INSTALL/registry/re-registry.json" "[i['instance_uuid'] for i in d['instances']]")" "$U1" "a re-run keeps every UUID"
reinit configure --install "$INSTALL" --engines cpp:1 --version dev --skip-openclaw
assert_eq "$(json "$INSTALL/registry/re-registry.json" "[i['id'] for i in d['instances']]")" "['cpp-1']" "a smaller spec registers only its instances"
reinit configure --install "$INSTALL" --engines cpp:2,lsp:1,scala:1 --version dev --skip-openclaw
assert_eq "$(json "$INSTALL/registry/re-registry.json" "d['instances'][2]['instance_uuid']")" "$CPP2" "an instance that returns keeps its UUID"

echo "the generated engine services"
ENG="$(cat "$INSTALL/compose.engines.yml")"
for s in engine-scala-1-re engine-scala-1-pe engine-cpp-1-re engine-cpp-2-pe engine-lsp-1-re engine-lsp-1-pe; do
  assert_contains "$ENG" "  $s:" "$s"
done
assert_contains "$ENG" '"http://engine-cpp-2-re:3000"' "a PE is paired with its own RE"
assert_contains "$ENG" '"6310:3004"' "and published on its band port"
assert_contains "$ENG" '${RE_IMAGE_SCALA_PE}' "the Scala PE uses its own image"
python3 - "$INSTALL/compose.engines.yml" <<'PY' && { echo "  PASS: compose.engines.yml parses as YAML"; PASS=$((PASS+1)); } || { echo "  FAIL: compose.engines.yml is not valid YAML"; FAIL=$((FAIL+1)); }
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
d = yaml.safe_load(open(sys.argv[1]))
assert len(d["services"]) == 8, d["services"].keys()
PY

echo "Prometheus targets follow the spec"
assert_eq "$(json "$INSTALL/config/file_sd/perception-engine-targets.json" "[t['targets'][0] for t in d]")" \
  "['engine-scala-1-pe:3004', 'engine-cpp-1-pe:3004', 'engine-cpp-2-pe:3004', 'engine-lsp-1-pe:3004']" "PE targets"
assert_eq "$(json "$INSTALL/config/file_sd/reality-engine-targets.json" "d[1]['labels']['instance']")" "cpp-1" "labelled by instance"

echo ".env, secrets and certificates"
ENV="$(cat "$INSTALL/.env")"
assert_contains "$ENV" "COMPOSE_FILE=compose.yml:compose.engines.yml" "COMPOSE_FILE joins both files"
assert_contains "$ENV" "RE_IMAGE_CPP=ghcr.io/jateeter/re-cpp:dev" "without an images file, images are by tag"
assert_contains "$ENV" "HEALTHKIT_PE_SCOPE_URLS=http://engine-scala-1-pe:3004,http://engine-cpp-1-pe:3004" "PIM reaches every PE"
assert_eq "$(stat -f %Lp "$INSTALL/.env" 2>/dev/null || stat -c %a "$INSTALL/.env")" 600 ".env is 0600"
S1="$(json "$INSTALL/state/secrets.json" "d['OPENCLAW_GATEWAY_TOKEN']")"
reinit configure --install "$INSTALL" --engines cpp:1 --version dev --skip-openclaw
assert_eq "$(json "$INSTALL/state/secrets.json" "d['OPENCLAW_GATEWAY_TOKEN']")" "$S1" "secrets are generated once and kept"
SAN="$(openssl x509 -in "$INSTALL/certs/server.crt" -noout -ext subjectAltName)"
assert_contains "$SAN" "IP Address:192.0.2.10" "the certificate covers the LAN address"
assert_contains "$SAN" "DNS:visualizer-backend" "and the TLS backend's name"
openssl verify -CAfile "$INSTALL/certs/ca.crt" "$INSTALL/certs/server.crt" >/dev/null 2>&1 \
  && { echo "  PASS: signed by the install's CA"; PASS=$((PASS+1)); } || { echo "  FAIL: not signed by the CA"; FAIL=$((FAIL+1)); }

echo "an images file pins by digest"
cat > "$TMP/images.json" <<'J'
{"images": [{"name": "re-cpp", "ref": "ghcr.io/jateeter/re-cpp", "digest": "sha256:aaaa"}]}
J
reinit configure --install "$INSTALL" --engines cpp:1 --version release-v0.0.1 --images "$TMP/images.json" --skip-openclaw
assert_contains "$(cat "$INSTALL/.env")" "RE_IMAGE_CPP=ghcr.io/jateeter/re-cpp@sha256:aaaa" "a digest from the images file"
assert_contains "$(cat "$INSTALL/.env")" "RE_IMAGE_LSP=ghcr.io/jateeter/re-lsp:release-v0.0.1" "others fall back to the version tag"

echo "bad specs are refused"
for bad in "cpp" "rust:1" "cpp:21" "cpp:1,cpp:2" "cpp:0" ""; do
  reinit configure --install "$TMP/bad" --engines "$bad" --version dev --skip-openclaw
  assert_eq "$RC" 1 "refused: '$bad'"
done

echo "the integration registry uses container addresses"
INT="$(cat "$INSTALL/config/integrations.json")"
case "$INT" in *"localhost:4000"*) echo "  FAIL: integrations.json still names localhost:4000"; FAIL=$((FAIL+1)) ;;
  *) echo "  PASS: no host address left"; PASS=$((PASS+1)) ;; esac
assert_contains "$INT" "ws://openclaw-gateway:18789" "the ACP gateway is the container"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
