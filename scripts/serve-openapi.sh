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

echo "Serving $DOCROOT on http://localhost:${PORT}/"
echo "  Swagger portal : http://localhost:${PORT}/"
echo "  Raw specs      : http://localhost:${PORT}/{cpp,lsp,scala}-{re,pe}.yaml"
echo "Ctrl-C to stop."
exec python3 -m http.server "$PORT" --directory "$DOCROOT"
