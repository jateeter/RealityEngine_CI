# Moving the output fold into the machine's atomic step

Status: **plan, not applied.** This describes a change to the Reality Engine's
end-of-step composition — the first structural change to the RE step — and is
written to be argued with before any engine is touched.

## The claim

Folding a machine's collection of potential outputs into the single output it
presents is the Reality Engine's job and the last thing it does in a machine's
atomic step. The fold currently sits beside that position rather than in it, so
the merged value is reported but not used, and the arbiter still resolves the
unfolded collection.

## Where the fold is now

Each runtime folds after its parallel work collapses, and writes the result into
`machineResults[].mergedOutputVector`:

| runtime | fold site | parallel construct it follows |
|---|---|---|
| C++ | `SimulationStep` build in `run_phases` | domain-worker `std::future`, joined at `futures[i].get()` |
| LSP | `process-machine-input` | the actor, which serialises the step |
| Scala | the sequential machine loop | precedes the arbiter's `Future` cell sharding |

That placement was correct for what the fold was then: a value for the Perception
Engine to read instead of `outputVector`, which was one arbitrarily chosen member
of the collection and differed per runtime (#154).

## Where it has to go, and why

The step has **two** merges, under different rules:

```
per-machine collection ──► fold (or/and/…/meet/join/…)  ──► mergedOutputVector ──► PE
        │
        └────────────────► contributions ──► per-cell arbiter ──► space, OREV
```

The lower path never sees the fold. Every asserted output becomes its own
`MergeOperation`, so a machine with seven completed Reality Events contributes
seven values to the same cell and the *cell arbiter* resolves contention that
belongs to the machine.

FallDetection makes this concrete. Its seven sequences assert, on output index 0:

```
nominal 0 · stumble 1 · sustained 2 · impact 3 · confirmed 4 · slow-collapse 4 · intentional-lying 0
```

At the sweep failure the resolved value was 2.0 on C++ and LSP and 0.0 on Scala —
neither the maximum nor the minimum, because only a subset fires on any given
step and the answer depends on which subset plus how each runtime's arbiter picks
and breaks ties among same-machine contributions.

With the fold applied first the machine contributes **one** value per cell. Every
possible firing subset yields a single determinate value, so no arbiter rule,
tie-break or shard ordering can make the runtimes differ on it. That is a
stronger property than the fold's closure and symmetry: it removes the
contention rather than resolving it consistently.

## What the move actually changes

`step.mergeBatch` stops carrying one entry per asserted output and starts
carrying one per machine per output region.

**This affects every machine, not only multi-valued ones.** Any machine whose
sequences assert overlapping cells currently reaches the arbiter as multiple
contributions and would afterwards reach it as one. The 732-machine parity
baseline from the last sweep does not transfer; it becomes the regression
reference against which the move is judged.

## The provenance problem

A `MergeOperation` today carries `machineId`, `sequenceId`, `outputIndex`,
`values` and `provenance`, and downstream work reads them:

- governance resolution is per firing sequence (`resolve_governance(machine, po.sequenceId, po.values)`)
- deprecation stamping matches the firing sequence id
- coverage records paging decisions per contribution
- the trigger-rule join needs `cesId`
- the arbiter's severity ranking reads `ragStatusCode`, resolved per sequence

A single folded contribution has no single `sequenceId`. Collapsing them would
lose which CES fired, and `sequenceId` is exactly what the cross-runtime parity
check compares.

**This is the substantive design question of the move**, and it is not answered
here. Three shapes, none free:

1. **Fold contributes, sequences still audit.** One `MergeOperation` per machine
   carrying the folded value plus the *set* of contributing sequence ids; the
   audit paths read the set. Preserves the evidence trail, changes its shape.
2. **Arbiter groups by machine.** Contributions keep their per-sequence identity,
   and the arbiter folds within a machine before resolving across machines.
   Leaves `mergeBatch` untouched but moves the fold into the arbiter, which is
   the wrong owner — the fold is the machine's, and per-machine k has to reach
   it.
3. **Two-phase merge batch.** A per-sequence batch for audit and a per-machine
   batch for resolution, derived from it. Honest about there being two questions;
   costs a second pass and a second thing to keep consistent.

(1) looks closest to the model — the machine presents one output, and the
evidence for it is the set of REs that completed — but it changes a record shape
that four consumers read, and it should be chosen deliberately rather than by
whoever writes the patch first.

## Consumer review for option (1) — findings

Option (1) is chosen: one `MergeOperation` per machine per output region,
carrying the folded value plus the set of contributing sequence ids.

The review found **seven** consumers of per-sequence identity, not four, and two
of them are functional rather than reporting. Neither is a blocker on its own,
but one requires a semantic decision that is not the fold's to make.

### Functional — changes behaviour, not just output

**1. Event bus** — `apply_event_bus`, reality.cpp. Keys subscriptions on
`machineId + "|" + sequenceId` and *writes into the perceptual space*
(`space.update_region`). Meta-machines subscribe to a specific
(producer machine, producer sequence) pair. A single collapsed operation has no
single `sequenceId`, so subscriptions either stop matching entirely — meta
machines never fire — or match one arbitrarily chosen sequence.

Tractable: `apply_event_bus` iterates the contributing set instead of reading a
scalar, and the existing dedup key already includes the sequence so it stays
correct. But it is a change to the event bus, which was not in scope, and the
event bus is how compose/meta machines observe producers.

**2. Arbitration by severity — 270 cells.** `resolve_cell` ranks by
`severity_rank(c.ragStatusCode, c.lifeSafety)` under `rule: SEVERITY` (2 cells)
and `withinRank: SEVERITY` (268 cells). `ragStatusCode` is resolved per firing
sequence by `resolve_governance(machine, sequenceId, values)`.

One folded contribution carries one `ragStatusCode`. **Which firing sequence's
governance applies to a value that came from several of them?** The plausible
answers — highest severity among contributors, the governance of the sequence
whose value survived the fold, none at all — are different policies with
different outcomes on those 270 cells, and the fold has no basis for choosing.
This is the decision that must be made before implementation, and it is a
governance question rather than a merge question.

Note the fold and the severity ranking can disagree by construction: `meet` can
select a value from a low-severity contributor while a high-severity one also
fired.

### Reporting — output shape changes, behaviour does not

**3. Deprecation stamping** — matches `seq.id == po.sequenceId` to attach a
lifecycle block and increment `record_deprecated_fire`. With one operation the
stamp becomes a set, and the counter counts machines rather than firings.

**4. Coverage paging decisions** — `record_paging_decision` runs per
contribution, so its totals drop to one per machine per step. Dashboards reading
those counters will step down; the underlying behaviour is unchanged.

**5. Canonical merge ordering** — sorts by `(machineId, sequenceId, outputIndex)`
to keep runtimes byte-identical. With one operation per machine the secondary
keys are constant and `machineId` alone orders it. Simplification, not a risk.

**6. `mergeBatch` JSON** — emits `sequenceId` per entry to listeners. Becomes a
set; any consumer reading it as a scalar breaks.

**7. PE dispatch ledger** — `perception_engine_server.cpp` reads
`op.at("sequenceId")` into a dispatch record. Same shape change, and it crosses
the RE/PE boundary, so both sides move together.

### Path forward under the two construction constraints

Two constraints resolve most of the review:

**A. Overlapping output positions within a machine are deliberate and stable.**
The constructor assigns two CESs the same position only when that position is
identical across every possible fold configuration. So intra-machine cell
contention is not contention at all — it is the machine's own composition, and
the arbiter resolving it was the defect. Folding is the correct resolution.

**B. Integration-provided sources occupy non-conflicted positions.** They are
not considered at machine internment and are assigned positions that do not
collide with machine outputs, so the fold cannot change how they resolve.

Together these mean the arbiter, after the move, resolves only genuine
contention: *between* machines, and between machines and integrations. That is
what SEVERITY was for.

**The one remaining gap, and its answer.** A folded contribution needs one
`ragStatusCode` for the 270 severity-ranked cells. Measured over the corpus: 135
of 1328 machines have an `outputMatches` pattern that maps to more than one RAG
code, so matching on the folded values alone is genuinely ambiguous for them —
the `sequenceId` filter is doing real work.

The resolution is already in the codebase. `severity_rank` is an ordered chain:

```
GREEN / absent = 0  <  AMBER = 1  <  RED = 2  <  lifeSafety = 3
```

So governance for a folded contribution is the **join over the severity ranks of
the contributing sequences' matched rules** — the same lattice operation the
fold vocabulary already defines, applied to a chain that already exists.

It has the properties the fold contract demands, for the same reasons:
deterministic; symmetric, since max over a set does not depend on enumeration
order; closed, since it returns one contributor's rank rather than inventing
one; and safety-preserving, since a RED-governed firing cannot be hidden by a
GREEN one that folded alongside it. That last property is what SEVERITY
arbitration exists to guarantee, so taking the join preserves its intent rather
than approximating it.

The `MergeOperation` therefore carries the folded value, the set of contributing
sequence ids, and the joined governance. The event bus iterates that set. The
audit consumers read it. Nothing needs a sequence identity the machine cannot
supply.

### Verdict

Option (1) is implementable, and under construction constraints A and B above
the path is complete: the fold resolves intra-machine contention, integrations
cannot collide with it, and governance for the folded contribution is the join
over its contributors' severity ranks.

Remaining work is mechanical rather than open:

- `MergeOperation` carries the contributing sequence set and the joined
  governance instead of a scalar `sequenceId`.
- `apply_event_bus` iterates that set; its dedup key already includes the
  sequence, so it stays correct.
- Deprecation stamping, coverage counters, `mergeBatch` JSON and the PE dispatch
  ledger follow the same shape change on both sides of the RE/PE boundary.
- The 732-machine baseline is the regression reference, since the move changes
  what the arbiter sees for every machine with overlapping CES outputs — 215 of
  1328 by measurement.

One thing to confirm during implementation rather than assume: constraint A is a
guarantee about the *constructors*, not something the loader enforces today.
Worth a corpus gate asserting it, so a machine that violates it is rejected at
internment rather than discovered as a divergence.

## Staging

The move is not one change. Suggested order, each independently revertible:

1. **Land the transformations** (in flight). Boolean five unchanged, chain five
   added, no placement change. Verifiable by unit test alone.
2. **Settle the chain top.** `strong-conjunction` and `strong-disjunction` are
   undefined without k, and k is not derivable from `bitsPerElement`. Needs a
   corpus declaration and a schema field. Until then those two are unusable —
   and the three runtimes must agree on what happens when k is absent, or they
   diverge by construction on the very transformations meant to fix divergence.
3. **Decide the provenance shape** above.
4. **Move the fold**, one runtime at a time, verifying the binary corpus is
   unchanged at each step against the 732-machine baseline.
5. **Re-run the sweep** with FallDetection reinstated, which is the acceptance
   test for the whole line of work.

## What would falsify this

If the binary corpus's OREV changes when the fold moves, then folding before
arbitration is not behaviour-preserving for machines that were relying on the
arbiter to resolve their own contributions — and that reliance would itself be
worth understanding before it is removed. The 732-machine baseline is what
detects it.

## Open, unrelated to the fold

The sweep's second failure, #748
`HSPH026_evaluation-capacity-measure-tracker`, is a `cpp+scala | lsp` split at
ISRE step 7 cell 0 and OREV step 7 cell 27 — the first divergence with LSP as
the outlier, and cell 0 belongs to a machine's *input* region, not an output
region. It is not obviously a fold problem and has not been diagnosed.

---

# Implementation contract

Normative. All three runtimes implement exactly this; anywhere they differ is a
divergence by construction.

## 1. `MergeOperation` shape

Replace the scalar firing identity with the contributing set.

```
  region            unchanged
  machineId         unchanged
  sequenceIds       NEW — sorted, deduplicated, the CESs that contributed
  outputIndex       REMOVED — meaningless once one operation covers the machine
  values            the FOLDED vector
  provenance        union of contributors' provenance, order-preserved, deduped
  governance        the joined PagingDecision (section 3)
  deprecation       present when ANY contributor is deprecated (section 4)
```

One operation per machine per output region per step. A machine that completed
no Reality Event contributes none, exactly as today.

## 2. The folded value

`values` is the machine's collection of potential outputs put through
`fold_outputs` / `fold-output-vectors` / `OutputMergeTransformation.fold` under
the machine's own `outputMergeTransformation`, with its `outputAlphabetTop` as
the chain top when declared.

A refusal (the Łukasiewicz pair with no declared chain top) yields no output, so
the machine contributes no operation for that region — same as completing no
Reality Event. It must not contribute a zero vector.

## 3. Governance — join over contributors

Resolve governance **per contributing sequence, against that sequence's own
asserted values**, exactly as today. Do not resolve against the folded value: a
rule written for one CES's output need not match the fold, and changing the
matching semantics is not part of this move.

Then select one:

1. highest `severity_rank(ragStatusCode, lifeSafety)` — the chain
   `GREEN/absent 0 < AMBER 1 < RED 2 < lifeSafety 3`;
2. ties broken by lexicographically smallest `sequenceId`.

Take that contributor's PagingDecision **whole** — `ragStatusCode`,
`processStatus`, `description`, `ownerTeam` and the rest travel together. Do not
compose a decision from fields of different rules; a mixed record describes no
rule that exists.

`std::nullopt` / NIL / None when no contributor resolved governance, as today.

Rationale: the join is safety-preserving — a RED-governed firing cannot be
hidden by a GREEN one folded beside it — and it is symmetric, so the answer does
not depend on enumeration order. 135 of 1328 machines have an `outputMatches`
pattern mapping to more than one RAG, so this is load-bearing, not decorative.

Coverage: `record_paging_decision` is called **once** per operation, with the
joined decision. Its totals drop from per-firing to per-machine-per-step; that
is expected, not a regression.

## 4. Deprecation

Attach when ANY contributor's sequence is deprecated. Report the same
lexicographic-smallest rule as section 3 among deprecated contributors, so the
choice is deterministic. `record_deprecated_fire` is called once per deprecated
contributor, preserving today's per-sequence count.

## 5. Event bus

`apply_event_bus` iterates `sequenceIds` and looks up
`machineId + "|" + sequenceId` per element. The existing dedup key already
includes the sequence, so subscription semantics are unchanged: every
(producer machine, producer sequence) subscription that would have fired before
still fires. This is the one consumer where behaviour must be *identical*, not
merely analogous — it writes into the perceptual space.

## 6. Canonical ordering

Sort `mergeBatch` by `machineId` alone. `sequenceId` and `outputIndex` are gone
as sort keys; `machineId` is unique per operation now, so ordering is total.

## 7. Wire shape

`mergeBatch[]` in JSON emits `sequenceIds` (array) in place of `sequenceId`
(string). The PE dispatch ledger reads the array. RE and PE change together —
a PE reading `sequenceId` from a new RE gets nothing, and the reverse is worse.

## 8. What must not change

- Machines with exactly one contributing sequence per region — the overwhelming
  majority — must produce byte-identical results. `sequenceIds` is a
  one-element array and the joined governance is that sequence's own.
- The 732-machine parity baseline is the regression reference. 215 of 1328
  machines have overlapping CES outputs and are the ones genuinely at risk.
- Arbitration for cells with a single contributing machine is untouched.

---

# Contract amendments — reconciliation of implementation divergences

The three runtimes implemented §1–§8 and diverged in four places. These
amendments are normative and supersede the text above where they conflict.

## A1. §8 was wrong. Corrected.

§8 claimed single-contributor machines produce byte-identical results. That is
false, and both the C++ and LSP implementations found it independently.

Byte-identity requires the fold to be the **identity on a one-element
collection**. It is for `or`/`and`/`xor` over `{0,1}` and for all five chain
transformations. It is NOT for:

- `nor` and `nand`, which **invert** a lone contributor;
- any Boolean gate applied to a contributor carrying an ordinal value, which
  **binarises** it.

Before the move the raw value reached the arbiter and the fold was only
reported. Now the fold *is* the contribution, so a machine whose outputs carry
magnitude and does not declare a transformation has that magnitude destroyed on
the way to arbitration.

The corpus change that resolves this today is already made: FallDetection and
FallSensorMotionPreaggregator declare `"outputMergeTransformation": "join"`.
The corpus gate in `RealityEngine_Machines/tests/contracts/fold_placement_test.py`
catches the next machine that needs one.

**Restated invariant:** a machine with one contributing sequence per region is
byte-identical *iff* its declared transformation is the identity on a singleton.
Pin both the holding and the failing case in tests rather than asserting the
general claim.

## A2. `governance` — full object, all three

The wire carries the winning contributor's `PagingDecision` **as a complete
object** under `governance`, shape unchanged from before the move.

C++ and LSP do this. **Scala must change**: it currently omits the key. Omitting
it was the right instinct for the wrong reason — a bare string would have put
two types on one field, but the answer is the object, not absence. A consumer
reading `governance.ragStatusCode` gets nothing from Scala today.

Scala has no `PagingDecision` in its step path and `recordPagingDecision` is
called from nowhere, so this is new construction there, not a rename. Build the
object from the same fields the other two emit; where Scala genuinely cannot
resolve a field, emit it absent rather than inventing a value, and say which in
the report.

## A3. `cesId` — the comma-joined set, all three

A folded contribution's `cesId` is the **comma-joined, sorted, deduplicated
`sequenceIds`**, with no spaces: `"aihr-hw-degradation,aihr-net-fault"`. A
one-element set renders as the bare id, so single-contributor machines are
unchanged on the wire.

C++ already does this. **LSP must change** — it currently uses the smallest
contributing id, which silently discards the rest.

`cesId` is now an **opaque key**, not a sequence identifier. Every reader must
be checked and, where it treats the value as a single sequence id, either
updated or documented as accepting the joined form:

- the arbiter's ordering comparator and its suppressed-contribution equality
  test — string operations, so correct as-is, but confirm;
- `/api/arbitration` serialisation and anything downstream of it;
- the PE dispatch ledger and trigger-envelope paths;
- **`RealityEngine_Manager`'s TypeScript PE**, which reads `op.sequenceId`
  behind a `typeof … === 'string' ? … : ''` guard and will degrade silently to
  empty strings rather than failing. Silent degradation is the failure mode this
  work exists to eliminate; it must be made to fail loudly or read the set.

Report every reader you found and what you did about it.

## A4. §4 "contributor" — per asserted output

`record_deprecated_fire` fires **once per asserted output from a deprecated
sequence**, not once per deprecated sequence. This preserves today's count
exactly, which is what §4 intended and said, and matters when one sequence
asserts several outputs in a step.

LSP reads it this way. **C++ and Scala must change** to match.

`sequenceIds` on the `MergeOperation` remains the **deduplicated sequence set** —
this amendment governs the deprecation counter only, not the identity set.

