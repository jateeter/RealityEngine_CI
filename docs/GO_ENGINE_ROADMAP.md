# RealityEngine_GO: implementation plan and roadmap

Last reviewed: 2026-11-22

The plan for a Go Reality Engine (RE) and Perception Engine (PE),
`jateeter/RealityEngine_GO`, on the `release-v0.0.3` milestone. It merges the
Go repository's own roadmap (its issues #1–#14, milestone `release-v0.0.3`)
with the suite-side work only this repository can do. The Go issues stay the
tracking record for the engine work; this file orders them, adds the CI half,
and records the owner decisions they depend on.

Related: [`QUORUM_CONTRACT.md`](QUORUM_CONTRACT.md) (follower and promotion
rules), [`BUILD_CONTROL_CONTRACT.md`](BUILD_CONTROL_CONTRACT.md),
[`ENGINEERING_CONTRACT.md`](ENGINEERING_CONTRACT.md),
[`RUST_VALIDATION_WORKFLOW.md`](RUST_VALIDATION_WORKFLOW.md) and
[`RUST_RUNTIME_EVALUATION.md`](RUST_RUNTIME_EVALUATION.md) (the precedent),
[`../SURFACE_SPEC.md`](../SURFACE_SPEC.md) (the surface), and
[`ReleaseRoadmap.md`](ReleaseRoadmap.md) (the release tracker).

## The target

> **A Go RE and PE that are first-class dFSA engines: canonical machine
> loading and transitions, the per-machine output fold, the full ISRE/OSRE step
> (merge batch, arbitration, retention, instance clock, histories), clones, and
> the whole PE (sources, sensors, push, streams, integrations, dispatch, MQTT),
> on the suite's TLS profile.**

"First class" means the complete RE and PE surface the voters implement, held
to what C++, LSP and Scala agree on. It does not mean a vote on day one.

## Owner decisions (2026-11-22)

| # | Decision | Consequence |
|---|---|---|
| D1 | **Go ships in `release-v0.0.3` as a non-voting conformance follower, with the full surface. Promotion to a voter is the last milestone, after the release.** | Go joins Rust and Manager's TypeScript PE as a follower (QUORUM_CONTRACT §1). Its verdict is shown under each voters' parity result in `summary.md` and never counts. The v0.0.3 certification stays the voters' 3-of-3. |
| D2 | **Standard minimal CI only. No second exception to "peripheral CI stays minimal".** | The Go repository's hosted workflow runs `gofmt -l`, `go vet`, `go test -race` and `go build`, and nothing else. Corpus replay and the surface probe (Go#9) are tools run locally and from this repository's lanes, never a hosted job. `ENGINEERING_CONTRACT.md` keeps Rust as its one exception. |

Go#9's open item "agree hosted CI scope with the owner" is settled by D2.

## Where it starts

`RealityEngine_GO@ac66780` (2026-11-22): Go 1.27.3 pinned in `.go-version`
and `go.mod`, no third-party dependencies, two commands
(`cmd/reality-engine`, `cmd/perception-engine`) that serve only
`GET /api/health` over plaintext on loopback, and an `AGENTS.md` carrying the
contract map. Go#4 (bootstrap) is closed; #1–#3 and #5–#14 are open.

Two gaps in the starting point:

- **No Go toolchain on the development Mac** (`go` not on `PATH`). C1 adds the
  host prerequisite and its check.
- **No `CLAUDE.md`.** The repository has `AGENTS.md`. Every workspace
  repository carries a `CLAUDE.md` that points at `ENGINEERING_CONTRACT.md` and
  `BUILD_CONTROL_CONTRACT.md` instead of restating them. This is added in the
  Go repository under Go#1.

## Precedent and sizing

Rust went from its first commit (2026-10-24) to RE 82/83 and PE 45/47 routes
implemented (its `conformance/SURFACE_STATUS.md`) in about four weeks, at about
18,800 lines. The evaluation's estimate for the same path had been 7–11 weeks
plus "several" for the PE. Go starts from a better position: the surface spec,
the participation-state wire shape (501 `unsupported`), the follower harness
(`scripts/lib/followers.py`) and the Rust implementation all exist now.

