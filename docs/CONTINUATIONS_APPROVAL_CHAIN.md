# Continuations Through the Approval Chain

Version 1.0.0, 2026-11-06.
Status: **authoritative** for how a multi-step agentic process, the IFRS
approval chain first, runs as continuations carried in the assetID frame
(owner decision, 2026-11-06; localAssetStorageStack#8, plan revision 3).

| This document governs | Specified elsewhere |
|---|---|
| The continuation and its rules | The clone, recycle and block-generation routes the engines serve: [`SURFACE_SPEC.md`](../SURFACE_SPEC.md), "Cloneable machines" |
| | The frame and its continuation log, held by the lifecycle service: localAssetStorageStack#13 |

Not implemented: no runtime or service carries continuations yet. Nothing here
is reported as working until the regression in RealityEngine_CI#715 passes.

## Context

- **Agentic dispatch is a procedure call.** The assetID is the stack frame: a
  structured set of the documents the agent acts on. Files appear as tagged
  URIs, along with permissions, authorities and identifications as needed.
  - A before hook, the **prologue**, builds the frame and dispatches.
  - An after hook, the **epilogue**, returns results through the same assetID.
- **Cloneable templates live in the active machine corpus.** Engines recognise
  them when they load the corpus. Cloning goes through
  `api/engine/{engineInstance}/clone/machine/{templateId}?asset={assetID}&envelope={envelopeId}`.
  - A clone always starts at the template's initial state.
  - It occupies one 64-cell block of the engine clone band, in the nest layout:
    input, output, fanout and bus quarters.
  - It is bound to one agentic action on one assetID. The dispatch envelope is
    its slot.
  - It is recycled when the action finishes: reset, its block freed, and the
    block's generation incremented.
- **The problem:** a clone is recycled as soon as its action finishes, but an
  IFRS approval can wait days for a human reviewer.

## The idea

The assetID frame carries a **continuation**: the rest of the process, stored
as data. Continuations are a member of the frame. Each clone runs one step. In
its epilogue, instead of returning to a caller, it does three things:

1. writes its results into the frame,
2. advances the continuation,
3. recycles itself.

The next step then clones a fresh template against the same assetID. **A human
wait holds no block.** The process waits as a parked continuation, not as a
running clone.

## The assetID frame

| Member | Holds |
|---|---|
| `documents` | the documents the agent acts on: tagged URIs with pinned revisions, permissions, authorities and identifications |
| `action`, `arguments` | the agentic action this step performs, built by the prologue |
| `return` | the step's results, written by the epilogue |
| `continuations` | the frame's continuation log, append-only, with `current` pointing at the live record |

The lifecycle service holds the frame: it is the store and gatekeeper, and the
single path for pod writes. Agents act on the frame's documents through it.

## The IFRS approval chain as a continuation

| Step | Template cloned | Resumed by | Continuation it leaves |
|---|---|---|---|
| Prepare | draft template | engine | k1: send to review |
| Request review | review template | engine | k2: *parked* until a reviewer acts |
| Review | none (human step) | reviewer principal | k3 approve, or back to k0 rework with findings |
| Approve | approve template | approver ≠ preparer | k4: record or publish |
| Record | publish template | engine | done, so the frame is closed |

A stale upstream works like an **escape continuation**. It supersedes whatever
is pending, marks the head STALE and re-enters at k0.

These steps line up with the existing `document_workflow` lifecycle: DRAFT →
IN_REVIEW → APPROVED, with STALE when an upstream changes (`draft`,
`request_review`, `approve`, `invalidate`).

## How a step runs

1. **Prologue**, run by RealityEngine_Manager's instantiation component:
   - it resumes the frame's `current` continuation, presenting the capability
     and the generation;
   - the lifecycle service checks them and the pinned hash, then returns
     `next`, or the `onStale` escape;
   - the component clones `next.templateId` on `next.engineId`;
   - it dispatches the agent with the assetID.
2. **The step:** the clone runs. The agent acts on the frame's documents.
3. **Epilogue:**
   - the agent writes `return`;
   - the component captures the next continuation, or parks it with a
     reviewer's capability;
   - the component recycles the clone, presenting the block generation the
     clone was made with.
4. **A human step** runs no clone. The reviewer acts in the lifecycle service,
   which resumes the parked continuation. The change reaches the engines as
   every lifecycle change does: Source → ISRE → recognition → OSRE → Manager →
   the next clone.

The engines carry no continuation state. They run the clones. Continuations
are frame data, held by the lifecycle service.

## Rules that make it safe

1. **Only templates in a continuation.** It names a template and an engine
   instance, never a clone id, because the clone is gone by the time the
   continuation is resumed.
2. **One-shot.** Each continuation carries a generation token and can be
   resumed exactly once.
   - Resuming it again, or resuming one that an invalidation superseded, is
     rejected.
   - The clone side has the same check: each block's generation increments at
     every recycle, and a recycle that presents a stale generation is refused
     (`SURFACE_SPEC.md`).
3. **Resumption needs a capability.** Each continuation names who may resume it.
   - Agents can never resume approve, record or publish. This enforces the rule
     that drafting agents cannot approve, post journals, publish or file.
   - The approve step also requires a different identity from the one recorded
     in the prepare frame.
   - Capabilities need real principals (lifecycle roadmap A2). A name string is
     not a capability.
4. **Pinned to a revision.** A continuation records the content hash it was
   captured against. If the hash has changed by the time it's resumed, it
   takes the escape path, not the approve path.
5. **Delimited.** The approval case is the boundary (the reset point), and each
   human wait is a capture point (the shift). Continuations never leak outside
   one assetID's approval process.
6. **The frame log is the evidence.** Every capture, resumption, supersession
   and abandonment is written into the frame's append-only log as a receipt.
   That trail of who resumed what, against which revision, is the approval
   evidence. Nobody has to assemble it afterward.
7. **A missing engine takes the escape path.** In deployment, engine instances
   commonly carry different corpora. A continuation's `next.engineId` may no
   longer carry its template, or may be gone. Resuming it then takes the
   escape path and records why; it never fails silently and never picks
   another engine on its own.

## The continuation record

```json
{
  "continuationId": "k2",
  "assetId": "<assetID>",
  "delimiter": "ifrs-approval-case",
  "next": { "engineId": "<engine instance>", "templateId": "<review-template>" },
  "resumableBy": { "role": "reviewer", "excludeIdentity": "<preparer identity>" },
  "pinned": { "revision": "<revision>", "sha256": "<hash>" },
  "generation": 3,
  "onStale": "k0",
  "status": "parked"
}
```

`status` is one of `captured`, `parked`, `resumed`, `superseded`, `abandoned`
or `closed`. The schema is defined with the frame (localAssetStorageStack#13).

## What this buys

- **Blocks stay free during human waits,** so the bound on active clones
  (`clone.maxActive`) is set by how much runs at once, not by how long reviews
  take.
- **Rework loops and invalidation are just continuation choices.** No extra
  state machine is needed.
- **The sequence is data, so parity stays simple.** In regression the voting
  engines run the clones against identical corpora, and their steps are
  compared like any machine's. The continuation log is part of the run's
  evidence (RealityEngine_CI#715).

## Open decisions

Each has a recommendation, recorded on localAssetStorageStack#8. None is
decided until the owner rules.

1. **Where parked continuations live:** in the assetID's pod document, or in the
   lifecycle service's append-only log with the pod holding a pointer?
   *Recommended:* the log, with a pointer. That keeps continuations under the
   store-and-gatekeeper role and the single pod-write path, and in the
   evidence log.
2. **Fixed chain or chosen successor:** is the chain fixed by the template at the
   start, or can a step choose its successor, for example escalating to a
   second approver above a materiality threshold?
   *Recommended:* the template chooses. The successor rule lives in the
   template in the corpus, where rules live, and the continuation records the
   choice that was made.
3. **Abandonment:** who may abandon a parked continuation, and what does
   abandoning it write to the frame?
   *Recommended:* only a principal holding the case's abandon capability, never
   an agent. Abandoning writes a receipt naming who, why and the generation,
   and closes the frame.
