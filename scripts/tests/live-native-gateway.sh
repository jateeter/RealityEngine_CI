#!/usr/bin/env bash
# Live check of the native OpenClaw gateway (RealityEngine_CI#592, slice b). Not
# run by CI: it needs launchd, Docker Desktop and a host OpenClaw on the pinned
# Node. It starts the real gateway as a LaunchAgent from a scratch install and
# checks what the issue's "done when" says about it:
#
#   - it is a LaunchAgent, on 127.0.0.1 only, answering /healthz;
#   - its home is the install's openclaw/, and ~/.openclaw is byte-identical
#     before and after;
#   - the OpenAI-compatible /v1 API answers with the token (and refuses without);
#   - a container reaches it through host.docker.internal;
#   - `gateway restart` and `unload` work, and unload leaves nothing listening.
#
# It uses its own project label and port (RE_LIVE_PORT, default 18795), never the
# development gateway on 18789.
#
#   scripts/tests/live-native-gateway.sh [--ocs DIR]     DIR = a localOpenClawStack checkout
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OCS="${2:-$CI_DIR/../localOpenClawStack}"
[ "${1:-}" != --ocs ] || OCS="$2"
PORT="${RE_LIVE_PORT:-18795}"
T="$(mktemp -d)"
D="$T/install"
fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }

# OpenClaw on the pinned Node: PATH first, else the nvm install of that Node.
REQ_NODE="$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['node']['exact'])" "$CI_DIR/release/host-requirements.json")"
if ! command -v openclaw >/dev/null 2>&1 || [ "$(node --version 2>/dev/null)" != "v$REQ_NODE" ]; then
  nb="$HOME/.nvm/versions/node/v$REQ_NODE/bin"
  [ -x "$nb/openclaw" ] && export PATH="$nb:$PATH"
fi
command -v openclaw >/dev/null 2>&1 || { echo "SKIPPED: no openclaw on Node $REQ_NODE"; exit 0; }
[ -d "$OCS/scripts" ] || { echo "SKIPPED: no localOpenClawStack checkout at $OCS"; exit 0; }

snapshot() { # a stable fingerprint of a tree: names, sizes and content
  [ -d "$1" ] || { echo none; return; }
  (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum 2>/dev/null; find . -type d | sort) | shasum | awk '{print $1}'
}
BEFORE="$(snapshot "$HOME/.openclaw")"

CLI="$CI_DIR/release/realityengine"
export REALITYENGINE_DIR="$D" REALITYENGINE_LAUNCHAGENTS_DIR="$T/LaunchAgents" REALITYENGINE_PROJECT=re-live-gw
export RE_PORT_OPENCLAW="$PORT" RE_PORT_BROWSER_CDP=9299 REALITYENGINE_GATEWAY_WAIT=90
cleanup() { /bin/bash "$CLI" gateway unload >/dev/null 2>&1 || true; docker rm -f re-live-gw-browser >/dev/null 2>&1 || true; rm -rf "$T"; }
trap cleanup EXIT

echo "native gateway (live)"
TOKEN="live-$(date +%s)-token"
mkdir -p "$D/state" "$D/logs"
cat > "$D/.env" <<EOF
COMPOSE_PROJECT_NAME=re-live-gw
RE_PORT_OPENCLAW=$PORT
RE_PORT_BROWSER_CDP=9299
OPENCLAW_GATEWAY_TOKEN=$TOKEN
EOF

# The home, made the way re-init makes it: the repo's own scripts, new schema.
OC="$T/ocs"; mkdir -p "$OC"
(cd "$OCS" && tar --exclude=.git --exclude=./.env --exclude=./openclaw -cf - .) | (cd "$OC" && tar -xf -)
BROWSER_IMG="$(sed -n 's/.*image: \(coollabsio\/openclaw-browser[^ ]*\).*/\1/p' "$CI_DIR/release/compose.yml" | head -1)"
docker rm -f re-live-gw-browser >/dev/null 2>&1 || true
HAVE_BROWSER=no
if docker image inspect "$BROWSER_IMG" >/dev/null 2>&1; then
  # The same flags compose gives the sidecar: CDP on the Mac's loopback only.
  docker run -d --name re-live-gw-browser -e PUID=1000 -e PGID=1000 -e CHROME_CLI="--remote-debugging-port=9222" \
    --shm-size 2g --security-opt no-new-privileges:true -p "127.0.0.1:9299:9223" "$BROWSER_IMG" >/dev/null && HAVE_BROWSER=yes