The sizes below are estimates for agent-assisted work at Rust's pace and are
not commitments. The release gate is evidence, not a date.

## Phases

The engine work is the Go repository's issues. Each phase lists them in
dependency order, the CI-side items it needs (C1–C4, below), and its exit
evidence. A phase exits on evidence recorded in the issue, never on a merge.

### G0: foundations (about 1 week)

| Item | Scope |
|---|---|
| Go#4 | Bootstrap. **Done** (Go PR #15). |
| Go#7 | Surface inventory derived from `SURFACE_SPEC.md` (RE, PE, streaming, phase-2 K-line routes; Manager excluded), pinned to a spec revision, refreshed by a command. Every specified but unimplemented route answers 501 with `participation: "unsupported"`; unknown routes stay 404. |
| Go#9 | Local conformance tooling: corpus snapshot pinned to the regression manifest and the Machines commit by digest, black-box replay through HTTP, known-failure ratchet with an issue per entry, surface probe. Local only, per D2. |
| C1 | Suite registration: build control, provenance, toolchain prerequisite. |

**Exit:** `go test -race ./...` green; the surface record lists every
specified route (none `missing`); corpus replay runs and reports pass,
known-failure and not-compared separately; `regression-test.sh --execute
--build-only` builds the Go pair and `verify-build-provenance.py --repos go`
checks it.

### G1: the dFSA core (about 1.5–2 weeks)

| Item | Scope |
|---|---|
| Go#10 | Recursive `MACHINES_DIR` loading with path-aware addressing (`relFile`, basename fallback), canonical keys (`events`, `outputEvents`, `nextEventIds`, `inputEvent`, `eventDimension`), dimension growth during load, comparators with per-element overrides, deferred successor activation, output events and provenance, single-machine `process` / `whatif` routes reporting both `machineOutput` and `mergedOutput`, import and export. |

