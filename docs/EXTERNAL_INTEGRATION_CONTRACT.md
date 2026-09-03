# External Integration Contract v1.0

Status: **the invariants are implemented in all three engines**; the verification
ladder in §5 is completed to different rungs by each worked instance.
Applies to: RealityEngine_CPP, RealityEngine_LSP, RealityEngine_Scala, and the
TypeScript PE in RealityEngine_Manager.

| | |
|---|---|
| MQTT bridge surface | CPP, LSP, Scala — see `SURFACE_SPEC.md` § MQTT Bridge |
| MQTT bridge implementations | four siblings — CPP (hand-rolled v3.1.1), Scala (Paho 1.2.5), LSP (native), Manager TypeScript PE (mqtt.js); each connects to a real broker and funnels PUBLISHes into PE sources |
| ACP/OpenClaw PE boundary | CPP, LSP, Scala |
| worked instance — MQTT | `RealityEngine_CPP/docs/MQTT_YUMA_DEMONSTRATION.md`, live against an external broker (§5 rung 4) |
| worked instance — ACP/OpenClaw | `docs/OPENCLAW_INTEGRATION.md`, PE-boundary and mock-gateway (§5 rung 3); live gateway not yet run |

This document is the single source of truth for **what an external system must
obey to contribute perceptual facts**. It is provider-neutral by construction: a
broker, an agent harness, a phone and a model endpoint differ in transport and
payload, and differ in nothing this document specifies.

It does not restate the route surface (`SURFACE_SPEC.md`), the integration
abstractions and provider adapters (`docs/INTEGRATION_ARCHITECTURE.md`), or how
contended cells resolve (`docs/ARBITER_CONTRACT.md`). It sits above them and
says what an integration is not allowed to do.

## 1. Why

Every external integration is the same shape wearing different clothes. MQTT
delivers sensor telemetry from a broker; OpenClaw returns an agent's judgement
through a gateway; HealthKit uploads a batch from a phone; localAIStack answers a
model call. Each arrives on its own transport, in its own payload, with its own
authentication — and each then has to become the same thing: **a value in a
region of the universal vector, at a time, with a lifetime.**

The failure this contract exists to prevent is an integration that takes a
shortcut on the way to that. A broker payload that carries its own offset, an
agent completion that resumes a machine directly, an adapter that pages someone
because it decided the reading looked bad — each is locally reasonable and each
destroys a property the rest of the system is built on. The properties are worth
more than any one integration's convenience, so they are stated once, here, and
every integration is checked against them rather than against its own document.

## 2. The invariants

### 2.1 Projection is registry-owned; the payload never carries a region

An external message says *what it observed*. It never says *where that lands in
the universal vector*. The mapping registry or the configured source mapping is
the sole authority for projection.

MQTT states this as "topics carry no offset information — the registry alone is
the authority for projection." ACP states the same rule in the other direction:
a completion names a `sourceMappingId`, and the PE resolves that to a
`sensorIdTemplate`, region and TTL. Both are the same invariant.

Why it is absolute: regions are allocated corpus-wide
(`RealityEngine_Machines/domains/region-allocation.json`, regenerated per
`MACHINE_CONCEPT.md` §9.1) and contended cells declare how they resolve
(`ARBITER_CONTRACT.md` §5). A payload that carries its own offset writes into
that allocation without appearing in it — an undeclared contributor to a cell
the arbitration registry believes it has accounted for.

### 2.2 Ingress is the only thing that activates a source

A source becomes active by receiving a value, and by nothing else. Registration
declares a source; it does not arm it. A source that has never received ingress
reports inactive at every observation point — at registration, before a reset,
and after one.

This is what makes an integration's liveness observable rather than asserted. A
configured-but-silent broker and a connected one differ in exactly one way that
a reader can check, and it is this one.

### 2.3 Governance is CES-owned; integration code never decides severity

The machine's `metadata.governance` and `metadata.triggerConfig` are the sole
source of truth for who is paged, against which runbook, under which escalation
policy, at which SLA. Bridge code, adapters and exporters carry that decision;
they never make it and never override it.

An adapter that pages on a threshold it judged itself creates a second alerting
authority whose disagreement with the corpus is invisible — both fire, neither
is wrong-looking, and the corpus stops being the description of the system.

### 2.4 Dispatch is fire-and-record; a completion re-enters as a fact

The PE emits a dispatch and records it. It does not wait for the external system,
and the external system does not resume anything. Whatever the agent, model or
tool eventually concludes returns through a configured source mapping, becomes a
value in a region like any other observation, and is interpreted by ordinary
machine interconnections.

The dispatch ledger is an audit and outbox record, not a workflow engine.
`PATCH /api/dispatch/records/{id}` carries delivery metadata only — status,
attempts, adapter name, provider run id, receipt, error text. It does not
complete a result, unblock a PE cycle, or drive RE state.

### 2.5 Reality Engine stays deterministic

Nothing in this document reaches Reality Engine. RE evaluates vector state and
returns a deterministic step result; every external contribution has already
become vector state before RE sees it. An integration that can change what RE
computes for a given input has broken the property that makes cross-runtime
parity meaningful.

## 3. The ingress paths

