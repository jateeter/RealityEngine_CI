# Ollama Integration — the MCP pattern

Scope: `RealityEngine_CPP`, `RealityEngine_LSP`, `RealityEngine_Scala`, and the TypeScript PE in `RealityEngine_Manager`. The integration owner for cross-engine defaults, orchestration, and the local regression lane is `RealityEngine_CI`.

## Which pattern this is

Two integration patterns sit under the same abstractions, and they differ in who
owns the work:

| | **MCP — this document** | **ACP — `OPENCLAW_INTEGRATION.md`** |
|---|---|---|
| Who executes | PE, locally and under policy | an external harness PE never hosts |
| Tool loop | PE owns it, against a gated `allowedTools` list | outside PE entirely |
| PE call | `local-adapter`, caller-driven and explicit | no-wait handoff, `202 Accepted` |
| Registry | `mcp: { execution, allowedTools }` on the entry | `completionMode: "pe-source-mapping"` |
| Failure shows up as | a dispatch record annotated delivering/delivered/failed | a handoff receipt with no completion |

Ollama is the MCP pattern's worked instance: the model runs locally, PE owns
tool execution, structured-output validation, retry policy and the source commit,
and every capability the model can reach is a policy-gated MCP tool. Both
patterns end the same way — a completion resolved through a source mapping, per
`EXTERNAL_INTEGRATION_CONTRACT.md` §2.4 — and that shared ending is what keeps
them comparable.

## The contract this implements

The rules every external integration obeys — that projection is registry-owned
and never carried by the payload, that ingress is the only thing that activates a
source, that governance is CES-owned, that dispatch is fire-and-record and a
completion re-enters as an ordinary fact — are specified once:

    RealityEngine_CI/docs/EXTERNAL_INTEGRATION_CONTRACT.md

This document is a **worked instance** of that contract. It supplies what the
contract deliberately does not know: the local endpoint and model, the
`ollama-local` registry entry, the dispatch and completion shapes, and the
regression stage that holds the runtimes to a shared model.

Against the §5 verification ladder this integration stands at **rung 4** on the
local lane — a real Ollama daemon, reached over its real HTTP surface, with the
`local-ai` regression stage asserting reachability and model agreement. The
hosted lane refuses Ollama, so nothing there exercises it.

The per-runtime route surface is **not** restated here.
`GET /api/integrations/ollama/status` and `POST /api/integrations/ollama/dispatch`,
and which runtimes implement them, live in `RealityEngine_CI/SURFACE_SPEC.md`.

## Model default and precedence

Two defaults exist, and they answer different questions.

- **The universe model: `nemotron-3-nano:4b-mlx`.** The model all RealityEngine
  testing and development runs against. The regression local lane pins it
  (below), `localAIStack` selects it as its LLM, and the native OpenClaw gateway
  and the release bundle default to it. It is the MLX build of NVIDIA's
  Nemotron 3 Nano 4B (safetensors, nvfp4, about 2.9 GB, 256K context, tools and
  thinking), pulled from the Ollama library (`ollama pull
  nemotron-3-nano:4b-mlx`, which needs Ollama 0.40.5 or later). The plain
  `nemotron-3-nano:4b` tag is the GGUF build (Q4_K_M) and runs on llama.cpp,
  not MLX. Measured on an M1 Pro with Ollama 0.40.11 on 2026-10-25: the MLX build
  generated 36.4 tokens/s against 25.3, and held 3.8 GB of GPU memory against
  2.8 GB.
- **The engine built-in default: `llama3.1:8b`.** What each runtime — C++, LSP,
  Scala and the TypeScript PE — resolves when nothing pins a model. It lives in
  the engine repos, is unchanged, and is rank 3 below. This document is its
  source of truth; each engine's code comment points here rather than restating it.

Resolution order, identical on every runtime:

| Rank | Source |
|---|---|
| 1 | `OLLAMA_MODEL` in the engine's environment — the per-engine override |
| 2 | `model` on the `kind: "ollama"` entry in the integration registry |
| 3 | the engine built-in default (`llama3.1:8b`) |

The local lane supplies rank 1, so the universe model reaches every engine it
starts; an engine started outside the lane, with nothing pinned, still resolves
`llama3.1:8b`.

The same order applies to `OLLAMA_BASE_URL` and the registry's `baseUrl`.

Two reasons the ordering is fixed rather than incidental. An explicit
environment variable is an operator instruction and must outrank a file that
ships with the repo — LSP and the TypeScript PE both had this inverted, so a
pinned model silently reached some engines and not others
(`RealityEngine_LSP#44`). And the runtimes must agree by default: they previously
resolved `gpt-oss:20b`, `llama3.2` and empty string respectively, which makes
comparing provider output across runtimes meaningless before it starts
(`RealityEngine_Scala#38`).

