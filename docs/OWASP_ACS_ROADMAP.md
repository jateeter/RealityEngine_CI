# OWASP ACS Roadmap: governing RealityEngine agent dispatch and ingress over A2A

Last reviewed: 2026-11-23

> **Revised 2026-11-22 (owner): A2A is the gateway, and this plan governs it.**
> The suite's agent gateway is the A2A (Agent2Agent) standard
> (RealityEngine_CI#841), replacing OpenClaw, which is sunset in
> release-v0.0.3 (`docs/AGENT_GOVERNANCE_REVIEW.md`, 2026-11-11). The A2A work
> and this ACS work are **one plan**: A2A is the wire between RealityEngine and
> agents, and ACS is the control and audit layer on that wire. § A2A
> (2026-11-22), below, is the revision. Where it differs from the original
> 2026-10-19 text that follows it, the revision wins. The original text is kept
> because its invariants, decisions A1–A6 and its proof ladder still hold, with
> "OpenClaw gateway" read as "the A2A agent" and "ACP adapter" read as "the A2A
> dispatch runner".

This file is the plan to develop, prove and release support for the **OWASP
Agent Control Standard (ACS) v0.1.0**, and the observability that the **Agent
Observability Standard (AOS)** contributed to it, in the RealityEngine ACP
integration. It covers two workflows:

- **Dispatch:** a PE trigger envelope becomes a handoff to an OpenClaw agent.
- **Response→Source:** that agent's response becomes a PE sensor source and
  re-enters the universe as a fact.

Each task has an owner area, its dependencies and a definition of done. Track it
the way `docs/ReleaseRoadmap.md` is tracked (§ How to track this file).

Sources:
- `docs/owasp_acs.md`: the summary this plan works from.
- Upstream: `github.com/GenAI-Security-Project/agent-control-standard`, tag
  `v0.1.0`. The schemas are in `specification/v0.1.0/`, published under
  `https://genai-security-project.github.io/agent-control-standard/schema/v0.1.0/`.
  The reference Guardian is in `reference-implementations/agt/`.
- AOS: `aos.owasp.org`. ACS carries over AOS's three pillars (Instrument,
  Trace, Inspect) and its Observed Agent / Guardian Agent split. In ACS v0.1.0,
  AOS's Trace and Inspect are optional conformance profiles beside the mandatory
  ACS-Core. "Aligning with AOS" in this plan therefore means declaring and
  passing the **Trace** and **Inspect** profiles.
- The contract this must keep: `docs/EXTERNAL_INTEGRATION_CONTRACT.md`. Its
  worked instance: `docs/OPENCLAW_INTEGRATION.md`.

## A2A (2026-11-22)

### What changes

- **The Observed Agent is an A2A remote agent,** any A2A-compliant service,
  found by its Agent Card (`/.well-known/agent-card.json`), not an OpenClaw
  session key. The gateway is a standard, not a product.
- **Two patterns, both governed.** RealityEngine meets agents in exactly two
  ways, and every A2A exchange is one of them:
  - **Dispatch (egress).** A PE trigger envelope becomes an A2A message that
    creates or continues a task at a remote agent. The per-instance runner (C1)
    is the A2A **client**. A task's terminal state and artifacts carry the
    response home.
  - **Ingress.** What an agent sends back, or an agent calling RealityEngine on
    its own initiative, becomes a Reality Event source write, and only through
    the PE's ingress (invariant 2.2). Here RealityEngine is an A2A **server**:
    each engine instance publishes its own Agent Card and accepts tasks only
    through its own Guardian (A1).

  The original plan's Response→Source workflow is the reply half of ingress.
  Unsolicited ingress is new and goes through the same commit gate (D2).
- **Where the ACS hooks attach.** On dispatch, the A2A send is the action
  that leaves the reasoning context, so it fires `steps/toolCallRequest`, and
  the task's result fires `steps/toolCallResult`. On ingress, an inbound A2A
  message fires `steps/userMessage` (or `steps/agentTrigger` for an unsolicited
  task) before anything reaches the PE, and the commit hook (D2) precedes the
  source write. `session_id` stays `dispatchId` for dispatch (A4). For
  ingress it is the A2A task id, scoped by `instance_uuid`.
- **Inside the agent (section O) depends on the service.** The OpenClaw hook
  pack is dropped with OpenClaw. For each compatible service, the plan records
  whether its runtime exposes hooks an ACS client can use. Where it doesn't,
  governance stops at our boundary, and the conformance statement (H3) says so.
- **Transport.** Every A2A link is TLS 1.3 under
  `config/transport-profile.json`: mTLS between RealityEngine entities,
  TLS-only for external agents (transport audience rule). The Agent Card
  declares the scheme. The ACS wire to the Guardian is a RealityEngine-internal
  link, so it is mTLS, which also closes upstream #70 (an unauthenticated wire)
  on our side.

### The RealityEngine A2A framework is the integration (owner, 2026-11-23)

**A9 is decided.** The target integration is a RealityEngine A2A framework.
It covers both patterns: dispatch (egress) and ingress. **The mapping to the
underlying APIs and flows is contained inside that integration abstraction.**
That covers ACS and its Guardian wire, AGT if used, A2A's bindings and
versions, MCP wrapping, OpenTelemetry/OCSF and the AgBOM.

What follows:

- **One boundary.** The engines, Manager's workflow driver and the corpus see
  only the framework's RealityEngine-side surface. That is the PE dispatch
  ledger (fire-and-record, 2.4) and the PE's ingress (2.2). No engine, and no
  other component, calls A2A, ACS or a Guardian directly or depends on their
  types.
- **Standard churn stays inside.** A new A2A version, ACS v0.2 or a
  different Guardian changes the framework, not the engines. The framework
  pins and declares the standards' versions it speaks.
- **Engines don't implement A2A.** #841's per-repository table had a "PE A2A
  client" in each engine. Under containment, an engine instead keeps the
  framework's engine-facing surface: the dispatch ledger and ingress,
  generalised from today's `acp/*` routes and specified in SURFACE_SPEC. That
  surface is what C++, LSP and Scala are compared on 3-of-3, and what the
  followers must agree with. Go#3 and Rust's A2A item move the same way.
- **Compatible services adopt the framework or its contract.** A service
  becomes compatible by speaking A2A to the framework, or by embedding the
  framework, never by integrating with an engine.

### What the framework needs

The status table tracks these as tasks K1–K14.

**Contract and surface**

