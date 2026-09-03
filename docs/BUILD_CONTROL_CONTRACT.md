# Build Control Contract v1.0

Status: **implemented and gated.** `scripts/regression-test.sh` owns the build
phase, `startUniverse.sh` validates prerequisites and refuses to launch stale
artifacts, and `scripts/verify-build-provenance.py` is the gate.
Applies to: RealityEngine_CPP, RealityEngine_LSP, RealityEngine_Scala,
RealityEngine_Machines, RealityEngine_Manager.

**Read this before building or deploying any engine.** If you are about to run
`make`, `sbt`, or `npm` inside an engine repository because you want a running
universe, this document is the reason that is probably not what you want.

## 1. The two facts

**Every engine is its own repository.** `RealityEngine_CPP`,
`RealityEngine_LSP` and `RealityEngine_Scala` are independent git repositories
with independent histories, branches, remotes and release cadences. None is a
submodule, subdirectory or subproject of another, and none is a subproject of
`RealityEngine_CI`. They sit as siblings under one workspace directory purely so
relative paths resolve.

**All builds are controlled through `RealityEngine_CI`.** The engine repositories
know how to compile themselves, and each carries a `Makefile` or `build.sbt` and
a `start.sh` that will rebuild a missing or stale artifact. That is a
convenience, not the control point. What gets built, in what order, at which
commit, with which prerequisites checked, and whether the result may be used, is
decided in `RealityEngine_CI`.

These two facts pull in opposite directions, and the failures come from resolving
them the wrong way: treating independent repositories as if a build in one
implied a build in the others, or treating `RealityEngine_CI` as if it were a
parent project whose build reaches into children it does not own.

## 2. Who builds what

`scripts/regression-test.sh` → `build_repos()` is the canonical build sequence.
It is the answer to "how is this repository built", per repository:

| Repository | Build command, run from `RealityEngine_CI` |
|---|---|
| RealityEngine_CPP | `make all` |
| RealityEngine_LSP | `bash scripts/bootstrap-quicklisp.sh --home`, then `make build` |
| RealityEngine_Scala — RE | `sbt clean assembly` in the repository root |
| RealityEngine_Scala — PE | `sbt clean assembly` in `perception-engine/` |
| RealityEngine_Machines | `bash scripts/validate-corpus.sh`, `npm ci`, `npm run typecheck` |
| RealityEngine_Manager | per package dir: `npm ci`, `npm run build`, `npm run typecheck` |
| RealityEngine_CI | `npm ci`, `mcp` install + test + `routes:check`, `npm run typecheck` |

Run the whole thing with:

```bash
cd RealityEngine_CI
./scripts/regression-test.sh --build-only     # build everything, start nothing
./scripts/regression-test.sh --skip-build     # use what is already built
```

### 2.1 RealityEngine_Scala is two builds, not one build with two subprojects

This is the misconception worth naming, because the repository layout invites it
and the failure is silent.

`RealityEngine_Scala` contains **two independent sbt builds**:

```
RealityEngine_Scala/
  build.sbt                     project/     → reality-engine.jar
  perception-engine/build.sbt   project/     → perception-engine.jar
```

The root `build.sbt` declares no `lazy val` subprojects, no `aggregate` and no
`dependsOn`. **The root assembly does not produce the perception engine.** Each
build needs its own invocation, from its own directory:

```bash
cd RealityEngine_Scala               && sbt clean assembly
cd RealityEngine_Scala/perception-engine && sbt clean assembly
```

Two related traps sit next to it:

- **`compile` is not `assembly`.** `sbt clean compile` produces classes;
  `startUniverse.sh` launches fat jars. Building with `compile` leaves the jars
  untouched and the launcher runs whatever was there before.
- **A local run hides both.** `RealityEngine_Scala/start.sh` rebuilds a jar that
  is missing or older than its sources, so a developer who never built the PE
  still gets a working universe. The harness relied on the launcher to build
  artifacts the harness claimed to have built, and the first cold-start run that
  reached the gate reported `artifact missing —
  target/scala-2.13/reality-engine.jar` (`RealityEngine_CI#173`).

## 3. Where builds happen

Two lanes, and they differ in what they build against:

**The regression harness builds in throwaway worktrees.** `--cold-start` creates
a git worktree per repository at the run's pinned SHA, and builds there. The main
checkout is untouched. This is what makes a run reproducible and what keeps a
dirty working tree from silently entering a parity result.

**`startUniverse.sh` launches each repository's checked-in artifact.** It does
not build in a worktree; it delegates to each engine's `start.sh`, which rebuilds
what is stale in the main checkout.

The consequence is the one that has actually cost time: **a stale main-checkout
artifact survives a "rebuilt everything" harness run**, because the harness built
somewhere else.

## 4. Prerequisites are validated, not assumed

`startUniverse.sh` checks the host before spawning anything that needs it:

- **C++** — `validate_cpp_build_deps()` verifies libc++ headers and Boost by
  compiling against the same include search order the real build uses, because
  the failures otherwise surface mid-build as missing `<atomic>` or `<cctype>`.
- **LSP** — Quicklisp is bootstrapped by the harness itself
  (`scripts/bootstrap-quicklisp.sh --home`). `RealityEngine_LSP/quicklisp/` is
  untracked, so a cold-start worktree never has it, and the hosted lane
  previously only worked because the *workflow* had prepared `$HOME` first. A
  harness that runs only when its caller happened to prepare the environment is
  not a harness.

## 5. The provenance gate

**No parity or proof run against engines that are not built from current source.**

`scripts/verify-build-provenance.py` is called by `startUniverse.sh` before the
multi-engine spawn and by `regression-test.sh` before the start phase. It checks,
per engine repository:

| Check | Refuses when |
|---|---|
| git | not on the expected branch, has uncommitted source, or is behind its remote |
| mtime | any launched artifact is older than the newest tracked source file, or older than the HEAD commit |

Engines only. The corpus and service repositories run from source and cannot go
stale this way; LSP has no compiled artifact at all — SBCL loads the `.lisp`
files at start — so its git state is the check.

The override is `RE_SKIP_PROVENANCE=1`, deliberately **not** `--warn-only`: the
regression harness passes `--warn-only` on every run, so reusing it would disable
the check on the lane that needs it most.

Why it exists: on 2026-08-22 a three-engine run reported Scala writing cells C++
and LSP did not. The divergence was investigated, filed, and the engine source
read closely before anyone noticed both Scala jars predated that morning's merge
— `perception-engine.jar` by 5h39m. The comparison was
current-vs-current-vs-yesterday, and it read as an engine defect. A parity sweep
attributes every difference to the engines, and that attribution is only sound if
all three are running the code you think they are.

## 6. Rules

1. **Build through `RealityEngine_CI`.** `./scripts/regression-test.sh
   --build-only` builds every repository in the right order with the right
   prerequisites. Reach for a per-repo `make` or `sbt` only when working on that
   repository alone, and never as the last step before a parity claim.
2. **Never assume one repository's build implies another's.** They are separate
   repositories; nothing propagates.
3. **Build what the launcher launches.** For Scala that means `assembly`, twice.
4. **Do not report a parity or proof result that skipped the provenance gate.**
   If `RE_SKIP_PROVENANCE=1` was set, say so alongside the result.
5. **A build that quietly does not happen is the same failure as a stage that
   quietly does not run.** Where a build is skipped for lane reasons, the harness
   records why; keep it that way.
