#!/usr/bin/env python3
"""Lattice fold for multi-valued machines — does Meet/Join work before we build it?

A multi-valued machine's cells range over an ordered alphabet rather than {0,1},
and the Boolean gates the Reality Engine folds with today are not defined over
one. Folding FallDetection's outputs with them flattens every value above 1 to
1 and destroys the machine (RealityEngine_CI#158).

This is the evidence step, run before any engine is changed. It answers three
questions about lattice-based symmetric merging over the machine that exposed
the problem:

  1. Is the fold closed over the machine's own alphabet?
  2. Is it symmetric — invariant under permutation of the collection?
  3. Would every runtime compute the same value from the same collection?

Meet and Join are the lattice-theoretic minimum and maximum. Both are
commutative, associative and idempotent, so a fold over an unordered collection
is well defined, and both return one of their inputs, so the result is a member
of the alphabet by construction rather than by a range check.

That last property is the one that separates this from the bitwise
generalisation proposed in #158. Bitwise `or` of 1 and 2 is 3 — a value neither
contributor asserted. For an ordinal severity ladder, where 1 is "stumble" and 2
is "sustained instability", inventing 3 ("impact recovered") is not a merge, it
is a fabrication. Meet and Join cannot do this.
"""

from __future__ import annotations

import itertools
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from event_keys import sequence_events, output_events  # noqa: E402

CORPUS = Path(__file__).resolve().parents[1].parent / "RealityEngine_Machines" / "machines"
FALL = CORPUS / "domains" / "health-personal" / "FallDetection.json"


# ── the candidate folds ───────────────────────────────────────────────────────

def fold_boolean(vectors, gate="or"):
    """What the engines do today. Defined over {0,1} only."""
    if not vectors:
        return None
    n = len(vectors)
    width = max(len(v) for v in vectors)
    out = []
    for i in range(width):
        k = sum(1 for v in vectors if i < len(v) and v[i] != 0)
        on = {"or": k >= 1, "and": k == n, "xor": k % 2 == 1,
              "nor": k == 0, "nand": k < n}[gate]
        out.append(1 if on else 0)
    return out


def fold_bitwise(vectors, gate="or", bits=4):
    """The generalisation proposed in #158. Closed over the *representable*
    range, not over the alphabet the machine actually uses."""
    if not vectors:
        return None
    mask = (1 << bits) - 1
    width = max(len(v) for v in vectors)
    out = []
    for i in range(width):
        vals = [int(v[i]) if i < len(v) else 0 for v in vectors]
        acc = vals[0]
        for v in vals[1:]:
            acc = {"or": acc | v, "and": acc & v, "xor": acc ^ v,
                   "nor": acc | v, "nand": acc & v}[gate]
        if gate in ("nor", "nand"):
            acc = (~acc) & mask
        out.append(acc)
    return out


def fold_lattice(vectors, gate="join"):
    """Lattice Meet and Join over the machine's alphabet.

    join = max — the envelope: the highest severity any contributor asserts.
    meet = min — the weakest link: the level every contributor agrees on.

    Both return one of their inputs, so the alphabet is preserved by
    construction. Absent cells contribute nothing rather than a zero: a
    contributor that is shorter than its peers has not asserted "0" there, it
    has not spoken, and treating silence as the bottom of the lattice would let
    a short vector veto a Meet.
    """
    if not vectors:
        return None
    width = max(len(v) for v in vectors)
    op = max if gate == "join" else min
    out = []
    for i in range(width):
        present = [int(v[i]) for v in vectors if i < len(v)]
        out.append(op(present) if present else 0)
    return out


# ── the machine under test ────────────────────────────────────────────────────

def fall_detection_outputs():
    machine = json.loads(FALL.read_text(encoding="utf-8"))["machine"]
    outs = []
    for sequence in machine["sequences"]:
        for vector in sequence_events(sequence):
            for output in output_events(vector):
                outs.append((sequence["id"], vector["id"], output["vector"]))
    return machine, outs


