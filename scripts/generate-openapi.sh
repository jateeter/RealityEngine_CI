#!/usr/bin/env bash
# Generate per-runtime OpenAPI YAML from SURFACE_SPEC.md + runtime overlays.
#
# Usage (from RealityEngine_CI root):
#   bash scripts/generate-openapi.sh [--propagate]
#
# --propagate   Also copy generated RE/PE YAML into each runtime repo's
#               docs/openapi/ directory (requires sibling repos to be checked out).
#
# Output: docs/openapi/{cpp,lsp,scala}-{re,pe}.yaml
# Source: RealityEngine_CPP/SURFACE_SPEC.md (canonical)
#         scripts/openapi/overlays/{cpp,lsp,scala}.yaml

set -euo pipefail
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="$(cd "$CI_DIR/.." && pwd)"
SCRIPT="$CI_DIR/scripts/openapi/generate.py"
SPEC="$WS/RealityEngine_CPP/SURFACE_SPEC.md"
OVERLAY_DIR="$CI_DIR/scripts/openapi/overlays"
OUT_DIR="$CI_DIR/docs/openapi"
PROPAGATE=false

for arg in "$@"; do
  [ "$arg" = "--propagate" ] && PROPAGATE=true
done

[ -f "$SPEC" ] || { echo "missing: $SPEC" >&2; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "pip3 install pyyaml"; exit 1; }

for runtime in cpp lsp scala; do
  python3 "$SCRIPT" \
    --spec    "$SPEC" \
    --overlay "$OVERLAY_DIR/${runtime}.yaml" \
    --out-re  "$OUT_DIR/${runtime}-re.yaml" \
    --out-pe  "$OUT_DIR/${runtime}-pe.yaml"
done

echo "generated: $OUT_DIR/{cpp,lsp,scala}-{re,pe}.yaml"

if $PROPAGATE; then
  cp "$OUT_DIR/cpp-re.yaml"   "$WS/RealityEngine_CPP/docs/openapi/reality-engine.yaml"
  cp "$OUT_DIR/cpp-pe.yaml"   "$WS/RealityEngine_CPP/docs/openapi/perception-engine.yaml"
  cp "$OUT_DIR/lsp-re.yaml"   "$WS/RealityEngine_LSP/docs/openapi/reality-engine.yaml"
  cp "$OUT_DIR/lsp-pe.yaml"   "$WS/RealityEngine_LSP/docs/openapi/perception-engine.yaml"
  for runtime in cpp lsp scala; do
    cp "$OUT_DIR/${runtime}-re.yaml" "$WS/RealityEngine_Manager/docs/openapi/${runtime}-re.yaml"
    cp "$OUT_DIR/${runtime}-pe.yaml" "$WS/RealityEngine_Manager/docs/openapi/${runtime}-pe.yaml"
  done
  echo "propagated to RealityEngine_CPP, RealityEngine_LSP, and RealityEngine_Manager"
fi
