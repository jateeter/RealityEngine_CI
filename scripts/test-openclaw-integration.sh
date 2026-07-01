#!/usr/bin/env bash
#
# Validate the deterministic OpenClaw PE integration contract against a running
# CPP, Scala, or LSP engine pair. The OpenClawCompletionE2E corpus fixture must
# be loaded in the paired RE and trigger dispatch must be enabled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PE_URL="${PE_URL:-https://localhost:3004}"
PE_URL="${PE_URL%/}"
AGENT_ID="${OPENCLAW_AGENT_ID:-hello-world}"
SOURCE_MAPPING_ID="${ACP_COMPLETION_SOURCE_MAPPING_ID:-acp-openclaw-completion}"
SENSOR_ID="acp.openclaw.${AGENT_ID}.completion"
FIXTURE_SEQUENCE_ID="openclaw-e2e-dispatch-seed"
RUN_ID="${OPENCLAW_E2E_RUN_ID:-$$-$(date +%s)}"
SEED_SOURCE_ID="openclaw-e2e-seed-${RUN_ID}"
COMPLETION_ID="openclaw-e2e-completion-${RUN_ID}"
TMP_DIR="$(mktemp -d -t re-openclaw-e2e.XXXXXX)"
COMPLETION_SOURCE_ID=""
FINAL_PUSH_STATUS_CODE=""
REPORT_JSON=""

usage() {
  cat <<'EOF'
Usage: test-openclaw-integration.sh [--report-json PATH]

Validates the OpenClaw ACP integration against a running PE service.

Options:
  --report-json PATH  Write a JSON success report with run IDs and push details.
  -h, --help          Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-json)
      [ "$#" -ge 2 ] || { echo "missing value for --report-json" >&2; exit 2; }
      REPORT_JSON="$2"
      shift 2
      ;;
    --report-json=*)
      REPORT_JSON="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cleanup() {
  curl -sk --max-time 5 -X DELETE "$PE_URL/api/sources/$SEED_SOURCE_ID" >/dev/null 2>&1 || true
  if [ -n "$COMPLETION_SOURCE_ID" ]; then
    curl -sk --max-time 5 -X DELETE "$PE_URL/api/sources/$COMPLETION_SOURCE_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

write_report() {
  [ -n "$REPORT_JSON" ] || return 0
  mkdir -p "$(dirname "$REPORT_JSON")"
  node - "$REPORT_JSON" "$TMP_DIR/final-push.json" "$PE_URL" "$RUN_ID" "$AGENT_ID" \
    "$SOURCE_MAPPING_ID" "$SENSOR_ID" "$DISPATCH_ID" "$ENVELOPE_ID" "$CORRELATION_ID" \
    "$COMPLETION_ID" "$COMPLETION_SOURCE_ID" "$FINAL_PUSH_STATUS_CODE" <<'NODE'
const fs = require('fs');
const [
  reportPath,
  finalPushPath,
  peUrl,
  runId,
  agentId,
  sourceMappingId,
  sensorId,
  dispatchId,
  envelopeId,
  correlationId,
  completionId,
  completionSourceId,
  finalPushStatusCode
] = process.argv.slice(2);

let finalPush = null;
try {
  finalPush = JSON.parse(fs.readFileSync(finalPushPath, 'utf8'));
} catch {
  finalPush = null;
}

const report = {
  status: 'pass',
  standard: 'openclaw-xacp',
  peUrl,
  runId,
  agentId,
  sourceMappingId,
  sensorId,
  dispatchId,
  envelopeId,
  correlationId,
  completionId,
  completionSourceId,
  completionRegion: { offset: 4210, length: 4 },
  finalPushStatusCode,
  finalPush,
  generatedAt: new Date().toISOString()
};

fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
NODE
  printf '[pass] OpenClaw e2e report written (%s)\n' "$REPORT_JSON"
}

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

assert_code() {
  local code="$1" expected="$2" label="$3"
  if [ "$code" = "$expected" ]; then
    printf '[pass] %s (%s)\n' "$label" "$code"
    return
  fi
  printf '[fail] %s: expected %s, got %s\n' "$label" "$expected" "$code" >&2
  sed 's/^/  /' "$TMP_DIR/response.json" >&2
  exit 1
}

assert_2xx() {
  local code="$1" label="$2"
  case "$code" in
    2*) printf '[pass] %s (%s)\n' "$label" "$code" ;;
    *)  printf '[fail] %s (%s)\n' "$label" "$code" >&2
        sed 's/^/  /' "$TMP_DIR/response.json" >&2
        exit 1 ;;
  esac
}

find_new_dispatch_id() {
  node - "$1" "$2" "$FIXTURE_SEQUENCE_ID" <<'NODE'
const fs = require('fs');
const current = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const baseline = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const sequenceId = process.argv[4];
const prior = new Set((baseline.records || []).map((record) => record.id));
const records = (current.records || [])
  .filter((record) => record.sequenceId === sequenceId && !prior.has(record.id))
  .sort((a, b) => Number(b.createdAt || 0) - Number(a.createdAt || 0));
if (records[0]?.id) process.stdout.write(records[0].id);
NODE
}

