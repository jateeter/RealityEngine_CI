#!/usr/bin/env bash
# The HealthKit → PIM → POD mirror leg (localHealthkitBridge
# docs/MIRROR_CONTRACT.md §8; MVP_ROADMAP D2, which makes it blocking).
#
# Brings up an isolated Community Solid Server and a PIM against it, then runs
# the bridge's PIMWireTests through PIM's public API:
#   1. happy path into vital-signs and a pillar, and idempotence;
#   2. conflict: a differing POD record is left unchanged (the POD wins);
#   3. no owner approval → 403, nothing written;
# plus a stale approved set (409) and a wrong bridge token (401). It then reads
# PIM's /api/pod/healthkit/status and requires the mirrored records to be
# counted there, read back from the POD rather than from the test's memory.
#
# Everything it starts is its own: a separate compose project, CSS and PIM
# ports, credentials and env file under the report directory, and a per-run
# account password and bridge token. It never touches an operator's PIM stack
# or .solid data, and tears everything down on exit.
#
# Usage: pim-mirror-leg.sh <pim-dir> <bridge-dir> <report-dir>
# Env:   PIM_MIRROR_CSS_PORT (13910), PIM_MIRROR_APP_PORT (18190)
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <pim-dir> <bridge-dir> <report-dir>" >&2
  exit 2
fi
PIM_DIR="$(cd "$1" && pwd)"
BRIDGE_DIR="$(cd "$2" && pwd)"
mkdir -p "$3"
REPORT_DIR="$(cd "$3" && pwd)"

CSS_PORT="${PIM_MIRROR_CSS_PORT:-13910}"
APP_PORT="${PIM_MIRROR_APP_PORT:-18190}"
PROJECT="re-ci-pim-mirror-${CSS_PORT}"
WORK="$REPORT_DIR/pim-mirror"
mkdir -p "$WORK"
chmod 700 "$WORK"

log() { printf '[pim-mirror] %s\n' "$*"; }

for tool in docker node npm swift curl jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || { log "missing tool: $tool"; exit 3; }
done

# Per-run secrets. Neither is printed; both live only under $WORK (0700).
CSS_ACCOUNT_PASSWORD="ci-$(openssl rand -hex 16)"
BRIDGE_TOKEN="$(openssl rand -hex 24)"
export CSS_ACCOUNT_PASSWORD

PIM_PID=""
cleanup() {
  local rc=$?
  if [ -n "$PIM_PID" ]; then kill "$PIM_PID" 2>/dev/null || true; wait "$PIM_PID" 2>/dev/null || true; fi
  (cd "$PIM_DIR" && COMPOSE_PROJECT_NAME="$PROJECT" CSS_PORT="$CSS_PORT" \
    HOST_CREDENTIALS_DIR="$WORK/credentials" \
    docker compose -f docker-compose.host-local.yml down -v --remove-orphans >"$WORK/compose-down.log" 2>&1) || true
  # The report directory is retained in run history; per-run credentials are
  # not evidence and must not be kept, even for a CSS that no longer exists.
  rm -rf "$WORK/credentials" "$WORK/pim.env"
  exit "$rc"
}
trap cleanup EXIT

log "CSS on :$CSS_PORT, PIM on :$APP_PORT, compose project $PROJECT"
(
  cd "$PIM_DIR"
  COMPOSE_PROJECT_NAME="$PROJECT" CSS_PORT="$CSS_PORT" APP_PORT="$APP_PORT" \
    HOST_CREDENTIALS_DIR="$WORK/credentials" HOST_LOCAL_ENV_FILE="$WORK/pim.env" \
    SKIP_LOCAL_PREFLIGHT=1 \
    sh scripts/local-host-solid-up.sh
) >"$WORK/solid-up.log" 2>&1 || { log "Solid bring-up failed; see $WORK/solid-up.log"; exit 1; }

log "building PIM"
(cd "$PIM_DIR" && npm run build) >"$WORK/pim-build.log" 2>&1 \
  || { log "PIM build failed; see $WORK/pim-build.log"; exit 1; }

log "starting PIM with the HealthKit mirror"
(
  cd "$PIM_DIR"
  set -a
  # shellcheck disable=SC1091
  . "$WORK/pim.env"
  set +a
  export HOST=127.0.0.1 PIM_HEALTHKIT_BRIDGE_TOKEN="$BRIDGE_TOKEN" HEALTHKIT_BRIDGE_ID="ci-pim-mirror"
  # No PE scope push here: the leg asserts the POD side of the mirror. Pushing
  # the owner's changes to live PEs is PIM unit coverage (healthkit.service).
  export HEALTHKIT_PE_SCOPE_URLS=""
  exec node dist/server.js
) >"$WORK/pim.log" 2>&1 &
PIM_PID=$!

PIM_URL="http://127.0.0.1:$APP_PORT"
ready=false
for _ in $(seq 1 60); do
  if ! kill -0 "$PIM_PID" 2>/dev/null; then break; fi
  if curl -fsS --max-time 3 -H "authorization: Bearer $BRIDGE_TOKEN" \
      "$PIM_URL/api/integrations/healthkit/metrics" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [ "$ready" != true ]; then
  log "PIM did not serve the mirror routes; see $WORK/pim.log"
  exit 1
fi

log "running the bridge's PIMWireTests"
set +e
(cd "$BRIDGE_DIR" && HEALTHKIT_PIM_WIRE_URL="$PIM_URL" HEALTHKIT_PIM_WIRE_TOKEN="$BRIDGE_TOKEN" \
  swift test --filter PIMWireTests) >"$WORK/wire-test.log" 2>&1
wire_rc=$?
set -e
if [ "$wire_rc" -ne 0 ]; then
  log "PIMWireTests failed (exit $wire_rc); see $WORK/wire-test.log"
  exit 1
fi
if grep -q "skipped" "$WORK/wire-test.log" && ! grep -q "Executed 1 test, with 0 failures" "$WORK/wire-test.log"; then
  log "PIMWireTests did not run"
  exit 1
fi

# The status surface must count what landed, read back from the POD.
curl -fsS --max-time 10 "$PIM_URL/api/pod/healthkit/status" >"$WORK/status.json"
vitals="$(jq -r '.data.pillars["vital-signs"] // .pillars["vital-signs"] // 0' "$WORK/status.json")"
activity="$(jq -r '.data.pillars.activity // .pillars.activity // 0' "$WORK/status.json")"
log "status counts: vital-signs=$vitals activity=$activity"
if [ "$vitals" -lt 1 ] || [ "$activity" -lt 1 ]; then
  log "status does not count the mirrored records"
  exit 1
fi

jq -n --argjson vitals "$vitals" --argjson activity "$activity" \
  '{status: "passed", legs: ["happy-path", "idempotence", "conflict-pod-wins", "no-approval-403", "stale-generation-409", "bad-token-401", "status-counts"], counts: {"vital-signs": $vitals, activity: $activity}}' \
  >"$REPORT_DIR/pim-mirror.json"
log "passed"
