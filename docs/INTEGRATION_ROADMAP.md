# Integration Architecture — Roadmap for RealityEngine_AI

Companion to [`INTEGRATION_ARCHITECTURE.md`](./INTEGRATION_ARCHITECTURE.md).

This roadmap is scoped to **RealityEngine_AI** — the TypeScript Perception Engine
under `perception-engine/backend/`, its MCP gateway, the example trigger
artifacts under `examples/triggers/`, the integration registry example under
`config/`, and the LangGraph orchestrator under `langgraph-orchestrator/`.

The architecture document enumerates the shared PE integration contract. This
roadmap started as the `_AI` gap plan; the registry, source mapper, trigger
dispatcher, dispatch ledger, completion ingest, OpenAI/Ollama bridges,
HealthKit/CareKit intake, and ACP/OpenClaw xACP handoff are now implemented in
the TypeScript PE. Remaining work should treat the tables below as planning
history where an item is already marked present in code.

---

## 1. Current State (RealityEngine_AI)

### 1.1 Perception Engine HTTP surface (`perception-engine/backend/src/server.ts`)

Routes present (22 total):

| Group | Endpoint |
|---|---|
| Lifecycle | `GET /api/health`, `GET /api/metrics`, `GET /api/state`, `POST /api/push`, `POST /api/auto/start`, `POST /api/auto/stop`, `PATCH /api/config`, `POST /api/reset` |
| Sources / sensors | `GET/POST /api/sources`, `PATCH/DELETE /api/sources/:id`, `POST /api/sensors/:id`, `POST /api/sources/bootstrap-from-machines` |
| MQTT bridge | `GET /api/mqtt/status`, `GET/PUT /api/mqtt/mappings`, `POST /api/mqtt/enable`, `POST /api/mqtt/disable`, `GET /api/mqtt/example` |
| Machines | `GET /api/machines` |

### 1.2 MCP gateway (`perception-engine/backend/src/mcp.ts`)

Server name: `reality-engine-perception`. Tools registered (snake_case):

```
perception_get_state, perception_push, perception_start_auto, perception_stop_auto,
perception_reset, perception_set_match_algorithm,
sources_list, sources_add_simulated, sources_add_sensor, sources_add_test,
sources_update, sources_delete, sensor_push_value,
reality_engine_health, machines_list, machines_load_json,
perceptual_sim_state, perceptual_sim_step, perceptual_sim_start, perceptual_sim_stop,
perceptual_sim_reset, perceptual_sim_history, demo_load
```

### 1.3 Integration contracts present

- `config/integrations.example.json` — full registry example (defaults,
  `integrations[]` for `mqtt`/`localai`/`openai`/`ollama`/`acp`/`healthkit`,
  `sourceMappings[]`). The TS loader indexes these mappings at startup.
- `examples/triggers/ai_trigger_envelope.template.json` — canonical
  `ces.terminal.event` envelope schema.
- `examples/triggers/ai_trigger.*.example.json` and
  `scenario_aqua_urgent_chain.json` — concrete envelope examples.
- `examples/triggers/graphql_trigger_template.py` — Python reference dispatcher
  to localAIStack `updateProcessState`.

### 1.4 Other components in this repo (not in the architecture doc)

- **`langgraph-orchestrator/`** — Python LangGraph service (`graph.py`,
  `clients.py`, `perception_bridge.py`, `dc_*` data-center adapters,
  `vector_encoding.py`). Currently a parallel orchestration surface, not
  connected to a PE dispatch ledger.
- **`visualizer/frontend/`** — React UI (the Machine Interconnection view,
  CES tooltip subsystem, Logs viewer, PE sources panel).
- **`perception-engine/backend/src/MqttBridge.ts` + `MqttMapping.ts`** —
  working MQTT integration (the only provider adapter wired end-to-end).

---

## 2. Gap Analysis vs `INTEGRATION_ARCHITECTURE.md`

Legend: ✅ present · ⚠️ partial/data-only · ❌ missing.

