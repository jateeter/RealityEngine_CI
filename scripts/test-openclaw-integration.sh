#!/usr/bin/env bash
#
# Validate the OpenClaw PE integration contract against a running engine PE.
#
# Defaults target the CI TLS proxy. Override PE_URL to point at CPP, Scala, or
# LSP PE instances directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PE_URL="${PE_URL:-https://localhost:3004}"
PE_URL="${PE_URL%/}"
AGENT_ID="${OPENCLAW_AGENT_ID:-hello-world}"
SOURCE_MAPPING_ID="${ACP_COMPLETION_SOURCE_MAPPING_ID:-acp-openclaw-completion}"
SENSOR_ID="acp.openclaw.${AGENT_ID}.completion"
TMP_DIR="$(mktemp -d -t re-openclaw-e2e.XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

curl_json() {
  local method="$1" url="$2" body="${3:-}"
  local out="$TMP_DIR/response.json" code
  if [ -n "$body" ]; then
    code="$(curl -sk --max-time 15 -o "$out" -w "%{http_code}" \
      -X "$method" "$url" -H "content-type: application/json" --data "$body" || true)"
  else
    code="$(curl -sk --max-time 15 -o "$out" -w "%{http_code}" -X "$method" "$url" || true)"
  fi
  printf '%s\n' "$code"
}

assert_2xx() {
  local code="$1" label="$2"
  case "$code" in
    2*) printf '[pass] %s (%s)\n' "$label" "$code" ;;
    *)  printf '[fail] %s (%s)\n' "$label" "$code" >&2
        sed 's/^/  /' "$TMP_DIR/response.json" >&2
        return 1 ;;
  esac
}

printf '[info] PE URL: %s\n' "$PE_URL"

code="$(curl_json GET "$PE_URL/api/integrations/acp/status")"
assert_2xx "$code" "ACP status endpoint"
cp "$TMP_DIR/response.json" "$TMP_DIR/acp-status.json"

dispatch_body=$(printf '{"dispatchId":"openclaw-e2e-placeholder","targetAgent":"%s","sourceMappingId":"%s","prompt":"hello world"}' "$AGENT_ID" "$SOURCE_MAPPING_ID")
code="$(curl_json POST "$PE_URL/api/integrations/acp/dispatch" "$dispatch_body")"
case "$code" in
  2*) printf '[pass] ACP dispatch handoff accepted (%s)\n' "$code" ;;
  404)
    printf '[skip] ACP dispatch needs an existing dispatch record on this engine (%s)\n' "$code"
    ;;
  *)
    printf '[fail] ACP dispatch returned unexpected status (%s)\n' "$code" >&2
    sed 's/^/  /' "$TMP_DIR/response.json" >&2
    exit 1
    ;;
esac

node "$CI_DIR/scripts/examples/openclaw-hello-agent.mjs" \
  --pe-url "$PE_URL" \
  --agent "$AGENT_ID" \
  --source-mapping-id "$SOURCE_MAPPING_ID" \
  --sensor-id "$SENSOR_ID" \
  --values "1,0,0.95,0" > "$TMP_DIR/agent-result.json"

node - "$TMP_DIR/agent-result.json" <<'NODE'
const fs = require('fs');
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!result.ok) {
  console.error(JSON.stringify(result, null, 2));
  process.exit(1);
}
console.log(`[pass] hello agent completion committed (${result.status})`);
NODE

code="$(curl_json GET "$PE_URL/api/sources")"
assert_2xx "$code" "sources endpoint after completion"

node - "$TMP_DIR/response.json" "$SENSOR_ID" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
const expected = process.argv[3];
const payload = JSON.parse(fs.readFileSync(path, 'utf8'));
const sources = Array.isArray(payload.sources) ? payload.sources : [];
const hit = sources.find((source) => {
  const sensorId = source.sensorId || source.sensor_id || source.id || source.name;
  return sensorId === expected || source.name === expected;
});
if (!hit) {
  console.error(`Expected source ${expected} was not found`);
  console.error(JSON.stringify(sources.slice(-10), null, 2));
  process.exit(1);
}
console.log(`[pass] OpenClaw completion is visible as PE source ${expected}`);
NODE
