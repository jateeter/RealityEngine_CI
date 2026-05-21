# Single Input Transition Assumption

**Date:** 2026-02-27
**Scope:** All example machines in `examples/machines/`

---

## Definition

The **Single Input Transition Assumption** states that between any two consecutive input vectors, at most one element changes value. For binary input spaces this is equivalent to requiring **Hamming distance ≤ 1** between successive inputs.

The assumption is motivated by physical reality: most sensors and digital systems change one signal at a time. Simultaneous multi-signal transitions — e.g., going from `[0,0]` directly to `[1,1]`, or from `[1,0]` directly to `[0,1]` — require all differing bits to switch in the same clock cycle, which is unlikely or ambiguous in physical systems.

**Notation used in this document:**

| Term | Meaning |
|------|---------|
| HD   | Hamming distance — number of positions that differ between two binary vectors |
| `→`  | Consecutive input step transition |
| HD=1 | Single transition (assumption holds) |
| HD≥2 | Multi-transition (assumption violated) |

---

## Summary Table

| Machine | Dimensionality | STA Required? | Defined Sequences Comply? | Violations in Defined Sequences | Behavior on Violation |
|---------|---------------|--------------|--------------------------|-----------------------------------|-----------------------|
| **MultiStep** | 3-bit binary | Yes (intra-sequence) | Mostly — one HD=3 inter-sequence jump | `[0,1,1]→[1,0,0]` in interleaved sequence (HD=3) | Works: inter-sequence jump lands on an always-active initial vector |
| **RSFlipFlop** | 2-bit binary | No | Yes | None | Immune: all vectors are `isInitial`; multi-bit transitions between valid states work correctly |
| **RS2** | 2-bit binary | Yes | Yes | None (but `[1,1]` is present as a reachable state via single transitions) | `[0,0]→[1,1]` (HD=2): no output; `[1,0]→[0,1]` (HD=2): may inadvertently RESET if rs2-reset-01 is pre-seeded |
| **KleeneStar** | 3-bit binary | No (by design) | No — "Zero Repetitions" sequence is HD=2 | `[0,0,1]→[0,1,0]` (HD=2, intentional) | Correct: design specifically accommodates this to represent zero loop iterations |
| **DataCenterMonitoring** | 8D continuous | N/A (not binary) | N/A | N/A — gradual monotonic progression assumed | Threshold comparator (±0.50) provides tolerance for small jumps; large sensor jumps may miss intermediate states |

---

## Machine-by-Machine Analysis

---

### 1. Multi-Step State Machine

**Input space:** 3-bit binary `{0,1}³`
**Sequences:** Seq1 `000→001→011→[0,1]`, Seq2 `100→101→111→[1,0]`

#### Intra-sequence transitions (STA required)

Each sequence's defined path advances one bit at a time:

| Sequence | Step | Transition | HD |
|----------|------|-----------|-----|
| Seq1 | 1→2 | `[0,0,0]→[0,0,1]` | 1 ✓ |
| Seq1 | 2→3 | `[0,0,1]→[0,1,1]` | 1 ✓ |
| Seq2 | 1→2 | `[1,0,0]→[1,0,1]` | 1 ✓ |
| Seq2 | 2→3 | `[1,0,1]→[1,1,1]` | 1 ✓ |

**Why STA is required for intra-sequence steps:** The intermediate vectors (`ms-seq1-001`, `ms-seq2-101`) are non-initial transitional nodes. They are only activated when their predecessor matches. Skipping a step — e.g., jumping `[0,0,0]→[0,1,1]` (HD=2) — deactivates `ms-seq1-001` immediately (no match on `[0,1,1]`), leaving `ms-seq1-011` unactivated. The sequence fails silently.

#### Inter-sequence transitions (STA NOT required)

The "Both Sequences Interleaved" input sequence demonstrates a HD=3 jump between Seq1's final state and Seq2's first state:

```
[0,0,0] → [0,0,1] → [0,1,1] → [1,0,0] → [1,0,1] → [1,1,1]
                                 ↑
                            HD=3 here: [0,1,1] → [1,0,0]
```

This works correctly because `ms-seq2-100` is an **initial vector** (always active). It does not require any predecessor to have fired — it is ready to match `[1,0,0]` regardless of the previous input. Initial vectors are immune to the single-transition assumption.

**Conclusion:** STA is required for traversal *within* a sequence. Between sequences, or when targeting an initial vector from any state, multi-bit transitions are safe.

---

### 2. RS Flip-Flop

**Input space:** 2-bit binary `{S,R}` — representing `[0,0]=HOLD`, `[1,0]=SET`, `[0,1]=RESET`, `[1,1]=FORBIDDEN`
**Sequences:** SET `[1,0]→[1,0]`, RESET `[0,1]→[0,1]` (both single-vector, isInitial)

#### All defined sequences comply with STA

| Sequence | Step | Transition | HD |
|----------|------|-----------|-----|
| SET | 1→2 | `[0,0]→[1,0]` | 1 ✓ |
| RESET | 1→2 | `[0,0]→[0,1]` | 1 ✓ |
| Comprehensive (13-step) | all | always through `[0,0]` | 1 ✓ |

The defined sequences always pass through the `[0,0]` HOLD state between SET and RESET, respecting STA.

#### STA is NOT mechanically required

Both event vectors (`rs-event-10` and `rs-event-01`) are **isInitial** with output vectors. They respond combinatorially on every cycle without any sequencing requirement. This means:

| Transition | HD | Result |
|-----------|-----|--------|
| `[0,0]→[1,0]` | 1 | SET outputs `[1,0]` ✓ |
| `[0,0]→[0,1]` | 1 | RESET outputs `[0,1]` ✓ |
| `[1,0]→[0,1]` | **2** | RESET outputs `[0,1]` ✓ — works correctly |
| `[0,1]→[1,0]` | **2** | SET outputs `[1,0]` ✓ — works correctly |
| `[0,0]→[1,1]` | **2** | No output — `[1,1]` matches neither event |
| `[1,0]→[1,1]` | 1 | No output — forbidden state |
| `[0,1]→[1,1]` | 1 | No output — forbidden state |

The hold-state convention in the defined sequences exists for clarity and physical realism, not because the machine requires it.

#### The `[1,1]` forbidden state

In classical RS flip-flop design, `S=1, R=1` simultaneously is undefined (both outputs would be forced, creating a race condition on deactivation). The Reality Engine representation matches this: `[1,1]` matches neither `rs-event-10` nor `rs-event-01`, so no output is produced. The state is safely ignored. Note that `[1,1]` is reachable via single-bit transitions (`[1,0]→[1,1]` or `[0,1]→[1,1]`) and transitions back via single-bit transitions (`[1,1]→[1,0]` or `[1,1]→[0,1]`).

**Conclusion:** STA is not required. The machine is a pure combinatorial recognizer with no internal state that would be broken by multi-bit transitions between valid inputs.

---

### 3. RS2

**Input space:** 2-bit binary `{S,R}`
**Sequences:** SET `[0,0]→[1,0]→[1,0]`, RESET `[0,0]→[0,1]→[0,1]` (two-step, initial node then final node)

#### All defined sequences comply with STA

| Sequence | Step | Transition | HD |
|----------|------|-----------|-----|
| SET | 1→2 | `[0,0]→[1,0]` | 1 ✓ |
| RESET | 1→2 | `[0,0]→[0,1]` | 1 ✓ |
| Complete test (8-step) | all | see below | all ≤1 ✓ |

Complete test sequence transitions:

```
[0,0]→[1,0]→[0,0]→[0,1]→[0,0]→[1,0]→[1,1]→[0,1]
  HD:   1     1     1     1     1     1     1
```