| Architecture element | _AI status | Notes |
|---|---|---|
| Provider-neutral commit semantics (sensor-source shape) | ✅ | `/api/sources`, `/api/sensors/:id` already commit to PE state. |
| **Integration Registry loader** (`INTEGRATIONS_CONFIG` / `config/integrations.json`) | ✅ | Loader and C++-compatible status shape are implemented. |
| **Source Mapper** — startup-resolved `sourceMappingId` → sensor source | ✅ | Generalized mapper backs completion ingest and bridge adapters. |
| **Trigger Envelope Dispatcher** — observe `mergeBatch`, build `ces.terminal.event` | ✅ | Dispatcher records envelopes without blocking PE push. |
| **Dispatch Ledger** — `GET /api/dispatch/ledger`, `GET/PATCH /api/dispatch/records/{id}` | ✅ | In-memory ring plus optional JSONL persistence. |
| **Completion Ingest** — `POST /api/integrations/completions` | ✅ | Provider-neutral completion path routes through `/api/signals`. |
| **`GET /api/integrations/status`** | ✅ | Reports loaded registry and source mappings. |
| **`GET /api/triggers/status`** | ✅ | Reports dispatcher counters and replay count. |
| Env flags `TRIGGERS_ENABLED`, `TRIGGER_DISPATCH_MODE`, `TRIGGER_GRAPHQL_URL` | ✅ | Read at PE startup. |
| **MCP recommended tools** (`re.read_state`, `re.list_machines`, `re.read_machine`, `pe.list_sources`, `pe.push_signal`, `pe.enqueue_push`, `trigger.replay`, `dispatch.read_ledger`) | ⚠️ | TS gateway exposes equivalent capabilities under snake_case names; **none of the `trigger.*` / `dispatch.*` tools exist**, and naming differs from the spec. |
| Mutating MCP tool policy gate | ❌ | All MCP tools are currently unguarded. |
| Provider adapters: **OpenAI** | ✅ | Responses/chat-compatible adapter and webhook completion path. |
| Provider adapters: **Ollama** | ✅ | Native and OpenAI-compatible local adapter. |
| Provider adapters: **ACP / OpenClaw xACP** | ✅ | No-wait handoff adapter plus status/dispatch routes. |
| Provider adapters: **HealthKit** bridge intake | ✅ | Authorized bridge payloads map through source mappings. |
| Provider adapters: **localAIStack GraphQL** | ⚠️ | Python reference template only; no in-process dispatcher. |
| Provider adapters: **MQTT** | ✅ | Already wired. |
| Provider adapters: **Manual** (CLI/test) | ✅ | Covered by `/api/signals` and `/api/integrations/completions`. |

### 2.1 Extensions _AI carries beyond the architecture doc

These are real, deployed concerns the roadmap should fold in:

- **LangGraph orchestrator** as an alternative dispatch target / consumer of
  envelopes. The architecture doc treats agents as opaque externals; in _AI
  there is a first-party LangGraph service that should be a registered
  `kind: "langgraph"` integration with `mcp.execution: local`.
- **Frontend dispatch/ledger UX**. The architecture doc is silent on UI; _AI
  already has the visualizer that is the natural home for a Dispatch Ledger
  viewer, Trigger Status panel, and per-machine envelope replay.
- **Bootstrap-from-machines** (`POST /api/sources/bootstrap-from-machines`)
  is _AI-specific and worth preserving as the source-of-truth for default
  source mappings derived from machine `perceptualMapping`.
- **`PerceptualSpaceSimulator`** is the TS engine that produces the
  `mergeBatch` entries the dispatcher must observe — the integration point
  for the trigger dispatcher lives in `perception-engine/backend/src/PerceptionEngine.ts`
  (and the visualizer's WebSocket frame `perceptual-simulation-stepped`,
  which already carries `mergeBatch`).

---

## 3. Development Roadmap

