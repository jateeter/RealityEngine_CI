# `MACHINES_DIR` — touch points and flow-through

Swept 2026-09-10 · 255 references across the focus set (excluding
`RealityEngine_AI`, `node_modules`, `.regression-tests`, build output)

## The finding

**One variable name carries three different meanings, on two independent axes.**
Every consumer is internally consistent; no two agree with each other.

### Axis 1 — what the path points at

| Meaning | Value shape | Who reads it this way |
|---|---|---|
| **A · repo root** | `…/RealityEngine_Machines` | `startUniverse.sh:54`, `run-all-tests.sh:27`, `deploy-validate-agent.sh:80`, `owl-reasoner-check.sh:24`, `verify-audit-chain.sh:38`, `verify-semantic-parity.sh:30`, `test-corpus-parity-loop.sh:52`, `test-observability-readiness.sh:15`, `localAIStack/scripts/validate-machines.sh:24`, both `e2e-tests.yml` jobs |
| **B · the `machines/` directory** | `…/RealityEngine_Machines/machines` | `CPP/start.sh:37`, `LSP/start.sh:27`, `Scala/start.sh:26`, `CPP/tests/e2e_services.sh:15`, `CPP/tests/e2e_healthkit_spezi.sh:11`, `Scala Main.scala:79`, `Scala Routes.scala:38`, `Scala SemanticMetrics.scala:32`, `CPP perception_engine_server.cpp:2903`, compose `MACHINES_DIR=/app/machines` |
| **C · localAIStack's own machines** | `localAIStack/services/…/data/machines` | `localAIStack/services/api/core/reality_bridge.py:162` |

### Axis 2 — whole repo, or the corpus this deployment selected

Orthogonal to the above, and the one that has actually broken things.
`startUniverse.sh:268` repoints `MACHINES_DIR` at the materialised corpus when
`--machine-corpus` selects one; every consumer that re-derives it from the repo
instead silently gets all 1,328 machines.

## The conversions, where A becomes B

`startUniverse.sh` holds meaning **A** and appends `/machines` at each hand-off
to a native engine — lines **1118**, **1154**, **1190**:

```bash
MACHINES_DIR="$MACHINES_DIR/machines" \
```

That conversion is the only thing keeping A and B consumers compatible, and it
is repeated three times rather than expressed once.

## Damage already attributed to this

| Symptom | Actually | Fixed in |
|---|---|---|
| Docker RE served 1,328 machines under `--machine-corpus=regression` | agent re-exported **A-as-repo**, overriding the selected corpus on every `compose up --force-recreate` | RealityEngine_CI#328 |
| Scala native lane "failed to come back after restart" | native lane inherited the full repo while the Docker lane deployed 12 | RealityEngine_CI#326 |
| 12 localAIStack CareKit tests failed under the agent, passed standalone | **A** exported over **C** — tests hunted `medication_adherence.json` in the corpus repo | RealityEngine_CI#326 |
| Scala HealthKit e2e "Reality Engine did not become ready" | inherited **A-as-repo** → 1,328 machines → 30s boot against a 10s budget | RealityEngine_Scala#112 |

Four distinct symptoms — a corpus count, a restart failure, twelve unit-test
failures, and a timeout — from one ambiguity. **None of them looked like a
naming problem.**

## Two workarounds already in the tree

Both predate this sweep, and each is a local patch on the general defect:

- `startUniverse.sh:2326` — `env -u MACHINES_DIR` before starting OpenClaw, with
  a comment that says the collision outright: *"CI's MACHINES_DIR is the
  RealityEngine_Machines repo root, but OpenClaw's machine-behaviors tooling
  interprets the same variable as the machines/ directory itself."*
- `run-all-tests.sh` — `env -u MACHINES_DIR` before the localAIStack pytest, for
  the **A over C** collision.

Two `env -u` workarounds for one variable is the shape of a name that should
have been split.

## What is already disambiguated

`MACHINE_CORPUS_DIR` (RealityEngine_CI#328) answers *"which corpus did this
deployment select"* for the compose mount, leaving `MACHINES_DIR` to mean the
repository. That split works and is the model for the rest.

## Remaining exposure

**Corrected 2026-09-10 after auditing each.** The first sweep listed four CI
scripts as "would ignore a selected corpus". Three of them *should*: they
resolve **repository** artifacts, and a materialised corpus contains only
`machines/` and a manifest — no `scripts/`, no `semantics/` — so pointing them
at one breaks them outright.

| Script | Resolves | Correct scope |
|---|---|---|
| `owl-reasoner-check.sh` | `$MACHINES_DIR/scripts/reason-owl.sh` | **repo** |
| `verify-audit-chain.sh` | `$machines_dir/semantics/abox-manifest.json` | **repo** |
| `verify-semantic-parity.sh` | `$machines_dir/semantics/abox-manifest.json` | **repo** |
| `test-corpus-parity-loop.sh` | walks `$MACHINES_DIR/machines` | **corpus** |

Only the last was genuinely exposed, and it was #328's shape again: walking
1,328 machines to compare engines started with 20. It now resolves
`MACHINE_CORPUS_DIR` → the stamped `MACHINE_CORPUS_ACTIVE_DIR` → full repo, so
the default is unchanged when nothing was selected.

The three repo-scoped scripts now declare that in a header and read
`MACHINES_REPO`, still accepting `MACHINES_DIR`, which makes the intent legible
rather than accidental.

The general lesson holds and is sharper for the correction: **"uses
MACHINES_DIR" is not the same question as "wants the corpus"**, and a grep
cannot tell them apart. Each consumer has to be read.
- `SemanticMetrics.scala:32` and `Routes.scala:38` both default to **B**
  independently of `Main.scala:79`. Three defaults for one runtime, still
  outstanding.

## Proposed shape

1. **`MACHINES_REPO`** — the repository. Never a corpus.
2. **`MACHINE_CORPUS_DIR`** — the corpus this deployment selected. Already
   exists; extend it past the compose mount.
3. **Retire `MACHINES_DIR`** from new code; keep it as a deprecated alias that
   resolves to one of the two, so the conversions stop being ad hoc.
4. **Do the `/machines` suffix once**, at the boundary, rather than three times
   in `startUniverse.sh`.
5. **localAIStack should not read `MACHINES_DIR` at all** — it means its own
   `data/machines`, which is meaning **C** and unrelated to the corpus repo.
   `LOCALAI_MACHINES_DIR` costs nothing and removes the collision that the
   `env -u` in `run-all-tests.sh` currently papers over.

Point 5 is the cheapest and retires a live workaround.

## Method

```bash
grep -rn "MACHINES_DIR" <focus repos> \
  | grep -v node_modules | grep -v .regression-tests | grep -v /target/ | grep -v .venv
```

Readers were separated from setters by matching `:-`, `getenv`, `getOrElse` and
`env(` forms. `RealityEngine_AI` is excluded as an isolated enclosure.