Every accepted inbound result — broker message, agent completion, bridge upload,
model response, manual callback — resolves to the one PE sensor-source shape
defined in `docs/INTEGRATION_ARCHITECTURE.md` § Source Mapper. Provider payloads
differ; PE commit semantics do not.

The transports are enumerated in `docs/INTEGRATION_ARCHITECTURE.md`
(`mqtt`, `localai`, `openai`, `ollama`, `acp`, `healthkit`, `mcp`, `manual`).
Adding a transport is an addition there; it does not amend this document, which
is the point of separating them.

The MQTT bridges state this rule from the inside, in the same words in all four
implementations: *"MQTT is not special-cased downstream. Every accepted PUBLISH
resolves to `{sensorId, region, values, ttlMs}` and is fed through the same
ingest callback the HTTP `POST /api/signals` path uses."* An integration that
needs a downstream special case has not finished converting its observation into
a fact.

## 4. The evidence chain

An integration is demonstrated when one external event can be followed to its
governance outcome without gaps, from the artefacts the running system already
produces. The chain has eight links, and an integration document shows them for
at least one real event:

1. **Source** — the external identity: broker and topic, gateway and agent,
   device and type.
2. **Payload** — the raw body as received.
3. **Projection** — the registry or mapping rules that fired, each with its
   extraction, its normalization, and the cell it wrote.
4. **PE sources** — the sensor sources updated, with age and TTL.
5. **Push** — the PE→RE submission, and the vector width it was sized to.
6. **Machine input** — the region as the target machine read it.
7. **CES match and output** — the initial event matched, the output values, and
   the provenance list.
8. **Governance and metrics** — the resolved paging contract from
   `triggerConfig`, and the counter it incremented.

`MQTT_YUMA_DEMONSTRATION.md` § The audit trail is the reference rendering of
this chain; it carries a twelfth line for the dashboard panel, which is
presentation rather than evidence.

What makes the chain worth insisting on: each link is reconstructable from the
`mergeBatch` alone. An integration that can only be shown to work by watching it
is an integration whose failures will also only be visible by watching.

## 5. The verification ladder

"It works" is four different claims. They are separate results and must be
reported separately, because passing a lower rung is not evidence for a higher
one.

| Rung | What it proves | External dependency |
|---|---|---|
| 1 · Isolated | The projection code maps payloads to cells correctly | none — fixtures |
| 2 · Mocked | The adapter speaks the real protocol, against a deterministic stand-in | none — mock service |
| 3 · PE boundary | Real PE, real corpus, real source commit and push | a running PE |
| 4 · Live | The real external system, over its real transport and auth | the external system |

A rung-3 pass with no rung-4 run means the contract is implemented and the
integration is unproven against the thing it integrates with. Say that, rather
than reporting rung 3 as success.

Neither worked instance is at rung 4 for everything it covers: MQTT reaches rung
4 against a live broker, and ACP/OpenClaw stops at rung 3 with the live-gateway
run still outstanding.

## 6. What an integration document must supply

An integration-specific document is not a copy of this one. It supplies what
this one deliberately does not know:

- **Identity and authentication** of the external system — host, port, protocol
  version, operator, credential handling.
- **The projection configuration** — the mapping registry file or source
  mapping, by path, with the rules readable.
- **The target machines** — which corpus machines it drives, their input
  regions, and the initial events those regions can match.
- **Reproduction** — the exact commands, per rung of §5, with the environment
  each needs.
- **Observed evidence** — the §4 chain for at least one real event, with real
  values.
- **Known limitations** — the rung it stops at, and what is missing to go higher.

It must not restate the route surface, which is `SURFACE_SPEC.md`, or the
per-runtime support matrix, which is also `SURFACE_SPEC.md`. A parity table
copied into an integration document is a second surface specification, and it
will be the one that goes stale.

## 7. Worked instances

| Instance | Document | Rung | Configuration |
|---|---|---|---|
| MQTT — external broker to the agriculture domain | `RealityEngine_CPP/docs/MQTT_YUMA_DEMONSTRATION.md` | 4 | `RealityEngine_CPP/config/mqtt-mappings.yuma-agriculture.json` |
| ACP/OpenClaw — agent dispatch and completion | `docs/OPENCLAW_INTEGRATION.md` | 3 | `config/integrations.json`, `openclaw-xacp` entry |

Both are agriculture and agent-facing respectively, and neither is normative.
They are worked examples of §2, and where one of them disagrees with this
document, this document is right and the instance is a defect.

## 8. Open

- **`INTEGRATION_ARCHITECTURE.md` exists as three near-identical copies** —
  `RealityEngine_CI/docs/`, `RealityEngine_CPP/docs/`, `RealityEngine_LSP/docs/`
  — differing by roughly a kilobyte each. That is the fork this scheme exists to
  prevent, one repository short of the `SURFACE_SPEC.md` failure of 2026-08-27.
  It is not yet registered in `scripts/check-surface-specs.sh` and so is not
  gated. Consolidating it to one master and two pointers is outstanding.
- **Rung 4 for ACP/OpenClaw** — live gateway and real target agent under
  regression, tracked in `docs/OPENCLAW_INTEGRATION.md` § Roadmap item 5,
  phase 3.
- **No gate asserts §2.1.** A payload that carried its own offset would be
  caught by review, not by CI. The check that would close it is a corpus-wide
  assertion that every writing contributor appears in the arbitration registry.