Six phases in dependency order. Each phase is independently shippable.
Effort labels are deliberate: **S** ≈ 1–2 days, **M** ≈ 3–5 days, **L** ≈ 1–2 weeks.

### Phase 0 — Integration Registry loader (foundation) · **S**

**Deliverable.** TS module that loads `config/integrations.json` (or path from
`INTEGRATIONS_CONFIG`) at PE startup, validates against the example schema,
exposes a typed `IntegrationRegistry` to the rest of the backend.

**Files.**
- new `perception-engine/backend/src/integrations/Registry.ts`
- new `perception-engine/backend/src/integrations/types.ts`
- `server.ts` — bootstrap call + cached singleton
- new `GET /api/integrations/status` returning the **C++-compatible** shape:
  ```
  { loaded, path, error,
    integrationCount, sourceMappingCount,
    integrations: [{ id, kind, enabled }],
    sourceMappings: [{ id, sensorId, sensorIdTemplate, region, ttlMs }],
    completionEndpoint }
  ```

**Acceptance.**
- `INTEGRATIONS_CONFIG=config/integrations.example.json` boot logs
  `"Loaded 5 integrations, 1 sourceMapping"`.
- `GET /api/integrations/status` returns the shape above, byte-compatible with
  `RealityEngine_CPP` (`integration_status()` in `src/perception_engine_server.cpp`).
- Absent file: PE starts, registry empty, status reports `loaded: false`,
  `path: null`, `error: null`.
- Unit tests for valid/invalid registries.

**Dependencies.** None.

---

### Phase 1 — Source Mapper + Completion Ingest · **M**

**Deliverable.** Provider-neutral commit endpoint and the resolver that turns
a `sourceMappingId` (or inline `sourceMapping`) into a concrete sensor write.

**Files.**
- new `perception-engine/backend/src/integrations/SourceMapper.ts` — resolves
  `sourceMappingId` → `{ sensorId, region, ttlMs }`. Must support the **same
  template tokens** the C++ ingestor honours in `sensorIdTemplate`:
  `{provider}`, `{agent}`, `{correlationId}`, `{envelopeId}`. Default
  `sensorId` when nothing resolves: `agent.<agent>.completion`.
- new `perception-engine/backend/src/integrations/extractors.ts` — JSON-pointer
  extractor (`extract.type: "json"`) plus passthrough/clamp normalization to
  match the registry schema.
- `server.ts` — two routes, both wire-compatible with the C++ handlers:
  - `POST /api/signals` — underlying primitive (publicly exposed in C++ —
    keep it public here). Body: `values: number[]` (required, non-empty) +
    one of `sensorId` (string) or `region: {offset, length}`. Optional:
    `name`, `active` (default true), `ttlMs` (default `30000`),
    `triggerPush` (default false), `compactPush` (default true).
    Response: `{ success, timestamp, source, push? }`.
  - `POST /api/integrations/completions` — provider-neutral adapter that
    builds a signal body and calls the signal path. Accepted body fields:
    `sourceMappingId` (also accept legacy alias `mappingId`); optional
    inline `sourceMapping` (merged onto the registry mapping); `provider`
    (default `"external"`); `agent` (also accept `agentId`, default
    `"agent"`); `sensorId` (overrides mapping); `correlationId`,
    `envelopeId`, `completionId` (also accept `id`); `values`, `active`,
    `ttlMs` (default `300000`); `triggerPush` (default `false`),
    `compactPush` (default `true`); `metadata` (object passthrough).
  - On success, broadcast WebSocket event
    `{ type: "agent.completion.received", provider, agent, sensorId,
       sourceMappingId, correlationId, envelopeId, timestamp }`
    (matches C++ broadcast — the visualizer in Phase 6 subscribes to this).

**Acceptance.**
- Curl with the example body in §Completion Ingest of the architecture doc
  commits a 4-cell update at offset 4200.
- Inline override path (`sourceMapping`) works without a registry entry;
  inline `sensorId` / `region` override the resolved mapping.
- Unknown `sourceMappingId` returns 404 with a typed error
  (`Unknown sourceMappingId "<id>"`) matching C++ wording.
