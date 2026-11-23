# RealityEngine A2A Framework Specification

**Version:** `re-a2a-v0.1-draft`. Last reviewed: 2026-11-23.
**Status: draft for owner review.** Nothing here is settled until the owner
approves it. Each open choice is listed in § 13.

This document is task **K1** in `docs/OWASP_ACS_ROADMAP.md` § A2A, and its
§ 6 is task **K3**. It is the master that every engine's implementation of the
RealityEngine A2A framework follows (decisions A9–A12, owner, 2026-11-23).

"Must", "must not" and "may" are normative. Every "must" is tested by a
conformance vector (§ 11), named beside the rule as `[V-…]`. A rule without a
vector is not yet enforceable, and the kit lists it as pending.

## 1. What the framework is

The framework is how RealityEngine meets agents. It has two patterns, and every
A2A exchange is one of them:

- **Dispatch (egress).** A PE's trigger envelope, recorded in its dispatch
  ledger, becomes an A2A message to a remote agent. The engine instance is the
  A2A **client**.
- **Ingress.** What an agent returns (the reply to a dispatch), or an agent
  calling RealityEngine on its own initiative, becomes a Reality Event write
  through the PE's ingress. The engine instance is an A2A **server**.

**Where it lives (A10, A11).**
- This specification and its conformance kit live in RealityEngine_CI.
- **Each engine implements the framework itself,** in its own repository and
  language, inside its PE. The implementations are C++, Common Lisp, Scala, and,
  as followers, Rust, Go and the TypeScript PE.
- The parts talk to each other and to the PE through in-process calls. **No
  HTTP or HTTPS is used inside an engine instance.** HTTP exists only at the A2A
  boundary, where A2A requires it.

**What is contained (A9).** Every mapping to the underlying standards is
inside the framework module of each engine, and nothing else in the engine
reaches past it:
- A2A's bindings and versions;
- OWASP ACS and the Guardian;
- MCP wrapping;
- OpenTelemetry and OCSF;
- the AgBOM.

**Invariants it keeps** (`docs/EXTERNAL_INTEGRATION_CONTRACT.md` §2):
- **2.1** Projection is registry-owned. Nothing in the framework chooses a
  region or a mapping.
- **2.2** Ingress alone activates a source.
- **2.3** Governance (severity, paging, runbook, SLA) is CES-owned. Policy
  here is safety only.
- **2.4** Dispatch is fire-and-record. The framework works off the PE cycle,
  on the PE's own worker, and never blocks a step.
- **2.5** The RE stays deterministic. The framework is in the PE, and nothing in
  it reaches the RE.

## 2. Versions this draft pins

| Standard | Version | Verify at |
|---|---|---|
| A2A | v1.0 (v1.0.1 the latest tag on 2026-11-22), JSON-RPC 2.0 binding | roadmap B1 |
| OWASP ACS | v0.1.x; the exact patch is pinned at B1 (v0.1.4 or later) | roadmap B1 |
| JSON canonical form | RFC 8785, JSON Canonicalization Scheme (JCS) | — |

Each implementation declares `re-a2a` together with the A2A and ACS versions
it speaks, in its Agent Card (§ 5.1) and in its K2 status route (§ 9).

## 3. The parts and their in-process interfaces

These interfaces are language-neutral. Each engine realises them in its own
idiom, and its resolution document (§ 12) records how. They are internal:
none is an HTTP route.

| Part | Operations (inputs → outputs) | Roadmap |
|---|---|---|
| **Dispatch ledger** (exists today) | `claim(instance) → record?`; `update(record.id, status, receipt?, error?)` | SURFACE_SPEC "Dispatch surface shapes" |
| **Agent directory** | `resolve(binding) → AgentCard` | K6 |
| **Dispatch runner** | `dispatch(record) → outcome` (§ 4) | K4, C1 |
| **Ingress handler** | `accept(a2aRequest, caller) → a2aResponse` (§ 5) | K5, C7 |
| **Governance port** | `decide(hook, payload, metadata) → decision` (§ 7) | K7 |
| **Audit** | `open(session)`, `append(session, entry) → headHash`, `seal(session) → headHash` (§ 8) | K8 |
| **Telemetry** | `span(name, attrs)`, `event(ocsf)`, `metric(name, labels, value)` | K9 |
| **PE ingress** (exists today) | `write(sourceMappingId, values, provenance)`: the in-process form of today's completion ingest | SURFACE_SPEC |

