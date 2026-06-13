#!/usr/bin/env bash
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$CI_DIR/.." && pwd)"

canonical="$ROOT_DIR/RealityEngine_CPP/SURFACE_SPEC.md"
targets=(
  "$ROOT_DIR/RealityEngine_LSP/SURFACE_SPEC.md"
  "$ROOT_DIR/RealityEngine_Scala/SURFACE_SPEC.md"
  "$ROOT_DIR/RealityEngine_Manager/SURFACE_SPEC.md"
)

[ -f "$canonical" ] || {
  echo "missing canonical surface spec: $canonical" >&2
  exit 1
}

for target in "${targets[@]}"; do
  [ -f "$target" ] || {
    echo "missing surface spec: $target" >&2
    exit 1
  }
  if ! cmp -s "$canonical" "$target"; then
    echo "SURFACE_SPEC drift: $target differs from $canonical" >&2
    exit 1
  fi
done

echo "SURFACE_SPEC copies match canonical: $canonical"