- Default-`triggerPush` is **false** — i.e. commit-only — matching C++.
- WS broadcast for completion received fires with the documented payload.

**Dependencies.** Phase 0.

---

### Phase 2 — Trigger Envelope Dispatcher · **M**

**Deliverable.** A subscriber on `PerceptionEngine` step events that scans
`mergeBatch` for governance-resolved trigger outputs and emits
`ces.terminal.event` envelopes. Fire-and-record only; never blocks the PE
cycle.

**Files.**
- new `perception-engine/backend/src/triggers/Dispatcher.ts`
- new `perception-engine/backend/src/triggers/envelopeBuilder.ts` — populates
  the canonical fields from `MergeOperation` + machine
  `metadata.triggerConfig` / `metadata.dispatchableAgent` / `metadata.aiTrigger`.
- `PerceptionEngine.ts` — emit a `mergeBatch` event the dispatcher listens to.
- Env flags read at boot (match C++ exactly):
  - `TRIGGERS_ENABLED` (bool — `triggerDispatchEnabled`)
  - `TRIGGER_DISPATCH_MODE` (default `"dry-run"`)
  - `TRIGGER_GRAPHQL_URL` (default `<LOCAL_AI_BASE_URL>/graphql`)
- new route `GET /api/triggers/status` returning the **C++-compatible** shape:
  ```
  { enabled, mode, graphqlEndpoint,
    records,
    envelopesCreated,
    droppedNoGovernance,
    droppedNoDispatch,
    dispatchErrors }
  ```

**Acceptance.**
- With `TRIGGERS_ENABLED=true TRIGGER_DISPATCH_MODE=dry-run`, every machine
  fire whose JSON carries a `triggerConfig` produces an envelope that
  matches the `examples/triggers/ai_trigger_envelope.template.json` shape
  (validated by JSON Schema).
- Counters `envelopesCreated` / `droppedNoGovernance` / `droppedNoDispatch`
  in `/api/triggers/status` increment as expected.
- Replay from `examples/triggers/ai_trigger.agx051_urgent_maint.example.json`
  through PE produces an envelope deep-equal to the example (modulo IDs/timestamps).

**Dependencies.** Phase 0 (status endpoint pattern).

---

### Phase 3 — Dispatch Ledger · **M**

**Deliverable.** Persisted outbox/audit record for every envelope the
dispatcher builds, plus the three documented routes.

**Files.**
- new `perception-engine/backend/src/dispatch/Ledger.ts` — in-memory ring with
  optional `DISPATCH_LEDGER_FILE` JSONL append for crash-survivable audit.
- new `perception-engine/backend/src/dispatch/types.ts`
- `server.ts` — three routes, all wire-compatible with C++:
  - `GET /api/dispatch/ledger` — **no query params** (C++ ignores them).
    Response: `{ enabled, mode, records: DispatchRecord[] }`.
  - `GET /api/dispatch/records/:id` (use `:id`, **not** `{id}`). Response:
    `{ record }`; 404 with `"Dispatch record not found"` on missing.
  - `PATCH /api/dispatch/records/:id` — accepted body fields (matching
    `update_dispatch_record` in C++):
    `status` (string), `error` (string), `clearError` (bool),
    `attempts` (number) or `incrementAttempts` (bool),
    `providerReceipt` (object — merged onto existing),
    `provider` (string — folded into `providerReceipt.provider`),
    `adapter` (string — folded into `providerReceipt.adapter`),
    `externalRunId` (string — folded into `providerReceipt.externalRunId`).
    Response: `{ success, record }`. Emit WebSocket broadcast
    `{ type: "dispatch.record.updated", dispatchId, status, target,
       attempts, timestamp }`.
- `DispatchRecord` shape (exposed in ledger + record endpoints, must match C++):
  ```
  { id, envelopeId, correlationId, status, mode, target,
    machineId, sequenceId,
    ragStatusCode, processStatus,
    attempts, createdAt, updatedAt,
    providerReceipt, envelope, error? }
  ```