The dispatch ledger and PE ingress already exist in every PE. The framework
calls them in-process and changes neither one's observable shape, except as § 9
states.

## 4. Dispatch (egress)

### 4.1 The flow

1. A CES match records a dispatch envelope in the PE's ledger, as today. The PE
   cycle is done with it at that point (2.4).
2. The runner claims the record, idempotently by `dispatchId` `[V-D1]`.
3. Governance: `sessionStart`, `agentTrigger`, `userMessage`, `turnStart` and
   `toolCallRequest` are decided in that order, before anything is sent
   (§ 7). A `deny` ends the dispatch (§ 4.3).
4. The runner resolves the bound agent (§ 4.2) and builds the A2A message:
   - the envelope's prompt as a text part;
   - the RealityEngine extension (§ 6), and the frame profile when the
     dispatch carries an assetID;
   - the step capability, when there is one, in `Authorization: Bearer`, never
     in the message.
5. The runner sends `SendMessage` (or the streaming form, when the card offers
   it) and follows the task until it reaches a terminal or interrupted state,
   within the record's TTL.
6. Ingress of the reply: the task's artifacts go through § 5.3, the commit gate,
   in-process, without any HTTP hop back to the PE.
7. `turnEnd` and `sessionEnd` are recorded, and the audit chain is sealed
   (§ 8).

### 4.2 Agent binding

A machine's `agentBinding` names an agent by its **directory entry** and a
**skill id**. The directory resolves the entry to an Agent Card URL from the
generated `config/integrations.json` and the instance registry, never from a
literal. The binding schema belongs to RealityEngine_Machines (K3). Fields
that today name an OpenClaw session key or target agent are mapped during the
deprecation window (§ 9).

### 4.3 Task state → ledger status

| A2A task state | Ledger `status` | Continuation outcome (frame profile) |
|---|---|---|
| (not yet sent) | `recorded`, today's value | — |
| `submitted`, `working` | `delivering` | — |
| `completed` | `delivered` | **return** (§ 6.4) |
| `input-required` | `delivering`; the record notes `awaiting-input` | **park** (§ 6.4) |
| `failed` | `failed`, `error: "a2a:failed:<reason>"` | **fail** (§ 6.4) |
| `canceled` | `failed`, `error: "a2a:canceled"` | **fail** |
| `rejected` | `failed`, `error: "a2a:rejected:<reason>"` | **fail** |
| governance `deny` | `failed`, `error: "acs:deny:<hook>:<reason>"` | **fail** |
| TTL lapses | `failed`, `error: "a2a:timeout"` | **fail** |

Notes on the table:
- **Status names.** `recorded`, `delivering` and `delivered` are the statuses
  the voters already write. C++ (`perception_engine_server.cpp`) and LSP
  (`perception-service.lisp`) write them in their provider adapters, and Scala
  writes them through `PATCH /api/dispatch/records/:id`. Only the
  `awaiting-input` note is new (§ 13, Q3).
- **Receipt fields.** The A2A `taskId` and `contextId` are recorded in
  `providerReceipt` (`externalRunId: taskId`), and so is the agent's card URL.

### 4.4 Message identity

A dispatch's A2A identities are deterministic, so that a retry is recognisable
and parity can be compared:

- `messageId` = `"re:" + instance_uuid + ":" + dispatchId + ":" + attempt`
  `[V-D2]`.
- `contextId` is the frame's assetID when the dispatch carries one. Otherwise
  it is `"re:" + instance_uuid + ":" + dispatchId` `[V-D3]`.
- `taskId` is minted by the agent (A2A does not let the client choose it), and
  is recorded in the receipt.

