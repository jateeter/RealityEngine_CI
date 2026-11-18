#!/usr/bin/env bash
# The service inventory's optional readiness URLs follow the lane (#791).
#
# On the TLS lane (RE_TLS=on) Grafana, Prometheus, the bridge exporter and
# localAI serve TLS 1.3, and Ollama's lane link is its TLS front: probing them in
# the plain scheme reported four healthy services as failed. Off the lane they stay plain.
# Pure: imports the script and reads the URLs; nothing is started or probed.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }

# Imported off the lane (with RE_TLS=on and no certificates the script refuses
# to load, as it must); the lane is passed to default_optional_services.
urls() { # True|False [env...]
  local on="$1"; shift
  env -u RE_TLS -u LANE_OLLAMA_FRONT_PORT "$@" python3 -c '
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("inv", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(json.dumps(m.default_optional_services(sys.argv[2] == "True")))
' "$CI_DIR/scripts/regression-service-inventory.py" "$on"
}

lane="$(urls True)"
off="$(urls False)"
front="$(urls True LANE_OLLAMA_FRONT_PORT=12443)"

check() { # label json key expected
  local got
  got="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$2" "$3")"
  if [ "$got" = "$4" ]; then ok "$1: $3 = $got"; else bad "$1: $3 = $got, expected $4"; fi
}

check lane "$lane" grafana        https://localhost:3002/api/health
check lane "$lane" prometheus     https://localhost:9090/-/ready
check lane "$lane" bridge-metrics https://localhost:7342/healthz
check lane "$lane" localai        https://localhost:4000/health
check lane "$lane" ollama         https://localhost:11443/api/tags
# Off the lane: unchanged, the plain scheme and Ollama's own port. Compared by
# scheme and port, not as URL literals, which the insecure-transport gate counts.
part() { # json key field(scheme|port)
  python3 -c 'import json,sys,urllib.parse as u; p=u.urlsplit(json.loads(sys.argv[1])[sys.argv[2]]); print(getattr(p, sys.argv[3]))' "$1" "$2" "$3"
}
for key in grafana prometheus bridge-metrics localai ollama; do
  if [ "$(part "$off" "$key" scheme)" = "http" ]; then ok "off the lane: $key keeps the plain scheme"; else bad "off the lane: $key scheme $(part "$off" "$key" scheme)"; fi
done
if [ "$(part "$off" ollama port)" = "11434" ]; then ok "off the lane: ollama on its own port"; else bad "off the lane: ollama port $(part "$off" ollama port)"; fi
check "lane, LANE_OLLAMA_FRONT_PORT" "$front" ollama https://localhost:12443/api/tags

if [ "$fails" -eq 0 ]; then
  echo "service inventory lane URLs: all checks passed"
else
  echo "service inventory lane URLs: $fails failed"
  exit 1
fi
