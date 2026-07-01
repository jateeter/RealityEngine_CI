#!/usr/bin/env bash
# Smoke test for the observability readiness contract used by startUniverse.sh.
#
# The default mode validates transport wiring: Prometheus, Grafana, and
# Promtail are started together, Prometheus has both RE and PE registry scrape
# jobs, and statusUniverse.sh reports Grafana when a universe stamp exists.
#
# Set REQUIRE_OBSERVABILITY_DATA=1 after a universe start to turn empty
# Prometheus/Loki data into hard failures. This catches the "dashboards load,
# but panels show No Data" regression class.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$CI_DIR"
export MACHINES_DIR="${MACHINES_DIR:-$CI_DIR/../RealityEngine_Machines}"
if [ -d /tmp/realityengine-prometheus-file-sd ]; then
  export PROMETHEUS_FILE_SD_DIR="${PROMETHEUS_FILE_SD_DIR:-/tmp/realityengine-prometheus-file-sd}"
else
  export PROMETHEUS_FILE_SD_DIR="${PROMETHEUS_FILE_SD_DIR:-$CI_DIR/config/prometheus-file-sd}"
fi
REQUIRE_OBSERVABILITY_DATA="${REQUIRE_OBSERVABILITY_DATA:-0}"

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

wait_container_running() {
  local label="$1" container="$2" max="${3:-30}"
  local n=0 status
  while [ "$n" -lt "$max" ]; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || echo missing)"
    if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
      echo "PASS $label running: dockerHealth=$status"
      return 0
    fi
    n=$((n + 1))
    sleep 2
  done
  echo "FAIL $label not running: dockerHealth=$status" >&2
  docker logs --tail 40 "$container" >&2 || true
  return 1
}

prom_query_count() {
  local query="$1"
  curl -sfG --data-urlencode "query=$query" \
    http://localhost:9090/api/v1/query | python3 -c '
import json
import sys
data = json.load(sys.stdin)
if data.get("status") != "success":
    raise SystemExit(1)
print(len(data.get("data", {}).get("result", [])))
'
}

prom_query_positive_count() {
  local query="$1"
  curl -sfG --data-urlencode "query=$query" \
    http://localhost:9090/api/v1/query | python3 -c '
import json
import sys
data = json.load(sys.stdin)
if data.get("status") != "success":
    raise SystemExit(1)
count = 0
for item in data.get("data", {}).get("result", []):
    try:
        if float(item.get("value", [0, "0"])[1]) > 0:
            count += 1
    except Exception:
        pass
print(count)
'
}

loki_label_count() {
  curl -skf https://localhost:3100/loki/api/v1/labels | python3 -c '
import json
import sys
data = json.load(sys.stdin)
if data.get("status") != "success":
    raise SystemExit(1)
print(len(data.get("data", [])))
'
}

file_sd_has_targets() {
  local path="$1"
  [ -f "$path" ] || return 1
  python3 - "$path" <<'PY'
import json
import sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if any(item.get("targets") for item in data) else 1)
PY
}

assert_prometheus_series() {
  local label="$1" query="$2"
  local count
  count="$(prom_query_count "$query" 2>/dev/null || echo 0)"
  if [ "${count:-0}" -gt 0 ]; then
    echo "PASS $label query returned $count series"
  elif [ "$REQUIRE_OBSERVABILITY_DATA" = "1" ]; then
    echo "FAIL $label query returned no series: $query" >&2
    return 1
  else
    echo "SKIP $label query returned no series: $query"
  fi
}

assert_prometheus_up() {
  local label="$1" query="$2" required="${3:-1}"
  local series healthy
  series="$(prom_query_count "$query" 2>/dev/null || echo 0)"
  healthy="$(prom_query_positive_count "$query" 2>/dev/null || echo 0)"
  if [ "${healthy:-0}" -gt 0 ]; then
    echo "PASS $label has $healthy healthy target(s) across $series series"
  elif [ "$required" = "1" ] && [ "$REQUIRE_OBSERVABILITY_DATA" = "1" ]; then
    echo "FAIL $label has no healthy targets across $series series: $query" >&2
    return 1
  elif [ "${series:-0}" -gt 0 ]; then
    echo "WARN $label is discovered but all $series target(s) are down: $query"
  else
    echo "SKIP $label has no discovered targets: $query"
  fi
}

assert_loki_labels() {
  local count
  count="$(loki_label_count 2>/dev/null || echo 0)"
  if [ "${count:-0}" -gt 0 ]; then
    echo "PASS Loki labels available: $count labels"
  elif [ "$REQUIRE_OBSERVABILITY_DATA" = "1" ]; then
    echo "FAIL Loki labels unavailable; log dashboards will show No Data" >&2
    return 1
  else
    echo "SKIP Loki labels unavailable before live log ingestion"
  fi
}

docker compose up -d --remove-orphans --force-recreate prometheus grafana promtail >/dev/null

wait_container_ready "Prometheus" reality-engine-prometheus "http://localhost:9090/-/ready"
wait_container_ready "Grafana" reality-engine-grafana "http://localhost:3002/api/health"
wait_container_running "Promtail" reality-engine-promtail

grep -q 'job_name:     reality-engine-registry' config/prometheus.yml
echo "PASS Prometheus config includes reality-engine-registry"
grep -q 'job_name:     perception-engine-registry' config/prometheus.yml
echo "PASS Prometheus config includes perception-engine-registry"

if file_sd_has_targets "$PROMETHEUS_FILE_SD_DIR/reality-engine-targets.json"; then
  assert_prometheus_up "Reality Engine registry target health" 'up{job="reality-engine-registry"}'
else
  echo "SKIP Reality Engine registry target health: no file_sd targets in $PROMETHEUS_FILE_SD_DIR"
fi

if file_sd_has_targets "$PROMETHEUS_FILE_SD_DIR/perception-engine-targets.json"; then
  assert_prometheus_up "Perception Engine registry target health" 'up{job="perception-engine-registry"}' 0
else
  echo "SKIP Perception Engine registry target health: no file_sd targets in $PROMETHEUS_FILE_SD_DIR"
fi

assert_prometheus_up "AI bridge operations scrape" 'up{job="ai-bridge-operations"}'
assert_prometheus_up "Qdrant scrape" 'up{job="qdrant"}'
assert_prometheus_series "CES output metrics" 'ces_sequence_outputs_total'
assert_loki_labels

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