def main() -> int:
    machine, outs = fall_detection_outputs()
    if not outs:
        raise SystemExit("FallDetection declares no output vectors")
    bits = machine["perceptualMapping"]["bitsPerElement"]
    alphabet = sorted({v for _, _, vec in outs for v in vec})

    print("FallDetection — the machine that exposed the problem")
    print(f"  bitsPerElement declared : {bits}  (representable 0..{(1 << bits) - 1})")
    print(f"  alphabet actually used  : {alphabet}")
    print(f"  matchAlgorithm          : {machine.get('matchAlgorithm')}")
    print("  potential outputs, one per completed Reality Event:")
    for sid, vid, vec in outs:
        print(f"      {sid:28} {vid:20} -> {vec}")

    vectors: list[list[int]] = [vec for _, _, vec in outs]

    def folded(fn, *args) -> list[int]:
        """Non-empty by construction here; None is the empty-collection case."""
        out = fn(*args)
        assert out is not None
        return out

    # 1 — closure over the alphabet the machine actually uses.
    print("\n1. CLOSURE — is every folded value a member of the machine's alphabet?")
    for label, result in (("boolean or", folded(fold_boolean, vectors, "or")),
                          ("bitwise or", folded(fold_bitwise, vectors, "or", bits)),
                          ("lattice join (max)", folded(fold_lattice, vectors, "join")),
                          ("lattice meet (min)", folded(fold_lattice, vectors, "meet"))):
        inside = all(v in alphabet for v in result)
        note = ""
        if label == "bitwise or":
            invented = sorted({v for v in result if v not in alphabet})
            if invented:
                note = f"  <- invents {invented}, asserted by no contributor"
        if label == "boolean or":
            note = "  <- flattens every value above 1"
        print(f"   {label:20} -> {str(result):12} in alphabet: {inside}{note}")

    # 2 — symmetry, checked by exhaustion rather than asserted.
    print("\n2. SYMMETRY — is the fold invariant under permutation of the collection?")
    for gate in ("join", "meet"):
        results = {tuple(folded(fold_lattice, list(p), gate)) for p in itertools.permutations(vectors)}
        print(f"   lattice {gate:5} over all {len(list(itertools.permutations(vectors)))} "
              f"orderings -> {len(results)} distinct result(s): "
              f"{'invariant' if len(results) == 1 else 'ORDER DEPENDENT'}")

    # Idempotence and associativity, the properties symmetry rests on.
    print("\n   underlying binary operation:")
    for name, op in (("meet (min)", min), ("join (max)", max)):
        idem = all(op([x, x]) == x for x in alphabet)
        comm = all(op([x, y]) == op([y, x]) for x in alphabet for y in alphabet)
        assoc = all(op([x, op([y, z])]) == op([op([x, y]), z])
                    for x in alphabet for y in alphabet for z in alphabet)
        closed = all(op([x, y]) in alphabet for x in alphabet for y in alphabet)
        print(f"      {name:11} idempotent={idem} commutative={comm} "
              f"associative={assoc} closed={closed}")

    # 3 — determinism across runtimes reduces to determinism of the function.
    print("\n3. CROSS-RUNTIME AGREEMENT")
    print("   The fold is a pure function of the collection. Given the same")
    print("   collection, three runtimes computing min/max agree by definition —")
    print("   there is no ordering, no accumulator state and no floating-point")
    print("   arithmetic for them to differ over. What remains to be shown live")
    print("   is that the collections themselves agree; that is an engine")
    print("   property, not a property of this fold.")

    # What the divergence actually looked like, and what each fold would present.
    print("\n4. THE FAILING CELL — sweep halted at #691, cell 1941 (output index 0)")
    print("   cpp-1 and lsp-1 reported 2.0 there; scala-1 reported 0.0.")
    print("   Output index 0 is an ordinal severity ladder:")
    ladder = {0: "nominal / intentional-lying", 1: "stumble recovered",
              2: "sustained instability", 3: "impact recovered",
              4: "confirmed fall / slow collapse"}
    for level in sorted(ladder):
        print(f"      {level} = {ladder[level]}")
    print("\n   Folding that ladder:")
    col0 = [[vec[0]] for vec in vectors]
    print(f"      contributors        : {[c[0] for c in col0]}")
    print(f"      boolean or          : {folded(fold_boolean, col0, 'or')[0]}   "
          f"— 'some fall signal', severity destroyed")
    print(f"      bitwise or          : {folded(fold_bitwise, col0, 'or', bits)[0]}   "
          f"— a level nobody asserted")
    print(f"      lattice join (max)  : {folded(fold_lattice, col0, 'join')[0]}   "
          f"— highest severity asserted, safety-preserving")
    print(f"      lattice meet (min)  : {folded(fold_lattice, col0, 'meet')[0]}   "
          f"— level all contributors agree on")

    print("\nCONCLUSION")
    print("  Meet and Join are closed over the machine's alphabet, symmetric by")
    print("  exhaustion, and idempotent/commutative/associative over it. Join is")
    print("  the safety-preserving reading for an ordinal severity ladder: a")
    print("  confirmed fall is not diluted by a concurrent nominal reading.")
    print("  Neither Boolean nor bitwise folding is admissible here — one")
    print("  destroys the ladder, the other invents rungs on it.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