**Acceptance.**
- Dispatcher writes each envelope to the ledger **before** any provider call.
- `PATCH` cannot mutate envelope contents — only the listed delivery-metadata
  fields above. Unknown / forbidden fields are silently ignored (matches C++).
- Ledger survives restart when `DISPATCH_LEDGER_FILE` is set.
- WS broadcast on PATCH fires with the documented payload.

**Dependencies.** Phase 2.

---

### Phase 4 — Provider Adapters · **L** (parallelizable)

Each adapter is an independent module conforming to a small interface:

```ts
interface ProviderAdapter {
  kind: 'openai' | 'ollama' | 'acp' | 'healthkit' | 'localai' | 'langgraph' | 'mqtt' | 'manual';
  init(cfg: IntegrationEntry, deps: AdapterDeps): Promise<void>;
  dispatch(envelope: TriggerEnvelope): Promise<DispatchReceipt>;   // fire-and-forget for HTTP
  shutdown(): Promise<void>;
}
```

Completion always returns through `POST /api/integrations/completions`.
None of these adapters complete an agent result synchronously inside the PE cycle.

**4a · Ollama** (recommended first — local, no secrets) · **S–M**
- Files: `perception-engine/backend/src/integrations/adapters/OllamaAdapter.ts`.
- Modes: native `/api/chat`, OpenAI-compatible.
- Validation: structured-output schema matches the registry `sourceMapping.extract`.
- Acceptance: round-trip on a local Ollama instance (gpt-oss:20b) producing a
  completion that PE commits via `/api/integrations/completions`.

**4b · localAIStack GraphQL** (port the Python reference) · **S–M**
- Files: `…/adapters/LocalAIGraphqlAdapter.ts`.
- Dispatch mode: `updateProcessState` mutation per
  `graphql_trigger_template.py`. Target URL comes from `TRIGGER_GRAPHQL_URL`
  with default `<LOCAL_AI_BASE_URL>/graphql` (matches C++).
- Additionally expose the **same four provider-specific routes the C++ server
  ships** so adapters and dashboards see one surface across engines:
  - `GET  /api/integrations/localai/status` — connection + base URL + last error
  - `GET  /api/integrations/localai/catalog` — discoverable mutations / known schema
  - `POST /api/integrations/localai/bootstrap` — boot-time discovery (also runs at startup when `BOOTSTRAP_LOCAL_AI=true`)
  - `POST /api/integrations/localai/invoke` — adhoc GraphQL passthrough; body `{ method, endpoint?, query, variables? }`
- Acceptance: dispatch matches the scenario in
  `examples/triggers/ai_trigger.scenario_aqua_urgent_chain.json`; all four
  `/api/integrations/localai/*` routes return the same JSON keys as the C++
  implementation.

**4c · OpenAI** · **M**
- Files: `…/adapters/OpenAIAdapter.ts`.
- Path: Responses API (hosted agents / managed model runs / webhooks);
  store run id in the ledger receipt only.
- Acceptance: dispatch + webhook completion lands a source update.

**4d · LangGraph (internal)** · **M**
- Files: `…/adapters/LangGraphAdapter.ts`.
- Crosses into `langgraph-orchestrator/`: define a stable HTTP/WS contract
  (`POST /langgraph/runs`) and adopt the completion ingest endpoint as the
  return path.
- Acceptance: a CES-terminal event triggers a LangGraph run; run completion
  posts back to `/api/integrations/completions` and updates PE state.

**4e · HealthKit bridge intake** · **S**
- Files: `…/adapters/HealthKitBridgeAdapter.ts` (server-side; receives
  authorized payloads only — the iOS bridge owns auth & anchored reads).
- Acceptance: bridge-shaped POSTs route through `SourceMapper` to the right
  sensor source.

**4f · Manual / CLI** · **S**
- Already mostly covered by the completion endpoint; document the curl recipes.

