#!/usr/bin/env python3
"""Write an arbitration registry that forces one rule across every contended cell.

Parity across the arbiter is only demonstrated for rules that actually run. The
corpus registry declares:

    entries: 2837    rules: PRECEDENCE 2835, SEVERITY 2
                     withinRank: (none) 2569, SEVERITY 268

so a regression run exercises two of the seven rules every runtime implements,
and `regression-arbiter.py` covers the same two as fixtures. `OR`, `MAX`, `AND`,
`MIN` and `MEAN` have never been compared across C++, LSP and Scala in any lane.

`MEAN` is the one to worry about. It is the only rule that combines
contributions arithmetically rather than selecting one of them, so it is the
only rule whose result depends on summation order and floating-point
associativity — three languages, three sets of arithmetic. C++ sorts
contributions into a canonical order before summing precisely because of this
and says so in `resolve_cell`. Whether the other two sort the same way has never
been tested, and a discrepancy there would be invisible under every rule that
picks a winner.

The variant keeps the cell set and the provider ranks of the real registry and
changes only the rule, so a sweep exercises the arbiter over the same contention
the corpus actually produces rather than a synthetic fixture. Point all three
engines at the output with ARBITRATION_REGISTRY, boot, and compare ISRE/OREV.

    arbitration-registry-variant.py --rule MEAN \
        --source ../RealityEngine_Machines/domains/arbitration-registry.json \
        --out /tmp/arbitration-MEAN.json

`--within-rank` sets the PRECEDENCE sub-policy, which is a separate axis: under
PRECEDENCE the rule that breaks a tie among equally-ranked contributors is
`withinRank`, and MIN/AND and MAX/OR there are likewise unexercised.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

# Must match ARBITER_RULES in regression-trajectory-parity.py. Both are written
# out rather than shared, because a runtime missing a rule is what the sweep is
# looking for and a single derived list would let that define itself away.
RULES = ("PRECEDENCE", "OR", "MAX", "AND", "MIN", "SEVERITY", "MEAN")
WITHIN_RANKS = ("", "SEVERITY", "MIN", "AND", "MAX", "OR")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, required=True,
                        help="the corpus arbitration registry to derive from")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--rule", required=True, choices=RULES)
    parser.add_argument("--within-rank", default=None, choices=WITHIN_RANKS,
                        help="PRECEDENCE tie-break policy; unset leaves the "
                             "source's own value")
    args = parser.parse_args()

    if not args.source.is_file():
        print(f"FAIL arbitration registry not found: {args.source}", file=sys.stderr)
        return 2
    try:
        doc = json.loads(args.source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL arbitration registry unreadable at {args.source}: {exc}", file=sys.stderr)
        return 2

    entries = doc.get("entries")
    if not isinstance(entries, list) or not entries:
        print(f"FAIL {args.source} declares no entries — nothing to force a rule over",
              file=sys.stderr)
        return 2

    for entry in entries:
        entry["rule"] = args.rule
        if args.within_rank is not None:
            # An empty withinRank means "no sub-policy", which is how the
            # engines read a missing key. Write it rather than deleting so the
            # variant states the choice.
            entry["withinRank"] = args.within_rank

    doc["entries"] = entries
    doc["generatedBy"] = "arbitration-registry-variant.py"
    doc["forcedRule"] = args.rule
    if args.within_rank is not None:
        doc["forcedWithinRank"] = args.within_rank
    doc["derivedFrom"] = str(args.source)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(doc, indent=2, sort_keys=True), encoding="utf-8")
    within = f" withinRank={args.within_rank!r}" if args.within_rank is not None else ""
    print(f"wrote {args.out}: {len(entries)} cells forced to {args.rule}{within}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
