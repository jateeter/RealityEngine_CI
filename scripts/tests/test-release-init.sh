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
cp "$CI_DIR/release/compose.yml" "$CI_DIR/release/images.json" "$CI_DIR/release/ollama-tls-front.mjs" "$OPT/release/"
cp "$CI_DIR"/release/config/* "$OPT/release/config/"
cp "$CI_DIR/scripts/lib/instance_uuids.py" "$CI_DIR/scripts/lib/re_pki.py" "$CI_DIR/scripts/lib/re_tls_server.py" \
   "$CI_DIR/scripts/lib/tls_proxy_lane_conf.py" "$CI_DIR/scripts/lib/obs_front_conf.py" "$OPT/ci/scripts/lib/"
cp "$CI_DIR"/config/{transport-profile.json,prometheus-web.lane.yml,prometheus-health.lane.yml,grafana-datasources.lane.yml} "$OPT/ci/config/"
mkdir -p "$OPT/ci/mcp/src" && cp "$CI_DIR/mcp/src/lane-tls.js" "$OPT/ci/mcp/src/"
cp "$CI_DIR/scripts/bridge-metrics-exporter.mjs" "$OPT/ci/scripts/"
cp "$CI_DIR"/config/{integrations.example.json,loki-config.yml,grafana-datasources.yml,grafana-dashboards.yml} "$OPT/ci/config/"
cp -R "$CI_DIR/config/dashboards" "$OPT/ci/config/dashboards"
# localAssetStorageStack's files (the init image's `assets` build context).
LASS="$CI_DIR/../localAssetStorageStack"
mkdir -p "$OPT/assets/scripts" "$OPT/assets/lifecycle" "$OPT/assets/css"
cp "$LASS/scripts/accounts.js" "$LASS/scripts/grant-assets.js" "$OPT/assets/scripts/"
cp -R "$LASS/scripts/lib" "$OPT/assets/scripts/lib"
cp -R "$LASS/lifecycle/src" "$OPT/assets/lifecycle/src"
cp "$LASS/css/config.json" "$OPT/assets/css/"

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
assert_eq "$(json "$INSTALL/registry/re-registry.json" "d['instances'][2]['pe_url']")" "https://localhost:6310" "host view: localhost addresses, https by default (#729)"
assert_eq "$(json "$INSTALL/registry/re-registry.internal.json" "d['instances'][2]['pe_url']")" "https://engine-cpp-2-pe:3004" "internal view: container addresses"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "d['host']")" "192.0.2.10" "the registry's host is the Mac's LAN address"

echo "the services block is the native instance registry's contract"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "sorted(d['services'])")" \
  "['localai_api', 'manager_backend', 'manager_frontend', 'mcp', 'openclaw_gateway', 'qdrant', 'registry']" "host view service names"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "d['services']['localai_api']")" \
  "{'url': 'http://localhost:4000', 'port': 4000}" "each service is {url, port}"
assert_eq "$(json "$INSTALL/registry/re-registry.internal.json" "d['services']['localai_api']['url']")" \
  "http://localai-api:8000" "internal view: container address"

echo "instance UUIDs (#296)"
U1="$(json "$INSTALL/registry/re-registry.json" "[i['instance_uuid'] for i in d['instances']]")"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "len(set(i['instance_uuid'] for i in d['instances']))")" 4 "four instances, four UUIDs"
assert_contains "$(cat "$INSTALL/engines/cpp-2.env")" "INSTANCE_CLOCK_DIR=/var/lib/reality-engine/clock" "the env file names the clock"
assert_contains "$(cat "$INSTALL/engines/cpp-2.env")" "MQTT_CLIENT_ID=re-pe-cpp-2-" "the env file names the PE's MQTT client id"
assert_eq "$(cat "$INSTALL"/engines/*.env | grep -c '^MQTT_CLIENT_ID=')" 4 "every instance has an MQTT client id"
assert_eq "$(cat "$INSTALL"/engines/*.env | grep '^MQTT_CLIENT_ID=' | sort -u | wc -l | tr -d ' ')" 4 "no two PEs share an MQTT client id"
CPP2="$(json "$INSTALL/registry/re-registry.json" "d['instances'][2]['instance_uuid']")"
assert_contains "$(cat "$INSTALL/engines/cpp-2.env")" "INSTANCE_UUID=$CPP2" "and the instance's UUID"
# Each PE is a participant of its own (#600): its UUID, distinct from every RE's.
CPP2PE="$(json "$INSTALL/registry/re-registry.json" "d['instances'][2]['pe_uuid']")"
assert_contains "$(cat "$INSTALL/engines/cpp-2.pe.env")" "PE_INSTANCE_UUID=$CPP2PE" "the PE env file names the PE's UUID"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "len(set([i['instance_uuid'] for i in d['instances']] + [i['pe_uuid'] for i in d['instances']]))")" 8 "four REs and four PEs, eight UUIDs"
assert_eq "$(python3 "$CI_DIR/scripts/lib/instance_uuids.py" check-registry "$INSTALL/registry/re-registry.json" >/dev/null 2>&1; echo $?)" 0 "the instance registry passes check-registry"
assert_contains "$(cat "$INSTALL/compose.engines.yml")" "cpp-2.pe.env" "the PE service loads its env file"
LOCALAI_UUID="$(sed -n 's/^LOCALAI_INSTANCE_UUID=//p' "$INSTALL/engines/localai.env")"
assert_eq "$(python3 -c "import uuid,sys; print(str(uuid.UUID(sys.argv[1])) == sys.argv[1])" "$LOCALAI_UUID" 2>/dev/null)" "True" \
  "localAI gets its clock participant UUID (localAIStack#140)"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "'$LOCALAI_UUID' in [i['instance_uuid'] for i in d['instances']] + [i['pe_uuid'] for i in d['instances']]")" \
  "False" "localAI's UUID is no engine participant's"
assert_contains "$(cat "$INSTALL/compose.engines.yml")" "localai.env" "the localAI service loads its env file"
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
assert_contains "$ENG" '"https://engine-cpp-2-re:3000"' "a PE is paired with its own RE"
assert_contains "$ENG" '"6310:3004"' "and published on its band port"
assert_contains "$ENG" '${RE_IMAGE_SCALA_PE}' "the Scala PE uses its own image"
assert_eq "$(grep -c 'OLLAMA_BASE_URL.*https://host.docker.internal:11443' "$INSTALL/compose.engines.yml")" 4 \
  "every PE reaches native Ollama on the host through its TLS front (TLS on by default)"
assert_contains "$(cat "$INSTALL/ollama-front/profile.env" 2>/dev/null)" "RE_TLS_GROUPS=X25519MLKEM768" "the front serves the profile's groups"
python3 - "$INSTALL/compose.engines.yml" <<'PY' && { echo "  PASS: compose.engines.yml parses as YAML"; PASS=$((PASS+1)); } || { echo "  FAIL: compose.engines.yml is not valid YAML"; FAIL=$((FAIL+1)); }
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
d = yaml.safe_load(open(sys.argv[1]))
# Four instances' RE and PE, localAI, and Manager's TypeScript PE with its own RE.
assert len(d["services"]) == 11, d["services"].keys()
assert {"ts-pe-re", "perception-engine-backend"} <= set(d["services"])
assert set(d["services"]["localai-api"]["depends_on"]) == {s for s in d["services"] if s.endswith("-pe")}
PY

echo "Prometheus targets follow the spec"
assert_eq "$(json "$INSTALL/config/file_sd/perception-engine-targets.json" "[t['targets'][0] for t in d]")" \
  "['engine-scala-1-pe:3004', 'engine-cpp-1-pe:3004', 'engine-cpp-2-pe:3004', 'engine-lsp-1-pe:3004']" "PE targets"
assert_eq "$(json "$INSTALL/config/file_sd/reality-engine-targets.json" "d[1]['labels']['instance']")" "cpp-1" "labelled by instance"

echo ".env, secrets and certificates"
ENV="$(cat "$INSTALL/.env")"
assert_contains "$ENV" "COMPOSE_FILE=compose.yml:compose.engines.yml:compose.assets.yml:compose.tls.yml" "COMPOSE_FILE joins the files, the TLS overlay by default"
assert_contains "$ENV" "RE_IMAGE_CPP=ghcr.io/jateeter/re-cpp:dev" "without an images file, images are by tag"
assert_contains "$ENV" "HEALTHKIT_PE_SCOPE_URLS=https://engine-scala-1-pe:3004,https://engine-cpp-1-pe:3004" "PIM reaches every PE"
# GNU stat first: on Linux, BSD `stat -f` is a filesystem query that succeeds.
assert_eq "$(stat -c %a "$INSTALL/.env" 2>/dev/null || stat -f %Lp "$INSTALL/.env")" 600 ".env is 0600"
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
assert_contains "$INT" "wss://host.docker.internal:18789" "the ACP gateway is the Mac's native gateway, reached from the containers"

echo
# ── The gateway is native: no gateway image, and the CDP port is allocated ───
assert_eq "$(python3 -c 'import json,sys; print(any(i["name"]=="re-openclaw-gateway" for i in json.load(open(sys.argv[1]))["images"]))' "$CI_DIR/release/images.json")" "False" "images.json has no gateway image"
assert_eq "$(grep -c '^  openclaw-gateway:' "$CI_DIR/release/compose.yml" || true)" "0" "compose.yml has no gateway service"
assert_contains "$(cat "$CI_DIR/release/compose.yml")" '127.0.0.1:${RE_PORT_BROWSER_CDP:-9222}:9223' "the browser publishes CDP on loopback only"


echo "the Grafana dashboards have data in a release install"
# rc3 showed No Data on four dashboards: their Loki panels selected only the
# native lane's source="host" while the release's Promtail labels its streams
# source="compose", and the AI bridge metrics came from an exporter only the
# native lane ran.
assert_eq "$(grep -l 'source=\\"host\\"' "$INSTALL"/config/dashboards/*.json 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "no dashboard selects the native lane's log streams alone"
assert_contains "$(cat "$INSTALL/config/promtail.yml")" "replacement: compose" "the release's Promtail labels its streams source=compose"
assert_eq "$([ -f "$INSTALL/config/bridge-metrics-exporter.mjs" ] && echo yes || echo no)" "yes" "re-init writes the bridge exporter"
assert_contains "$(cat "$INSTALL/config/prometheus.yml")" "bridge-metrics:7342" "Prometheus scrapes the bridge exporter"
assert_contains "$(cat "$INSTALL/compose.yml")" "./config/bridge-metrics-exporter.mjs:/opt/bridge/bridge-metrics-exporter.mjs:ro" \
  "the bridge-metrics service runs it"
assert_contains "$(cat "$CI_DIR/release/init/Dockerfile")" "COPY scripts/bridge-metrics-exporter.mjs /opt/ci/scripts/" \
  "the re-init image carries it"

echo "lane certificates (#729): issued on every configure, used only with --tls on"
reinit configure --install "$INSTALL" --engines cpp:2,lsp:1,scala:1 --version dev --skip-openclaw --tls off
assert_eq "$RC" 0 "configure --tls off exits 0"
[ -f "$INSTALL/pki/ca/ca.crt" ] && [ -f "$INSTALL/pki/issued/cpp-2/chain.pem" ] && [ -f "$INSTALL/pki/issued/registry/chain.pem" ] \
  && [ -f "$INSTALL/pki/issued/manager/chain.pem" ] && [ -f "$INSTALL/pki/issued/harness/cert.pem" ]
assert_eq "$?" 0 "the install CA and every certificate are issued with TLS off"
assert_eq "$(grep -c RE_TLS_CERT "$INSTALL/compose.engines.yml" || true)" 0 "TLS off: no engine carries RE_TLS_*"
uuid="$(json "$INSTALL/release.json" "[i['instance_uuid'] for i in d['instances'] if i['id']=='cpp-2'][0]")"
[ -n "$uuid" ]; assert_eq "$?" 0 "cpp-2 has an instance UUID"
assert_contains "$(openssl x509 -in "$INSTALL/pki/issued/cpp-2/cert.pem" -noout -ext subjectAltName)" \
  "URI:urn:uuid:$uuid" "an instance certificate carries its urn:uuid"
assert_contains "$(openssl x509 -in "$INSTALL/pki/issued/cpp-2/cert.pem" -noout -ext subjectAltName)" "DNS:engine-cpp-2-re" \
  "and its compose service names"
reinit configure --install "$INSTALL" --engines cpp:2,lsp:1,scala:1 --version dev --skip-openclaw --tls on
assert_eq "$RC" 0 "configure --tls on exits 0"
assert_contains "$(cat "$INSTALL/compose.engines.yml")" "RE_TLS_CERT" "TLS on: the engines carry RE_TLS_*"
assert_contains "$(cat "$INSTALL/compose.engines.yml")" "./pki/issued/cpp-2:/run/re-tls/instance:ro" "each mounts its own certificate"
assert_eq "$(grep -c 'pki/ca/ca.key' "$INSTALL/compose.engines.yml" "$INSTALL/compose.tls.yml" | awk -F: '{s+=$2} END {print s}')" 0 "the CA key is mounted nowhere"
assert_contains "$(cat "$INSTALL/compose.engines.yml")" "https://engine-cpp-2-re:3000" "a PE reaches its RE over https"
assert_contains "$(cat "$INSTALL/compose.engines.yml")" "--certificate=/run/re-tls/instance/chain.pem" "health checks present the certificate"
assert_contains "$(cat "$INSTALL/.env")" "COMPOSE_FILE=compose.yml:compose.engines.yml:compose.assets.yml:compose.tls.yml" "the TLS overlay is in COMPOSE_FILE"
assert_contains "$(cat "$INSTALL/.env")" "RE_TLS=on" ".env records the switch"
assert_contains "$(cat "$INSTALL/compose.tls.yml")" "registry" "the instance registry serves TLS"
# Rust, a follower (owner, 2026-11-12): in the instance registry with
# role follower, on its own band; a spec of followers alone starts no vote.
reinit configure --install "$TMP/rust" --engines cpp:1,lsp:1,scala:1,rust:1 --version dev --skip-openclaw
assert_eq "$RC" 0 "a spec with rust:1 configures"
assert_eq "$(python3 -c "import json; print([(i['id'], i.get('role', 'voter'), i['pe_port']) for i in json.load(open('$TMP/rust/registry/re-registry.json'))['instances'] if i['runtime']=='rust'])")" "[('rust-1', 'follower', 6900)]" "rust-1 is a follower on 6900"
assert_contains "$(cat "$TMP/rust/compose.engines.yml")" "/app/bin/perception-engine" "rust-1's PE runs from re-rust"
reinit configure --install "$TMP/rustonly" --engines rust:1 --version dev --skip-openclaw
assert_eq "$RC" 1 "a spec of followers alone is refused"

# The asset storage stack and Rust (owner, 2026-11-12).
ASSETSY="$(cat "$INSTALL/compose.assets.yml" 2>/dev/null)"
assert_contains "$ASSETSY" "solidproject/community-server:7.3.0@sha256:" "assets-css runs the pinned upstream CSS"
assert_contains "$ASSETSY" "RE_IMAGE_DOKIELI" "assets-dokieli runs the release image"
assert_contains "$ASSETSY" "RE_IMAGE_LIFECYCLE" "the lifecycle runs the release image"
assert_contains "$ASSETSY" "assets-grant" "a one-shot grants the lifecycle its access"
assert_contains "$ASSETSY" "LIFECYCLE_URL" "Manager's instantiation reaches the lifecycle"
assert_contains "$(cat "$INSTALL/.env")" "COMPOSE_FILE=compose.yml:compose.engines.yml:compose.assets.yml" "the asset stack is in COMPOSE_FILE"
assert_contains "$(cat "$INSTALL/assets/runtime/registry.json" 2>/dev/null)" "https://lifecycle:8443/" "the stack's service file names the lifecycle"
assert_eq "$([ -f "$INSTALL/assets/scripts/grant-assets.js" ] && echo yes)" yes "the provisioning scripts are in the install"
# Every relative import of the install's asset scripts resolves inside the
# install: grant-assets.js imported scripts/lib/secrets-home.js, which neither
# the image nor the install carried, and assets-grant failed on the first line
# of e1-rc1-cert-20261119c.
MISSING="$(node -e '
const fs = require("fs"), path = require("path");
const root = process.argv[1], seen = new Set(), missing = [];
const walk = (f) => {
  if (seen.has(f)) return; seen.add(f);
  if (!fs.existsSync(f)) { missing.push(path.relative(root, f)); return; }
  const src = fs.readFileSync(f, "utf8");
  for (const m of src.matchAll(/(?:from\s+|import\s*\(\s*)["\x27](\.{1,2}\/[^"\x27]+)["\x27]/g)) walk(path.resolve(path.dirname(f), m[1]));
};
for (const n of ["accounts.js", "grant-assets.js"]) walk(path.join(root, "scripts", n));
console.log(missing.join(" "));
' "$INSTALL/assets")"
assert_eq "$MISSING" "" "every relative import of the install's asset scripts is in the install"
# assets-grant finds the accounts where the install keeps them: the directory
# the install's own secrets-home.js resolves from the service's environment is
# the mount of ./assets/.secrets. It resolved /root/.reality-engine/secrets/
# localAssetStorageStack, which nothing mounted (e1-rc2-cert-20261119a).
GRANT_HOME="$(python3 -c '
import json, sys, yaml
svc = yaml.safe_load(open(sys.argv[1]))["services"]["assets-grant"]
print(json.dumps(svc.get("environment") or {}))' "$INSTALL/compose.assets.yml" \
  | HOME=/root node --input-type=module -e '
let s = ""; for await (const c of process.stdin) s += c;
const { secretsHome } = await import(process.argv[1]);
console.log(secretsHome({ HOME: "/root", ...JSON.parse(s) }));' "$INSTALL/assets/scripts/lib/secrets-home.js")"
GRANT_MOUNT="$(python3 -c '
import sys, yaml
svc = yaml.safe_load(open(sys.argv[1]))["services"]["assets-grant"]
print(next((v.split(":")[1] for v in svc.get("volumes", []) if v.split(":")[0] == "./assets/.secrets"), ""))' "$INSTALL/compose.assets.yml")"
assert_eq "$GRANT_HOME" "$GRANT_MOUNT" "assets-grant's secrets home is the mount of the install's assets/.secrets"
# The Go observability services behind OpenSSL fronts (#729).
TLSY="$(cat "$INSTALL/compose.tls.yml")"
assert_contains "$TLSY" "service:loki" "Loki's front shares its network namespace"
assert_contains "$TLSY" "service:grafana" "Grafana's front shares its network namespace"
assert_contains "$TLSY" "127.0.0.1:9091" "Prometheus listens on its container's loopback"
assert_contains "$(cat "$INSTALL/config/fronts/loki.conf" 2>/dev/null)" "ssl_verify_client      on;" "Loki's front requires the lane certificate"
assert_contains "$(cat "$INSTALL/compose.tls.yml")" "https://registry:8000/re-registry.internal.json" "Manager reads the registry over https"
assert_contains "$(cat "$INSTALL/compose.tls.yml")" "./pki/issued/manager:/run/re-tls/instance:ro" "Manager carries its lane certificate"
assert_contains "$(cat "$INSTALL/config/nginx.lane.conf")" "ssl_protocols       TLSv1.3;" "tls-proxy's lane config: TLS 1.3 only"
# PIM's device listener for the iPhone (PIM#91, #808): TLS on only, on every
# interface (no 127.0.0.1 bind), with the lane certificate naming the LAN IP.
PIM_TLS="$(python3 -c '
import json, sys, yaml
print(json.dumps(yaml.safe_load(open(sys.argv[1]))["services"]["pim"]))' "$INSTALL/compose.tls.yml")"
assert_contains "$PIM_TLS" '"PIM_DEVICE_PORT": "8443"' "PIM opens its device listener on the lane"
assert_contains "$PIM_TLS" '"${RE_PORT_PIM_DEVICE:-8091}:8443"' "and publishes it on every interface"
assert_contains "$(cat "$INSTALL/.env")" "RE_PORT_PIM_DEVICE=8091" "the device port is an install port"
assert_eq "$(grep -c 'PIM_DEVICE_PORT' "$INSTALL/compose.yml" 2>/dev/null || true)" "0" "the plaintext base never opens it"
assert_eq "$(grep -c 'certs/server' "$INSTALL/config/nginx.lane.conf")" 0 "and not the legacy certificate"
assert_eq "$(json "$INSTALL/registry/re-registry.json" "d['instances'][2]['pe_url']")" "https://localhost:6310" "host view: https"
assert_eq "$(json "$INSTALL/registry/re-registry.internal.json" "d['services']['registry']['url']")" "https://registry:8000" "internal view: https registry"
assert_eq "$(json "$INSTALL/release.json" "d['tls']['enabled']")" "True" "release.json records TLS on"
assert_eq "$(json "$INSTALL/release.json" "d['tls']['profile']")" "re-transport-2026.11" "and the profile it runs under"
reinit configure --install "$INSTALL" --engines cpp:2,lsp:1,scala:1 --version dev --skip-openclaw --tls off
[ ! -f "$INSTALL/compose.tls.yml" ]; assert_eq "$?" 0 "turning TLS off removes the overlay"
reinit configure --install "$TMP/fresh-tls" --engines cpp:1 --version dev --skip-openclaw --tls on
assert_eq "$RC" 0 "a fresh install configures with --tls on"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