## 5. Ingress

### 5.1 The Agent Card

Each engine instance's PE serves its own Agent Card at
`/.well-known/agent-card.json` on the PE's listener, under the lane's TLS. The
card declares:
- one interface per binding the implementation offers;
- the RealityEngine extension (§ 6) with `required: true`;
- the authentication schemes (§ 10);
- `re-a2a` and the A2A version;
- the **skills** the instance accepts: today, only `re.reply`, the return of a
  dispatch.

Unsolicited skills are added by policy (§ 5.4). A card is per instance, never
shared, and names the instance's `instance_uuid` `[V-I1]`.

### 5.2 Accepting a request

The ingress handler, in this order:
1. **Transport and caller:** mTLS for RealityEngine entities, TLS plus the
   declared scheme for external parties. An unauthenticated caller is refused
   before any parsing `[V-I2]`.
2. **Version:** `A2A-Version`. An unsupported version answers
   `VersionNotSupportedError`.
3. **Extension:** the RealityEngine extension must be activated and valid
   (§ 6.5). Otherwise the request is refused with an A2A error naming the
   failed check `[V-I3]`.
4. **Governance:** `userMessage` for a reply, `agentTrigger` for an unsolicited
   task, then the commit hook (§ 5.3).
5. **The commit gate,** then PE ingress, in-process.

### 5.3 The commit gate

Before anything is written into the PE:
- **Extract:** take the returned values from the task artifact's RealityEngine
  data part (§ 6.4).
- **Govern:** the governance port decides the commit hook (`memoryStore`, as B2
  confirms), with values, `sourceMappingId` and the resolved sensor and region.
  It may allow or deny, never modify values (A3) `[V-I4]`.
- **On allow:** `write` to PE ingress with provenance (§ 6.3).
- **On deny:** the source stays inactive (2.2), and the ledger and audit record
  why.

The PE remains the authority for `sourceMappingId`, sensor and region. The
framework reads them; it never supplies them (2.1).

### 5.4 Unsolicited ingress

An agent's own initiative, which is not a reply to one of this instance's
dispatches, is **refused** unless policy names both the caller and the skill.
An accepted unsolicited task opens its own audit session. Its `session_id` is
the A2A `taskId`, scoped by `instance_uuid`.

## 6. The RealityEngine A2A extension (K3)

### 6.1 Identity and activation

- **URI:** `urn:realityengine:a2a:ext:v0.1` (proposal; § 13, Q1).
- **Declared** in every RealityEngine Agent Card, and in every compatible
  service's card, under `capabilities.extensions`, with `required: true`.
- **Activated** per request with A2A's extension header (`A2A-Extensions`; some
  sources spell it `X-A2A-Extensions`, and B1 pins the v1.0 spelling). The
  response lists it as activated.
- **Carried** in `message.metadata` under the extension URI, and in each
  returned artifact's `metadata` under the same URI. The A2A convention for
  extension data is the metadata keyed by the URI.

### 6.2 Two profiles

| Profile | Present when | Carries |
|---|---|---|
| `dispatch` | always | where the request came from (§ 6.3) |
| `frame` | the dispatch acts on an assetID frame (a clone step, a document workflow) | the frame's asset references and its continuation (§ 6.3) |

A dispatch without an assetID (an ordinary CES trigger) carries `dispatch`
only.

### 6.3 The object