- **K1 — Framework contract.** `docs/A2A_GATEWAY_CONTRACT.md` (B4), extended
  to cover:
  - the engine-facing surface;
  - the A2A-facing surface;
  - the governance surface (the Guardian port);
  - the rule that nothing crosses the boundary except through these.
- **K2 — Engine-facing surface in SURFACE_SPEC.** Generalise
  `/api/integrations/acp/*` and `/api/integrations/completions` into
  runtime-neutral dispatch and ingress routes:
  - the dispatch record and its states;
  - the ingress write;
  - the participation states;
  - a deprecation window for the `acp` names and the `ACP_*` variables.
- **K3 — Agent binding in the corpus.** A machine's `agent:*` binding names an
  A2A agent and skill: an Agent Card URL or a directory entry, plus a skill
  id. It is schema-checked in RealityEngine_Machines and runtime-neutral, as
  the AI governance regime's agents already are (Machines#256).

**Dispatch and ingress**

- **K4 — Dispatch runner.** C1, as the framework's egress. Per instance, it:
  - claims ledger records;
  - resolves and caches Agent Cards;
  - negotiates the binding (JSON-RPC, gRPC or HTTP+JSON) and `A2A-Version`;
  - sends the message;
  - follows the task (streaming, push or poll);
  - handles cancel, retry, idempotency by `dispatchId`, and TTL;
  - maps task states to ledger states.
- **K5 — Ingress server.** C7, as the framework's ingress. Per instance, it:
  - publishes the instance's Agent Card and skills;
  - authenticates the caller;
  - holds an inbound task to a policy;
  - passes the commit gate (D2) into the PE's ingress.

  Unsolicited tasks are refused unless policy names the caller and the skill.
- **K6 — Agent directory.** Which agents exist and where. Sources are the
  generated `config/integrations.json` and the instance registry, and the
  directory is served per install. It holds no hard-coded URLs
  (`check-registry-url-literals.sh`).

**Governance and evidence (contained)**

- **K7 — Governance port.** One internal interface that every hook goes
  through. Its first implementation is the ACS v0.1.x client and the
  per-instance deterministic Guardian (A1, A2). AGT, the upstream reference
  Guardian or a later ACS version plugs in behind the same port. Fail-closed
  lives here (A5).
- **K8 — Audit, provenance and signing.** E1–E4, owned by the framework:
  - the hash chain per session;
  - provenance back to the CES match;
  - keys from the secrets home, per instance.
- **K9 — Observability and Inspect.** F1–F6 and F4's AgBOM, emitted by the
  framework only, every signal labelled with `instance_uuid`.