All transitions are HD=1. The `[1,1]` state is reached by a single-bit transition from `[1,0]` (only `R` changes), and the final `[1,1]→[0,1]` is also HD=1. This is the "undefined input" test case: after `[1,1]` invalidates both successors, the subsequent `[0,1]` produces no output because `rs2-reset-01` was deactivated by `[1,1]` and cannot be re-seeded without a prior `[0,0]`.

#### STA IS required for reliable operation

Unlike RSFlipFlop, RS2 has **sequential** (non-initial) final vectors. The output is only produced when:
1. An initial vector (`rs2-set-00` or `rs2-reset-00`) matches `[0,0]`, seeding a successor
2. That successor then matches `[1,0]` or `[0,1]`

Violation scenarios:

| Transition | HD | Result |
|-----------|-----|--------|
| `[0,0]→[1,0]` | 1 | SET output `[1,0]` ✓ (normal) |
| `[0,0]→[0,1]` | 1 | RESET output `[0,1]` ✓ (normal) |
| `[0,0]→[1,1]` | **2** | No output — `[1,1]` matches neither successor |
| `[1,0]→[0,1]` | **2** | May inadvertently RESET if `rs2-reset-01` is pre-seeded from a prior `[0,0]` step; otherwise no output |
| `[0,1]→[1,0]` | **2** | May inadvertently SET if `rs2-set-10` is pre-seeded; otherwise no output |

**The `[1,1]` undefined state:** Reached via HD=1 transitions, it invalidates all active successors (both `rs2-set-10` and `rs2-reset-01` see a no-match on `[1,1]` and deactivate). Recovery requires a subsequent `[0,0]` to re-seed them. This behavior is explicitly tested in the machine's complete test sequence.

**Note on `[1,0]→[0,1]` (HD=2):** Both successors are seeded after every `[0,0]`. If `rs2-reset-01` is active when `[0,1]` arrives directly from `[1,0]`, it will match and produce RESET output — even though no explicit hold state was presented. This is a subtle cross-contamination that only occurs when both successors happen to be active simultaneously, which is always true after any `[0,0]` step.

**Conclusion:** STA is required. Without it, the machine may produce unintended outputs (`[1,0]→[0,1]` triggering RESET) or fail to produce intended outputs (`[0,0]→[1,1]` silently discarding the intent).

---

### 4. Kleene Star Operator

**Input space:** 3-bit binary `{0,1}³` (using only the low 3 bits of the perceptual mapping region)
**Sequences:** Seq1 `(001)+(000)*(010)→[0,1]`, Seq2 `(010)+(000|001)*(001)→[1,0]`

**Notation:** `(X)+` = one-or-more X (Kleene plus, A*A for isInitial triggers), `(X)*` = zero-or-more X (Kleene star on non-initial loop body), `(A|B)` = alternation, adjacency = concatenation. The trigger states `001` (Seq1) and `010` (Seq2) are `isInitial` and therefore implement A*A = A+: at least one match of the trigger is required before the loop body and terminal become active.

#### Defined sequences — STA compliance

| Sequence | Transition | HD | Notes |
|----------|-----------|-----|-------|
| Seq1 Zero-Reps | `[0,0,1]→[0,1,0]` | **2** | Intentional — (001)+ trigger arms (010) directly; zero (000)* iterations |
| Seq1 Two-Reps step 1 | `[0,0,1]→[0,0,0]` | 1 ✓ | |
| Seq1 Two-Reps step 2 | `[0,0,0]→[0,0,0]` | 0 ✓ | Same vector repeated |
| Seq1 Two-Reps step 3 | `[0,0,0]→[0,1,0]` | 1 ✓ | |
| Seq2 Alternation step 1 | `[0,1,0]→[0,0,0]` | 1 ✓ | |
| Seq2 Alternation step 2 | `[0,0,0]→[0,0,1]` | 1 ✓ | |
| Seq2 Alternation step 3 | `[0,0,1]→[0,0,1]` | 0 ✓ | Same vector repeated |
| Combined step 1 | `[0,0,1]→[0,0,0]` | 1 ✓ | |
| Combined step 2 | `[0,0,0]→[0,1,0]` | 1 ✓ | |