```json
{
  "profile": ["dispatch", "frame"],
  "dispatch": {
    "instanceUuid": "<instance_uuid>",
    "dispatchId": "<ledger id>",
    "envelopeId": "<envelope id>",
    "correlationId": "<correlation id>",
    "machineId": "<machine id>",
    "sequenceIds": ["<sequence id>"],
    "skill": "<skill id>",
    "clock": { "instance": "<instance_uuid>", "lamport": 1234, "step": 56 }
  },
  "frame": {
    "assetId": "<assetID>",
    "delimiter": "<case delimiter>",
    "caseKeys": { "entity": "<entity>", "period": "<period>", "assetType": "<type>" },
    "documents": [
      { "uri": "<pod URI>", "revision": "<revision>", "sha256": "<hex>", "etag": "<etag>",
        "permissions": ["pod:read"] }
    ],
    "upstreamRefs": [ { "uri": "<URI>", "revision": "<revision>", "sha256": "<hex>" } ],
    "action": "<action>",
    "arguments": { },
    "continuation": {
      "continuationId": "k2",
      "generation": 3,
      "next": { "engineId": "<engine instance>", "templateId": "<template>" },
      "onStale": "k0"
    },
    "capabilityScope": {
      "frameId": "<assetID>", "continuationId": "k2",
      "scopes": ["pod:read"], "notAfter": "<lamport or lifecycle time>"
    }
  }
}
```

The field meanings and sources:
- **`frame`:** these are the members of the assetID frame and of the
  continuation record, as `docs/CONTINUATIONS_APPROVAL_CHAIN.md` and the
  lifecycle API define them. The framework **copies them from the lifecycle's
  frame; it never derives, mints or reorders them** `[V-X1]`.
- **`capabilityScope`:** describes the capability; it is never the capability
  itself. The token travels only in `Authorization` and must never appear in
  the extension, a log, a trace or the audit chain `[V-X2]`.
- **`dispatch`:** copied from the ledger record and the instance clock. It
  never uses a wall-clock time `[V-X3]`.

### 6.4 The return

The agent returns its result in a task artifact with one **data part**. The
part's data is:

```json
{
  "outcome": "return",
  "return": { },
  "values": { },
  "echo": { "assetId": "<assetID>", "continuationId": "k2", "generation": 3,
            "documents": [ { "uri": "<pod URI>", "revision": "<revision>", "sha256": "<hex>" } ] }
}
```

- **`outcome`** is one of:
  - `return`: the step completed. `return` is written to the frame, and
    `values` go through the commit gate.
  - `park`: the step waits for a person. The A2A task goes to
    `input-required`.
  - `fail`: with `reason`. The engine side then reports the step failed to the
    lifecycle (`POST /frames/:id/continuations/:k/fail`).
- **`echo`** repeats the frame identity the agent acted on. It must equal what
  was sent, byte for byte under § 6.6, or the receiver takes the escape path
  `[V-X4]`.
- **Who records the outcome.** The agent never captures, resumes or advances a
  continuation. The engine side does that with the lifecycle, as today. A
  graph or agent never chooses the next step: only the PE's ISRE folding does.

### 6.5 What a receiver checks

Before acting, a receiver checks these in order. The first failure decides:
1. The extension is present and activated, and its version is supported.
2. The `profile` matches the request (a reply to a frame dispatch carries
   `frame`).
3. **Generation:** the continuation's `generation` equals the current one. A
   stale one takes the escape path `[V-X5]`.
4. **Pins:** every `documents[]` and `upstreamRefs[]` revision and SHA-256 is
   still current. A changed pin takes the escape path, never the approve path
   `[V-X6]`.
5. **Principal:** the caller's identity is allowed by `resumableBy`, and agents
   never resume approve, record or publish.
6. **Echo:** the `echo` equals the dispatched frame identity `[V-X4]`.

A failed check is recorded in the ledger, in the audit chain and, on the frame
profile, as the lifecycle's escape. It is never silently dropped.

### 6.6 Canonical serialisation

Every implementation must produce **the same bytes** for the same inputs:

- **JSON:** RFC 8785 (JCS), which sorts keys by UTF-16 code unit, writes
  numbers in ECMAScript form, and writes strings with minimal escaping `[V-C1]`.
  JCS uses the same number form the engines already write on the wire.
- **Strings** pass as received. No Unicode normalisation is applied, so a
  string's bytes never change in transit `[V-C2]`.
- **Times:** only the instance clock `{instance, lamport, step}` and lifecycle
  values. No wall-clock timestamp is in the extension.
- **Empty and absent:** an absent member is omitted, never written as `null`
  or `""`, except where § 6.3 shows the member always present.