**Dependencies.** Phases 1 + 2 + 3.

---

### Phase 5 — MCP gateway alignment & policy gating · **S–M**

**Deliverable.** Bring MCP tool naming and surface into line with the
architecture doc; gate mutating tools behind an explicit policy.

**Files.** `perception-engine/backend/src/mcp.ts` (+ a new
`mcp/policy.ts`).

**Tool name plan.** Register the dotted names as the canonical ones and keep
the existing snake_case names as aliases for one minor version:

| Architecture-doc name | Maps to existing |
|---|---|
| `re.read_state` | `perception_get_state` |
| `re.list_machines` | `machines_list` |
| `re.read_machine` | (new — read one machine JSON; thin wrapper over `/api/machines`) |
| `pe.list_sources` | `sources_list` |
| `pe.push_signal` | `sensor_push_value` |
| `pe.enqueue_push` | `perception_push` (or new debounced variant) |
| `trigger.replay` | **new** — given a ledger `dispatchId`, re-emit envelope (no PE state mutation) |
| `dispatch.read_ledger` | **new** — proxy to `GET /api/dispatch/ledger` |

**Policy.** Annotate each tool with `{ mutates: bool, requires: 'policy:*' }`
and reject mutating calls unless an `MCP_POLICY_ALLOW` env or per-client
capability is present.

**Acceptance.**
- All architecture-doc tool names callable.
- `trigger.replay` rebuilds an envelope from the ledger and emits it.
- A mutating call without policy is rejected with a typed error.

**Dependencies.** Phases 2 + 3.

---

### Phase 6 — Frontend surfacing in the visualizer · **M**

Natural home: the Machine Interconnection view we just landed.

**Deliverables.**
- **Integration status pill** in `MachineContainerView` header — reads
  `/api/integrations/status` (`integrationCount`, `path`, `loaded`).