**Perception folding is part of G1, not later.** The fold by the machine's
declared `outputMergeTransformation` is what a machine presents and what is
written to the perceptual space (SURFACE_SPEC, "A machine transition reports
both the fold and the arbiter's pick"). A refusing fold, such as the Łukasiewicz
pair without a chain top, reports `mergedOutput: null` and keeps
`machineOutput`. Go implements the fold as the voters do today.
`FOLD_PLACEMENT.md`, which moves the fold into the atomic step, is still a plan.
When it lands, the voters change first and Go follows in the same release.

**Exit:** the regression corpus replays with no unexpected failure. A live
differential over the regression corpus against all three voters (not only
cpp-1, the Rust evaluation's gap) gives identical output on every sequence the
voters agree on.

### G2: the step, ISRE/OSRE and the rest of the RE (about 3–5 weeks)

| Item | Scope |
|---|---|
| Go#13 | `POST /api/engine/process` mapped across machines in parallel (goroutines joined before OSRE(n) resolves), merge batch, per-cell arbitration under `ARBITER_CONTRACT.md`, `transitionsInhibited`, step completion and `phaseDetail`, ISRE/OSRE histories, `GET /api/engine/history`, arbitration retention and `GET /api/arbitration?step=N`, the instance clock `{instance, lamport, step}`, `INSTANCE_UUID` with an exclusive instance lock, `X-RE-Instance`. OSRE takes machine contributions only; providers act on ISRE composition. The representative-pick question stays with CI#678, never Rust's choice. |
| Go#5 | Cloneable templates recognised at load, the clone space, clone and generation-checked recycle, `GET /api/engine/clones`. Run `localAssetStorageStack`'s IFRS chain against Go as a follower (#715). |
| Go#2 | The rest of the RE tables: `/api/engine/config` and the eight universal controls, `/api/runtime/*`, metrics with CES coverage, Reality Event and sequence routes, machine graph, perceptual simulation (active events and regions, lane notation), sampler, perception, governance, demos, engine SSE. Full-corpus load measured and published. |

**Phase-2 K-line snapshot routes** (`/api/runtime/snapshot*`, `restore`) stay
declared `unsupported`. No voter implements them today, which is unanimous
silence (QUORUM_CONTRACT §3), and their scope is CI#603. Go follows when the
voters do.

**Exit:** every RE-only harness stage runs with `go-1` as a follower and
reports `agrees` or a filed `differs`; the RE surface record has no
`unsupported` route outside phase 2; `go test -race` covers concurrent
processing.

### G3: the Perception Engine (about 3–4 weeks; can start beside G2)

| Item | Scope |
|---|---|
| Go#8 | PE health, state and config; sources and sensors with TTL; `bootstrap-from-machines` (skip-if-present, honours `machineIds`); machine ingestion; signals; the RE machines proxy; layer-local reset (the PE never resets the RE). |
| Go#11 | Push cycle (synchronous, asynchronous jobs, auto push), partial-step requests, `lastPush` as the last step, SSE and WebSocket streams that do not leak goroutines. |
| Go#3 | Integrations (localAI invoke contract, the OpenAI route on the local LLM, HealthKit and CareKit ingest under `localHealthkitBridge/docs/INGEST_CONTRACT.md`), dispatch, the dispatch ledger and replay, triggers, the MQTT bridge with its mapping. Integration scope is decision O3. |

**Exit:** the follower lane's PE stages run against Go;
`RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts`
passes against the Go PE.

### G4: transport security (in parallel from G1; must be done before G5)

| Item | Scope |
|---|---|
| Go#6 | `RE_TLS_*` inputs, TLS 1.3 only, mTLS with verified peers, `urn:uuid:<instance_uuid>` in the instance certificate, CRL, fail-closed startup, no plaintext listener on a TLS lane, outbound HTTPS/WSS to the RE, localAI, MQTT and the gateway. |

Go's `crypto/tls` cannot restrict TLS 1.3 cipher suites (`Config.CipherSuites`
governs TLS 1.0–1.2 only). The suite already has an owner-approved pattern for
Go services (2026-11-12, `TRANSPORT_SECURITY.md`): the service listens only on
loopback inside its network namespace, and an OpenSSL (nginx) front serves the
profile with mTLS. The Go engines take that pattern unless Go gains TLS 1.3
suite configuration first. Go does support `X25519MLKEM768` natively. Each new
link is added to `config/transport-inventory.json` and the transport BOM in the
same change.

**Exit:** the transport probe stage measures every Go link compliant; the
release gate `check-transport-inventory.py --require-compliant` passes with them
included.

### G5: follower admission and release (about 1–2 weeks, after G2–G4)

| Item | Scope |
|---|---|
| Go#12 + C2 | Go in the follower lane beside Rust: `go-1` registered with `role: follower`, kept out of `quorum_composition()`, its verdict under each voters' parity result. |
| Go#14 + C3 | Image `re-go`, the docker lane, the release bundle, clean install, rollback, release notes listing the supported surface and anything still `unsupported`. |

**Exit (v0.0.3 inclusion):** a release candidate whose regression run includes
`go-1` as a follower on the local and hosted lanes, the release candidate
certified on the voters' 3-of-3, Go's verdicts recorded per stage, and the E1–E3
install checks passing with `re-go` in the bundle. A Go `differs` is a
recorded finding, not a release blocker, as for Rust (D1).

### G6: promotion to voter (after `release-v0.0.3`)

Not on the v0.0.3 milestone. The rule is QUORUM_CONTRACT §1: the whole RE and
PE surface implemented, then three consecutive certifying runs, then one
deliberate change that makes the quorum N-of-N and sweeps every file that names
the voting set (about 32 files by the Rust evaluation's count: `startUniverse.sh`,
`stopUniverse.sh`, `regression-test.sh`, the parity stages, `allocate-ports.sh`,
`docker-compose.yml`, the release bundle, the e2e quorum spec, the MCP server,
the OpenAPI generators and the docs). Rust is held to the same rule. Promoting
one follower or both, and in what order, is the owner's decision when the
evidence exists. C4 tracks the inventory.

## Suite-side work in this repository

| ID | Item | Phase | Tracking |
|---|---|---|---|
| C1 | **Register RealityEngine_GO in the build and the workspace.** `BUILD_CONTROL_CONTRACT.md` row (`go build -trimpath` for both commands); `regression-test.sh` clone, pin, cold-start worktree and `build_repos()`; `verify-build-provenance.py` entry for both binaries; Go toolchain prerequisite and check (one Go version in `.go-version`, `go.mod`, images and this Mac, as JDK 25 is held); workspace map and this repository's `CLAUDE.md` list Go as a follower in development. | G0 | CI#836 |
| C2 | **Generalise the follower lane to more than one follower.** `scripts/rust-conformance.sh` → a lane that takes each follower by name; `regression-test.sh --follower rust,go`; one indented verdict line per follower in `summary.md`; `test-followers.sh` covers two followers, an absent one and a deliberate difference; `go-1` ports. | G2–G5 | CI#837 |
| C3 | **Package `re-go`.** `docker/go/Dockerfile` (static binaries, distroless or alpine, the OpenSSL front), compose services `engine-go-re` / `engine-go-pe`, `release/images.json`, `release/init/reinit.py`, `release/realityengine`, `release-images.yml`, `release-manifest.py`, transport inventory and BOM, `install.sh` and `uninstall.sh`, docs. | G4–G5 | CI#838 |
| C4 | **Promotion inventory.** The list of every file naming the voting set, and the N-of-N change that sweeps them, ready for when a follower qualifies. Not on the v0.0.3 milestone. | G6 | CI#839 (no milestone) |

## Ports (proposal, decision O1)

| Lane | PE | RE | Why |
|---|---|---|---|
| native follower lane (`go-1`) | 5850 | 5851 | Off the `allocate-ports.sh` grid: instance *n* of a voter takes base + 100·(n−1), so every *x*00 slot in 5000–5900 belongs to some voter's instance (lsp-2 is 5700/5701). Rust's 5800/5801 sits on that grid and collides with lsp-3; noted, not changed here. |
| docker lane and release install | 6700 | 6701 | Follows the docker pattern (6100, 6300, 6600, 6900); free today. |

Under `RE_FREE_PORTS=true` the ports are OS-assigned, as for every engine, and
the instance registry records them.

## Open decisions for the owner

| # | Question | Proposal |
|---|---|---|
| O1 | Ports | The table above. |
| O2 | Required surface for v0.0.3 | Every RE and PE route the voters implement. Phase-2 K-line routes are declared `unsupported` until the voters implement them (CI#603). |
| O3 | Integration scope, given the OpenClaw sunset planned for v0.0.3 (`AGENT_GOVERNANCE_REVIEW.md`) | Implement the ACP source and completion mapping against the runtime-neutral ACP contract the voters carry at the time, not the OpenClaw gateway specifically. Go does not build a surface the release is retiring. |
| O4 | Whether a Go `differs` on a stage can block v0.0.3 | No, as for Rust (D1). Recorded per stage and filed. |

## Dependencies on other open work

- **CI#678**, the arbiter's representative pick: Go follows the ruling, not
  Rust.
- **CI#610**, the `/api/health` shape: Go answers as the spec says
  (`{status, timestamp, version}`), as Rust does, until the ruling.
- **CI#600**, the full Lamport receive rule, and **CI#603**, K-lines: Go
  implements what the voters carry at G2 and follows later changes.
- **`FOLD_PLACEMENT.md`**: if applied in v0.0.3, it changes G1's fold site in
  the voters first.
- **QUORUM_CONTRACT §2**: the participation-state wire shape is specified, and
  Go emits it from G0 (Go#7). The voters do not emit it yet.

## How to track this file

Phase status lives in the Go issues and C1–C4. Change this file when a
decision is taken, a phase exits (name the evidence), or the scope moves. Go#1
links here.