#### STA is NOT required — by design

The "Zero Repetitions" sequence `[0,0,1]→[0,1,0]` is **intentionally** HD=2. It is not a bug or oversight; it is the canonical demonstration of what "zero iterations of the Kleene star" means: the `000*` loop body is never entered, and the input transitions directly from the trigger `001` to the terminal `010`.

This works correctly because after `[0,0,1]` fires (the `(001)+` trigger — isInitial, A*A = A+, at least one match required), it activates **both** successors simultaneously: `kleene-seq1-000` (loop body) and `kleene-seq1-010` (terminal). When `[0,1,0]` arrives immediately — skipping `[0,0,0]` entirely — `kleene-seq1-010` is already active and matches, producing output `[0,1]`.

The two-bit jump between `001` and `010` is meaningful: these vectors are distinct recognition patterns, not "adjacent states" in a Gray-code sense. The machine operates on what was observed, not on how many bits changed.

**Semantic interpretation:** In the Kleene star model, the transition from the triggering event to the terminal event can skip any number of loop iterations — including zero. The Hamming distance between these vectors is irrelevant to the correctness of the pattern match. Only the temporal ordering of observed vectors matters.

**Conclusion:** STA does not apply. KleeneStar is designed for **pattern-sequence recognition**, not state-machine traversal. Multi-bit transitions between non-adjacent patterns are explicitly correct and documented.

---

### 5. Data Center Monitoring

**Input space:** 8-dimensional continuous `[0.0, 1.0]⁸`
**Sequences:** Thermal Overload (5-step, Normal→Warm→Hot→Critical→Emergency)

#### STA concept does not apply directly

The single-transition assumption is defined for **binary** input spaces where Hamming distance is well-defined. For continuous vectors, the analogous concept is **monotonic progression** — each sensor reading advances by a bounded amount per step.

The machine uses THRESHOLD comparators with wide tolerance (±0.50). This means a single vector can span a large range of values:

```
Vector "Normal":    [≈0.25, ≈0.30, ≈0.28, ≈0.38, ≈0.35, ≈0.45, ≈0.38, ≈0.05]
Vector "Emergency": [≈0.96, ≈0.99, ≈0.97, ≈0.98, ≈0.97, ≈0.98, ≈0.97, ≈0.48]
```

The defined "Gradual Degradation" sequence (12 steps) uses monotonically increasing sensor readings — each step advances all metrics by a small amount. This is analogous to the STA: one "degree of concern" at a time.

However, because the threshold is ±0.50, a sensor reading that jumps significantly (e.g., from 0.25 to 0.95) could still match an intermediate state. The wide threshold is a deliberate design choice to handle noisy sensor environments, not a violation of any assumption.

**What a violation means here:** If a system jumped from "Normal" directly to "Emergency" values in a single step, the intermediate states (Warm, Hot, Critical) would be missed — their initial vectors would not have been activated and the sequence would not progress. Unlike binary machines, there is no crisp HD boundary; tolerance depends on the threshold values configured.

**Conclusion:** STA is not directly applicable. The continuous-space analog — **gradual monotonic progression** — is assumed. The defined sequences are compliant. The wide threshold (±0.50) provides natural tolerance for bounded sensor jumps.

---

## Design Implications

### When the assumption holds (MultiStep, RS2)

These machines are explicitly designed around sequential state traversal. The initial vectors are "always listening" nodes, but intermediate nodes require their predecessors to have fired. Designers using these machines should:

- Ensure input sequences advance one dimension at a time
- Use a "hold" or "idle" state (e.g., `[0,0]` for RS2) as a base from which transitions originate
- Understand that multi-bit jumps will silently fail to advance the sequence

