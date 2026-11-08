#!/usr/bin/env bash
# Serve the generated OpenAPI specs + Swagger portal over plain HTTP.
#
# Usage (from RealityEngine_CI root):
#   bash scripts/serve-openapi.sh [PORT]
#
# Then open:   http://localhost:<PORT>/            (Swagger UI portal)
#              http://localhost:<PORT>/cpp-re.yaml (raw spec)
#
# Defaults to port 8088. Requires Python 3 (no extra packages).

set -euo pipefail
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCROOT="$CI_DIR/docs/openapi"
PORT="${1:-8088}"

[ -f "$DOCROOT/index.html" ] || { echo "missing portal: $DOCROOT/index.html (run scripts/generate-openapi.sh first)" >&2; exit 1; }

HOST="${OPENAPI_SWAGGER_HOST:-127.0.0.1}"
REGISTRY="${RE_REGISTRY_PATH:-/tmp/re-registry/re-registry.json}"

# The lane's TLS (#730): OPENAPI_TLS_CERT/KEY make the portal serve TLS 1.3.
TLS_ARGS=()
SCHEME=http
if [ -n "${OPENAPI_TLS_CERT:-}" ]; then
  TLS_ARGS=(--tls-cert "$OPENAPI_TLS_CERT" --tls-key "${OPENAPI_TLS_KEY:?OPENAPI_TLS_CERT is set, so OPENAPI_TLS_KEY must be too}")
  SCHEME=https
fi

echo "Serving $DOCROOT on $SCHEME://${HOST}:${PORT}/"
echo "  Swagger portal : $SCHEME://${HOST}:${PORT}/"
echo "  Raw specs      : $SCHEME://${HOST}:${PORT}/{cpp,lsp,scala}-{re,pe}.yaml"
echo "  Proxy          : $SCHEME://${HOST}:${PORT}/proxy/{cpp,lsp,scala}/{re,pe}/..."
echo "Ctrl-C to stop."
exec python3 "$CI_DIR/scripts/serve_openapi.py" \
  --host "$HOST" \
  --port "$PORT" \
  --docroot "$DOCROOT" \
  --registry "$REGISTRY" \
  ${TLS_ARGS[@]+"${TLS_ARGS[@]}"}
