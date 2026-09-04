#!/usr/bin/env python3
"""Multi-valued output merge transformations — reference implementations and proofs.

The Boolean gates the Reality Engine folds with today are defined over {0,1}. A
multi-valued machine's cells range over an ordered chain, and folding those with
a Boolean gate destroys them (RealityEngine_CI#158).

This file is the specification the three runtimes implement against. Every
transformation here is checked for the properties the fold contract requires,
by exhaustion over the domain rather than by assertion:

  closure     the result is a member of the alphabet — the fold may not invent
              a value no contributor asserted, nor one outside the chain
  symmetry    invariant under permutation of the collection, which carries no
              order
  determinism a pure function of the collection, with no accumulator state and
              no floating-point arithmetic for runtimes to differ over

Idempotence is NOT required and is deliberately not assumed. Meet, join and
median are idempotent; the Łukasiewicz strong operations are not — x ⊕ x
saturates and x ⊙ x extinguishes, which is the point of them. A fold over a
collection is well defined without it as long as the operation is symmetric.

## The chain top, k

The Łukasiewicz operations are defined on a finite chain Ł_(k+1) = {0..k} where
k is absolute truth:

    negation            ¬x = k − x
    strong disjunction  x ⊕ y = min(k, x + y)
    strong conjunction  x ⊙ y = ¬(¬x ⊕ ¬y) = max(0, x + y − k)

so k is a parameter of the transformation, not a constant. It is NOT derivable
from `bitsPerElement`: FallDetection declares 4 bits, which is representable
0..15, but uses the alphabet {0,1,2,3,4}. Folding it with k=15 makes ⊕ a plain
sum that never saturates and ⊙ extinguish almost everything — both useless.
See CHAIN_TOP_IS_UNRESOLVED below; this needs a declaration.

Meet, join and median take no k and are unaffected by the question.

## Efficiency

An optimisation review is expected, so each transformation is written to the
shape the runtimes should implement rather than the shortest expression of it:

    meet, join          single pass, O(n), no allocation, early exit at the
                        chain bound
    strong disjunction  single pass sum, O(n), early exit once k is reached
    strong conjunction  single pass sum, O(n); the threshold k(n−1) is known
                        before the loop
    discrete median     O(n) selection, not O(n log n) sort, and integer-only —
                        floor(median) over integers is exactly the lower middle
                        element, so no float arithmetic enters the step

That last point is a determinism property as much as an efficiency one: an
integer selection cannot differ across runtimes the way a float division could.
"""

from __future__ import annotations
import sys
from pathlib import Path

import itertools
import json
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from event_keys import sequence_events, output_events  # noqa: E402

CORPUS = Path(__file__).resolve().parents[1].parent / "RealityEngine_Machines" / "machines"

# Raised where a decision is needed rather than guessed at.
CHAIN_TOP_IS_UNRESOLVED = (
    "k (chain top) is a property of the machine's alphabet and is not declared "
    "anywhere in the corpus today. bitsPerElement gives the representable range, "
    "not the chain: FallDetection declares 4 bits (0..15) and uses {0..4}."
)


# ── lattice: closed, idempotent, no parameter ────────────────────────────────

def meet(values: list[int]) -> int:
    """Weakest link. Bounded by the lowest contributor; a single 0 vetoes.

    Runtime shape: single pass, early exit at 0 — the chain bottom absorbs.
    """
    out = values[0]
    for v in values[1:]:
        if v < out:
            out = v
            if out == 0:
                break
    return out


def join(values: list[int], k: int | None = None) -> int:
    """Envelope. Bounded by the highest contributor; safety-preserving.

    Runtime shape: single pass, early exit at k when the chain top is known.

    Each read is CLAMPED to k when k is known, and the clamp is load-bearing
    rather than cosmetic. Without it the early exit makes join order-dependent
    for a contribution above the chain: an earlier out-of-chain value stops the
    scan at its own magnitude and a later one is never compared, so
    join([1,3,5], k=3) answered 3 while join([5,3,1], k=3) answered 5 — the same
    collection, two results, which is exactly the property this fold exists to
    guarantee. Found by the LSP implementation, which reproduced the hole
    faithfully rather than silently correcting it.

    The clamp also keeps the result inside the chain, which closure requires. A
    contribution above k is a corpus error; reading it as k is the reading that
    neither fabricates a rung nor lets ordering decide the answer.
    """
    bound = (lambda v: k if (k is not None and v > k) else v)
    out = bound(values[0])
    for v in values[1:]:
        cv = bound(v)
        if cv > out:
            out = cv
            if k is not None and out >= k:
                break
    return out


# ── Łukasiewicz: closed, NOT idempotent, parameterised by k ──────────────────

