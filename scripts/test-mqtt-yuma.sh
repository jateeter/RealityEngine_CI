#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# test-mqtt-yuma.sh — End-to-end MQTT integration test using the Yuma
# agriculture broker (yuma.lateraledge.cloud:1883).
#
# Flow:
#   1  Check PE is healthy
#   2  Load mappings (file → PE example → inline default)
#   3  Enable MQTT bridge via POST /api/mqtt/enable
#   4  Poll GET /api/mqtt/status until connected (--timeout-connect seconds)
#   5  Poll GET /api/sources until Yuma sensor IDs appear (--timeout-sources s)
#   6  Report pass/fail with per-sensor detail
#
# Usage:
#   ./scripts/test-mqtt-yuma.sh [options]
#
# Options:
#   --pe-url URL          PE base URL  (default: https://localhost:3004)
#   --broker-url URL      MQTT broker  (default: mqtt://yuma.lateraledge.cloud:1883)
#   --mappings PATH       Path to mappings JSON file; if omitted, the script
#                         tries ../RealityEngine_CPP/config/mqtt-mappings.yuma.json
#                         then falls back to GET /api/mqtt/example from the PE
#   --username USER       MQTT username (optional)
#   --password PASS       MQTT password (optional)
#   --timeout-connect N   Seconds to wait for broker connection (default: 30)
#   --timeout-sources N   Seconds to wait for Yuma sources to appear (default: 60)
#   --skip-enable         Skip POST /api/mqtt/enable (bridge already configured)
#   --verbose             Print each HTTP response body
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CPP_DIR="$CI_DIR/../RealityEngine_CPP"

# ── Defaults ─────────────────────────────────────────────────────────────────
PE_URL="https://localhost:3004"
BROKER_URL="mqtt://yuma.lateraledge.cloud:1883"
MAPPINGS_PATH=""
MQTT_USERNAME=""
MQTT_PASSWORD=""
TIMEOUT_CONNECT=30
TIMEOUT_SOURCES=60
SKIP_ENABLE=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pe-url=*)           PE_URL="${1#*=}";            shift ;;
    --pe-url)             PE_URL="$2";                 shift 2 ;;
    --broker-url=*)       BROKER_URL="${1#*=}";        shift ;;
    --broker-url)         BROKER_URL="$2";             shift 2 ;;
    --mappings=*)         MAPPINGS_PATH="${1#*=}";     shift ;;
    --mappings)           MAPPINGS_PATH="$2";          shift 2 ;;
    --username=*)         MQTT_USERNAME="${1#*=}";     shift ;;
    --username)           MQTT_USERNAME="$2";          shift 2 ;;
    --password=*)         MQTT_PASSWORD="${1#*=}";     shift ;;
    --password)           MQTT_PASSWORD="$2";          shift 2 ;;
    --timeout-connect=*)  TIMEOUT_CONNECT="${1#*=}";   shift ;;
    --timeout-connect)    TIMEOUT_CONNECT="$2";        shift 2 ;;
    --timeout-sources=*)  TIMEOUT_SOURCES="${1#*=}";   shift ;;
    --timeout-sources)    TIMEOUT_SOURCES="$2";        shift 2 ;;
    --skip-enable)        SKIP_ENABLE=true;            shift ;;
    --verbose)            VERBOSE=true;                shift ;;
    -h|--help)
      sed -n '/^# ─/,/^# ─/p' "$0" | head -40
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}ℹ${NC} $*"; }
warn() { echo -e "${RED}⚠${NC} $*"; }
hdr()  { echo -e "\n${CYAN}${BOLD}─── $* ───${NC}"; }
die()  { echo -e "\n${RED}✗  FATAL:${NC} $*\n"; exit 1; }

PASS=0; FAIL=0; ERRORS=()

check_pass() { PASS=$((PASS+1)); ok "$*"; }
check_fail() { FAIL=$((FAIL+1)); ERRORS+=("$*"); warn "$*"; }

