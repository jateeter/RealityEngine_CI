# RealityEngine_CI E2E Guidance

This directory contains full-stack tests for the composed RealityEngine application.

- Prefer tests that consume `RE_REGISTRY_URL` and active engine metadata.
- Keep OpenClaw, Manager, Machines, and byte-equivalence assertions separated.
- Capture evidence without assuming generated reports should be committed.
- When failures diverge by engine, compare C++, LSP, and Scala payload identity before byte equality.

## The declared parity surface

Quorum is 3-of-3 — `docs/QUORUM_CONTRACT.md`. All three native runtimes
agree or the signature is a disagreement; a runtime that did not answer is
enumerated, never counted as agreement; and a shape all three refuse is
reported as "no runtime implements this" rather than passing quietly.

`lib/parity-surface.ts` states, per captured signature, what agreement means
for that surface and why. `tree-to-pe-manager-equivalence.spec.ts` compares
against it instead of hashing every `/api/*` response the browser happened to
issue.

Why it exists: byte equivalence is something `SURFACE_SPEC.md` grants a surface
**explicitly** — `GET /api/engine/config` carries a "Byte equivalence applies"
heading and says why — and a response captured because a React component
fetched it inherits no such grant. Requiring it everywhere asserted more than
the specification says, and on #321 that reported two non-divergences as
failures.

Three strictness levels:

| Level | Meaning |
|---|---|
| `bytes` | bodies identical — whitespace and key order included, because uniform presentation is part of the API |
| `projection` | identical after the rule's **named** allowances are removed; key and array order still compared |
| `observed` | captured and reported, never compared (the Manager control plane) |

An undeclared signature is byte-compared, which is what everything got before
rules existed — so declaring nothing changes nothing, and a route that joins the
flow later cannot slip in under a weaker rule than its peers. Its finding says
`undeclared surface` and asks to be classified.

