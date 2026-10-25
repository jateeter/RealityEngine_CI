#!/usr/bin/env bash
# The release bundle names ONE embedding default, and it is the one localAIStack's
# model registry declares, and it runs on MLX (RealityEngine_CI#593).
#
# The embedder was once written down in four places that disagreed: the registry
# said nomic-embed-text, localAI's config said ternary-bonsai:4 (marked broken),
# and the release compose and CLI each carried their own default. A model change
# then silently meant a different default in each. Owner rule, 2026-10-24: each
# role's default must run on MLX; any other model may run on either runtime.
#
# Always asserted: compose (localAI and Open WebUI) and the CLI's model check
# agree. Asserted when a localAIStack checkout is a sibling (or LOCALAISTACK_DIR):
# that default equals the registry's, and the registry declares it `mlx`. Without
# one the registry half is reported as SKIPPED, not passed.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
check() { # <name> <expected> <actual>
  if [ "$2" == "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; fails=$((fails + 1)); fi
}

compose_default() { # <VAR> <file>: the ${VAR:-default} on the line that sets it
  sed -nE "s/^[[:space:]]*${1}:[[:space:]]*\\\$\\{EMBED_MODEL:-([^}]+)\\}.*/\\1/p" "$2" | head -1
}

localai="$(compose_default EMBED_MODEL "$CI_DIR/release/compose.yml")"
webui="$(compose_default RAG_EMBEDDING_MODEL "$CI_DIR/release/compose.yml")"
cli="$(sed -nE 's/.*for m in nemotron-3-nano:4b-mlx "\$\{EMBED_MODEL:-([^}]+)\}".*/\1/p' "$CI_DIR/release/realityengine" | head -1)"

echo "release embedding default"
check "compose names a default for localAI" yes "$([ -n "$localai" ] && echo yes || echo no)"
check "Open WebUI embeds with the same model as localAI" "$localai" "$webui"
check "the CLI's Ollama check expects the same model" "$localai" "$cli"

las="${LOCALAISTACK_DIR:-$CI_DIR/../localAIStack}"
reg="$las/config/models.registry.json"
if [ -f "$reg" ]; then
  default_tag="$(python3 -I - "$reg" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
rid = r["roles"]["embedding"]["default"]
m = next(x for x in r["models"] if x["id"] == rid)
print(m["tag"], m.get("runner", ""))
PY
)"
  check "localAI's registry default is the release default" "$localai" "${default_tag% *}"
  check "...and it declares the MLX runner" "mlx" "${default_tag#* }"
else
  echo "  SKIPPED  localAI registry comparison: no localAIStack checkout at $las (set LOCALAISTACK_DIR)"
fi

[ "$fails" -eq 0 ] && { echo "all ok"; exit 0; }
echo "$fails failure(s)"; exit 1