def strong_disjunction(values: list[int], k: int) -> int:
    """Truncated sum ⊕ — evidence accumulation, saturating at k.

    Several weak independent indicators combine into a strong one:
    1 ⊕ 1 ⊕ 1 = min(3, 3) = 3 on the chain {0..3}.

    Runtime shape: single pass sum with early exit once k is reached.
    """
    total = 0
    for v in values:
        total += v
        if total >= k:
            return k
    return total


def strong_conjunction(values: list[int], k: int) -> int:
    """t-norm ⊙ — strict simultaneous-onset threshold.

    max(0, Σx − k(n−1)). Rises above 0 only on near-unanimous high agreement;
    one absolute disagreement extinguishes it.

    Runtime shape: threshold known before the loop, so a single pass sum
    suffices; no per-pair work.
    """
    threshold = k * (len(values) - 1)
    total = sum(values)
    return total - threshold if total > threshold else 0


# ── statistical: closed, idempotent, no parameter ────────────────────────────

def discrete_median(values: list[int]) -> int:
    """Majority consensus, rejecting anomalous outliers.

    For odd n the middle element. For even n floor(median) — which over
    integers is exactly the lower of the two middle elements, so this is a
    selection and never a division. Keeping it integral is what stops float
    arithmetic entering the step and giving three runtimes three answers.

    Runtime shape: O(n) selection (nth_element / quickselect), not a full sort.
    """
    ordered = sorted(values)
    return ordered[(len(ordered) - 1) // 2]


MV_TRANSFORMS = {
    "meet":               lambda vs, k: meet(vs),
    "join":               lambda vs, k: join(vs, k),
    "strong-conjunction": lambda vs, k: strong_conjunction(vs, k),
    "strong-disjunction": lambda vs, k: strong_disjunction(vs, k),
    "discrete-median":    lambda vs, k: discrete_median(vs),
}

TAKES_CHAIN_TOP = {"join", "strong-conjunction", "strong-disjunction"}
IDEMPOTENT = {"meet", "join", "discrete-median"}


# ── verification ─────────────────────────────────────────────────────────────

def verify(k: int = 3, max_n: int = 5) -> list[str]:
    """Exhaustive over the chain {0..k} for collections up to max_n."""
    alphabet = list(range(k + 1))
    failures = []

    for name, fn in MV_TRANSFORMS.items():
        for n in range(1, max_n + 1):
            for combo in itertools.product(alphabet, repeat=n):
                got = fn(list(combo), k)

                # closure — inside the chain
                if got not in alphabet:
                    failures.append(f"{name}{combo} -> {got} outside chain {alphabet}")
                    continue

                # symmetry — invariant under permutation
                results = {fn(list(p), k) for p in itertools.permutations(combo)}
                if len(results) != 1:
                    failures.append(f"{name}{combo} -> {results} order dependent")

            # idempotence, where claimed
            if name in IDEMPOTENT:
                for x in alphabet:
                    if fn([x] * n, k) != x:
                        failures.append(f"{name} not idempotent at x={x}, n={n}")
    return failures


def verify_off_chain_symmetry(k: int = 3, over: int = 2, max_n: int = 4) -> list[str]:
    """Symmetry must survive contributions ABOVE the chain top.

    The on-chain sweep cannot see this class of defect: where every value is
    <= k, an early exit at k can only fire on a genuine maximum. Feed the same
    fold a value above k and an unclamped early exit stops the scan at whatever
    happened to arrive first — join([1,3,5], k=3) answering 3 and
    join([5,3,1], k=3) answering 5.

    A contribution above k is a malformed corpus rather than normal operation,
    but a fold whose answer depends on arrival order is exactly what three
    runtimes must not have, so it is verified rather than assumed away.
    """
    failures = []
    alphabet = list(range(k + 1 + over))  # deliberately overruns the chain
    for name, fn in MV_TRANSFORMS.items():
        for n in range(1, max_n + 1):
            for combo in itertools.product(alphabet, repeat=n):
                results = {fn(list(p), k) for p in itertools.permutations(combo)}
                if len(results) != 1:
                    failures.append(
                        f"{name}{combo} k={k} -> {results} order dependent off-chain")
    return failures


def verify_lattice_returns_a_contributor(k: int = 3, max_n: int = 4) -> list[str]:
    """Meet, join and median return one of their inputs — they cannot fabricate.

    Stronger than closure: bitwise or of 1 and 2 is 3, inside the chain but
    asserted by nobody. On an ordinal severity ladder that invents a rung.
    """
    failures = []
    alphabet = list(range(k + 1))
    for name in ("meet", "join", "discrete-median"):
        fn = MV_TRANSFORMS[name]
        for n in range(1, max_n + 1):
            for combo in itertools.product(alphabet, repeat=n):
                got = fn(list(combo), k)
                if got not in combo:
                    failures.append(f"{name}{combo} -> {got}, not a contributor")
    return failures


def verify_de_morgan(k: int = 3, max_n: int = 4) -> list[str]:
    """⊙ is the De Morgan dual of ⊕ under ¬x = k − x, as specified."""
    failures = []
    alphabet = list(range(k + 1))
    for n in range(1, max_n + 1):
        for combo in itertools.product(alphabet, repeat=n):
            direct = strong_conjunction(list(combo), k)
            dual = k - strong_disjunction([k - x for x in combo], k)
            if direct != dual:
                failures.append(f"de Morgan fails at {combo}: {direct} != {dual}")
    return failures


def main() -> int:
    print("MULTI-VALUED OUTPUT MERGE TRANSFORMATIONS — verification\n")

    print("1. WORKED EXAMPLES from the specification (chain {0..3}, k=3)")
    print(f"   strong-disjunction [1,1,1]   -> {strong_disjunction([1,1,1], 3)}   "
          f"(three weak indicators accumulate to confirmed)")
    print(f"   strong-conjunction [3,3,2]   -> {strong_conjunction([3,3,2], 3)}   "
          f"(near-unanimous high agreement survives)")
    print(f"   strong-conjunction [3,3,0]   -> {strong_conjunction([3,3,0], 3)}   "
          f"(one absolute disagreement extinguishes)")
    print(f"   discrete-median    [3,3,0,3] -> {discrete_median([3,3,0,3])}   "
          f"(transient dropout filtered)")

    print("\n2. PROPERTIES — exhaustive over chain {0..3}, collections to n=5")
    failures = verify(k=3, max_n=5)
    print(f"   closure + symmetry + idempotence: "
          f"{'ALL HOLD' if not failures else f'{len(failures)} FAILURE(S)'}")
    for f in failures[:5]:
        print(f"      {f}")

    print("\n   non-idempotent by design (this is the point of them):")
    for name in ("strong-disjunction", "strong-conjunction"):
        fn = MV_TRANSFORMS[name]
        ex = [(x, fn([x, x], 3)) for x in (1, 2, 3)]
        print(f"      {name:20} x⊙x / x⊕x: " +
              ", ".join(f"{x}->{y}" for x, y in ex))

    print("\n   off-chain (contributions above k, malformed corpus):")
    fo = verify_off_chain_symmetry(k=3, over=2, max_n=4)
    print(f"   {'ALL HOLD' if not fo else f'{len(fo)} FAILURE(S)'}")
    for f in fo[:3]:
        print(f"      {f}")

    print("\n3. NO FABRICATION — meet, join, median return a contributor")
    ff = verify_lattice_returns_a_contributor(k=3, max_n=4)
    print(f"   {'ALL HOLD' if not ff else f'{len(ff)} FAILURE(S)'}")
    print(f"   contrast, bitwise or [1,2] -> {1|2}  — inside the chain, asserted by nobody")

    print("\n4. DE MORGAN DUALITY — ⊙ = ¬(¬x ⊕ ¬y)")
    fd = verify_de_morgan(k=3, max_n=4)
    print(f"   {'HOLDS' if not fd else f'{len(fd)} FAILURE(S)'}")

    print("\n5. FALLDETECTION — the machine that exposed the problem")
    fall = json.loads((CORPUS / "domains" / "health-personal" / "FallDetection.json")
                      .read_text(encoding="utf-8"))["machine"]
    outs = [o["vector"] for s in fall["sequences"] for v in sequence_events(s)
            for o in output_events(v)]
    col0 = [v[0] for v in outs]
    alphabet = sorted({x for v in outs for x in v})
    print(f"   alphabet in use : {alphabet}   bitsPerElement: "
          f"{fall['perceptualMapping']['bitsPerElement']} (representable 0..15)")
    print(f"   severity ladder : {col0}")
    for k_candidate in (max(alphabet), (1 << fall["perceptualMapping"]["bitsPerElement"]) - 1):
        label = "alphabet max" if k_candidate == max(alphabet) else "representable max"
        row = {n: MV_TRANSFORMS[n](col0, k_candidate) for n in MV_TRANSFORMS}
        print(f"   k={k_candidate:<2} ({label:17}) " +
              "  ".join(f"{n}={row[n]}" for n in
                        ("meet", "join", "strong-conjunction", "strong-disjunction",
                         "discrete-median")))

    print("\n   UNRESOLVED: " + CHAIN_TOP_IS_UNRESOLVED)
    print("   meet, join and discrete-median are unaffected — they take no k.")
    print("   strong-conjunction and strong-disjunction change materially with it.")

    return 1 if (failures or ff or fd or fo) else 0


if __name__ == "__main__":
    raise SystemExit(main())