**An allowance is a named key with a citation, and the test of whether it is
honest is whether what it gives up is covered elsewhere.** The one allowance
today is `created`/`skipped` on `POST /api/pe/sources/bootstrap-from-machines`:
they report what an idempotent call did given what was already registered, so
they carry the reset divergence (#163) rather than anything about this call —
and the source set those counters describe is compared byte-for-byte by
`GET /api/pe/sources`, so no coverage is lost.

What is **not** an allowance is the case that looks identical from a distance.
`sequences[].initialEventIds` on `GET /api/machines` was Scala-only and might
have read as permitted internal augmentation — except it has a consumer, so it
was a conformance gap and stayed compared. CPP#91 and LSP#105 closed it; the
rule stays allowance-free so a runtime dropping the key is reported again. See
SURFACE_SPEC.md, "Open gaps".

Identity filtering deliberately is *not* mirrored from
`scripts/lib/parity_identity.py`. That module strips engine-minted ids because
the payloads it compares carry ids invented per process; these captures carry
corpus-derived ones (`machine-arbitrationreader`), so the same filter would drop
real content. `scripts/tests/parity-surface.test.mjs` fixes the rules against
the actual #321 payloads.

## Which specs run in which universe shape

`tests/` is the canonical home of the app-level specs — they were deduped here
from `RealityEngine_Machines` deliberately. Do not re-add copies there.

| Spec | Multi-engine | Why |
|---|---|---|
| `tree-to-pe-manager-equivalence.spec.ts` | ✅ runs | resolved endpoints from the instance registry from the start |
| `visualizer-ui.spec.ts` | ✅ runs | promoted 2026-09-07 after #301 |
| `api.spec.ts` | ✅ runs | promoted 2026-09-07 after #301; one test skips (#311) |
| `full-integration.spec.ts` | ✅ runs | promoted 2026-09-07 after #301 |
| `multi-step-output-workflow.spec.ts` | ⏭ skipped | skips on the regression corpus (see "Corpus dependencies") |
| `perceptual-space-interconnection.spec.ts` | ⏭ skipped | skips on the regression corpus (see "Corpus dependencies") |

#301 made global-setup and the specs resolve endpoints from the instance
registry instead of hardcoding the Docker stack's TLS proxy
(`https://localhost:5001` RE, `:3004` PE). A native `--engines=` launch binds
RE/PE at instance-registry-assigned ports over HTTP (scala 5000/5001, cpp
5300/5301, lsp 5600/5601). Each promotion was earned by a measured run on
`cpp:2,lsp:1,scala:1`, recorded beside the allowlist. The two still excluded
are no longer pinned; they skip on the regression corpus, so promoting them
would prove nothing until a corpus exercises them.

Selection lives in `scripts/lib/ci-e2e-specs.sh`; `scripts/run-all-tests.sh`
reports every skipped spec by name, and deployment mode escalates those skips to
failures. `scripts/tests/test-ci-e2e-specs.sh` asserts the run and skip lists
partition this directory exactly, so a new spec cannot land unrun and unreported.

**To promote a spec to multi-engine:** make it resolve its base URLs from
`RE_REGISTRY_URL` instead of hardcoding them, then add it to
`CI_E2E_MULTI_ENGINE_SPECS`. The unit test refuses any allowlisted spec that
still pins `:5001` or `:3004`.

## Which hosted job runs what

One job, `multi-engine-and-parity-tests` in `.github/workflows/e2e-tests.yml`,
boots one shared universe — `--engines=cpp:2,scala:1,lsp:1
--machine-corpus=regression` — and runs every gate against it:

| Step | Instances | Specs |
|---|---|---|
| Run all CI e2e specs against shared core | all | `ci_e2e_specs_for_mode multi-engine` — the four above |
| Run multi-instance integration tests | `cpp-1` + `cpp-2` | Machines' `tests/integration/multi-instance.spec.ts` |
| Run cross-runtime contract specs | all | Machines' contract specs |
| Byte-equivalence parity across runtimes | `cpp-1` + `lsp-1` + `scala-1` | `tree-to-pe-manager-equivalence.spec.ts` |
| Corpus addressing parity across runtimes | all | Machines' corpus-addressing spec |

The step sources the library rather than listing specs inline, so the split
cannot drift between the local runner and hosted CI. There is no single-engine
Docker job any more: the two excluded specs run only locally, via
`run-all-tests.sh --e2e` against a full-corpus universe.

`tree-to-pe-manager-equivalence` hardcodes `lsp-1`, `scala-1` and `cpp-1`
because byte equivalence is only meaningful across distinct runtimes; the
`cpp-1`/`cpp-2` pair cannot substitute. The job fails if the spec does not
actually execute, rather than trusting a green exit, and it self-skips
elsewhere with the missing engine ids in the reason.

## Corpus dependencies

`multi-step-output-workflow` and `perceptual-space-interconnection` drive the
digital-logic fixtures `MultiStep`, `RS2` and `RSFlipFlop`. Those are **not** in
`config/regression-corpus.txt` (21 machines: the standard-deployment twelve
plus what the parity gates need), which is what the hosted job boots with via
`--machine-corpus=regression`.

Both specs guard on this through `helpers/require-machines.ts` and skip with a
reason naming the missing machines. They run for real against a full-corpus
universe — the default `startUniverse.sh`, and `run-all-tests.sh --e2e` locally.

A 404 for a machine the corpus never claimed to load is not a product signal, so
these skip rather than fail. Deployment mode still treats the skip as a failure
at the suite level, so a certification run cannot quietly omit them.

## Selector guidance

The landing surface is a domain **tree**, not the old card grid. `.mc-card` and
`.msv-search` still exist in the Manager frontend but are not on the landing
route.

Prefer stable classes over role+name where names collide:

| Want | Use | Not |
|---|---|---|
| Wordmark | `.rep-title` | `h1` (none exists) |
| Interconnect nav | `.rep-nav-interconnect` | `getByRole('button', {name:'Interconnect'})` — also matches the `Interconnects` filter chip |
| Machine list | `getByRole('tree', {name:/Machines grouped by domain/})` | `h3` (first match is a hidden Settings section) |
| Search | `getByPlaceholder(/search domains/)`, `.rep-search-clear` | `.msv-search` |

`RealityEngine_Manager/visualizer/frontend/e2e/` tracks this UI closely and is
the best reference for current selectors.

## Standing rules — authoritative in `../docs/ENGINEERING_CONTRACT.md`

These apply here and are **not** restated in this file. The table is an index
to the contract, not a copy of it: it names every rule so you know what to look
up, and the contract's wording governs wherever the two differ.

| Rule | In short |
| --- | --- |
| Qualify every "registry" | Never the bare word — instance / machine / cesgen / arbitration / domain / semantic-bus / tag. |
| Regenerate a stale `<name>` registry, don't fail it | Each `<name>` registry is a view of the running system. A gate regenerates it and fails only on a disagreement that survives regeneration. |
| Verify a merge beyond the hosted checks | A green PR is not a verified PR; the hosted path cannot reach the integration points. Name what you could not exercise, and record what you noticed but did not chase. |
| _CI is the authority | Peripheral repos keep minimal CI that forces local validation; RealityEngine_CI verifies fixes against a live universe. Check its `docs/` before adding CI anywhere else. |
| Name it `CLAUDE.md` | Uppercase, always. On a case-insensitive filesystem `claude.md` is the same inode; dedupe on `st_ino`, never on a resolved path. |
| Never commit to main | Branch from `origin/main`, PR, verify, squash-merge, clean up. |
| Use bash, not zsh | Shell work runs in `/opt/homebrew/bin/bash` (5.x), not zsh or macOS `/bin/bash` 3.2: any loop, unquoted variable, glob or `set --` goes through it with `set -euo pipefail`, and you check the command's exit status, not the pipeline tail. |

Read the contract for the full text, the qualifier table, and the cleanup steps.