# curl wrapper — handles TLS (self-signed certs) and optionally logs bodies
_curl() { curl -sk --max-time 10 "$@"; }

# ── 1 · PE health ─────────────────────────────────────────────────────────────
hdr "1 · PE health  $PE_URL"

PE_HEALTH=$(_curl "$PE_URL/api/health" 2>/dev/null || true)
if echo "$PE_HEALTH" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') or d.get('status') in ('ok','healthy') or d.get('healthy') else 1)" \
    2>/dev/null; then
  check_pass "PE /api/health: OK"
else
  die "PE not healthy at $PE_URL/api/health — start the stack first"
fi

# ── 2 · Load mappings ─────────────────────────────────────────────────────────
hdr "2 · Mappings"

MAPPINGS_JSON=""

# Priority 1: explicit file
if [ -n "$MAPPINGS_PATH" ]; then
  [ -f "$MAPPINGS_PATH" ] || die "Mappings file not found: $MAPPINGS_PATH"
  MAPPINGS_JSON=$(cat "$MAPPINGS_PATH")
  ok "Mappings loaded from file: $MAPPINGS_PATH"

# Priority 2: CPP repo sibling
elif [ -f "$CPP_DIR/config/mqtt-mappings.yuma.json" ]; then
  MAPPINGS_JSON=$(cat "$CPP_DIR/config/mqtt-mappings.yuma.json")
  ok "Mappings loaded from CPP repo: mqtt-mappings.yuma.json"