- **Byte-exact parts.** The extension object and the return's `echo` are
  compared byte for byte. The rest of an A2A request is compared after the
  K12 kit's masking, which covers fields minted per instance: `instanceUuid`,
  `dispatchId`, the derived ids of § 4.4 and the step capability. Under that
  masking, the request must be identical across engines `[V-C3]`.

## 7. Governance (the port)

- **Every hook goes through one port.** The hooks and their order are
  `docs/OWASP_ACS_ROADMAP.md`'s mapping tables, adjusted for A2A in § A2A
  there. Payloads use ACS's message shapes in-process. ACS leaves transport out
  of scope, so in-process calls conform.
- **Fail closed:** no answer, a timeout or an error is `deny` (A5) `[V-G1]`.
- **The decision record** is `{hook, disposition, reason, policyDigest,
  requestId, sessionId, clock}`, and it is appended to the audit chain.
- **Policy is data with exact semantics** (K7, specified separately in
  `docs/A2A_POLICY_SPEC.md`, to be written). It is an ordered decision table
  over the hook payload: first match wins, total, and denies by default. Each
  engine evaluates it natively, and the same table gives the same decision in
  every implementation `[V-G2]`. An optional out-of-process Guardian (OPA, the
  upstream reference) is an interoperability check behind the same port, never
  the release Guardian.
- **What a decision may change:** `modify` redacts the prompt and metadata
  only. It never touches values, `sourceMappingId`, region, TTL, the target, or
  any member of the extension `[V-G3]`.

## 8. Audit, provenance and signing

- **One chain per session** (a dispatch, or an accepted unsolicited task).
  - The root is `sessionStart`.
  - Each entry is `{seq, prevHash, entry}`, and its hash is SHA-256 over its JCS
    bytes.
  - The seal is `sessionEnd`.
  - The head hash is written into the ledger receipt `[V-A1]`.
- **Signing:** an HMAC-SHA256 envelope signature per entry, with a key per
  instance from the secrets home. It is never `ACP_SESSION_KEY` `[V-A2]`.
- **Provenance** is the `dispatch` profile, which links back to the CES match,
  plus, for a commit, the response's `echo`.
- **Comparable chains.** Chains from different engines for the same masked
  inputs must be identical after the § 6.6 masking `[V-A3]`.

## 9. Engine-facing surface (K2, a SURFACE_SPEC revision)

These are proposals for the SURFACE_SPEC "Integrations" revision. Every
route is served by every PE, and compared 3-of-3.

| Method | Path | Purpose |
|---|---|---|
| GET | `/.well-known/agent-card.json` | the instance's Agent Card (§ 5.1) |
| POST | `/a2a` | the A2A JSON-RPC endpoint (ingress, § 5) |
| GET | `/api/integrations/a2a/status` | `re-a2a`, A2A and ACS versions, participation state, the directory's agents, open sessions |
| GET | `/api/integrations/a2a/asks` | dispatches held by `ask` (C6), for Manager |
| POST | `/api/integrations/a2a/asks/:id` | an operator's `approve` or `deny` |
| GET, PATCH | `/api/dispatch/ledger`, `/api/dispatch/records/:id` | unchanged |

**Deprecated over one release** (v0.0.3 serves both, v0.0.4 removes them):
- `/api/integrations/acp/status` and `/api/integrations/acp/dispatch`;
- `/api/integrations/completions` as an external route. Ingress is in-process
  now; Manager's manual testing keeps it until then;
- the `ACP_*` and `OPENCLAW_GATEWAY_URL` variables, replaced by `RE_A2A_*`
  (names to be fixed in the SURFACE_SPEC change).

**Participation states** apply unchanged: `not-configured`, `not-active`,
`unsupported`, `unavailable`. A PE whose framework isn't built answers the
routes above with `unsupported`, never a success-shaped stub.

## 10. Identity and transport

- **The boundary is TLS 1.3** under `config/transport-profile.json`:
  - mTLS between RealityEngine entities (an engine's runner to an engine's
    ingress, or to a compatible service like localLangChainStack);
  - TLS-only toward external parties (the transport audience rule), with the
    card's declared scheme.
