# RealityEngine_Rust validation workflow

Owner decision, 2026-10-30: `RealityEngine_Rust` gets a Rust-specific
validation workflow that runs self-contained, and the full regression suite
runs on it on a much less frequent basis. This document is that workflow. The
exception to "peripheral CI stays minimal" that allows it is bounded in
[`ENGINEERING_CONTRACT.md`](ENGINEERING_CONTRACT.md), "The one exception".
Where Rust stands against the specifications is
[`RUST_RUNTIME_EVALUATION.md`](RUST_RUNTIME_EVALUATION.md); its role, a
non-voting conformance follower, is CI#607.

## The four tiers

| tier | what it is | where it runs | needs | proves |
|---|---|---|---|---|
| **R0** static | `cargo fmt --check`, `clippy -D warnings`, unit tests, release build, toolchain pin | hosted, `RealityEngine_Rust/.github/workflows/validate.yml` | the Rust checkout | it builds, lints and its unit tests pass |
| **R1** conformance | the regression corpus, vendored, replayed through the HTTP router against what the corpus declares; and every route `SURFACE_SPEC.md` defines, probed for its implementation status | hosted, same workflow | the Rust checkout | Rust conforms to the corpus snapshot it carries, and the implementation status of every specified route is known |
| **R2** follower | Rust beside a live 3-of-3 universe as a non-voting extra runtime: the RE-only parity stages, plus the corpus declarations held against the three engines | local, `scripts/validate.sh r2` → `RealityEngine_CI/scripts/rust-conformance.sh` | sibling checkouts, a universe | Rust agrees with the voters on what it implements |
| **R3** full suite | `scripts/regression-test.sh` with Rust registered as a follower | local, from `RealityEngine_CI` | the whole workspace | the release candidate, Rust included, end to end |

Every tier reports availability, contract conformance and parity separately,
as the e2e rules require. A tier that could not run reports **unavailable**
(exit 3 from `validate.sh`), never a pass.

## Cadence

