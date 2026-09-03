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

Two processes, from two sbt builds in one repository — the root build for the
Reality Engine, `perception-engine/` for the standalone Perception Engine.

| | RE | PE |
|---|---|---|
| Default port | `5001` | `5000` |
| Entrypoint | `src/main/scala/com/realityengine/Main.scala` | `perception-engine/src/main/scala/...` |
| Health | `GET /health` | `GET /api/health` |
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

## How to reproduce

Builds are controlled through `RealityEngine_CI`, not from inside the Scala
repository — see `docs/BUILD_CONTROL_CONTRACT.md`:

```bash
cd RealityEngine_CI
./scripts/regression-test.sh --build-only
```

That builds both Scala artifacts with the right invocations. If you are working
on the Scala repository alone, the two builds are **independent sbt builds, not
subprojects** — the root `build.sbt` declares no `aggregate` and no `dependsOn`,
so the root assembly does not produce the perception engine, and `compile` does
not produce the fat jars the launcher runs:

```bash
cd RealityEngine_Scala               && sbt clean assembly
cd RealityEngine_Scala/perception-engine && sbt clean assembly
```

```bash
# Native single-engine. start.sh rebuilds either jar that is missing or older
# than its sources, which is convenient and is also how a missing PE build
# stays invisible locally (RealityEngine_CI#173).
cd RealityEngine_Scala
./start.sh
curl http://localhost:5001/health
curl http://localhost:5000/api/health

# Registry-backed, as part of a universe
cd ../RealityEngine_CI
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
- **Two build artifacts go stale independently.** `startUniverse.sh` launches
  each repository's checked-in jar, and on 2026-08-22 both Scala jars predated
  that morning's merge — `perception-engine.jar` by 5h39m — producing a
  three-engine divergence that was investigated as an engine defect before the
  build skew was found. `scripts/verify-build-provenance.py` now gates this;
  the override is `RE_SKIP_PROVENANCE=1`, deliberately not `--warn-only`.
- **`GET /api/engine/stats` is not uniform.** `SURFACE_SPEC.md` lists it as
  uniform but the runtimes return different payloads. Use `GET /api/config` for
  `vectorDimension`.