### When the assumption does not hold (RSFlipFlop, KleeneStar)

These machines tolerate or require multi-bit transitions:

- **RSFlipFlop**: All vectors are isInitial. There is no "memory" of past inputs. It is safe and correct to jump `[1,0]→[0,1]` directly.
- **KleeneStar**: The zero-repetition case requires jumping from a trigger pattern to a terminal pattern across a HD=2 boundary. Enforcing STA would make zero-repetition semantics impossible to express.

### The isInitial property as the key determinant

The fundamental distinction is whether a vector is `isInitial`:

| Vector type | Deactivates on no-match? | Requires predecessor? | STA required? |
|------------|--------------------------|----------------------|--------------|
| `isInitial` | No | No | No |
| Transitional (no output) | Yes | Yes | Yes |
| Final (has output) | Yes | Yes | Yes |

Machines composed entirely of `isInitial` vectors (RSFlipFlop) are immune to STA violations. Machines with multi-step chains (MultiStep, RS2) require STA within those chains.

### The A*A = A+ rule for isInitial vectors

Although `isInitial` vectors never deactivate (providing the `A*` self-loop), they only activate their `nextVectorIds` **when they match**. This means:

> **All `isInitial` vectors with `nextVectorIds` implement `A+ (= A*A)`, not `A*`.**

The `A*` part is the self-loop — the vector remains active indefinitely and re-arms successors on every match. The mandatory `A` is the match that first activates successors. Zero occurrences of the initial state would leave successors permanently inactive.

This distinction matters for documenting CES regular expression patterns:

| Incorrect notation | Correct notation | Reason |
|-------------------|-----------------|--------|
| `A* → B+ → C`    | `A+ → B+ → C`  | At least one A match is required to arm B |
| `NORMAL* → WARM+` | `NORMAL+ → WARM+` | WARM cannot become active without a NORMAL match |
| `SAFE(isInitial)` | `SAFE+`         | At least one SAFE match is needed to produce output |
| `(001)* (000)* (010)` | `(001)+ (000)* (010)` | The trigger 001 must fire at least once to arm 000 and 010 |

The exception is a non-initial loop body like `(000)*` in KleeneStar: `000` is **not** isInitial; it is activated by the `(001)+` trigger which also simultaneously activates the terminal. Because both loop body and terminal are armed by the trigger, `000` can genuinely have zero occurrences. The `*` on the loop body is correct.

---

## Input Sequence Compliance Summary

### Sequences with Hamming distance > 1 (binary machines only)

| Machine | Sequence Name | Transition | HD | Intent |
|---------|--------------|-----------|-----|--------|
| **MultiStep** | Both Sequences Interleaved | `[0,1,1]→[1,0,0]` | **3** | Intentional: Seq1 complete → Seq2 initial (initial vector absorbs any jump) |
| **KleeneStar** | Sequence 1: Zero Repetitions | `[0,0,1]→[0,1,0]` | **2** | Intentional: (001)+ trigger directly arms (010) terminal — (000)* loop body skipped with zero iterations |

All other defined input sequences for all machines use HD ≤ 1 between consecutive steps.

---

## Test Coverage

The behavioral differences documented above are verified in:

```
src/__tests__/MultiStepRSInterconnection.test.ts
  → RS2: "[1,0] without prior [0,0] produces NO output"
  → RS2: "[1,1] input invalidates both successors"
  → RS2: "RS2 CAN SET after Seq2 if a [0,0] hold step intervenes"
  → RSFlipFlop: all defined comprehensive sequence steps verified
  → RSFlipFlop: "output region [6:8] is correctly bounded"

src/__tests__/CriticalEventSequence.test.ts
  → KleeneStar: "should produce output for one-rep Kleene trace 001→000→010"
```

---

*Document authored: 2026-02-27*