- **Dispatch Ledger drawer** — table over `/api/dispatch/ledger` (returns
  `{ enabled, mode, records[] }` — full set; client-side filter by
  `machineId` / `correlationId` since the server doesn't paginate). Link from
  any ledger row into the ego-graph centered on that machine.
- **Per-machine envelope panel** in the existing `SequenceTooltip` — extend
  `TooltipMachineData` with `recentEnvelopes`, computed client-side from the
  ledger response filtered by `machineId`. Adds a 4th section to the
  tooltip, reusing existing CSS.
- **Triggers status badge** in the top bar — reads `/api/triggers/status`,
  surfaces `dry-run` vs live `mode`, `envelopesCreated`, `dispatchErrors`.
- **Replay action** in ledger rows → MCP `trigger.replay` (with a confirm
  dialog when not in `dry-run`).
- **WebSocket subscriptions.** The visualizer's existing WS connection adds
  handlers for two new event types broadcast by the PE:
  - `agent.completion.received` — fires when `POST /api/integrations/completions` commits a source; refresh the ledger drawer and flash the relevant machine's tooltip section.
  - `dispatch.record.updated` — fires when `PATCH /api/dispatch/records/:id` lands; update the ledger row in place.

**Acceptance.**
- The new panel renders during the AQUA-urgent chain demo with envelopes
  visible per machine in real time.
- Replaying a ledger row in `dry-run` produces a new ledger entry with
  `mode: replay` and does not mutate PE state.

**Dependencies.** Phases 2 + 3 + 5.

---

## 4. Cross-cutting concerns

- **Schema validation.** Add an Ajv-based validator for the envelope schema
  in `examples/triggers/ai_trigger_envelope.template.json` and run it both
  inside the dispatcher (pre-write to ledger) and in tests against every
  `examples/triggers/ai_trigger.*.example.json` file. Catches drift early.
- **Determinism.** All adapters must be fire-and-record. Add a CI test that
  fails if any adapter awaits an external response inside the PE step
  callback (static check on `PerceptionEngine.on('mergeBatch')` handler graph).
- **Observability.** Extend `/api/metrics` with counters for
  `triggers_built_total`, `dispatch_records_total{adapter,status}`,
  `completions_ingested_total{provider}`. Prometheus/Grafana scrape config
  already lives in `config/`.
- **Security.** Mutating MCP tools, `PATCH /api/dispatch/records/:id`, and
  webhook receivers must share one auth middleware (token or mTLS).
  Document expected dev defaults (currently the dev cert in `certs/`).
- **C++ parity.** Where the C++ slice already names a field/route, copy the
  shape exactly (`GET /api/dispatch/ledger`, `PATCH /api/dispatch/records/:id`
  with the doc-specified deny-list) so the two engines stay drop-in
  compatible for adapters and ledger readers.

---

## 5. Suggested sequencing & first PRs

1. **PR #1 — Phase 0**: registry loader + `/api/integrations/status`. Small,
   safe, unlocks everything else.
2. **PR #2 — Phase 1**: `SourceMapper` + `POST /api/integrations/completions`.
   Replaces ad-hoc `/api/sensors/:id` callbacks with the documented contract.
3. **PR #3 — Phase 2**: trigger dispatcher in `dry-run` only. Counters
   visible; no provider calls yet.
4. **PR #4 — Phase 3**: dispatch ledger + routes.
5. **PRs #5–9 — Phase 4 adapters**: Ollama → localAIStack GraphQL →
   LangGraph → OpenAI → HealthKit. Independently mergeable.
6. **PR #10 — Phase 5**: MCP alignment + policy gating.
7. **PR #11 — Phase 6**: visualizer surfacing.

Each PR carries its own JSON-Schema/unit tests; integration tests join in
PR #3 (end-to-end envelope round-trip in `dry-run`) and again in PR #4
(committed completion lands as a source update).

---

## 6. Open questions (worth deciding before Phase 4)

1. **Where does LangGraph live in the registry?** New `kind: "langgraph"`
   or reuse `kind: "mcp"` with `execution: "local"`? Recommendation: new
   kind, because completion semantics (state-graph runs) differ from
   tool-call MCP.
2. **Ledger storage.** In-memory + JSONL is enough for v1; do we want
   SQLite for cross-restart query? Recommendation: defer to Phase 4d if
   LangGraph runs need long-horizon correlation.
3. **Envelope schema versioning.** Today the template carries
   `schemaVersion: "1.0.0"`. Decide now whether `1.x` is wire-compatible
   (additive only) — affects how adapters tolerate unknown fields.
4. **`/api/signals` alias.** *Resolved.* The C++ implementation publicly
   exposes `POST /api/signals` as the underlying primitive
   (`ingest_signal()` in `src/perception_engine_server.cpp`). For wire
   compatibility, `_AI` must do the same — keep the route public, document
   it alongside `/api/integrations/completions`, and route both through the
   same `SourceMapper` write path.

---

## Appendix A — C++ integration route table (authoritative cross-reference)

Sourced verbatim from `RealityEngine_CPP/src/perception_engine_server.cpp`.
Each TS route delivered by this roadmap **must match the method, path,
request body keys, and response keys below** for `_AI` and `_CPP` to be
drop-in interchangeable from an adapter's point of view.

| Method | Path | Handler (C++) | Notes |
|---|---|---|---|
| GET    | `/api/integrations/status`              | `integration_status()`       | Phase 0 |
| POST   | `/api/integrations/completions`         | `ingest_completion(body)`    | Phase 1 |
| POST   | `/api/signals`                          | `ingest_signal(body)`        | Phase 1 — keep public |
| GET    | `/api/triggers/status`                  | `trigger_status()`           | Phase 2 |
| GET    | `/api/dispatch/ledger`                  | `dispatch_ledger()`          | Phase 3 — no query params |
| GET    | `/api/dispatch/records/:id`             | `read_dispatch_record(id)`   | Phase 3 — `:id` not `{id}` |
| PATCH  | `/api/dispatch/records/:id`             | `update_dispatch_record(id, body)` | Phase 3 |
| GET    | `/api/integrations/localai/status`      | `localai_status()`           | Phase 4b |
| GET    | `/api/integrations/localai/catalog`     | `localai_catalog()`          | Phase 4b |
| POST   | `/api/integrations/localai/bootstrap`   | `bootstrap_localai()`        | Phase 4b — also runs at boot when configured |
| POST   | `/api/integrations/localai/invoke`      | `invoke_localai(body)`       | Phase 4b |
| GET    | `/api/integrations/acp/status`          | `acp_status()`               | Implemented — OpenClaw xACP handoff metadata |
| POST   | `/api/integrations/acp/dispatch`        | `dispatch_acp(body)`         | Implemented — accepted no-wait handoff |

### Environment flags read at boot (C++ contract)

| Env var | Default | Used by |
|---|---|---|
| `INTEGRATIONS_CONFIG`     | `config/integrations.json` if present | Phase 0 registry loader |
| `TRIGGERS_ENABLED`        | `false` (bool) | Phase 2 dispatcher |
| `TRIGGER_DISPATCH_MODE`   | `"dry-run"`    | Phase 2 dispatcher |
| `TRIGGER_GRAPHQL_URL`     | `<LOCAL_AI_BASE_URL>/graphql` | Phase 2 / Phase 4b |
| `LOCAL_AI_BASE_URL`       | (provider-specific) | Phase 4b — base for localAI routes |
| `BOOTSTRAP_LOCAL_AI`      | `false` | Phase 4b — runs `bootstrap_localai()` at startup |
| `DISPATCH_LEDGER_FILE`    | unset (in-memory only) | Phase 3 (TS extension) |
| `ACP_ENABLED`             | `false` | ACP/OpenClaw xACP handoff adapter |
| `ACP_COMMAND` / `OPENCLAW_ACP_COMMAND` | `openclaw acp` | ACP handoff receipt metadata |
| `ACP_GATEWAY_URL` / `OPENCLAW_GATEWAY_URL` | `ws://127.0.0.1:18789` | ACP handoff receipt metadata |
| `ACP_SESSION_KEY` / `OPENCLAW_ACP_SESSION` | `agent:main:main` | ACP handoff receipt metadata |
| `ACP_COMPLETION_SOURCE_MAPPING_ID` | `agent-completion-risk` | ACP completion source mapping default |
| `MQTT_BROKER_HOST` etc.   | unset (bridge disabled) | already wired in `_AI` |

### WebSocket events the visualizer (Phase 6) must handle

| Event type | Emitted by C++ | TS handler |
|---|---|---|
| `agent.completion.received` | `ingest_completion()` after a successful commit | Refresh ledger drawer, flash tooltip Last-Fire section |
| `dispatch.record.updated`   | `update_dispatch_record()` after a successful PATCH | Update ledger row in place |
| `perceptual-simulation-stepped` | existing, carries `mergeBatch` | already consumed by `MachineSequenceTooltip` |

### Diff-style summary of corrections applied to this roadmap

- Path params: `{id}` → `:id` (Express/CPP style).
- `GET /api/dispatch/ledger` carries **no** `?limit&since` — server returns the full ring; pagination/filtering is client-side.
- `GET /api/integrations/status` response shape uses keys `integrations` / `sourceMappings` / `path` / `loaded` (not `providers` / `loadedFrom`).
- `GET /api/triggers/status` response uses `envelopesCreated`, `droppedNoGovernance`, `droppedNoDispatch`, `dispatchErrors`, `graphqlEndpoint` (not `built`/`dispatched`/`dropped`).
- `PATCH /api/dispatch/records/:id` accepted fields: `status`, `error`, `clearError`, `attempts`, `incrementAttempts`, `providerReceipt`, `provider`, `adapter`, `externalRunId`.
- `POST /api/signals` is **public**, not internal — keep parity with C++.
- LocalAI provider-specific routes (`status`/`catalog`/`bootstrap`/`invoke`) added under Phase 4b for parity.