Overriding stays per engine. Setting `OLLAMA_MODEL` for one instance changes only
that instance; the regression local lane exports it once so all three native
engines share a model.

### Defaults run on MLX

Owner rule (2026-10-24, RealityEngine_CI#593): each role's **default** model must
run on MLX; any other model may run on MLX or ggml. Ollama reports the runtime
per model in `GET /api/tags` (`details.runner`), and that is what is measured
here, not inferred from the model's format:

| role | default | runner | other measured |
|---|---|---|---|
| LLM | `nemotron-3-nano:4b-mlx` | `mlx` | `nemotron-3-nano:4b` `llamacpp`, `llama3.1:8b` `ggml`, `gemma3:4b` `llamacpp` |
| embedding | `embeddinggemma-2:270m` | `mlx` | `nomic-embed-text` `ggml` |

localAIStack's registry declares `runner` per model and a test fails if a role's
default does not declare `mlx`. The embedder is the same in localAI, Open WebUI,
the release compose file and the CLI's model check
(`scripts/tests/test-release-embed-default.sh`). Vectors from two embedders do not
mix even at the same dimension (both are 768), so changing it re-embeds localAI's
Qdrant collections behind an alias (`realityengine reembed`; `make reembed` in
localAIStack). `ollama show embeddinggemma-2:270m` reports an embedding length of
512 while the model returns 768-dim vectors, so the dimension is probed, not read.

### Structured output (`format`) — all four PEs behave identically

A native Ollama dispatch normally sends `format` (C++/Scala/TypeScript: `"json"`;
LSP: a JSON schema built from the source mapping) so the model's reply parses and
carries the keys the source mapping extracts. Ollama refuses it for some models.
The rule, held **identically** by the C++, LSP and Scala PEs and the Manager
TypeScript PE:

1. A request-level `formatJson` (dispatch body; `formatJson` in the TypeScript
   integration entry) wins in both directions: `false` omits `format`, `true`
   sends it.
2. Otherwise `format` is sent unless the model family (the tag before `:`) is in
   the engine's no-structured-output list. The list is currently
   `nemotron-3-nano`, kept in each engine at the symbol named in that repo's
   `CLAUDE.md`.
3. **When `format` is omitted, the prompt carries what `format` would have.** The
   engine appends this to the system prompt, built from the source mapping's
   pointers in declaration order (the top-level key of each, de-duplicated):

   ```text

   Respond with ONLY one JSON object, with no prose and no markdown fences, that has exactly these keys, each a number or boolean: k1, k2. For example: {"k1": 0, "k2": 0}
   ```

   (A mapping with no pointers gets `... that has exactly this key, an array of
   numbers: values. For example: {"values": [0]}`.) The text is **byte-identical**
   in all four engines, so one model sees one prompt whichever engine asks.
4. For models in the list the engine also sends `think: false`.

Why 3 and 4 exist. Omitting `format` alone left the reply unconstrained: on the
RC3 universe (2026-10-24) a dispatch failed on C++ and Scala with `missing
required JSON pointer: /completed`, and on LSP with its 10 s total timeout,
because the default prompt never named the mapping's keys and thinking made the
free-form answer slow. Measured on `nemotron-3-nano:4b` with the `agent-completion-risk`
mapping:

| system prompt | thinking | valid reply |
|---|---|---|
| no contract | on | 0/2 |
| JSON Schema as text | on | 4/4, 2-5 s |
| required keys + example (this contract) | on | 6/8, 0.5-8 s |
| required keys + example (this contract) | off | 8/8, 0.4 s |

**Parity is a contract, not a convenience.** The three engines are compared byte
for byte; if one sent `format` and another did not, or showed the model a
different prompt, the same model would answer differently per engine and the
sweep would attribute it to the engine. A change to the list, the prompt text or
the rule lands in all four repos in one sweep. (The C++ PE additionally accepts
an explicit `format` string in the body; that is a C++-only escape hatch and not
part of the contract. The engines' *default* system prompts still differ by
engine; only the appended contract is shared.)

### What `nemotron-3-nano:4b` cannot do

Both builds (`:4b-mlx`, the universe model, and the GGUF `:4b`) declare
`completion`, `tools` and `thinking`. Observed on the GGUF build against
Ollama 0.40.6 on 2026-10-24:

- a request carrying `tools` is honoured and returns `tool_calls`, so the agent
  graph (`bind_tools`) and OpenClaw runs that advertise tools work on the
  universe model;
- **structured output is refused.** Both `format: "json"` and a JSON-schema
  `format` return `{"error":"structured output is unavailable"}`. See
  "Structured output" below for what the engines do about it;
- `thinking` is on by default and does not help when the task is to fill in
  named fields: the engines send `think: false` for this model (measured below).

**Ollama 0.40.11 no longer refuses `format`.** On 2026-10-25 both builds
answered `format: "json"` and a JSON-schema `format` with conforming JSON. The
PEs still omit `format` for the whole `nemotron-3-nano` family, keyed on the
name before the colon, so `:4b-mlx` is treated like `:4b`. Sending `format`
again changes all four PE runtimes together and needs the Ollama minimum raised
to 0.40.11; it has not been done.

The interim universe model `gemma3:4b` honoured `format: "json"` but refused
`tools`. `tinyllama-mlx` (TinyLlama 1.1B Chat on the MLX runner), the model
before it, had a 2048-token context that could not hold an OpenClaw agent
prompt, and it refused both tools and `format: "json"`.

## Registry entry

`config/integrations.json`, `ollama-local`:

```json
{
  "id": "ollama-local",
  "kind": "ollama",
  "enabled": false,
  "baseUrl": "http://localhost:11434",
  "model": "nemotron-3-nano:4b-mlx",
  "apiMode": "native",
  "completionSourceMappingId": "agent-completion-risk",
  "mcp": {
    "execution": "local",
    "allowedTools": ["re.read_state", "pe.list_sources"]
  },
  "completionMode": "local-adapter"
}
```

Completions land through the `agent-completion-risk` source mapping —
`sensorIdTemplate` `agent.{agent}.completion`, region `[4200:4204]`, json
pointers `/completed`, `/failed`, `/confidence`, `/actionClass`, passthrough with
clamp, `ttlMs` 300000, debounced push. Per
`EXTERNAL_INTEGRATION_CONTRACT.md` §2.1, that mapping is the sole authority for
where a model response lands; the response never names a region.

The `mcp` block is what makes this the MCP pattern rather than a plain HTTP
provider call. `execution: "local"` says PE runs the tool loop in-process, and
`allowedTools` is the whole capability surface the model can reach — here
`re.read_state` and `pe.list_sources`, both read-only. Per
`INTEGRATION_ARCHITECTURE.md` § MCP Gateway, mutating tools must be
policy-gated; a model reaching a mutating tool that is not on this list is a
policy failure, not a configuration one.

## Dispatch

Ollama dispatch uses the local `/api/chat`, `/api/generate`, `/api/embed`, or
OpenAI-compatible endpoints. PE owns tool execution, structured-output
validation, retry policy, and source commits.

- `GET /api/integrations/ollama/status` reports the configured local endpoint,
  model, default completion mapping, and `/api/tags` reachability.
- `POST /api/integrations/ollama/dispatch` takes a recorded `dispatchId`, builds
  an Ollama `/api/chat` request from the trigger envelope, annotates the dispatch
  record as delivering/delivered/failed, and, when the model response contains a
  JSON `values` array, commits the result through
  `POST /api/integrations/completions`.
- `bin/reality_engine_cli pe ollama-dispatch <dispatchId>` wraps the same HTTPS
  endpoint for local scripts and future MCP tools.

The adapter is explicit and caller-driven. Per the contract's §2.4, PE push
cycles never wait on Ollama, model execution, tool calls, or completion handling.

## Regression coverage

`scripts/regression-local-ai.py` runs on the local lane — the hosted lane refuses
Ollama and localAIStack, so nothing there can say whether they work. Until this
stage existed, `--profile local` started them and then tested nothing, which
bought a slower run rather than more coverage.

Four things are checked, and they fail for different reasons:

1. localAIStack answers its health endpoint.
2. Every PE reports Ollama as reachable. A PE answering `reachable: false` is the
   interesting failure — the provider is supposed to be up on this lane, so a
   well-formed "not reachable" is still a defect.
3. Every PE agrees on which model it is configured for. Runtimes disagreeing
   about the model would make any downstream comparison meaningless.
4. The model each PE is configured for is actually installed. `reachable` only
   proves Ollama's HTTP surface answers — on the first live run of this probe all
   three PEs reported reachable while pointing at models the local Ollama did not
   have, so every dispatch would have failed against a stage that passed.

Check 4 is the one worth keeping in mind when reading a green `local-ai` result:
it is the difference between "the daemon is up" and "this will actually
dispatch".

## Running it

```bash
# Bring the universe up with the local AI support the stage needs
./startUniverse.sh --engines=cpp:1,lsp:1,scala:1 --warn-only

# Probe the local AI surfaces
python3 scripts/regression-local-ai.py

# Pull the universe model once
ollama pull nemotron-3-nano:4b-mlx

# The local lane pins nemotron-3-nano:4b-mlx by default; name another to override it
./scripts/regression-test.sh --profile local
OLLAMA_MODEL=nemotron-3-nano:4b ./scripts/regression-test.sh --profile local
```
