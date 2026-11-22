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
| D1 | **Go ships in `release-v0.0.3` as a non-voting conformance follower, with the full surface. Promotion to a voter is the last milestone, after the release.** | Go joins Rust and Manager's TypeScript PE as a follower (QUORUM_CONTRACT §1). Quorum stays the voters' 3-of-3, which Go can neither form nor break. D6 makes Go's agreement a release requirement. |
| D2 | **Standard minimal CI only. No second exception to "peripheral CI stays minimal".** | The Go repository's hosted workflow runs `gofmt -l`, `go vet`, `go test -race` and `go build`, and nothing else. Corpus replay and the surface probe (Go#9) are tools run locally and from this repository's lanes, never a hosted job. `ENGINEERING_CONTRACT.md` keeps Rust as its one exception. |
| D3 | **Ports come from `--free-ports`** so instances never collide. **Where fixed ports are required, 5850 (PE) and 5851 (RE) are reserved for Go.** | See [Ports](#ports). |
| D4 | **K-lines are implemented with full parity and follower compliance:** the K-line store and its routes (CI#603) and the snapshot and restore routes (CI#287), 3-of-3 among the voters, with Go and Rust agreeing. | K-lines move into G2 and are part of the v0.0.3 surface, not declared `unsupported`. |
| D5 | **The agent gateway is the A2A (Agent2Agent) standard,** with compatible services integrated through it (CI#841). | Go#3 builds an A2A client, not an OpenClaw ACP adapter. |
| D6 | **Followers must agree with the voters, and a follower that does not blocks the release, for Go and Rust** (CI#842). | This reverses the 2026-11-18 "shown, not counted" rule. A Go or Rust `differs`, `unsupported` or unavailable lane on a certifying run blocks v0.0.3. |

Go#9's open item "agree hosted CI scope with the owner" is settled by D2.
Go#1's open decisions are settled by D1 and D3–D6.

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

| K-lines (D4) | The K-line store under CI#603: boundaries from the transition rule (opens; closes `completed`, `abandoned`, `subsumed`, `interrupted`), feedback scope to `klineFeedbackHops`, the `re-source-kinds/1` taxonomy, the open table and start-state ring per committed step, the append-only per-instance store under `$RE_INSTANCE_STATE_DIR/klines/<instance_uuid>/` covered by the instance lock, `GET /api/klines`, `/open`, `/:id`, `/stats`, `POST /api/klines/export` (`re-kline-bundle/1`). The snapshot and restore routes under CI#287 (`/api/runtime/snapshot*`, `/api/runtime/restore`) to the SURFACE_SPEC phase-2 acceptance, cross-runtime restore included. Tracked in Go#13 (store, boundaries) and Go#2 (routes). |

**K-lines need the voters first.** No runtime implements them today. D4 puts
them in v0.0.3 on C++, LSP and Scala (CI#603, CI#287), and Go and Rust
(Rust#81) must agree with what the voters land. Go can build against the spec
early, but its K-line stages can only be judged once the voters agree. Until
then they report `not-compared`.

**Exit:** every RE harness stage runs with `go-1` as a follower and reports
`agrees` (D6). Nothing in the RE surface record is `unsupported`. The K-line
boundaries stage agrees on the parity key
`(focal, sequence, open.step, close.step, outcome, path)`. `go test -race`
covers concurrent processing.

### G3: the Perception Engine (about 3–4 weeks; can start beside G2)

| Item | Scope |
|---|---|
| Go#8 | PE health, state and config; sources and sensors with TTL; `bootstrap-from-machines` (skip-if-present, honours `machineIds`); machine ingestion; signals; the RE machines proxy; layer-local reset (the PE never resets the RE). |
| Go#11 | Push cycle (synchronous, asynchronous jobs, auto push), partial-step requests, `lastPush` as the last step, SSE and WebSocket streams that do not leak goroutines. |
| Go#3 | Integrations (localAI invoke contract, the OpenAI route on the local LLM, HealthKit and CareKit ingest under `localHealthkitBridge/docs/INGEST_CONTRACT.md`), dispatch, the dispatch ledger and replay, triggers, the MQTT bridge with its mapping. Agent dispatch goes through an **A2A client** under the gateway contract CI#841 (D5), not the OpenClaw ACP adapter. |

**Exit:** the follower lane's PE stages agree for Go, the A2A dispatch stage
included;
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
`go-1` and `rust-1` as followers on the local and hosted lanes. The candidate is
certified on the voters' 3-of-3, **and both followers record `agrees` on every
parity stage** (D6, CI#842). The E1–E3 install checks pass with `re-go` in the
bundle. A follower that differs, is unsupported or whose lane is unavailable
blocks the release.

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
| C2 | **Generalise the follower lane to more than one follower.** `scripts/rust-conformance.sh` → a lane that takes each follower by name; `regression-test.sh --follower rust,go`; one indented verdict line per follower in `summary.md`; `test-followers.sh` covers two followers, an absent one and a deliberate difference; `go` in `allocate-ports.sh` (free claim by default, fixed base 5850, D3). The release-blocking gate itself is CI#842. | G2–G5 | CI#837 |
| C3 | **Package `re-go`.** `docker/go/Dockerfile` (static binaries, distroless or alpine, the OpenSSL front), compose services `engine-go-re` / `engine-go-pe`, `release/images.json`, `release/init/reinit.py`, `release/realityengine`, `release-images.yml`, `release-manifest.py`, transport inventory and BOM, `install.sh` and `uninstall.sh`, docs. | G4–G5 | CI#838 |
| C4 | **Promotion inventory.** The list of every file naming the voting set, and the N-of-N change that sweeps them, ready for when a follower qualifies. Not on the v0.0.3 milestone. | G6 | CI#839 (no milestone) |

## Ports

**Go's ports are allocated with `--free-ports` (`RE_FREE_PORTS=true`)** so no
two instances can collide (D3). The OS assigns them, and the instance registry
records them. Every lane that can claim free ports does: the native universe,
the follower lane and regression.

**Where a fixed port is unavoidable, Go has 5850 (PE) and 5851 (RE)
reserved.** That applies to a docker or release port mapping that must be
stated in advance, or an operator pin. These sit off the `allocate-ports.sh`
grid: instance *n* of a voter takes base + 100·(n−1), so every *x*00 slot from
5000 to 5900 belongs to some voter's instance (lsp-2 is 5700/5701). The
reservation is recorded in `DEPLOYMENT_CONTRACT.md`'s port table in C1.

*Noted, not changed here:* Rust's fixed 5800/5801 sits on that grid and
collides with lsp-3.

## The other follower

Manager's TypeScript PE is bound to Manager (owner, 2026-11-22). It follows
Manager's lead first and tracks the follower release gate second. The owner
decides its deviations case by case, and they don't block a release
automatically. This doesn't change anything in Go's plan: D6 applies to Go and
Rust as written.

## Dependencies on other open work

- **CI#678**, the arbiter's representative pick: Go follows the ruling, not
  Rust.
- **CI#610**, the `/api/health` shape: Go answers as the spec says
  (`{status, timestamp, version}`), as Rust does, until the ruling.
- **CI#603 and CI#287**, K-lines and snapshots: the voters' implementation in
  v0.0.3 is the oracle for Go's K-line stages (D4).
- **CI#600**, the full Lamport receive rule: Go implements what the voters carry
  at G2 and follows later changes.
- **CI#841**, the A2A gateway contract: Go#3's dispatch waits on it.
- **CI#842**, the follower release gate: G5's exit depends on it.
- **`FOLD_PLACEMENT.md`**: if applied in v0.0.3, it changes G1's fold site in
  the voters first.
- **QUORUM_CONTRACT §2**: the participation-state wire shape is specified, and
  Go emits it from G0 (Go#7). The voters do not emit it yet.

## How to track this file

Phase status lives in the Go issues and C1–C4. Change this file when a
decision is taken, a phase exits (name the evidence), or the scope moves. Go#1
links here.