printf '[info] PE URL: %s\n' "$PE_URL"
printf '[info] OpenClaw e2e run: %s\n' "$RUN_ID"

code="$(curl_json GET "$PE_URL/api/integrations/acp/status")"
assert_2xx "$code" "ACP status endpoint"
node - "$TMP_DIR/response.json" "$SOURCE_MAPPING_ID" <<'NODE'
const fs = require('fs');
const status = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const expectedMapping = process.argv[3];
const failures = [];
if (status.enabled !== true) failures.push('enabled must be true');
if (status.noWaitDispatch !== true) failures.push('noWaitDispatch must be true');
if (status.adapter !== 'openclaw-xacp') failures.push('adapter must be openclaw-xacp');
if (status.surface !== 'xACP') failures.push('surface must be xACP');
if (status.completionSourceMappingId !== expectedMapping) failures.push('completionSourceMappingId mismatch');
if (status.dispatchEndpoint !== '/api/integrations/acp/dispatch') failures.push('dispatchEndpoint mismatch');
if (status.completionEndpoint !== '/api/integrations/completions') failures.push('completionEndpoint mismatch');
if (failures.length) {
  console.error(failures.join('; '));
  console.error(JSON.stringify(status, null, 2));
  process.exit(1);
}
console.log('[pass] ACP status contract is configured');
NODE

code="$(curl_json GET "$PE_URL/api/dispatch/ledger")"
assert_2xx "$code" "dispatch ledger baseline"
cp "$TMP_DIR/response.json" "$TMP_DIR/ledger-before.json"

seed_body=$(printf '{"id":"%s","type":"test","name":"OpenClaw E2E Dispatch Seed","active":true,"region":{"offset":4210,"length":4},"inputs":[[0,1,0,1]],"loop":false}' "$SEED_SOURCE_ID")
code="$(curl_json POST "$PE_URL/api/sources" "$seed_body")"
assert_2xx "$code" "OpenClaw dispatch seed source registration"

code="$(curl_json POST "$PE_URL/api/push" '{"compact":true}')"
assert_2xx "$code" "OpenClaw dispatch seed push"

code="$(curl_json DELETE "$PE_URL/api/sources/$SEED_SOURCE_ID")"
assert_2xx "$code" "OpenClaw dispatch seed source cleanup"

code="$(curl_json GET "$PE_URL/api/dispatch/ledger")"
assert_2xx "$code" "dispatch ledger after seed"
cp "$TMP_DIR/response.json" "$TMP_DIR/ledger-after.json"
DISPATCH_ID="$(find_new_dispatch_id "$TMP_DIR/ledger-after.json" "$TMP_DIR/ledger-before.json")"
if [ -z "$DISPATCH_ID" ]; then
  printf '[fail] fixture sequence %s did not create a dispatch record\n' "$FIXTURE_SEQUENCE_ID" >&2
  printf '  Confirm OpenClawCompletionE2E.json is loaded and TRIGGERS_ENABLED=true.\n' >&2
  exit 1
fi
printf '[pass] fixture dispatch record created (%s)\n' "$DISPATCH_ID"

dispatch_body=$(printf '{"dispatchId":"%s","targetAgent":"%s","sourceMappingId":"%s","prompt":"Return the deterministic OpenClaw completion vector."}' "$DISPATCH_ID" "$AGENT_ID" "$SOURCE_MAPPING_ID")
code="$(curl_json POST "$PE_URL/api/integrations/acp/dispatch" "$dispatch_body")"
assert_code "$code" "202" "ACP dispatch handoff accepted"
cp "$TMP_DIR/response.json" "$TMP_DIR/acp-handoff.json"

node - "$TMP_DIR/acp-handoff.json" "$DISPATCH_ID" "$AGENT_ID" "$SOURCE_MAPPING_ID" <<'NODE'
const fs = require('fs');
const response = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const [dispatchId, agent, mapping] = process.argv.slice(3);
const handoff = response.handoff || {};
const failures = [];
if (response.accepted !== true) failures.push('accepted must be true');
if (response.noWaitDispatch !== true) failures.push('response noWaitDispatch must be true');
if (response.dispatchId !== dispatchId) failures.push('response dispatchId mismatch');
if (handoff.dispatchId !== dispatchId) failures.push('handoff dispatchId mismatch');
if (handoff.targetAgent !== agent) failures.push('handoff targetAgent mismatch');
if (handoff.completionSourceMappingId !== mapping) failures.push('handoff mapping mismatch');
if (handoff.noWaitDispatch !== true) failures.push('handoff noWaitDispatch must be true');
if (!handoff.envelopeId) failures.push('handoff envelopeId missing');
if (!handoff.correlationId) failures.push('handoff correlationId missing');
if (!handoff.gatewayUrl) failures.push('handoff gatewayUrl missing');
if (failures.length) {
  console.error(failures.join('; '));
  console.error(JSON.stringify(response, null, 2));
  process.exit(1);
}
console.log('[pass] ACP handoff schema and correlation fields are complete');
NODE