# Priority 3: PE bundled example (Yuma agriculture)
else
  info "Fetching bundled Yuma example from PE GET /api/mqtt/example..."
  MAPPINGS_JSON=$(_curl "$PE_URL/api/mqtt/example" 2>/dev/null || true)
  if echo "$MAPPINGS_JSON" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); assert d.get('mappings') or d.get('rules')" \
      2>/dev/null; then
    MAPPING_COUNT=$(echo "$MAPPINGS_JSON" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(len(d.get('mappings', d.get('rules', []))))" \
      2>/dev/null || echo "?")
    ok "Mappings loaded from PE example endpoint ($MAPPING_COUNT rules)"
  else
    die "Could not load Yuma mappings — provide --mappings=PATH or add RealityEngine_CPP sibling"
  fi
fi

MAPPING_COUNT=$(echo "$MAPPINGS_JSON" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(len(d.get('mappings', d.get('rules', []))))" \
  2>/dev/null || echo "?")

# Derive expected sensor IDs from mappings (sensorIdTemplate values, no wildcards)
EXPECTED_IDS=$(echo "$MAPPINGS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rules = d.get('mappings', d.get('rules', []))
ids = []
for r in rules:
    tpl = r.get('sensorIdTemplate', '')
    # skip wildcard templates (contain {N} capture groups) — they're dynamic
    if '{' not in tpl:
        ids.append(tpl)
for i in ids:
    print(i)
" 2>/dev/null || true)

# ── 3 · Enable / verify bridge ────────────────────────────────────────────────
hdr "3 · MQTT bridge enable"

if [ "$SKIP_ENABLE" = false ]; then
  info "Calling POST /api/mqtt/enable (broker: $BROKER_URL, mappings: $MAPPING_COUNT rules)..."

  # Build enable body — write mappings to a temp file to avoid shell quoting issues
  _MAPPINGS_TMP=$(mktemp /tmp/yuma-mappings.XXXXXX.json)
  printf '%s' "$MAPPINGS_JSON" > "$_MAPPINGS_TMP"
  ENABLE_BODY=$(python3 - "$_MAPPINGS_TMP" "$BROKER_URL" "$MQTT_USERNAME" "$MQTT_PASSWORD" <<'PYEOF'
import json, sys
mappings = json.loads(open(sys.argv[1]).read())
body = {"brokerUrl": sys.argv[2], "mappings": mappings}
if sys.argv[3]: body["username"] = sys.argv[3]
if sys.argv[4]: body["password"] = sys.argv[4]
print(json.dumps(body))
PYEOF
)
  rm -f "$_MAPPINGS_TMP"

  ENABLE_RESP=$(_curl -X POST "$PE_URL/api/mqtt/enable" \
    -H "Content-Type: application/json" \
    -d "$ENABLE_BODY" 2>/dev/null || true)

  [ "$VERBOSE" = true ] && echo "  enable response: $ENABLE_RESP"

  if echo "$ENABLE_RESP" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('success') or d.get('enabled') else 1)" \
      2>/dev/null; then
    RESP_COUNT=$(echo "$ENABLE_RESP" | python3 -c \
      "import json,sys; print(json.load(sys.stdin).get('mappings','?'))" 2>/dev/null || echo "?")
    check_pass "MQTT enable accepted ($RESP_COUNT mapping rules loaded)"
    # Surface any overlap warnings
    RESP_WARNS=$(echo "$ENABLE_RESP" | python3 -c \
      "import json,sys; w=json.load(sys.stdin).get('warnings',[]); [print(' ',x) for x in w]" \
      2>/dev/null || true)
    [ -n "$RESP_WARNS" ] && warn "Mapping warnings:\n$RESP_WARNS"
  else
    ERR=$(echo "$ENABLE_RESP" | python3 -c \
      "import json,sys; print(json.load(sys.stdin).get('error','unknown error'))" 2>/dev/null || echo "$ENABLE_RESP")
    die "POST /api/mqtt/enable failed: $ERR"
  fi
else
  info "Skipping enable (--skip-enable); checking existing bridge status..."
fi

# ── 4 · Poll for broker connection ────────────────────────────────────────────
hdr "4 · Broker connection  (timeout: ${TIMEOUT_CONNECT}s)"

n=0
CONNECTED=false
while [ "$n" -lt "$TIMEOUT_CONNECT" ]; do
  STATUS_JSON=$(_curl "$PE_URL/api/mqtt/status" 2>/dev/null || true)
  [ "$VERBOSE" = true ] && echo "  status: $STATUS_JSON"
  IS_CONN=$(echo "$STATUS_JSON" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print('true' if d.get('connected') else 'false')" \
    2>/dev/null || echo "false")
  if [ "$IS_CONN" = "true" ]; then
    CONNECTED=true; break
  fi
  echo -n "."; sleep 2; n=$((n+2))
done
echo ""

if [ "$CONNECTED" = true ]; then
  BROKER_ACTUAL=$(echo "$STATUS_JSON" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('brokerUrl') or d.get('broker',{}).get('url','?'))" 2>/dev/null || echo "?")
  MSG_RX=$(echo "$STATUS_JSON" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); b=d.get('bridge',d.get('stats',d)); print(b.get('messagesReceived','?'))" \
    2>/dev/null || echo "?")
  check_pass "Broker connected: $BROKER_ACTUAL  (messages received: $MSG_RX)"
else
  IS_ENABLED=$(echo "$STATUS_JSON" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('enabled','?'))" 2>/dev/null || echo "?")
  check_fail "Broker not connected after ${TIMEOUT_CONNECT}s (enabled=$IS_ENABLED, broker=$BROKER_URL)"
  warn "Bridge may need credentials (--username / --password) or the broker is unreachable"
fi

# ── 5 · Poll for Yuma sensor sources ─────────────────────────────────────────
# PE auto-creates sources named mqtt:<topic> for each mapping rule that fires.
# We poll /api/sources and count how many have an mqtt: prefix, then show
# which mapping offsets are covered and their current values.
hdr "5 · Yuma sensor sources  (timeout: ${TIMEOUT_SOURCES}s)"

# Derive expected offsets from mappings (written to temp file for Python)
_MAPPINGS_TMP2=$(mktemp /tmp/yuma-mappings-check.XXXXXX.json)
printf '%s' "$MAPPINGS_JSON" > "$_MAPPINGS_TMP2"
EXPECTED_COUNT=$(python3 - "$_MAPPINGS_TMP2" <<'PYEOF'
import json, sys
d = json.loads(open(sys.argv[1]).read())
print(len(d.get('mappings', d.get('rules', []))))
PYEOF
)
rm -f "$_MAPPINGS_TMP2"

n=0
SOURCES_FOUND=false
_SOURCES_TMP=$(mktemp /tmp/yuma-sources.XXXXXX.json)

while [ "$n" -lt "$TIMEOUT_SOURCES" ]; do
  _src=$(_curl "$PE_URL/api/sources" 2>/dev/null || true)
  if [ -n "$_src" ]; then
    printf '%s' "$_src" > "$_SOURCES_TMP"
    MQTT_COUNT=$(python3 -c "
import json
ss = json.loads(open('$_SOURCES_TMP').read()).get('sources', [])
# PE names MQTT sources as 'mqtt:<topic>' or matches known Yuma topic fragments
n = sum(1 for s in ss if s.get('name','').startswith('mqtt:') or 'LATERAL/' in s.get('name',''))
print(n)
" 2>/dev/null || echo 0)
    if [ "$MQTT_COUNT" -gt 0 ]; then
      SOURCES_FOUND=true
      break
    fi
  fi
  echo -n "."; sleep 3; n=$((n+3))
done
echo ""

if [ "$SOURCES_FOUND" = true ]; then
  check_pass "MQTT sensor sources auto-created: $MQTT_COUNT / $EXPECTED_COUNT mapping rules"
  # Show per-source detail
  python3 -c "
import json
ss = json.loads(open('$_SOURCES_TMP').read()).get('sources', [])
mqtt = [s for s in ss if s.get('name','').startswith('mqtt:') or 'LATERAL/' in s.get('name','')]
# Group by topic
topics = {}
for s in mqtt:
    t = s.get('name','?')
    topics.setdefault(t, []).append(s)
for topic, srcs in sorted(topics.items()):
    offsets = sorted(s.get('region',{}).get('offset','?') for s in srcs)
    print(f'  {topic}')
    print(f'    offsets: {offsets}')
" 2>/dev/null || true
else
  check_fail "No MQTT sensor sources appeared after ${TIMEOUT_SOURCES}s (broker connected=$CONNECTED)"
  if [ "$CONNECTED" = true ]; then
    warn "Broker connected but no messages received on subscribed topics yet"
    warn "Yuma devices may not be publishing — data may arrive later"
  fi
fi
rm -f "$_SOURCES_TMP"

# ── 6 · Final status snapshot ────────────────────────────────────────────────
hdr "6 · Final MQTT status snapshot"

FINAL_STATUS=$(_curl "$PE_URL/api/mqtt/status" 2>/dev/null || true)
echo "$FINAL_STATUS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
b = d.get('bridge', d.get('stats', d))
broker_url = d.get('brokerUrl') or d.get('broker', {}).get('url', '—')
print(f'  enabled:           {d.get(\"enabled\")}')
print(f'  connected:         {d.get(\"connected\")}')
print(f'  brokerUrl:         {broker_url}')
print(f'  messagesReceived:  {b.get(\"messagesReceived\", \"?\")}')
print(f'  messagesMapped:    {b.get(\"messagesMapped\", \"?\")}')
print(f'  messagesRejected:  {b.get(\"messagesRejected\", \"?\")}')
print(f'  pushesTriggered:   {b.get(\"pushesTriggered\", \"?\")}')
" 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  MQTT Yuma E2E Test  —  $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════════════════════════════"

if [ "${#ERRORS[@]}" -gt 0 ]; then
  echo ""
  for e in "${ERRORS[@]}"; do
    echo -e "  ${RED}✗${NC} $e"
  done
  echo ""
  exit 1
else
  echo ""
  echo -e "  ${GREEN}All checks passed.${NC}"
  echo ""
  exit 0
fi
