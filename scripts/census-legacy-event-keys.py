#!/usr/bin/env python3
"""Census of surviving legacy Reality Event key spellings across the workspace.

RealityEngine_CI#220 layer 1c removes the dual-accept. Every site listed here is
one that stops working when it does, so this is the gate on 1c rather than a
report about it.

Classification matters more than the count. A `vectors` in a Qdrant collection
body or a URL segment is not ours; a `vectors` in a corpus fixture is.
"""
from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path("/Users/johnt/workspace/GitHub")

REPOS = [
    "RealityEngine_CI", "RealityEngine_Manager", "RealityEngine_Machines",
    "RealityEngine_CPP", "RealityEngine_LSP", "RealityEngine_Scala",
    "localAIStack", "localOpenClawStack", "localHealthkitBridge",
]

# The four keys layer 1 renames, as they appear in source.
KEYS = ["outputVectorIds", "outputVectors", "nextVectorIds", "vectors"]
# Only key-shaped occurrences: a quoted key, a property access, an object-literal
# key, or a subscript. A bare identifier named `vectors` is a local variable and
# has nothing to do with the schema.
_K = r"(?:outputVectorIds|outputVectors|nextVectorIds|vectors)"
KEY_RE = re.compile(
    rf'"{_K}"'          # "vectors"
    rf"|'{_K}'"         # 'vectors'
    rf"|\.{_K}\b"       # .vectors
    rf"|\b{_K}\s*:"     # vectors:   (object literal / type decl)
)

CODE_EXT = {".py", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".scala", ".lisp",
            ".cpp", ".hpp", ".h", ".sh", ".json", ".yml", ".yaml", ".swift"}

SKIP_DIRS = {"node_modules", ".git", "dist", "build", "target", "__pycache__",
             ".regression-tests", "playwright-report", "test-results", "venv",
             ".venv", "quicklisp", "bin", "obj", "coverage", ".next",
             # Vendored SwiftPM dependencies. swift-crypto ships RFC "test
             # vectors" — cryptographic, nothing to do with this schema.
             ".build", "checkouts", "Pods", "Carthage"}


# ── Is the name bound by the program, or carried by the data? ─────────────
#
# This is the distinction the census exists to draw, and it is not about
# spelling. A site breaks when the corpus is renamed only if the name travels in
# the JSON.
#
#   corpus key          the data carries it. Renaming the corpus breaks this
#                       site. Layer 1c gates on exactly these.
#   internal identifier the source declares it. Renaming the corpus does not
#                       touch it, because nothing outside the file knows the name.
#
# The decisive signal is quoting. **A JSON key has to be quoted to be read** —
# in Python, TypeScript, Scala, Lisp and C++ alike, data is reached through a
# string. So in a CODE file an unquoted occurrence is an identifier the program
# bound: `if not vectors:`, `s.vectors`, `changes.outputVectors`,
# `tr.outputVectors`. In a DATA file (.json, .yaml) the same token unquoted is a
# key, because there is no program there to bind anything.
#
# Why this rule was added: the census reported all 65 surviving sites as
# "ACTIVE: source". None of them was migration work — they are local variables,
# struct members, a Scala field already typed `Map[String, RealityEvent]`, the
# schema clause that *forbids* the old key, and the rename script's own mapping
# table. Reported that way the count cannot fall as the migration completes, so
# a reader concludes it stalled. A diagnostic that overstates its findings gets
# ignored, and this one gates a rename whose failure mode is silent.

DATA_EXT = {".json", ".yaml", ".yml"}

# Reaching a key through a string, in each language here. Evidence that the name
# came from the data and not from the source.
DATA_ACCESS_RE = re.compile(
    rf"""(?:\.get|\.at|\[|jget|jbool|jstring|jnumber|downField|hcursor|json::|"""
    rf"""getOrElse|as\[)[^\n]{{0,24}}["']{_K}["']"""
)

# A compound identifier is a different word: `vectorsAdded`, `storeVectors`,
# `allVectors`, `outputVectorId`. Renaming the corpus has no bearing on them.
COMPOUND_RE = re.compile(rf"\w{_K}|{_K}\w")

QUOTED_KEY_RE = re.compile(rf"""["']{_K}["']""")

# Prose that happens to contain the word, inside a string meant for a human.
PROSE_SINK_RE = re.compile(r"\becho\b|console\.log|print\(|printf|puts\b|format\b")


def is_internal_identifier(rel: str, line: str) -> bool:
    """True when the program binds this name rather than the data carrying it."""
    ext = Path(rel).suffix
    if ext in DATA_EXT:
        return False              # no program here; every key is data
    if DATA_ACCESS_RE.search(line):
        return False              # reached through a string: it came from the data
    if COMPOUND_RE.search(line) and not QUOTED_KEY_RE.search(line):
        return True               # a different word entirely
    return not QUOTED_KEY_RE.search(line)


