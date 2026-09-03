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

**Canonical default: `llama3.1:8b`.** Every runtime — C++, LSP, Scala and the
TypeScript PE — resolves this when nothing else is set. This document is the
source of truth; each engine's code comment points here rather than restating it.

Resolution order, identical on every runtime:

| Rank | Source |
|---|---|
| 1 | `OLLAMA_MODEL` in the engine's environment — the per-engine override |
| 2 | `model` on the `kind: "ollama"` entry in the integration registry |
| 3 | the canonical default above |

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

## Registry entry

`config/integrations.json`, `ollama-local`:

```json
{
  "id": "ollama-local",
  "kind": "ollama",
  "enabled": false,
  "baseUrl": "http://localhost:11434",
  "model": "llama3.1:8b",
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

# Pin one model across all three native engines
OLLAMA_MODEL=llama3.1:8b ./scripts/regression-test.sh --profile local
```
