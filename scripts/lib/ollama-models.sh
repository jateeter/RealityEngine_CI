#!/usr/bin/env bash
# The Ollama models this universe will ask for, resolved the way each consumer
# resolves its own, so startUniverse.sh checks what is actually used.
#
# The old check looked for any tag containing "llama3" and for EMBED_MODEL from
# CI's .env. It reported "Model: llama3.1:8b" on a universe running
# nemotron-3-nano:4b, and "Model: ternary-bonsai:4" (CI's .env.example value,
# which localAI never reads) while localAI embedded with nomic-embed-text. It
# also said nothing when OpenClaw's saved config still pinned its agents to a
# model the rest of the universe had left (2026-10-24).
#
#   universe_ollama_models <las_dir> [<ocs_dir>]
#       prints "<consumer>\t<model>" per model, one line each:
#         localai-llm, localai-embed: an exported LLM_MODEL / EMBED_MODEL, then
#           <las_dir>/.env, then the default in <las_dir>/docker-compose.yml —
#           compose's own precedence. CI's .env is not consulted.
#         openclaw: every distinct ollama/<model> that <ocs_dir>/openclaw/
#           openclaw.json assigns (agents.defaults and each agent), omitted
#           when the config does not exist yet (start.sh seeds it).
#   ollama_has_model <tags_json> <model>
#       exit 0 when /api/tags lists <model> exactly; a model named without a
#       tag means ":latest", as Ollama resolves it.

las_model() { # <las_dir> <VAR>
    local las="$1" var="$2" v=""
    v="$(printenv "$var" 2>/dev/null || true)"
    if [ -z "$v" ] && [ -f "$las/.env" ]; then
        v="$(grep -E "^${var}=" "$las/.env" | tail -1 | cut -d= -f2- | tr -d "\"'")"
    fi
    if [ -z "$v" ] && [ -f "$las/docker-compose.yml" ]; then
        v="$(sed -nE "s/.*\\\$\\{${var}:-([^}]+)\\}.*/\\1/p" "$las/docker-compose.yml" | head -1)"
    fi
    printf '%s' "$v"
}

universe_ollama_models() {
    local las="$1" ocs="${2:-}" m
    m="$(las_model "$las" LLM_MODEL)";   [ -n "$m" ] && printf 'localai-llm\t%s\n' "$m"
    m="$(las_model "$las" EMBED_MODEL)"; [ -n "$m" ] && printf 'localai-embed\t%s\n' "$m"
    if [ -n "$ocs" ] && [ -f "$ocs/openclaw/openclaw.json" ]; then
        python3 - "$ocs/openclaw/openclaw.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
agents = cfg.get("agents") or {}
seen = []
for a in [agents.get("defaults") or {}] + list(agents.get("list") or []):
    p = ((a.get("model") or {}).get("primary") or "")
    if p.startswith("ollama/") and p[7:] not in seen:
        seen.append(p[7:])
for m in seen:
    print(f"openclaw\t{m}")
PY
    fi
}

ollama_has_model() {
    printf '%s' "$1" | python3 -c '
import json, sys
want = sys.argv[1] if ":" in sys.argv[1] else sys.argv[1] + ":latest"
try:
    names = {m.get("name") for m in json.load(sys.stdin).get("models", [])}
except ValueError:
    names = set()
sys.exit(0 if want in names else 1)' "$2"
}