def classify(repo: str, rel: str, line: str) -> str:
    """What kind of site this is — which decides whether 1c must touch it."""
    low = line.lower()
    p = rel.lower()

    # The schema names the old keys in order to REJECT them (1c tightening:
    # `"not": {"required": ["vectors"]}`). Removing these would remove the gate.
    if p.startswith("schemas/"):
        return "GATE: schema rejects the old key"

    # The migration tooling has to name the old keys in order to act on them:
    # the rename script's mapping table, and this census's own KEYS list and
    # regex. Including this file, which scans the tree it lives in and would
    # otherwise report itself as four sites of outstanding migration work — a
    # diagnostic counting its own definition of what it looks for.
    if "rename-corpus-event-keys" in p or "census-legacy-event-keys" in p:
        return "MIGRATION TOOL: the mapping itself"

    # Things that are not ours, in any spelling.
    if "qdrant" in low or "vectorstore" in p or ('"vectors"' in line and "distance" in low):
        return "NOT-OURS: Qdrant collection schema"
    if "pathprefix" in low or "path(segment" in low or "/vectors" in line:
        return "NOT-OURS: URL segment"
    if "std::vector" in line or "vector<" in low or "vector[double]" in low:
        return "NOT-OURS: language type"
    # The perceptual-simulation configure/chunk payload is a list of NUMERIC
    # vectors, not CES events. It is spelled the same and is a different thing.
    if ("configure/chunk" in low or "to_numbers" in low
            or "vector[vector[double]]" in low
            or "simulationconfigurechunk" in low
            or "chunk" in low                      # CHUNK_BODY, the chunk payload
            or ("openapi" in p and "vectors" in low)):
        return "NOT-OURS: numeric universal-input vectors"

    # Human-readable text that happens to contain the word.
    if PROSE_SINK_RE.search(line) and QUOTED_KEY_RE.search(line) is None:
        return "PROSE (correctly untouched)"

    # Already tolerant — these read both spellings today.
    if any(t in line for t in ("at_either", "jget-either", "sequence_events",
                               "sequenceEvents", "output_events", "outputEvents(",
                               "next_event_ids", "nextEventIds(", "event_keys",
                               "eventKeys", ".orElse(")):
        return "TOLERANT (delete at 1c)"

    # Prose inside a JSON string VALUE, e.g. "eventSpace": "3D binary vectors:
    # 000-111". The corpus is full of this and it is exactly what the path-aware
    # rewrite protected; a text sweep would have destroyed it.
    if re.search(r'"\s*:\s*"[^"]*\bvectors\b', line):
        return "PROSE (correctly untouched)"

    # Prose.
    stripped = line.strip()
    if stripped.startswith(("*", "//", "#", ";", "--", "/*")) or '"""' in line:
        return "COMMENT/DOC"

    # Bound by the program, not carried by the data. Checked last among the
    # substantive rules so a more specific verdict above always wins.
    if is_internal_identifier(rel, line):
        return "INTERNAL IDENTIFIER (rename-independent)"

    kind = "corpus fixture" if any(s in p for s in ("test", "spec", "e2e", "fixture")) else "source"
    if repo == "RealityEngine_Machines" and p.startswith("machines/"):
        kind = "CORPUS DATA"
    return f"ACTIVE: {kind}"


def main() -> int:
    rows = []
    for repo in REPOS:
        base = ROOT / repo
        if not base.is_dir():
            print(f"(missing repo: {repo})", file=sys.stderr)
            continue
        for path in base.rglob("*"):
            if not path.is_file() or path.suffix not in CODE_EXT:
                continue
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            if not KEY_RE.search(text):
                continue
            rel = str(path.relative_to(base))
            for n, line in enumerate(text.splitlines(), 1):
                if KEY_RE.search(line):
                    rows.append((repo, rel, n, classify(repo, rel, line), line.strip()[:160]))

    by_class: dict[str, list] = defaultdict(list)
    for r in rows:
        by_class[r[3]].append(r)

    print("=" * 78)
    print("LEGACY REALITY EVENT KEY CENSUS — gate on RealityEngine_CI#220 layer 1c")
    print("=" * 78)
    for cls in sorted(by_class, key=lambda c: (-len(by_class[c]), c)):
        print(f"\n{cls}   ({len(by_class[cls])} lines)")
        per_repo: dict[str, int] = defaultdict(int)
        for repo, *_ in by_class[cls]:
            per_repo[repo] += 1
        for repo, n in sorted(per_repo.items(), key=lambda kv: -kv[1]):
            print(f"    {repo:26} {n:6}")

    print("\n" + "=" * 78)
    print("ACTIVE SITES — these are what 1c must convert")
    print("=" * 78)
    for cls in sorted(c for c in by_class if c.startswith("ACTIVE")):
        print(f"\n### {cls}")
        per_file: dict[tuple[str, str], int] = defaultdict(int)
        for repo, rel, *_ in by_class[cls]:
            per_file[(repo, rel)] += 1
        for (repo, rel), n in sorted(per_file.items(), key=lambda kv: (-kv[1], kv[0])):
            print(f"  {n:4}  {repo}/{rel}")

    Path("census.json").write_text(json.dumps(
        [{"repo": r, "file": f, "line": n, "class": c, "text": t} for r, f, n, c, t in rows],
        indent=2))
    print(f"\n\nfull detail written to census.json ({len(rows)} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