fi
env OPENCLAW_SCHEMA=entries OPENCLAW_STATE_DIR="$D/openclaw" OPENCLAW_HOME_DIR="$D/openclaw" \
    OPENCLAW_BROWSER_CDP_URL=http://127.0.0.1:9299 \
    OPENCLAW_GATEWAY_BIND=loopback OPENCLAW_HTTP_ENDPOINTS=true OPENCLAW_GATEWAY_PORT="$PORT" \
    OLLAMA_BASE_URL=http://127.0.0.1:11434 OPENCLAW_DEFAULT_MODEL=ollama/nemotron-3-nano:4b \
    OPENCLAW_AGENT_PROFILE=regression bash -c '
      set -e; cd "$0"
      idx="$(scripts/agent-profile.sh regression)"
      export OPENCLAW_AGENT_INDEX_PATH="$idx"
      scripts/harden-config.sh && scripts/sync-machine-agents.sh && scripts/verify-openclaw-config.sh' "$OC" >"$T/gen.out" 2>&1 \
  && ok "the home is generated and verified ($(grep -c . "$T/gen.out") lines)" || { bad "generating the home"; tail -20 "$T/gen.out"; exit 1; }

/bin/bash "$CLI" gateway load >"$T/load.out" 2>&1 && ok "gateway load" || { bad "gateway load"; cat "$T/load.out"; tail -30 "$D/logs/openclaw-gateway.log" 2>/dev/null; exit 1; }

launchctl print "gui/$(id -u)/org.realityengine.openclaw-gateway.re-live-gw" >/dev/null 2>&1 \
  && ok "it is a loaded LaunchAgent" || bad "no LaunchAgent is loaded"

LISTEN="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | sort -u | tr '\n' ' ')"
# OpenClaw's "loopback" binds 127.0.0.1 and ::1; anything else (*, a LAN address) is a failure.
nonloop="$(printf '%s\n' $LISTEN | grep -v -E "^(127\.0\.0\.1|\[::1\]):$PORT$" || true)"
{ [ -n "$LISTEN" ] && [ -z "$nonloop" ]; } && ok "listening on loopback only ($LISTEN)" || bad "listening on: ${LISTEN:-nothing}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
[ "$(code "http://127.0.0.1:$PORT/healthz")" = 200 ] && ok "/healthz answers" || bad "/healthz"
[ "$(code -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/models")" = 200 ] && ok "/v1/models answers with the token" || bad "/v1/models with the token: $(code -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/models")"
c="$(code "http://127.0.0.1:$PORT/v1/models")"; [ "$c" = 401 ] || [ "$c" = 403 ] && ok "/v1/models refuses without the token ($c)" || bad "/v1/models without the token: $c"

if docker info >/dev/null 2>&1; then
  c="$(docker run --rm curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' -m 10 "http://host.docker.internal:$PORT/healthz" 2>/dev/null || true)"
  [ "$c" = 200 ] && ok "a container reaches it through host.docker.internal" || bad "container -> host.docker.internal: ${c:-no answer}"
else
  echo "  SKIPPED  container reachability: Docker is not running"
fi

if [ "$HAVE_BROWSER" = yes ]; then
  for _ in $(seq 1 30); do curl -fsS -m 2 http://127.0.0.1:9299/json/version >/dev/null 2>&1 && break; sleep 2; done
  BL="$(lsof -nP -iTCP:9299 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | sort -u | tr '\n' ' ')"
  [ "$BL" = "127.0.0.1:9299 " ] && ok "browser CDP is published on 127.0.0.1 only ($BL)" || bad "browser CDP listens on: ${BL:-nothing}"
  st="$(PATH="$PATH" OPENCLAW_STATE_DIR="$D/openclaw" OPENCLAW_CONFIG_PATH="$D/openclaw/openclaw.json" OPENCLAW_GATEWAY_TOKEN="$TOKEN" \
        openclaw browser --url "ws://127.0.0.1:$PORT" --token "$TOKEN" status 2>&1 || true)"
  printf '%s' "$st" | grep -q "running: true" && printf '%s' "$st" | grep -q "transport: cdp" \
    && ok "the gateway is attached to the sidecar over CDP" || { bad "the gateway is not attached to the sidecar"; printf '%s\n' "$st" | head -8; }
else
  echo "  SKIPPED  browser sidecar: image $BROWSER_IMG is not loaded in Docker (docker pull it to include this check)"
fi

[ -s "$D/logs/openclaw-gateway.log" ] && ok "its log is in the install ($D/logs)" || bad "no gateway log in the install"
ls "$D/openclaw" | grep -q openclaw.json && ok "its home is the install's openclaw/" || bad "no config in the install's home"

/bin/bash "$CLI" gateway restart >"$T/restart.out" 2>&1 && ok "gateway restart" || { bad "gateway restart"; cat "$T/restart.out"; }
/bin/bash "$CLI" gateway unload >/dev/null 2>&1
sleep 2
[ -z "$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1')" ] && ok "unload leaves nothing listening" || bad "something still listens on $PORT"

AFTER="$(snapshot "$HOME/.openclaw")"
[ "$BEFORE" = "$AFTER" ] && ok "~/.openclaw is byte-identical before and after" || bad "~/.openclaw CHANGED (before $BEFORE, after $AFTER)"

[ "$fails" -eq 0 ] && { echo "all ok"; exit 0; }
echo "$fails failure(s)"; exit 1