| tier | when | rough cost |
|---|---|---|
| R0 + R1 | every push and pull request on `RealityEngine_Rust` | ~2 min hosted; R1 itself is under a second |
| R2 | each phase exit of the repair plan (Rust#2), any Rust change to engine-visible behaviour before it is relied on, and weekly while Rust is under active development | a universe boot plus the RE-only stages |
| R3 | each release candidate that carries Rust (release-v0.0.2 and later), and monthly otherwise | a full regression run |

R3 is deliberately **not** on the 09:17 daily regression cron, and nothing about
Rust is added to that run. The voters' daily certification is unchanged and
cannot be turned red by the follower.

These cadences are the starting point; changing them is an edit to this table.

## R1 in detail

`RealityEngine_Rust/tests/conformance.rs`, run by `scripts/validate.sh r1`.

- **The corpus snapshot.** `conformance/corpus/` holds the 23 machines
  `config/regression-corpus.txt` takes from `RealityEngine_Machines` (the three
  localAIStack entries are recorded as excluded, with the reason).
  `conformance/corpus.lock.json` pins the Machines commit, the manifest's commit
  and digest, and a sha256 per file. R1 refuses a file that is missing,
  unlocked or edited by hand. `scripts/refresh-corpus.sh` re-vendors from a
  clean Machines checkout; it is local maintenance, never a hosted step.
- **Black box.** Each machine is registered through `POST /api/machines` on a
  fresh engine and each declared input sequence is driven through
  `POST /api/engine/reset` and `POST /api/engine/process` as universal Reality
  Events at the machine's input offset, the path the evaluation measured.
- **The oracle is the corpus.** `expectedOutputCount` is read as the number of
  steps with a non-null arbitrated output, and `expectedOutputVector` as the
  vector of the last one. No specification defines those keys, so this reading
  is R1's, and R2 holds it against the engines (below). Sequences that declare
  neither are reported `not compared`: 30 of the 59 in the snapshot today, as
  the corpus uses several other metadata vocabularies.
- **Canonical keys, findings not crashes.** R1 reads `eventDimension`,
  `outputs[].vector`, `inputEvent` and the canonical event keys. Where Rust
  answers otherwise, R1 falls back so the downstream checks still measure, and
  records the key as its own failing check.
- **The ratchet.** `conformance/known-failures.json` lists each current failure
  with its issue. An unlisted failure fails R1; so does a listed failure that
  now passes, a listed id that no longer exists, or an entry with no issue. A
  fix therefore has to delete the entries it closed, and the list cannot
  outlive the defects.

At the first commit: 8 pass, 47 known failures (all 23 machines load with zero
events, Rust#3, which masks #4 and #5 behind it; `eventDimension` absent,
Rust#6), 30 not compared, 0 unexpected. That is the evaluation's "as shipped"
result reproduced without a live engine.

## R1: the API surface

`RealityEngine_Rust/tests/surface.rs`, also run by `scripts/validate.sh r1`.
Its goal: **every API the specification defines exists in a record, with its
implementation status known.** The readable answer is
`RealityEngine_Rust/conformance/SURFACE_STATUS.md`.

- **Driven by the spec, not a hand list.** `scripts/refresh-surface.sh` parses
  the route tables of this repo's `SURFACE_SPEC.md` into
  `conformance/surface/spec-routes.json`. That file holds the spec's commit,
  its sha256 and a digest of the parsed routes, which R1 recomputes. It takes
  the RE and PE `| Method | Path | CPP | LSP | Scala |` and `| Protocol | ... |`
  tables (79 RE and 47 PE routes, streaming included) and the 5 phase-2 K-line
  routes, which the spec writes outside those tables. The Manager section is
  Manager's surface and is left out.
- **Probed, black box.** Each route is sent through the router in process, with
  `{}` as its body and `probe` for each path parameter, and classified as one of:
  - `implemented`: the router serves it, without a 5xx, and any 4xx carries
    `{"error"}`;
  - `implemented-bad-envelope`;
  - `implemented-error`;
  - `declared-unsupported`: it answers with the participation state;
  - `missing`: the router's own empty 404/405, or no service (Rust has no PE).

  A unit test holds the classifier to each state against a synthetic router.
- **The record.** `conformance/surface-status.json` gives each route its status
  and, for anything not implemented, its tracking issue. R1 fails when:
  - an observed status differs from the record;
  - a spec route has no entry;
  - an entry names no spec route;
  - a non-implemented route names no issue;
  - the generated `SURFACE_STATUS.md` is out of date.

  So a newly added route, or a new route in the spec, cannot go unrecorded.
- **Existence, not behaviour.** A route recorded `implemented` may still be
  non-conforming. The record's notes name the known shape defects
  (`/api/config` #6, `json/list` #7, `engine/process` #5), and behaviour is the
  corpus replay and R2.

At the first record: RE 14 of 79 implemented, PE 0 of 47 (no PE),
phase 2 0 of 5. Every `missing` route answers silently, which "Participation
States" forbids; declaring them is Rust#15, which waits on the wire shape
(CI#607).

## R2 in detail

### Built: the live comparison (Rust#9, 2026-10-30)

`RealityEngine_Rust/scripts/differential.py` compares a candidate RE with a
reference RE, both running on the same corpus. For every corpus input
sequence it resets both engines and drives each event through
`POST /api/machines/:id/process` (`{"inputEvent": ...}`). It then compares each
step's `machineOutput.vector` (the arbiter's pick) and `mergedOutput` (what the
machine presents). A difference carries both emissions.
`RE_REFERENCE_URL=<re> scripts/validate.sh r2` starts the Rust build on the
same corpus and runs it. Check the reference's build provenance first.

First live result, on the full corpus (1327 machines, 5846 sequences), with
each engine built from current `main`:

| Rust vs | identical |
|---|---|
| C++ | 5846 / 5846 |
| LSP | 5844 (2 differ) |
| Scala, seed 16944 | 5841 (5 differ) |

Every difference is the arbiter's representative pick, never the presented
output, and the reference engines disagree among themselves on exactly those
sequences (#678). A Rust build with the retired numeric `gte` fails with 2289
different. Found along the way: RealityEngine_Scala#200, where the
single-machine route fails beyond the 7680 seed.

Not yet compared: `POST /api/engine/process` (the universal path), the PE (Rust
has none), and the parity stages below.

### Built: the follower lane (CI#607, 2026-10-31)

`scripts/rust-conformance.sh` is the runner. `validate.sh r2` calls it without
`RE_REFERENCE_URL`, after its own `refresh-corpus.sh --check` and
`refresh-surface.sh --check`, so a stale snapshot is named first.

- **Follower support in the harness** (`scripts/lib/followers.py`). An instance
  with `"role": "follower"` never votes (QUORUM_CONTRACT.md section 1). The four
  RE-only stages drop it when they read instance data, and both
  `quorum_composition()`s leave it out. `scripts/tests/test-followers.sh`
  covers this, including that a 2-1 split among the voters stays a
  disagreement whichever side the follower takes.
- **The runner.** It builds Rust and checks its provenance:
  `verify-build-provenance.py --repos rust`. `rust` is an opt-in target there,
  so the certifying run never checks it. The runner then starts `rust-1` on
  5801 beside the universe, on the corpus the universe booted and at the width
  the voters report. Its UUID is allocated as `native/rust-1`. It writes its own
  instance data, the universe's plus `rust-1` as a follower, and never touches
  the universe's instance registry.
- **One verdict per stage.** The runner covers `machine-set`, `engine-process`,
  `export`, `engine-config --no-step` and `arbitration-retention`, and runs each
  stage twice: the voters
  alone, then the voters with Rust as one more instance. The stage's own
  comparison decides both runs.
  - `agrees`: the voters agree and the joint run passes.
  - `differs`: the voters agree and the joint run fails. The joint report names
    the difference.
  - `unsupported`: Rust answers one of the stage's essential routes with the
    ruled `501`.
  - `not-compared`: the voters disagree, so there is nothing to follow.
- **Exit status.** 0 when at least one stage agrees and none differs. 1 when a
  stage differs, the build is stale, or Rust will not start. 3 when the lane is
  unavailable or nothing was compared.
- **Every stage resets every voter**, as it does in the regression run. Run it
  beside a development universe, not one whose state you want to keep.

First live result (2026-10-31). The voters were cpp-1, lsp-1 and scala-1 built
from current main, on the full corpus (1327 machines) at width 16944. They
agreed on every stage, so each row is Rust alone:

| stage | rust-1 | why |
|---|---|---|
| machine-set | agrees | |
| engine-process | differs | all 167 outputs are numerically identical, but Rust encodes integral values as `1.0` where all three emit `1` (Rust#33) |
| export | unsupported | `GET /api/machines/:id/export` answers the ruled 501 |
| engine-config | differs | seven of the eight universal controls are absent (Rust#11, #12) |

A follower has no PE, so its registry entry declares `pe_participation:
"unsupported"`, and `reset_contract` resets only its RE half. An undeclared
missing PE is still a failed reset.

`arbitration-retention` joined the lane on 2026-11-01, when Rust gained
`GET /api/arbitration` (Rust#12). The stage resets each instance itself, so it
reads the same declaration, and `config/arbitration-legacy-baseline.json` carries
a `rust` legacy body. That body was recorded from Rust and is byte-identical to
C++'s. Against standalone C++ on the regression corpus, with Rust as a follower
in the joint registry, the stage passes 2 of 2 with the retained bodies
byte-identical. The lane has not yet run it against a live universe.

**Stages a follower cannot join yet.** `regression-trajectory-parity.py`,
`regression-corpus-parity-loop.py` and `regression-arbiter.py` drive their steps
through each instance's PE (`/api/push`, PE sources). A follower with no PE has
nothing to drive, so these wait for the Rust PE (Rust#17, #20). Rust#11's and
#12's acceptance criteria name them.

Still to build:

3. **The declaration cross-check.** For every sequence R1 compares, replay it
   on the three voters and compare their 3-of-3 agreement with the corpus
   declaration. Agreement confirms R1's oracle for that sequence. **A
   disagreement between the corpus declaration and the three engines is
   reported to the owner to arbitrate**: the run names the machine, sequence,
   declaration and every engine's emission, and neither side is changed to make
   the other pass. Until the owner rules, R1 keeps the sequence as a known
   failure or not-compared, naming the pending ruling.

## R3 in detail — to be built

`regression-test.sh` gains an opt-in follower runtime (for example
`--follower rust`) that builds `RealityEngine_Rust` with the others, starts it
beside the voters and runs each stage with Rust as a follower. The report keeps
Rust in its own section and never folds it into the certifying verdict. R3 is
what a release candidate that ships `re-rust` must pass.

## Noticed, not chased

- The evaluation of 2026-10-24 counted 78 RE and 45 PE route rows. The spec at
  `fc60831` has 79 and 47, counting the streaming rows (SSE `/api/engine/stream`,
  SSE `/api/events`, WebSocket `/ws`) that sit in `Protocol` tables. Which
  counting the evaluation used was not re-derived.
- The surface probe cannot see routes Rust serves that the spec does not define
  (axum does not list its routes). Today all 14 of Rust's routes are in the spec.

- 30 of the 59 regression-corpus input sequences declare no
  `expectedOutputCount`/`expectedOutputVector`. They carry other vocabularies
  (`expectedOutputs`, `expectedTerminalOutput`, `expectedOutputSequence`,
  `redExpected`, ...). Giving the corpus one declared-expectation vocabulary
  would let R1 compare all of them; that is a corpus decision for
  RealityEngine_Machines, not something R1 should guess at.
- The hosted R0/R1 lane has not run yet; it first runs on the PR that adds it.
