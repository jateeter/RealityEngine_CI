#!/usr/bin/env python3
"""corpus-vector-dimension — the perceptual space a corpus actually requires.

Prints max(offset + length) over every region in every machine, floored at the
engine default of 7680.

WHY IT IS ITS OWN FILE
----------------------
Starting an engine with a perceptual space smaller than the corpus needs does
not raise: the machines that map outside the space simply fail to load, and the
runtime reports a short machine count. That count is indistinguishable from a
loader defect, so a sweep that did not size the space first reports a capacity
problem as a parity failure.

`scripts/claude.md` states the rule directly — "machines mapping outside the
space are reported as a capacity class, never as a parity verdict" — and
`test-corpus-parity-loop.sh` computes the same number inline for the same
reason. Two copies of a number that decides whether a result is a defect or a
misconfiguration is one copy too many, so it lives here and both call it.

At the corpus as it stands the answer is 16944, against an engine default of
7680: every full-corpus run needs this, not just the loop.

Usage:
    scripts/lib/corpus-vector-dimension.py <machines-root>
"""

from __future__ import annotations

import json
import pathlib
import sys

ENGINE_DEFAULT = 7680


def required_dimension(root: pathlib.Path) -> int:
    required = ENGINE_DEFAULT
    for path in root.rglob("*.json"):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            # A machine that will not parse is the schema gate's finding, not
            # this script's. Sizing the space is not the place to fail on it.
            continue
        stack = [doc]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                if "offset" in node and "length" in node:
                    try:
                        required = max(required, int(node["offset"]) + int(node["length"]))
                    except (TypeError, ValueError):
                        pass
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)
    return required


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: corpus-vector-dimension.py <machines-root>", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    if not root.is_dir():
        print(f"corpus-vector-dimension: no such directory: {root}", file=sys.stderr)
        return 1
    print(required_dimension(root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
