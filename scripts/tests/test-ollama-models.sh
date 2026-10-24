#!/usr/bin/env bash
# startUniverse.sh checks the Ollama models its consumers actually resolve
# (scripts/lib/ollama-models.sh).
#
# On 2026-10-24 the old check printed "Model: llama3.1:8b" (any tag containing
# "llama3") and "Model: ternary-bonsai:4" (CI's .env, which localAI never
# reads) on a universe whose localAI ran nemotron-3-nano:4b and
# nomic-embed-text, and said nothing about OpenClaw agents still pinned to
# llama3.1:8b.
#
# Sandboxed: fake localAIStack and localOpenClawStack directories in a temp dir
# and a literal /api/tags document. Nothing is started and Ollama is not called.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../lib/ollama-models.sh
source "$CI_DIR/scripts/lib/ollama-models.sh"
unset LLM_MODEL EMBED_MODEL

fails=0
check() { # <name> <expected> <actual>
  if [ "$2" == "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; fails=$((fails + 1)); fi
}

LAS="$TMP/las"; OCS="$TMP/ocs"
mkdir -p "$LAS" "$OCS/openclaw"
cat > "$LAS/docker-compose.yml" <<'YML'
    environment:
      LLM_MODEL: "${LLM_MODEL:-compose-llm:1b}"
      EMBED_MODEL: "${EMBED_MODEL:-compose-embed}"
YML

echo "localAI: compose defaults when nothing else is set"
check "defaults" "localai-llm	compose-llm:1b
localai-embed	compose-embed" "$(universe_ollama_models "$LAS")"

echo "localAI: localAIStack/.env beats the compose default"
printf 'LLM_MODEL=nemotron-3-nano:4b\nEMBED_MODEL="nomic-embed-text"\n' > "$LAS/.env"
check ".env" "localai-llm	nemotron-3-nano:4b
localai-embed	nomic-embed-text" "$(universe_ollama_models "$LAS")"

echo "localAI: an exported variable beats .env; an unexported one does not"
EMBED_MODEL=unexported-embed
check "unexported ignored" "localai-embed	nomic-embed-text" "$(universe_ollama_models "$LAS" | grep embed)"
check "exported wins" "localai-embed	exported-embed" "$(EMBED_MODEL=exported-embed universe_ollama_models "$LAS" | grep embed)"
unset EMBED_MODEL

echo "OpenClaw: every distinct ollama model it assigns, defaults first"
cat > "$OCS/openclaw/openclaw.json" <<'JSON'
{"agents": {"defaults": {"model": {"primary": "ollama/nemotron-3-nano:4b"}},
            "list": [{"id": "main", "model": {"primary": "ollama/llama3.1:8b"}},
                     {"id": "a", "model": {"primary": "ollama/nemotron-3-nano:4b"}},
                     {"id": "b", "model": {"primary": "openai-codex/gpt-5.5"}},
                     {"id": "c"}]}}
JSON
check "openclaw" "openclaw	nemotron-3-nano:4b
openclaw	llama3.1:8b" "$(universe_ollama_models "$LAS" "$OCS" | grep openclaw)"
check "no ocs dir → no openclaw lines" "0" "$(universe_ollama_models "$LAS" "" | grep -c openclaw || true)"
check "no config yet → no openclaw lines" "0" "$(universe_ollama_models "$LAS" "$TMP/none" | grep -c openclaw || true)"

echo "ollama_has_model: exact tag, bare name means :latest"
TAGS='{"models":[{"name":"llama3.1:8b"},{"name":"nomic-embed-text:latest"}]}'
r() { if ollama_has_model "$TAGS" "$1"; then echo yes; else echo no; fi; }
check "exact" yes "$(r llama3.1:8b)"
check "bare → :latest" yes "$(r nomic-embed-text)"
check "substring is not a match" no "$(r llama3)"
check "other tag is not a match" no "$(r llama3.1:70b)"
check "missing" no "$(r nemotron-3-nano:4b)"
check "bad tags json" no "$(if ollama_has_model "not json" llama3.1:8b; then echo yes; else echo no; fi)"

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
