# Deployment Gate — Failure Triage

Last reviewed: 2026-09-10 · Baseline run `20260910T230109Z`, on merged `main`

```
agent level    28 passed  ·  1 failed
gate internal  25 passed  ·  9 failed   (6 suites)
```

The single agent-level failure **is** the gate; it is an aggregate, not a
finding of its own. Everything outside the gate — health, all four container
restarts, all four native lanes start *and* restart — is green.

## Why this file exists

A schedule is about to run this every six hours and file issues. Without a
written floor, every cycle re-reports the same six suites and the signal is
buried in its own noise. **28/1 is the expected floor and is not news.** News is
a *new* failing unit, or the floor moving.

Categories below are ordered by what they cost to resolve, not by severity.

---

## A · Known and filed — 1 suite

### A1 · `C++ (make e2e)` → `cesgen_contracts_parity`

6 step mismatches across `AICoolingRegulator`, `AIHardwareResilience`,
`AIModelWellness`.

**Not an engine defect.** The C++ test's own comment predicts it: the fold moved
into the machine's atomic step, so multi-sequence machines emit one folded entry
where `contracts.json` (recorded 2026-07-10, before the 2026-09-04 corpus
rewrite) holds one per firing. Single-sequence machines still match
byte-for-byte.

- Tracked: **RealityEngine_CI#327**, RealityEngine_Machines#115
- Blocked on: re-recording, and the decision recorded on #327 that the oracle is
  a *participant* — quorum (3-of-3) replaces it, shaped with the owner first
- Expected to keep failing until then. **Do not re-file.**

---

## B · Harness configuration — 2 suites

These fail for reasons that have nothing to do with their subject. They are the
cheapest to fix and the most misleading to leave.

### B1 · `Manager frontend e2e (Playwright)`

Every test fails, including `shows the active engine instance`, the simplest
assertion in the suite.

**Cause:** the spec navigates to `http://localhost:5173` per its `baseURL`;
both `:5173` and `:3001` answer **302 → https://**. Nothing downstream of page
load is being tested.

- **Unfiled.** Should be.
- Consequence beyond this suite: the testid migration in Manager#116 is
  compile-verified only and cannot be proven until this clears
  (`docs/VISUALIZER_REDESIGN_ROADMAP.md`, M1).
- Fix shape: point `baseURL` at the TLS endpoint, or have the gate run the
  frontend without the proxy. Decide which is the *intended* deployment first —
  the answer belongs in `SURFACE_SPEC.md`, not in a Playwright config.

### B2 · `CI e2e (Playwright)`

79 passed, 6 skipped; failures concentrated in **webkit** and **Mobile Chrome**.

`playwright.config.ts` runs four browser projects locally and **one (chromium)
under CI**, so the local gate exercises three projects CI has never run and
nobody has ever kept green.

- **Unfiled.**
- Decide deliberately: either the gate runs chromium only (matching CI), or the
  other three become supported and get fixed. Today's state — running them and
  ignoring the result — is the worst of both.

---

## C · Environment and timing — 1 suite

### C1 · `Scala PE (make e2e-healthkit-spezi)`

```
Reality Engine did not become ready at http://localhost:3399/api/health
make: *** [e2e-healthkit-spezi] Error 1
```

The suite spawns its **own** RE on `:3399` and PE on `:3401`, and the RE never
came up. **LSP's equivalent suite passes**, so this is Scala-specific.

Two candidates, and they are distinguishable:

1. **JVM boot budget** — the same shape as the native-lane failure fixed
   earlier: Scala took longer than the poll allowed while C++ and LSP fit. Check
   what corpus this suite's RE loads; if it is the full 1,328 the budget is the
   problem.
2. **Port collision** with the running universe.

Cheap to tell apart: run the suite alone against a quiet machine.

- **Unfiled.**

---

## D · Reporting integrity — 1 suite

### D1 · `OpenClaw PE integration e2e`

The suite's own output ends:

```
[pass] OpenClaw e2e report written (/tmp/re-openclaw-e2e-reports/default.json)
```

…and the gate records it as **FAIL**. Either the script exits non-zero after
declaring success, or a later step fails silently and the `[pass]` line is not
the last word.

**This is the most alarming of the six** and the least visible. A suite whose
self-report and exit code disagree can fail while claiming to pass — and the
inverse is what the whole session has been finding. Worth resolving before the
others regardless of how the OpenClaw integration itself is doing.

- **Unfiled.**

---

## E · Genuine, untriaged — 1 test

### E1 · `PE Sensor Registration › RAG signal regions [64:72] are covered by a sensor`

The **last survivor** of the three RAG gates. Its siblings —
`rag_corrective_cycle machine is registered in RE` and `session machines are
registered in RE` — now pass, fixed by the corpus work (#328) that made the
Docker RE mount the selected corpus instead of all 1,328 machines.

This one is a **PE sensor** question, not a corpus one, so the corpus fix was
never going to reach it. The RE holds 27 machines (17 corpus + 10 localAI,
verified by enumeration); whether a *sensor* covers `[64:72]` is a separate
registration path.

- **Unfiled.** The only one of the six that is a plain product question.

---

## Working order

| Step | Why first |
|---|---|
| 1 · **D1** OpenClaw exit-code integrity | A gate that can pass while failing invalidates every other reading |
| 2 · **B1** Manager HTTPS redirect | Unblocks a whole suite and Manager#116's unproven migration |
| 3 · **B2** browser-project decision | One config decision retires 6 failures |
| 4 · **C1** Scala PE readiness | Diagnosis is one isolated run |
| 5 · **E1** RAG sensor region | Genuine product work, needs no harness change |
| 6 · **A1** contracts re-record | Blocked on the quorum shaping conversation |

Steps 1–3 are configuration and reporting; they should move the floor from
28/1 to close to 28/0 without touching a runtime. Steps 4–6 are real work.

## Maintenance

When a category empties, delete it and say what closed it. When the floor moves,
update the header — **a triage file that describes yesterday's floor is worse
than none**, because the schedule is calibrated against it and will report
either everything or nothing.
