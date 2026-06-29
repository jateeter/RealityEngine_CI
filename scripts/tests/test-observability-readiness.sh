#!/usr/bin/env bash
# Smoke test for the observability readiness contract used by startUniverse.sh.
#
# It starts only the Prometheus/Grafana compose services, waits for Docker
# health and the advertised host endpoints, and checks statusUniverse.sh when
# a universe stamp exists.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$CI_DIR"
export MACHINES_DIR="${MACHINES_DIR:-$CI_DIR/../RealityEngine_Machines}"

wait_container_ready() {
  local label="$1" container="$2" url="$3" max="${4:-45}"
  local n=0 status
  while [ "$n" -lt "$max" ]; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || echo missing)"
    if [ "$status" = "healthy" ] && curl -sf --max-time 3 "$url" >/dev/null 2>&1; then
      echo "PASS $label ready: dockerHealth=$status url=$url"
      return 0
    fi
    n=$((n + 1))
    sleep 2
  done
  echo "FAIL $label not ready: dockerHealth=$status url=$url" >&2
  docker inspect "$container" 2>/dev/null | python3 -c '
import json
import sys
try:
    data = json.load(sys.stdin)
    log = data[0].get("State", {}).get("Health", {}).get("Log") or []
    if log:
        print("lastHealthcheck:", (log[-1].get("Output") or "").strip())
except Exception:
    pass
' >&2 || true
  docker logs --tail 40 "$container" >&2 || true
  return 1
}

docker compose up -d --remove-orphans prometheus grafana >/dev/null

wait_container_ready "Prometheus" reality-engine-prometheus "http://localhost:9090/-/ready"
wait_container_ready "Grafana" reality-engine-grafana "http://localhost:3002/api/health"

if [ -f .universe-engine-selection ]; then
  status_json="$(./statusUniverse.sh --json || true)"
  python3 -c '
import json
import sys
data = json.loads(sys.stdin.read())
for service in data.get("services", []):
    if service.get("engine") == "Grafana":
        if service.get("health") == "ok":
            print("PASS statusUniverse Grafana health=ok")
            raise SystemExit(0)
        print("FAIL statusUniverse Grafana health=%s" % service.get("health"), file=sys.stderr)
        raise SystemExit(1)
print("FAIL statusUniverse did not report Grafana", file=sys.stderr)
raise SystemExit(1)
' <<< "$status_json"
elif [ "${REQUIRE_STATUS_UNIVERSE:-0}" = "1" ]; then
  echo "FAIL statusUniverse check requested, but .universe-engine-selection is absent" >&2
  exit 1
else
  echo "SKIP statusUniverse Grafana assertion: .universe-engine-selection is absent"
fi
