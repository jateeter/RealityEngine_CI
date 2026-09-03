# Scala Integration — the engine as an integration target

The pipeline this document covers, read from the outside in:

```
integrator → runtime registry (re-registry.json) → scala-N entry →
RE :5001 (Akka actor engine) + PE :5000 (standalone Scala PE) →
PE source mappings → PE push → RE step result
```

Most integration documents describe an external system contributing facts *to*
RealityEngine. This one is the mirror: it describes the Scala runtime as the
thing being integrated *with* — what an integrator addresses, how it is
discovered, what it exposes, and where it behaves differently from its siblings.

## The contract this implements

The rules governing anything that crosses the PE boundary — that projection is
registry-owned and never carried by the payload, that ingress is the only thing
that activates a source, that governance is CES-owned, that dispatch is
fire-and-record — are specified once:

    RealityEngine_CI/docs/EXTERNAL_INTEGRATION_CONTRACT.md

The integration model the Scala PE implements — the registry, source mapper,
dispatcher, ledger, completion ingest, MCP gateway — is
`docs/INTEGRATION_ARCHITECTURE.md`, and the Scala PE holds a pointer to it at
`perception-engine/docs/INTEGRATION_ARCHITECTURE.md`.

The route surface is **not** restated here. Which routes exist and which
runtimes implement them is `SURFACE_SPEC.md`, whose `Scala` column is the
authority for this engine.

## Engine identity

`RealityEngine_Scala` is an **independent git repository** — its own history,
branches and remote — not a submodule or subproject of `RealityEngine_CI`. It
sits as a sibling directory so relative paths resolve, and that adjacency is the
only relationship the filesystem expresses.

It runs as **two processes, from two independent sbt builds**: the root build
produces the Reality Engine, and `perception-engine/` is a separate build with
its own `build.sbt` and `project/` that produces the Perception Engine. They are
not subprojects of one build — see `docs/BUILD_CONTROL_CONTRACT.md` §2.1, which
is the authority on that and on why it matters.

| | RE | PE |
|---|---|---|
| Default port | `5001` | `5000` |
| Entrypoint | `src/main/scala/com/realityengine/Main.scala` | `perception-engine/src/main/scala/...` |
| Health | `GET /api/health` | `GET /api/health` |
| Root `/` | name/version/status banner, not health | — |
| Artifact | `target/scala-2.13/reality-engine.jar` | `perception-engine/target/scala-2.13/perception-engine.jar` |
| Additional instances | `+100` per instance — `scala-2` is `5101`/`5100` | as RE |

`VECTOR_DIMENSION` defaults to `7680`; `MACHINES_DIR` defaults to
`../RealityEngine_Machines/machines`. Both are set by `start.sh`, and
`startUniverse.sh` overrides them when a corpus needs a wider space.

Two port facts an integrator has to know, both from `DEPLOYMENT_CONTRACT.md`:

- **`5001` is shared by design** with the CI Docker public RE endpoint, so
  tooling targets one port for "the Reality Engine". The two cannot run at the
  same time — a native Scala RE and the Docker stack contend for the same bind.
- **Scala tops out at three instances.** `scala-4` would claim `5300`/`5301`,
  which is `cpp-1`. The `+100` ladder is shared across runtimes, not per-runtime.

## Discovery: address the registry, not the port

An integrator that hard-codes `5001` works until the day a second instance
exists or the ports move. The runtime registry is the supported way in:

```
RE_REGISTRY_URL=http://127.0.0.1:5999/re-registry.json
```

Each running engine contributes one entry, written by `scripts/registry.sh`:

```json
{
  "id": "scala-1",
  "runtime": "scala",
  "re_url": "http://localhost:5001",
  "pe_url": "http://localhost:5000",
  "re_port": 5001,
  "pe_port": 5000,
  "pid_re": 12345,
  "pid_pe": 12346,
  "started_at": "2026-09-03T00:00:00Z",
  "status": "running"
}
```

Resolve `runtime == "scala"` and read `re_url` / `pe_url`. `RE_BASE_URL` and
`PE_BASE_URL` remain available for single-engine fallback, and are the right
choice only when there is exactly one engine and you put it there.

## What it exposes to integrators

The Scala PE implements the same integration surface as its siblings:

- **MQTT** — `perception/mqtt/MqttBridge.scala`, a full Eclipse Paho 1.2.5
  client. It connects to a real broker and funnels every accepted PUBLISH into
  PE sources through the same ingest callback `POST /api/signals` uses. See
  `RealityEngine_CPP/docs/MQTT_YUMA_DEMONSTRATION.md` for the worked instance;
  the mapping registry format is identical across runtimes.
- **ACP / OpenClaw** — status and dispatch endpoints, dispatch-ledger records for
  accepted handoffs, and `sourceMappingId` resolution on completion.
  See `docs/OPENCLAW_INTEGRATION.md`.
- **MCP / Ollama** — status and dispatch, resolving the canonical model per
  `docs/OLLAMA_INTEGRATION.md`.
- **HealthKit and CareKit** — device-bridge status and ingest, defaulting to
  `carekit-task` like every other runtime.

## The source and completion path

Identical to the other runtimes, and that is the point — an integrator writes one
adapter, not three. An inbound result resolves to the PE sensor-source shape,
commits through the same path `POST /api/signals` uses, and reaches RE only when
PE assembles a vector and pushes it. RE returns a deterministic step result.

Nothing an integrator sends reaches the Akka actors directly. The actor model is
an implementation detail of how RE evaluates machines, not a surface.

## Building it

Not restated here. Builds are controlled through `RealityEngine_CI` — which
repository builds, in what order, at which commit, and whether the result may be
used — and the per-repository commands, the two-independent-builds rule and the
`compile`-is-not-`assembly` trap all live in one place:

    RealityEngine_CI/docs/BUILD_CONTROL_CONTRACT.md

```bash
cd RealityEngine_CI
./scripts/regression-test.sh --build-only
```

What matters to an **integrator** rather than a builder is narrower: the engine
you are testing against may not be built from the source you think it is.
`RealityEngine_Scala/start.sh` rebuilds a jar that is missing or older than its
sources, so a native run is usually current — but `startUniverse.sh` launches
the main checkout's artifacts while the regression harness builds in throwaway
worktrees, so a harness run that "rebuilt everything" can still start a stale
main-checkout jar. `scripts/verify-build-provenance.py` refuses that before
anything spawns.

If you are diagnosing a Scala-only difference, confirm the gate ran before
concluding anything about the engine. §5 of the build contract explains why, and
the "Known limitations" below is the incident it came from.

## Bringing it up

```bash
# Native single-engine
cd RealityEngine_Scala && ./start.sh
curl http://localhost:5001/api/health    # RE
curl http://localhost:5000/api/health    # PE

# Registry-backed, as part of a universe — the supported path
cd RealityEngine_CI
./startUniverse.sh --engines=scala:1 --machine-load=runtime --warn-only
curl http://127.0.0.1:5999/re-registry.json | python3 -m json.tool
```

## Known limitations

- **`POST /api/reset` means something different here.** The three runtimes
  disagree: cpp keeps its sources, lsp discards them, and **scala reactivates
  every one of them**. An integrator that resets between scenarios will find
  sources live on Scala that are inert elsewhere. The settled contract is
  `RealityEngine_CI#163`/`#166`, which no runtime implements yet; the acceptance
  stage is `scripts/regression-reset-contract.py` and it fails by design.
- **Interned sequences advance correctly here, and this is the reference
  behaviour.** Measured 2026-08-19: Scala walks a three-vector interned sequence
  `0→1→2→0` as specified, while cpp freezes at index 0. When Scala and another
  runtime disagree about sequence advance, Scala is the one to trust until those
  defects close.
- **This engine's two artifacts go stale independently**, and Scala is the
  runtime where that has actually happened. Because the RE and PE come from two
  separate builds, one can be current while the other is hours behind: on
  2026-08-22 both jars predated that morning's merge, `perception-engine.jar` by
  5h39m, and the resulting three-engine divergence was investigated as a Scala
  engine defect before the build skew was found. It is the reason the provenance
  gate exists. If a difference appears to be Scala-specific, rule this out first
  — `docs/BUILD_CONTROL_CONTRACT.md` §5 has the gate and its override.
- **`GET /api/engine/stats` is not uniform.** `SURFACE_SPEC.md` lists it as
  uniform but the runtimes return different payloads. Use `GET /api/config` for
  `vectorDimension`.