- **Certificates** are per instance, from the suite PKI.
- **A language whose TLS can't meet the profile** uses the suite's recorded
  pattern (Go's OpenSSL front, 2026-11-12). That front terminates TLS at the
  boundary. It is not an internal HTTP hop, and the parts behind it are still
  in-process.
- **Inventory:** every boundary link goes in `config/transport-inventory.json`.

## 11. Conformance and publication (K12)

The kit lives in `conformance/a2a/` in this repository, published with each
`re-a2a` version:

- **`schemas/`:** JSON Schemas for the extension object, the return data part,
  the decision record, the audit entry and the K2 routes.
- **`vectors/`:** each vector is an input (a ledger record, a lifecycle frame, a
  policy table, an agent's reply) with the exact expected outputs:
  - the A2A request in JCS form, after masking;
  - the extension and `echo` bytes;
  - the ledger transitions;
  - the audit chain;
  - the decisions.

  The negative vectors are a stale generation, a changed pin, a wrong
  principal, a replayed request, a bad signature, a token found in the
  extension, a `modify` that touches values, an unauthenticated caller, and an
  unsupported version.
- **`harness/`:**
  - a deterministic test agent (an A2A server that answers by script);
  - a test caller (for ingress);
  - a driver that runs every vector against one PE.

  Any engine, new or existing, runs it against itself.
- **The `acs-a2a` regression stage** drives every PE through the harness. It
  compares 3-of-3 among C++, LSP and Scala, and Rust, Go and the TypeScript PE
  must agree (#842).

**An engine is aligned** when it passes every vector of the `re-a2a` version
its resolution document names. A compatible service (an agent host like
localLangChainStack) is aligned when it passes the service subset: it declares
the extension, echoes it exactly, and never mints or rewrites it.

**Versioning:**
- A change to a `must`, the extension's shape, or a vector bumps `re-a2a`'s
  minor version.
- An engine names the version it implements, and the kit refuses a mismatch.
- A new A2A or ACS version changes this document first, then the
  implementations, under the same gate.

## 12. Per-engine resolution documents (A10)

Each engine repository holds `docs/A2A_FRAMEWORK.md`, beginning:

> Authority: RealityEngine_CI `docs/A2A_FRAMEWORK_SPEC.md`, version
> `re-a2a-vX.Y`. Where this document and the specification differ, the
> specification wins, and the difference is a defect here.

It records, rule by rule (§ and vector id):
- how the engine realises each in-process interface of § 3 in its language;
- the A2A SDK it uses, if any, and how the SDK is kept inside the framework
  module;
- any deviation, with its reason and the owner's ruling.

A resolution may decide how a rule is realised. It may never change what is
observable at the boundary. The repository's `CLAUDE.md` and `AGENTS.md`
point to both documents.

## 13. Open questions for the owner

- **Q1. Extension URI.** Use `urn:realityengine:a2a:ext:v0.1`, or a resolvable
  URL that serves this document.
- **Q2. `contextId` for a frame.** This draft sets `contextId` to the assetID,
  so every step of a frame shares one A2A context, and a compatible service's
  thread is keyed by `assetId + continuationId`. The alternative is one context
  per continuation.
- **Q3. The park state in the ledger.** An agent's `input-required` maps to
  the existing `delivering` plus an `awaiting-input` note in
  `providerReceipt`. The alternative is a new ledger status, which would be a
  SURFACE_SPEC change on every PE.
- **Q4. The deprecation window.** One release (v0.0.3 serves both, v0.0.4
  removes them), or longer.
- **Q5. Who dispatches a workflow step.** Today Manager's instantiation
  component dispatches clone agents. Under this specification, does it ask the
  step's engine PE to dispatch (the clone is on that engine), or does it call
  a PE's framework in-process? Manager's TypeScript PE is a framework
  implementation of its own.
- **Q6. Policy specification.** K7's decision-table format as its own document
  (`docs/A2A_POLICY_SPEC.md`), or a chapter here.