read -r ENVELOPE_ID CORRELATION_ID < <(node - "$TMP_DIR/acp-handoff.json" <<'NODE'
const fs = require('fs');
const handoff = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).handoff;
process.stdout.write(`${handoff.envelopeId} ${handoff.correlationId}\n`);
NODE
)

code="$(curl_json GET "$PE_URL/api/dispatch/records/$DISPATCH_ID")"
assert_2xx "$code" "dispatch record after ACP acceptance"
node - "$TMP_DIR/response.json" "$DISPATCH_ID" "$ENVELOPE_ID" "$CORRELATION_ID" <<'NODE'
const fs = require('fs');
const record = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).record || {};
const [dispatchId, envelopeId, correlationId] = process.argv.slice(3);
const receipt = record.providerReceipt || {};
const failures = [];
if (record.id !== dispatchId) failures.push('record id mismatch');
if (record.status !== 'accepted') failures.push('record status must be accepted');
if (record.envelopeId !== envelopeId) failures.push('record envelopeId mismatch');
if (record.correlationId !== correlationId) failures.push('record correlationId mismatch');
if (receipt.adapter !== 'openclaw-xacp') failures.push('provider receipt adapter mismatch');
if (receipt.dispatchId !== dispatchId) failures.push('provider receipt dispatchId mismatch');
if (failures.length) {
  console.error(failures.join('; '));
  console.error(JSON.stringify(record, null, 2));
  process.exit(1);
}
console.log('[pass] dispatch ledger records the accepted OpenClaw handoff');
NODE

node "$CI_DIR/scripts/examples/openclaw-hello-agent.mjs" \
  --pe-url "$PE_URL" \
  --agent "$AGENT_ID" \
  --source-mapping-id "$SOURCE_MAPPING_ID" \
  --sensor-id "$SENSOR_ID" \
  --values "1,0,0.95,0" \
  --correlation-id "$CORRELATION_ID" \
  --envelope-id "$ENVELOPE_ID" \
  --completion-id "$COMPLETION_ID" > "$TMP_DIR/agent-result.json"

node - "$TMP_DIR/agent-result.json" "$CORRELATION_ID" "$ENVELOPE_ID" "$COMPLETION_ID" <<'NODE'
const fs = require('fs');
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const [correlationId, envelopeId, completionId] = process.argv.slice(3);
if (!result.ok) {
  console.error(JSON.stringify(result, null, 2));
  process.exit(1);
}
const completion = result.response?.completion || {};
if (completion.correlationId !== correlationId
    || completion.envelopeId !== envelopeId
    || completion.completionId !== completionId) {
  console.error('completion correlation fields were not preserved');
  console.error(JSON.stringify(result, null, 2));
  process.exit(1);
}
console.log(`[pass] correlated hello-agent completion committed (${result.status})`);
NODE

code="$(curl_json GET "$PE_URL/api/sources")"
assert_2xx "$code" "sources endpoint after completion"

COMPLETION_SOURCE_ID="$(node - "$TMP_DIR/response.json" "$SENSOR_ID" <<'NODE'
const fs = require('fs');
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const expected = process.argv[3];
const sources = Array.isArray(payload.sources) ? payload.sources : [];
const hit = sources.find((source) => {
  const sensorId = source.sensorId || source.sensor_id || source.id || source.name;
  return sensorId === expected || source.name === expected;
});
if (!hit) {
  console.error(`Expected source ${expected} was not found`);
  process.exit(1);
}
if (Number(hit.region?.offset) !== 4210 || Number(hit.region?.length) !== 4) {
  console.error(`Expected source region 4210:4, got ${JSON.stringify(hit.region)}`);
  process.exit(1);
}
process.stdout.write(hit.id || expected);
NODE
)"
printf '[pass] OpenClaw completion source mapped to region 4210:4 (%s)\n' "$COMPLETION_SOURCE_ID"

code="$(curl_json POST "$PE_URL/api/push" '{"compact":true}')"
FINAL_PUSH_STATUS_CODE="$code"
assert_2xx "$code" "OpenClaw completion push"
cp "$TMP_DIR/response.json" "$TMP_DIR/final-push.json"
node - "$TMP_DIR/final-push.json" <<'NODE'
const fs = require('fs');
const push = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const isObject = push && typeof push === 'object' && !Array.isArray(push);
if (!(isObject && (push.success || push.pushed || Object.prototype.hasOwnProperty.call(push, 'stepCount') || push.id))) {
  console.error('push response did not expose a recognized success marker');
  console.error(JSON.stringify(push, null, 2));
  process.exit(1);
}
console.log('[pass] OpenClaw completion reached PE push path');
NODE

write_report
