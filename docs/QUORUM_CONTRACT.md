# Quorum Contract v1.0

Status: **decided.** Binding on every harness that compares runtimes.
Decided 2026-09-11, recorded from RealityEngine_CI#327.
Applies to: `RealityEngine_CI` harness scripts and e2e, `RealityEngine_Machines`
contract tests, and any future comparison across runtimes.

## 1. Quorum is 3-of-3

**All three native runtimes — C++, LSP, Scala — must agree, or the signature is
a disagreement.** There is no majority rule, no reference member, no designated
baseline.

A 2-of-3 split is a **disagreement**, not a decision. Reporting it as "the
majority says X" anoints two runtimes as correct on no evidence beyond their
number, and silently records the third's behaviour as acceptable deviation.

**The TypeScript PE follows suit**, and Manager follows it. It conforms to the
agreed contract; it is not a fourth vote that can outnumber a disagreement.

### Why not a majority

The worked example, and the reason this is not abstract
(RealityEngine_CI#349):

```
GET /api/machine-graph
  cpp    2db006dda0eb
  lsp    bfaf274cd919   ← identical
  scala  bfaf274cd919   ← identical
```

Two runtimes agreed; one did not. The cause was real — C++ emitted graph edges
in map (id) order while the other two used canonical (name) order, so the same
six edges came back permuted at *identical* byte length. **Under a 2-of-3 rule
this reports as consensus and C++'s ordering is recorded as acceptable.** Under
3-of-3 it is a disagreement, and it was a defect (RealityEngine_CPP#94).

This is the same failure the harness already names as "#138: never silently
anoints the majority". This contract makes that a rule rather than a caution.

## 2. Non-participation is declared, never silent

A runtime that cannot or will not take part answers with a **participation
state** — the closed set in `SURFACE_SPEC.md` → *Participation States*:

| State | Conforming |
|---|---|
| `active` | yes |
| `not-configured` | yes |
| `not-active` | yes |
| `unsupported` | yes |
| `unavailable` | **no — a finding** |

**`missing` is not one of them.** A runtime that simply returns nothing is not
declining; it is failing to answer, and that is a finding in its own right.

A comparison **must not** treat an absent runtime as agreement, and must not
treat it as a reduced quorum either: 3-of-3 means three declared `active`
answers. Two `active` and one `not-configured` is a lane that cannot evaluate
this signature, and it reports as such.

## 3. Unanimous silence is a result, not a skip

**Where every runtime answers `unsupported` for a signature, that agreement is
itself a finding and must be reported as one.**

It says the shape is unimplemented *everywhere* — a gap in the contract rather
than in one engine. Filing it under "skipped" is how an unbuilt surface becomes
indistinguishable from one nobody happened to exercise.

The skip output **enumerates** every such signature. It does not summarise them
as a count.

## 4. Authority lives in git; derived artifacts track their source

- **Anything carrying authority is a file in git**, changed through review, with
  history and blame. No authoritative artifact is generated into a temp
  directory and trusted.
- **Work-product whose lifecycle belongs to a regression run may live outside
  git** — but it **must be able to tell it is stale** relative to the
  authoritative documents it derives from.

The case that produced this rule: `contracts.json` sat two months behind the
corpus it described, because its `--check` drift gate was wired to nothing
(#327). A derived artifact that cannot detect its own staleness is an assertion
about the past wearing the appearance of a current check.

**Settled consequence:** `ces-contracts.json` carries authority, so it is a file
in git under `RealityEngine_CI/config/` — not a per-run computation, and not
generated into a temp directory and trusted.

A related trap the same case exposes, worth naming because it is not a quorum
question but is what quorum replaces: a contract recorded by **replaying the
corpus through one engine** makes that engine unfalsifiable. The gate can never
find a defect *in* the oracle, because to regenerate you must already trust the
thing the gate exists to check. Deriving the expected stream from 3-of-3
agreement retires the privileged participant; where the three disagree, that
*is* the finding.

## 5. A disagreement reports, with enough detail to act

Not merely "they differ". A disagreement carries:

- the **signature**;
- **what each runtime emitted** — hash or value, not just "differs";
- **which rule** it was held to, and what that rule already allows;
- enough that a reader need not re-run to know what happened.

`e2e/lib/parity-surface.ts` is the reference implementation: it records the rule
each compared signature resolved to **whether or not it agreed**, because a gate
that reports only its failures cannot be audited for what it stopped checking.

## 6. What this forbids, concretely

- Designating a reference member and comparing others against it — the
  designated-baseline defect (#138).
- Calling the largest cluster "the majority" and the remainder "divergent".
- Passing a signature because the runtimes that answered agreed, when one did
  not answer.
- Recording a skip without naming what was skipped and why.
- Relaxing a rule to make a gate green. An allowance must name what it gives up
  and show that coverage is preserved elsewhere (PR #324).

## 7. Conformance

A harness conforms when, for every compared signature, it can answer:

1. Did all three native runtimes return `active`? If not, which state did each
   return?
2. Did all three agree? If not, what did each emit?
3. Which rule was applied, and what does that rule allow?
4. If skipped: which signatures, and for what declared reason?

### Where the rule is implemented

| Harness | How it conforms |
|---|---|
| `scripts/regression-universal-vectors.py` | `quorum_composition()` reports a run missing a native runtime; a multi-cluster result is a `"disagreement"` carrying every cluster's signature, with no reference member. |
| `e2e/lib/parity-surface.ts` | `compareSurface()` is symmetric — the verdict does not depend on which runtime dissents — and the finding carries all three emissions. `unanimousSilence()` implements §3. |
| `e2e/tests/tree-to-pe-manager-equivalence.spec.ts` | Enumerates `signaturesOutsideQuorum` (§2) and `noRuntimeImplements` (§3) to stdout and into the run manifest. |
| `scripts/tests/parity-surface.test.mjs` | Pins the rule: a 2-1 split must produce a finding whose record contains no "baseline", "reference", "majority" or "divergent"; the verdict must be identical whichever runtime dissents. |

Known non-conformance at the time of writing:

- Participation states are specified in `SURFACE_SPEC.md` but not yet emitted by
  the runtimes; until they are, "no answer" cannot be distinguished from
  "declined", and §2 is enforced by *presence* of a response rather than by a
  declared state. `unanimousSilence()` reads a unanimous non-2xx as the closest
  available proxy for a unanimous `unsupported`.
- `scripts/regression-trajectory-parity.py` and the other Python stages compare
  without a quorum-composition precondition. They fail loudly on divergence, so
  none anoints a majority, but a two-runtime run still reports as parity.