- **K10 — MCP wrapping.** When a governed session uses MCP tools (`re-mcp`,
  #714), the framework wraps them (`protocols/MCP/*`). Tools are scoped per
  session, which closes the #714 deficiency by construction.

**Security and identity**

- **K11 — Identity and transport.**
  - Per-instance certificates from the suite PKI.
  - mTLS to RealityEngine entities, TLS-only to external agents (the transport
    audience rule).
  - A2A authentication schemes declared in the Agent Card.
  - Every link goes in `config/transport-inventory.json`.

**Proof, packaging and operation**

- **K12 — Conformance kit.**
  - A deterministic test agent and a mock Guardian.
  - A2A's own conformance tests (B6) and the ACS harness (B3).
  - A parity mode in which only the deterministic policy layer decides.
  - The `acs-a2a` regression stage (G9).
- **K13 — Packaging.**
  - The framework's own version, declared beside the A2A and ACS versions it
    pins.
  - One implementation used by every instance, since engines don't embed it.
  - Images `re-a2a` (runner plus ingress) and `re-acs-guardian`, generated per
    instance by `re-init` and natively by `startUniverse.sh`.
- **K14 — Operator surface.**
  - Manager observes tasks and answers `ask` (C6), as observation and
    configuration only. No AGT or ACS host goes in Manager (2026-11-11).
  - Manager's workflow driver dispatches through the framework like any other
    client.
  - The OpenClaw sunset migrates the clone agents and the regression stages
    (#841 scope 6).

**Open for the owner**

- **A10 — Where the framework lives:** a new repository (for example
  `RealityEngine_A2A`), or inside RealityEngine_CI. A new repository would
  join the focus set and build control.
- **A11 — Implementation language, and whether to build on an A2A SDK** (the
  A2A project publishes Python, JavaScript, Java, Go and .NET SDKs) or
  implement the wire directly. Either way the SDK stays inside the framework.
  Today's adapter and Manager are TypeScript, and the suite's Go services need
  the OpenSSL front for TLS 1.3 suites.
- **A12 — Whether the framework is published** as a RealityEngine A2A framework
  other services can adopt, or stays internal for v0.0.3.

### Revised decisions

- **A7 (decided 2026-11-23): release-v0.0.3.** release-v0.0.2 is complete and
  closed, so v0.0.3 is the next release. v0.0.3 must include the leftovers of
  earlier releases, and this plan is one of them: it was set for "the next
  release" in 2026-10 and v0.0.2 shipped without it.
- **A8 (revised): A2A in.**
  - A2A is the gateway, so governing A2A traffic is in scope.
  - At 2026-10-19, upstream ACS reserved A2A wrapping for v0.2. We therefore
    instrument A2A at our own boundary with the v0.1 hooks above.
    `protocols/A2A/*` is adopted when the pinned ACS version defines it. B1
    verifies upstream's current state.
  - MCP: wrapped MCP is mandatory if a session uses MCP at all (ACS 0.1.3,
    `AGENT_GOVERNANCE_REVIEW.md` §1). That reopens the MCP half of the original
    A8, and B2 records it.
  - The OpenClaw-internal hooks fall away with OpenClaw.
- **A9 (decided 2026-11-23): the RealityEngine A2A framework is the target
  integration,** for dispatch and ingress, with every mapping to the
  underlying standards' APIs and flows contained in it (above). A10–A12 are
  open.

### Revised and added tasks

| ID | Task | Area | Depends on | Status |
|---|---|---|---|---|
| A7 | Release vehicle: v0.0.3, with the leftovers of earlier releases | owner | — | decided 2026-11-23 |
| A8 | Scope: A2A in, MCP wrapping as ACS requires, OpenClaw hooks out | owner | — | revised 2026-11-22 |
| A9 | The RealityEngine A2A framework is the target integration, containing every mapping | owner | — | decided 2026-11-23 |
| A10 | Where the framework lives | owner | — | open |
| A11 | Language, and SDK or own wire | owner | — | open |
| A12 | Published for others, or internal in v0.0.3 | owner | — | open |
| K1–K14 | What the framework needs (§ What the framework needs) | CI + owner | A9 | open |
| B1 | Re-pin: the current ACS release (v0.1.4 or later; the review recommended retargeting) and A2A v1.0.x, both vendored | CI | — | open |
| B4 | `docs/A2A_GATEWAY_CONTRACT.md` (#841 scope 1; K1): dispatch, ingress, Agent Card per instance, task-state ↔ ledger mapping, the containment boundary | CI/docs | B1 | open |
| B5 | Ingress hook mapping, beside B2's dispatch mapping | CI/docs | B2, B4 | open |
| B6 | A2A conformance: the A2A project's test kit run against each runner and each instance's Agent Card | CI | B1, B4 | open |
| C1 | Runner = per-instance A2A client (dispatch), replacing the OpenClaw adapter | CI | A1, A9 | revised |
| C7 | Per-instance A2A server (ingress), behind that instance's Guardian | CI | A1, A9, B5 | new |
| D2 | Commit gate covers solicited and unsolicited ingress | CI | D1, C7 | revised |
| O1–O6 | Per compatible service: hook inventory where the runtime has one, else the gap goes in H3 | per service | A9 | revised |
| G4 | Rung 4 against a live A2A agent (the first compatible services, #841 scope 5) and the release Guardians | CI/operator | G3, A2 | revised |
| G9 | Regression stage `acs-a2a` replaces `acs-acp`, joins #841's A2A stage: 3-of-3, and the followers must agree (#842) | CI | G3 | revised |

The harness label becomes `acs-a2a-v0.1` (formerly `acs-acp-v0.1.0`) once B1
fixes the ACS version.

## The target

**ACS v0.1.0 for ACP** is done when:

- every dispatch and every Response→Source commit of the `openclaw-xacp`
  integration passes through the ACS Guardian of the engine instance it belongs
  to, over the v0.1.0 wire, as do the OpenClaw agent's own hooks;
- the Guardian's decision is enforced, and enforcement **fails closed**;
- each dispatch is one hash-chained, signed audit session, traced end to end;
- the integration declares **ACS-Core + Trace + Inspect + Provenance +
  Signing** at the handshake and passes the upstream conformance harness for
  each declared profile;
- it is proven at rung 4 of the contract's verification ladder, on all three
  engines, in a release install;
- it is shipped in a RealityEngine release, with a conformance report.

## Where we are, 2026-10-19

| Area | State | Evidence |
|---|---|---|
| ACP PE contract | `GET /api/integrations/acp/status`, `POST /api/integrations/acp/dispatch` (202, fire-and-record), `POST /api/integrations/completions` on CPP, LSP, Scala, and the TypeScript PE | `docs/OPENCLAW_INTEGRATION.md` § Current State |
| Adapter | `scripts/openclaw-acp-adapter.mjs` (166 lines) is **one-shot**. It takes a handoff receipt, calls the gateway's `/v1/chat/completions`, extracts `values`, posts the completion and patches the ledger | `npm run openclaw:adapter` |
| **Durable handoff transport** | **None.** Nothing consumes accepted handoffs. A release install configures ACP (`release/init/reinit.py`) but runs no adapter, so the Dispatch → Response→Source loop does not run without a human | `OPENCLAW_INTEGRATION.md` § Main Gap; `release/compose.yml` |
| Verification rung | **3**: real PE, real corpus, deterministic hello-world callback. The regression stage `openclaw-integration-*` runs that callback, not the live adapter path | `EXTERNAL_INTEGRATION_CONTRACT.md` §5, §7 |
| Session policy | **None.** ACP has no equivalent of MCP's `allowedTools` | `OPENCLAW_INTEGRATION.md` roadmap item 6 |
| Correlation | **None** across session key, ACP run id, dispatch, envelope and completion ids | roadmap item 7 |
| Metrics | adapter counters in `bridge-metrics-exporter.mjs` (:7342), the AI Bridge Operations dashboard | `OPENCLAW_INTEGRATION.md` § Operational Metrics |
| ACS / AOS | **Nothing implemented.** No hook, Guardian, audit chain, trace or AgBOM | — |

Upstream state that constrains the plan (`docs/owasp_acs.md` §9):
- Only `steps/toolCallRequest` and `steps/toolCallResult` are evaluated live in
  the reference Guardian.
- The wire is unauthenticated (upstream #70).
- The reference Guardian fails open by default (#32, #37).
- Conformance in v0.1.0 is self-declared.

## How the standard maps onto the two workflows

**Roles.** The OpenClaw target agent is the **Observed Agent**. **Every engine
instance** (`cpp-1`, `lsp-2`, and so on) gets its own **ACP runner** (C1) and
its own **Guardian Agent** (A1). The runner is the instrumentation point for its
instance's dispatches: it fires hooks to that instance's Guardian and enforces
the decisions. Inside OpenClaw, an ACS hook pack (O2) fires the agent's own
hooks to the Guardian of the instance that owns the session.

No Guardian has an overarching view. Agent spaces can be unique to an instance,
with no view of the distributed whole, so each instance governs its own. The
engines' code stays as it is (invariant 2.5, below).

| Step in the workflow | Today | ACS hook (v0.1.0) | Dispositions | Enforced by |
|---|---|---|---|---|
| **Dispatch** | | | | |
| A CES match records a trigger envelope; the PE marks the dispatch `accepted` | PE | — (PE-internal; the PE's 202 records, it does not hand off) | — | — |
| The runner claims an `accepted` record | none | `steps/sessionStart` (opens the audit chain) | allow / deny | runner |
| Why the agent is being woken: machine, CES, envelope, governance | none | `steps/agentTrigger` | allow / deny / ask / defer | runner |
| The prompt built from the envelope | adapter | `steps/userMessage` | allow / deny / modify (redaction) / ask | runner |
| The gateway call leaves the integration | adapter | `steps/turnStart`, then `steps/toolCallRequest` for the gateway call (ACS: any action that leaves the reasoning context MUST fire it) | allow / deny / modify (redaction) / ask / defer | runner |
| **Response→Source** | | | | |
| The gateway's answer arrives | adapter | `steps/toolCallResult`, then `steps/agentResponse` | allow / deny | runner |
| Values extracted and projected to `sourceMappingId` | adapter | `steps/memoryStore` (the commit into persistent vector state); confirmed or replaced in B2 | allow / deny; **never modify values** (A3) | runner |
| `POST /api/integrations/completions` → sensor source → next push | adapter, PE | `steps/turnEnd` | audit only | — |
| Ledger terminal: completed, failed, denied, or no completion in time | adapter, ledger | `steps/sessionEnd` (seals the chain) | audit only | runner |
| Liveness | — | `system/ping` | not audited | runner ↔ Guardian |
| What the agent is made of | — | `agbom/snapshot`, `agbom/changed` | — | runner (Inspect) |

**Inside the Observed Agent** (section O; in scope by A8):

| OpenClaw event | ACS hook (v0.1.0) | Enforced by |
|---|---|---|
| The agent's own tool calls and their results | `steps/toolCallRequest`, `steps/toolCallResult` | the ACS hook pack, if the event can block (O1); otherwise audit only |
| Session compaction start and finish | `steps/preCompact`, `steps/postCompact` | the hook pack; provenance carried across the summary |
| Subagent and ACP-runtime spawns (`sessions_spawn`) | `steps/subagentStart`, `steps/subagentStop` | the hook pack |
| Skills registered, loaded, unloaded | `steps/skillRegister`, `steps/skillLoad`, `steps/skillUnload`, bound to an approved digest | the hook pack |
| Memory and knowledge reads and writes | `steps/memoryContextRetrieval`, `steps/memoryStore`, `steps/knowledgeRetrieval` | the hook pack |

Both tables are proposals. B2 confirms each row against the v0.1.0 schemas, and
O1 confirms which OpenClaw events exist and which can block. Anything that
cannot be instrumented is recorded with its reason in the conformance statement,
not left implied.

## Invariants this work must keep

These come from `EXTERNAL_INTEGRATION_CONTRACT.md` §2. Where ACS seems to
conflict with one of them, the invariant wins and the conformance statement
says so.

- **2.1 Projection is registry-owned.** A Guardian `modify` never changes
  `sourceMappingId`, region, values or TTL. If it could, the Guardian would
  become an undeclared contributor to a cell the arbitration registry has
  accounted for.
- **2.2 Ingress alone activates a source.** A denied, deferred or unanswered
  commit leaves the source inactive, which is how the denial can be observed.
- **2.3 Governance is CES-owned.** The Guardian enforces *safety* (who may be
  reached, with what, carrying what). It never decides severity, paging,
  runbook or SLA, and its policy must not read `triggerConfig` in order to
  override it.
- **2.4 Dispatch is fire-and-record.** All hooks run in the runner, after the
  PE's 202, so the PE cycle never waits on a Guardian. The ledger carries ACS
  decisions only as delivery metadata.
- **2.5 RE stays deterministic.** No hook reaches RE. With the Guardian
  allowing, every parity stage must give byte-identical results to a run with
  ACS off.
- **Parity across engines.** Each instance's Guardian decides alone. Where
  instances run the same policy (every regression and release default does),
  the same dispatch from `cpp-1`, `lsp-1` and `scala-1` must get the same
  decision. So the deterministic layer is the only layer that may decide, and
  the optional LLM layer is never on in a parity run. Where an operator gives
  an instance its own policy, its decisions may differ. The decision record
  names the policy digest that made it, so a difference can be attributed.
- **Identity per instance.** A runner and a Guardian belong to one instance and
  carry that instance's `instance_uuid` (#296). Neither mints a UUID, and no
  two instances share either one.
- **Fail closed.** No Guardian answer means no handoff and no commit. Upstream
  defaults to failing open; that default is not acceptable here.

## Status summary

| ID | Task | Area | Depends on | Status | Tracking |
|---|---|---|---|---|---|
| **A1** | Where the hook client lives | owner | — | decided: a runner and a Guardian per engine instance | |
| **A2** | Which Guardian runs | owner | — | decided: in-repo deterministic in the release; upstream reference at rung 4 | |
| **A3** | Dispositions allowed per hook | owner | B2 | decided: `modify` redacts only | |
| **A4** | Session, turn and agent identity | owner | — | decided: session = `dispatchId` | |
| **A5** | Fail-closed timeouts and the `ask` path | owner | — | decided: timeout denies; `ask` answered in Manager | |
| **A6** | Trace backend | owner | — | decided: existing Prometheus/Loki/Grafana plus Collector and Tempo, with their use verified | |
| **A7** | Release vehicle and version | owner | — | decided: the next release; `acs-acp-v0.1.0`. **Decided 2026-11-23: release-v0.0.3** | |
| **A8** | Scope | owner | — | decided: MCP wrapping and A2A out; OpenClaw-internal hooks **in**. **Revised 2026-11-22: A2A in** (§ A2A) | |
| **A9** | A2A framework | owner | — | **decided 2026-11-23:** the RealityEngine A2A framework, containing every mapping (§ A2A) | #841 |
| **B1** | Vendor the v0.1.0 schemas, pinned | CI | — | open | |
| **B2** | ACP ACS profile: the hook mapping, confirmed | CI/docs | B1 | open | |
| **B3** | Upstream conformance harness, runnable locally | CI | B1 | open | |
| **C1** | Durable ACP handoff runner | CI | A1 | open | |
| **C2** | ACS client: wire, handshake, envelope | CI | B1, A4 | open | |
| **C3** | Dispatch hooks and enforcement | CI | C1, C2, A3, A5 | open | |
| **C4** | Session policy as the deterministic layer | CI/Machines | A2, C2 | open | |
| **C5** | Fail-closed and liveness | CI | C2, A5 | open | |
| **C6** | `ask` approval in Manager | Manager | C3, A5 | open | |
| **D1** | Response hooks: `toolCallResult`, `agentResponse` | CI | C3 | open | |
| **D2** | Commit gate before the completion is posted | CI | D1, A3 | open | |
| **D3** | Session end, and the handoff that never completes | CI | D2 | open | |
| **O1** | OpenClaw hook inventory: which events exist, which can block | OpenClaw | — | open | |
| **O2** | ACS hook pack for OpenClaw, routed to the owning instance's Guardian | OpenClaw | O1, C2, A4 | open | |
| **O3** | Tool calls inside the agent | OpenClaw | O2 | open | |
| **O4** | Compaction, subagents and skills | OpenClaw | O2 | open | |
| **O5** | Memory and knowledge | OpenClaw | O2 | open | |
| **O6** | Gaps OpenClaw cannot instrument, filed upstream | OpenClaw/owner | O1 | open | |
| **E1** | Hash-chained audit log per session | CI | C2 | open | |
| **E2** | Replay protection | CI | E1 | open | |
| **E3** | Provenance profile | CI | C3, D2 | open | |
| **E4** | Signing profile (HMAC-SHA256) | CI/release | C2 | open | |
| **F1** | Trace: one OpenTelemetry trace per dispatch | CI/release | A6, C3, D2 | open | |
| **F2** | Trace: OCSF events for decisions | CI | F1 | open | |
| **F3** | Metrics and dashboard | CI | C3, D3 | open | |
| **F4** | Inspect: AgBOM snapshot and change | CI/OpenClaw | B2 | open | |
| **F5** | Collector and Tempo, wired to the existing stack | CI/release | A6 | open | |
| **F6** | Verify each observability service is used | CI | F1–F5 | open | |
| **G1** | Rung 1: every emitted envelope validates | CI | B1, C3, D2 | open | |
| **G2** | Rung 2: mock gateway and deterministic Guardian | CI | G1 | open | |
| **G3** | Rung 3: PE boundary on every engine | CI | G2, C1 | open | |
| **G4** | Rung 4: live OpenClaw and the chosen Guardian | CI/operator | G3, A2 | open | |
| **G5** | Upstream conformance harness passes | CI | B3, G2 | open | |
| **G6** | Negative suite | CI | E1, E2, E4, C5 | open | |
| **G7** | Determinism and parity unchanged | CI | G3 | open | |
| **G8** | Evidence chain with the ACS links | CI/docs | G4 | open | |
| **G9** | Regression stage `acs-acp` on both local lanes | CI | G3 | open | |
| **H1** | Images and install | CI/release | C1, A2 | open | |
| **H2** | Documentation aligned | CI/docs | B2, G4 | open | |
| **H3** | Conformance statement and report | CI/docs | G5, G8 | open | |
| **H4** | Ship through the release process | release operator | H1–H3, A7 | open | |
| **H5** | Upstream contribution | owner | H3 | open | |

## A. Decisions, made 2026-10-19

A7 and A8 are revised, and A9–A12 added, in § A2A (2026-11-22, 2026-11-23).

- [x] **A1 — A runner and a Guardian per engine instance.** Every engine
  instance gets its own ACP runner (C1) and its own Guardian, and together
  they close the durable-transport gap.
  - Why: agent spaces can be unique to an instance, with no overarching view of
    the distributed whole, so no shared component may govern them.
  - Consequences:
    - The pair is generated per instance spec, the way engine services are
      (`reinit.py engine_services`; natively, `startUniverse.sh` per
      `--engines` entry).
    - Each pair carries its instance's `instance_uuid`.
    - Each runner claims only its own PE's ledger records.
    - The OpenClaw hook pack routes by session to the owning instance's
      Guardian.
    - The engines' code does not change.
- [x] **A2 — Both Guardians.** The release ships an in-repo deterministic
  Guardian (OPA/Rego), one per instance. The upstream reference Guardian (Bun,
  wrapping Microsoft's Agent Governance Toolkit) is the rung-4
  interoperability target (G4), pinned by digest and configured to fail closed.
- [x] **A3 — `modify` redacts only.**
  - A Guardian may redact the prompt and metadata.
  - It may never change values, `sourceMappingId`, region or TTL (§2.1), or
    the gateway target.
  - `ask` and `defer` are allowed only before the gateway call. Response→Source
    hooks are allow or deny.
- [x] **A4 — Session = `dispatchId`.**
  - ACS `session_id` = `dispatchId`, and `turn_id` = attempt number.
  - `agent_id` = the OpenClaw target agent and session key.
  - Metadata carries the originating instance's `instance_uuid` and Lamport
    `{instance, lamport, step}`.
  - A `dispatchId` is unique within its instance. The pair (`instance_uuid`,
    `dispatchId`) is unique everywhere and is what the hook pack routes on.
- [x] **A5 — Fail closed; `ask` is answered in Manager.**
  - A Guardian timeout or no answer means deny.
  - An `ask` holds the dispatch in ledger status `pending` with a bounded TTL.
    An operator approves or denies it in Manager. When the TTL lapses, it is
    denied.
- [x] **A6 — The existing stack, plus a Collector and Tempo, verified.** Use the
  current Prometheus, Loki and Grafana for metrics, OCSF events and dashboards.
  Add an OpenTelemetry Collector and Tempo for traces. Prove that each service
  actually receives and serves this work's data (F6) rather than assuming it.
- [x] **A7 — The next release.** `release-v0.0.1` is not reopened. The work
  ships in the next release, versioned `acs-acp-v0.1.0` in the release manifest
  and declared at the handshake.
- [x] **A8 — Scope.**
  - Out: `protocols/MCP/*` wrapping (the MCP pattern stays as it is), and A2A,
    which upstream reserves for v0.2.
  - **In: OpenClaw-internal hooks** — the agent's own tool calls, compaction,
    subagents, skills, memory and knowledge (section O).

## B. Spec baseline

- [ ] **B1 — Vendor the v0.1.0 schemas.** Copy the 44 JSON Schemas into
  `vendor/acs/v0.1.0/` with the upstream commit, a checksum file and the Apache
  2.0 notice. Add a check that refuses a schema edited in place.
  - **Done:** the schemas validate and the check is in Scripts Unit Tests.
- [ ] **B2 — ACP ACS profile.** Write `docs/ACP_ACS_PROFILE.md`. Under contract
  §6 it is the integration document for this work, so it must not restate
  `SURFACE_SPEC.md`. It contains:
  - each hook, its payload built from our artefacts (envelope, ledger record,
    receipt, completion);
  - the dispositions allowed for each hook (A3);
  - the hooks not instrumented, each with its reason.
  - **Done:** every row of the mapping table above is either confirmed against
    a schema or replaced with a cited reason.
- [ ] **B3 — Conformance harness.** Run upstream `bun run conformance` from a
  pinned checkout against a local endpoint, as a script under `scripts/`.
  - **Done:** it runs on this Mac against the reference Guardian, and the
    result is recorded.

## C. Dispatch workflow (Instrument)

- [ ] **C1 — Durable ACP handoff runner, one per instance (A1).**
  - Turn `openclaw-acp-adapter.mjs` into a service, `re-acp-runner`.
  - Each instance gets its own runner, paired with its own Guardian. The runner
    finds its PE in the instance registry by `instance_uuid`, never from a
    literal (`check-registry-url-literals.sh`).
  - It claims only its own PE's `accepted` dispatch records, idempotently by
    `dispatchId`, and runs the adapter path.
  - Its state, the audit chains included, is in a named volume per instance.
    An instance keeps its volume across restarts and spec changes, as its UUID
    and clock do.
  - Natively, `startUniverse.sh` spawns one pair per `--engines` entry. In a
    release, `reinit.py engine_services` generates the pair beside each
    instance's PE and RE.
  - Adding `cpp:2` gives `cpp-2` its own pair. Removing an instance stops its
    pair and keeps its volume.
  - **Done:** a CES-triggered dispatch on each instance reaches the gateway and
    returns a committed completion with no human step, on both lanes, with a
    multi-instance spec (`cpp:2,lsp:1,scala:1`).
- [ ] **C2 — ACS client.**
  - JSON-RPC 2.0 over HTTP to the Guardian, beginning with `handshake/hello`,
    which declares the profiles.
  - Every request carries `acs_version`, `request_id`, `timestamp`, metadata
    (A4), payload and signature (E4).
  - **Done:** G1 passes for every request type the runner sends.
- [ ] **C3 — Dispatch hooks.**
  - `sessionStart`, `agentTrigger`, `userMessage`, `turnStart` and
    `toolCallRequest`, in that order, before the gateway call.
  - A deny ends the dispatch: ledger `failed`, error `acs:deny:<hook>:<reason>`,
    and the receipt carries the decision and the `request_id`. This uses the
    existing statuses, so no engine changes.
  - A `modify` applies only within A3.
  - **Done:** G2 covers every disposition at every dispatch hook.
- [ ] **C4 — Session policy as the deterministic layer.** This is
  `OPENCLAW_INTEGRATION.md` roadmap item 6, done as Guardian policy.
  - The `openclaw-xacp` integration-registry entry gains `allowedGatewayUrls`,
    `allowedSessionKeyPrefixes`, `allowedTargetAgents` and
    `permissionProfile`.
  - Each instance's Guardian loads its own policy as data. The default policy
    is identical for every instance, and an operator may give one instance its
    own.
  - Every decision records the digest of the policy that made it.
  - The policy states safety only (§2.3).
  - **Done:** with the default policy, a dispatch outside policy is denied on
    every instance with the same decision. With a per-instance policy, only
    that instance's decisions change.
- [ ] **C5 — Fail closed.**
  - `system/ping` at runner start and on an interval.
  - Guardian unreachable, timing out (A5) or answering with a bad signature
    means no gateway call and the dispatch denied with a reason.
  - **Done:** G6 proves each case.

- [ ] **C6 — `ask` approval in Manager (A5).**
  - Manager lists every instance's dispatches held in `pending` by an `ask`,
    with the hook, the redacted payload, the policy digest and the remaining
    TTL.
  - The operator approves or denies. The answer goes to that instance's
    Guardian as the `ask` resolution, which is itself an audited entry in the
    session's chain.
  - When the TTL lapses, the dispatch is denied with reason `ask-expired`.
  - This is a `RealityEngine_Manager` change, with a Manager e2e test.
  - **Done:** approve, deny and expiry each work end to end on one instance and
    leave the other instances untouched.

## D. Response→Source workflow

- [ ] **D1 — Response hooks.** `toolCallResult` with the raw gateway response,
  then `agentResponse` with the agent's text, both before value extraction.
  - **Done:** a denied response produces no completion, and the ledger records
  why.
- [ ] **D2 — Commit gate.**
  - The commit hook (B2: `memoryStore`, or its replacement) carries the
    extracted values, `sourceMappingId`, and the sensor id and region it
    resolves to. The PE is the authority for these; the runner reads them from
    `acp/status`.
  - Only after an allow does the runner post `/api/integrations/completions`.
  - A deny leaves the source inactive (§2.2).
  - **Done:** for an allowed commit the PE's sensor source matches today's
    path byte for byte. For a denied one, the source reports inactive at every
    observation point.
- [ ] **D3 — Session end.**
  - `turnEnd` after the commit.
  - `sessionEnd` at every ledger terminal state seals the chain.
  - A watchdog ends a handoff with no completion within its TTL as `sessionEnd`
    with reason `timeout`. This is the ACP failure mode
    (`OPENCLAW_INTEGRATION.md` § Which pattern this is), made visible.
  - **Done:** no session stays open past its TTL, and each one is sealed.

## O. OpenClaw-internal hooks (inside the Observed Agent)

OpenClaw 2026.6.34 has an internal hook system: `openclaw hooks list | info |
enable`, with hook packs installed as plugins (`openclaw plugins install`). Its
bundled hooks include `command-logger`, `compaction-notifier` and
`session-memory`. This section puts ACS hooks there. Any ACS hook pack, plugin
or configuration change lives in `localOpenClawStack`.

- [ ] **O1 — Hook inventory.** List every OpenClaw hook event in the pinned
  version, and for each one record:
  - whether it can **block** or change the action, or only **notify**;
  - its payload;
  - the ACS hook it maps to.
  - **Done:** the table in § How the standard maps is confirmed or corrected
    row by row, with OpenClaw's docs or source cited for each.
- [ ] **O2 — ACS hook pack.** An OpenClaw plugin that:
  - turns each mapped event into an ACS request through C2's client;
  - routes it to the Guardian of the instance that owns the session, using the
    (`instance_uuid`, `dispatchId`) pair carried from the handoff (A4);
  - blocks on the answer where O1 says it can, and fails closed (A5).
  - An event in a session no instance owns (an operator chat in Open WebUI) is
    out of this integration and is recorded as such, not routed.
  - **Done:** the pack is pinned and installed by `localOpenClawStack`'s start
    script and by the release image, and each event it handles reaches the
    right instance's Guardian.
- [ ] **O3 — Tool calls inside the agent.** The agent's own tool calls fire
  `toolCallRequest`, which is ACS's central enforcement point, and their results
  fire `toolCallResult` before they reach the agent's context.
  - **Done:** a tool call outside the instance's policy is refused inside
    OpenClaw, if O1 found a blocking point. If it found none, the call is
    audited and the gap is stated in H3.
- [ ] **O4 — Compaction, subagents and skills.**
  - `preCompact` and `postCompact` carry provenance across a summary, so that
    compaction does not launder it.
  - `subagentStart` and `subagentStop` fire for `sessions_spawn`, including the
    ACP runtime.
  - Skills are bound to an approved digest: `skillLoad` of a skill whose digest
    is not approved is denied.
  - **Done:** each hook fires in a G4 run.
- [ ] **O5 — Memory and knowledge.** `memoryContextRetrieval`, `memoryStore` and
  `knowledgeRetrieval` fire for OpenClaw's memory and its retrieval.
  - **Done:** each hook fires in a G4 run.
- [ ] **O6 — What OpenClaw cannot instrument.** Every event O1 found
  notify-only, missing, or without the payload ACS needs is listed in H3 and
  filed with OpenClaw upstream (owner).

## E. Audit, provenance and signing

- [ ] **E1 — Audit chain.** One hash-chained log per session, rooted at
  `sessionStart` and sealed at `sessionEnd`, in the runner's volume. The chain
  head hash is written into the ledger receipt, so the PE side can be checked
  against it.
  - **Done:** a verifier script recomputes every sealed chain, and G6 tampers
    with one.
- [ ] **E2 — Replay protection.**
  - A `request_id` is never reused.
  - Timestamps are within a window.
  - The engine's Lamport `{instance, lamport, step}` in metadata is monotone
    per instance.
  - **Done:** a replayed request is refused (G6).
- [ ] **E3 — Provenance profile.** Arguments carry `origin` and `derivedFrom`:
  - the instance UUID, machine id, CES id and envelope id for dispatch;
  - the gateway, agent, response id and dispatch id for the response;
  - the response, the extraction rule and the mapping for the commit.

  This is the contract's §4 evidence chain, carried in the hooks.
  - **Done:** an allowed commit's provenance reaches back to the CES match that
    triggered it.
- [ ] **E4 — Signing profile.** HMAC-SHA256 envelope signatures.
  - The key is generated by `re-init` into `state/secrets.json`, and natively
    by `startUniverse.sh`.
  - It is never `ACP_SESSION_KEY`, which is a session address, not a secret.
  - **Done:** an unsigned or wrongly signed message is refused in both
    directions.

## F. Observability (the AOS pillars)

The decided pipeline (A6) is one OpenTelemetry Collector per install:
- traces go to Tempo;
- OCSF decision events and runner logs go to the **existing Loki**;
- metrics go to the **existing Prometheus**;
- the **existing Grafana** gets a Tempo datasource with links between traces and
  logs, and dashboards over all three.

Each runner and Guardian, and the OpenClaw hook pack, export OTLP to the
Collector. Every signal carries `instance_uuid`, so a view is per instance by
default (A1).

- [ ] **F1 — Trace.** One OpenTelemetry trace per dispatch.
  - Spans for each hook, the gateway call, the OpenClaw-internal hooks (O2) and
    the commit.
  - Attributes: `dispatchId`, `envelopeId`, `correlationId`, `sessionKey`,
    `completionId`, ACS `request_id`, `instance_uuid` and engine type.
  - This closes `OPENCLAW_INTEGRATION.md` roadmap item 7.
  - **Done:** for any `dispatchId`, one query shows its whole path on every
    engine.
- [ ] **F2 — OCSF events.** Each Guardian decision is an OCSF event through the
  Collector to Loki, labelled with `instance_uuid` and carrying the trace id.
  - **Done:** every deny and every `ask` is findable by trace id.
- [ ] **F3 — Metrics.**
  - New counters, scraped by Prometheus from each runner, Guardian and the
    bridge exporter, labelled by instance: decisions by hook and disposition,
    Guardian latency, fail-closed denials, handoffs with no completion, and
    sealed versus open sessions.
  - New panels on AI Bridge Operations.
  - **Done:** the panels show a G4 run.
- [ ] **F4 — Inspect (AgBOM).** A CycloneDX AgBOM of the ACP surface:
  - the OpenClaw gateway image digest;
  - the model and its Ollama digest;
  - the agents of the deployed corpus, which follow the corpus;
  - the runner and Guardian images;
  - the PE instances from the instance registry.

  `agbom/snapshot` answers on request. `agbom/changed` fires when a machines
  load changes the agents. Inspect-Dynamic is not declared in v0.1.0.
  - **Done:** a machines load produces a correct `agbom/changed`.
- [ ] **F5 — Collector and Tempo.**
  - Add both to the release catalog, pinned by tag and digest, and to the
    native observability stack.
  - Configure the Collector's three pipelines as above.
  - Provision the Tempo datasource and the trace-to-logs links in Grafana.
  - Keep Loki, Promtail, Prometheus and Grafana at the versions in
    `config/shared-service-versions.json`. Add the two new services there, so
    `check-shared-service-versions.py` covers them.
  - **Done:** the release install and the native stack both start the
    Collector and Tempo, and the version check passes.
- [ ] **F6 — Verify that each service is used.** Assert from the running
  system, not from configuration, that:
  - **Prometheus** has a healthy scrape target for every instance's runner and
    Guardian, and the F3 series exist for each `instance_uuid`;
  - **Loki** holds the F2 events for a G4 dispatch, queryable by trace id and
    by instance;
  - **Tempo** returns that dispatch's trace, with every expected span;
  - **Grafana** has each datasource healthy, the dashboards render with data,
    and a trace links to its logs.
  - This becomes part of `acs-acp` (G9) and is recorded in the service
    inventory. A service that is configured but receives nothing fails, as
    §2.2 holds for sources.
  - **Done:** F6 passes on the local lane and in a release install.

## G. Prove

Each rung of the contract's §5 is reported separately, and a lower rung is not
evidence for a higher one.

- [ ] **G1 — Rung 1, isolated.** Every envelope the runner can emit, from
  fixtures, validates against the vendored schemas (B1).
- [ ] **G2 — Rung 2, mocked.** Extend `scripts/tests/openclaw-acp-adapter-e2e.test.mjs`
  with a deterministic mock Guardian and cover:
  - every disposition at every hook;
  - fail-closed;
  - the audit chain.
  This rung also runs on the hosted lane.
- [ ] **G3 — Rung 3, PE boundary.** Extend `scripts/test-openclaw-integration.sh`
  to run the full runner path against each instance in the instance registry,
  each through its own runner and Guardian, with a spec that includes a second
  instance of one type. Assert:
  - identical decisions for the same dispatch under the default policy;
  - with one instance on its own policy, only that instance's decisions change,
    and no instance's audit, trace or Guardian sees another instance's
    session;
  - a sealed chain;
  - the sensor source at `4210:4` for an allow, and inactive for a deny.
- [ ] **G4 — Rung 4, live.** The live OpenClaw gateway with the ACS hook pack, a
  real target agent and the release Guardians, plus one run against the
  upstream reference Guardian (A2).
  - The run must exercise every O3–O5 hook that O1 found, routed to the right
    instance.
  - It also closes `OPENCLAW_INTEGRATION.md` roadmap item 5, phase 3.
- [ ] **G5 — Upstream conformance.** B3's harness passes for each declared
  profile. Anything it cannot check is listed in H3.
- [ ] **G6 — Negative suite.** Guardian down, timeout, a bad signature, a
  replayed request, a tampered chain, a policy-violating dispatch, and a
  `modify` that tries to change values (it must be refused).
- [ ] **G7 — Determinism unchanged.** With the Guardian allowing, every parity
  stage (trajectory, machine-set, export, engine-process, reset) is identical
  to a run with ACS off at the same commits (§2.5).
- [ ] **G8 — Evidence chain.** Show the contract's §4 chain for one real G4
  event, extended with the hook decisions, chain head and trace id. It goes in
  `ACP_ACS_PROFILE.md`.
- [ ] **G9 — Regression stage.** `acs-acp` runs in `regression-test.sh` on the
  `local` and `local-containerized` lanes. The hosted profile runs G2 only and
  refuses the live stages, as it does for OpenClaw today.
  - **Done for G:** two consecutive green local and containerized runs with
    `acs-acp` passing, and G7 shows no change.

## H. Release

- [ ] **H1 — Images and install.**
  - Add `re-acp-runner` and `re-acs-guardian` to `release/images.json`, with
    B6 hygiene. `reinit.py engine_services` generates one pair per instance.
    They need no host ports: the pair talks to its PE and to the Collector
    inside the install network.
  - Add the Collector and Tempo to `release/compose.yml` (F5).
  - `re-init` generates a signing key per instance and the default policy.
  - The OpenClaw gateway image carries the ACS hook pack (O2).
  - Add `release/compose.yml` to the Release images workflow's PR paths
    (noticed on 2026-10-19).
  - **Done:** E1 of the release roadmap is green with `acs-acp`.
- [ ] **H2 — Documentation.** Update:
  - `OPENCLAW_INTEGRATION.md`: the runner, policy, rung;
  - `EXTERNAL_INTEGRATION_CONTRACT.md` §7: the rung;
  - `INTEGRATION_ARCHITECTURE.md`;
  - `INSTALL.md`: what fail-closed means for a user, where decisions are seen,
    how `ask` is answered;
  - the root and CI `CLAUDE.md` for the new service and environment.
- [ ] **H3 — Conformance statement.**
  - Self-declared, as v0.1.0 allows. It lists the declared profiles, the
    hooks instrumented, the hooks not instrumented with reasons, the deviations
    taken for the invariants, the G5 results, and the upstream gaps worked
    around (#70, #32, #37).
  - The deliverable is `docs/ACS_CONFORMANCE.md`, published with the release.
- [ ] **H4 — Ship.** Through `RELEASE.md` in the release chosen by A7:
  - the candidate images;
  - the containerized lane with `acs-acp`;
  - the clean-Mac install;
  - the manifest recording `acs-acp-v0.1.0`.
- [ ] **H5 — Upstream.** Upstream values a conformance report showing where ACS
  breaks in practice more than any other contribution (`owasp_acs.md` §11). The
  issue form and Discussion are the owner's to file. Commits there need a human
  DCO sign-off.

## Sequence

| Phase | Tasks | Exit |
|---|---|---|
| 1. Decide | A1–A8 | **done 2026-10-19** |
| 2. Baseline | B1–B3, O1 | the schemas pinned, the profile written, the harness runs, OpenClaw's hook points known |
| 3. Transport | C1 | the loop runs with no human step (useful even without ACS) |
| 4. Instrument | C2–C5, D1–D3, O2–O6 | every hook fires at its instance's Guardian and is enforced, fail-closed |
| 5. Audit and observe | E1–E4, F1–F6 | sessions sealed and signed, traced, AgBOM served, each observability service shown to be in use |
| 6. Prove | G1–G9 | rungs 1–4 green, conformance passes, parity unchanged |
| 7. Release | H1–H5 | shipped, documented, conformance statement published |

C1 comes first among the build tasks: without it there is no place to put a
hook, and no release install can show either workflow working. O1 runs during
the baseline, because what OpenClaw can block determines how much of A8's scope
is enforcement and how much is audit.

## Risks

- **Spec churn.** v0.2.0 is due March 2027 and changes async, batching and
  `ask`. Pinning B1 to v0.1.0 contains this; moving to v0.2.0 is a separate
  plan.
- **Upstream Guardian maturity.** It fails open, has an unauthenticated wire,
  and evaluates two hooks live. Shipping our own deterministic Guardian (A2)
  keeps the release independent of all three.
- **OpenClaw's hooks may only notify.** If O1 finds no blocking point for the
  agent's tool calls, ACS's central enforcement point is audit-only inside the
  agent. The boundary hooks (C, D) still enforce. H3 has to say so plainly, and
  O6 asks OpenClaw for a blocking hook.
- **Memory per instance.** A runner and Guardian per instance multiplies the
  footprint by the instance count, up to 20 per type. Record each one's
  footprint in B6, and give INSTALL.md's memory guidance per instance.
- **A second authority.** A Guardian policy that drifts into severity or paging
  decisions breaks §2.3 silently. Review C4's policy against `triggerConfig`
  and keep it to safety.
- **Latency.** Hooks add Guardian round-trips to every dispatch. They are off
  the PE cycle (§2.4), but F3 must show their cost to the handoff.

## Noticed, not chased

- `docs/owasp_acs.md` counts 22 methods. Upstream counts 19 native hooks, plus
  `agbom/*` and `system/ping`. B2 should use the upstream names, which have a
  `steps/` prefix.
- `localOpenClawStack/README.md` describes `ACP_SESSION_KEY` as a "shared
  secret". The release sets it to `agent:main:main`, a session address. E4 must
  not reuse it, and the README is wrong.
- The regression stage `openclaw-integration-*` tests the hello-world callback,
  not the adapter. Until G3, its name overstates what it covers.
