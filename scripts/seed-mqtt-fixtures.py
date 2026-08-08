#!/usr/bin/env python3
"""Derive publishable MQTT fixtures from an MQTT mapping registry.

The regression suite's MQTT stage waits for the PE to auto-create sensor
sources, which only happens once messages actually arrive on the mapped
topics. A reachable broker is not enough — it has to be carrying traffic.

The live Yuma broker carries it, but a certification run should not depend on
a third party being up and publishing at the moment the run happens. This
reads the same mapping registry the engines are configured with and emits one
payload per topic, so the fixtures cannot drift away from the mappings: add a
mapping and its field appears here automatically.

Values sit in the middle of each mapping's normalize band, so every reading is
in range and the resulting perceptual value is unremarkable — the stage is
asserting that the pipeline carries a reading, not what the reading says.

Output is one `topic<TAB>payload` line per topic, for a publisher to consume.

    python3 scripts/seed-mqtt-fixtures.py config/mqtt-mappings.yuma.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def midpoint(normalize: dict[str, Any] | None) -> float:
    """A value inside the mapping's declared range."""
    if not isinstance(normalize, dict):
        return 1.0
    lo, hi = normalize.get("min"), normalize.get("max")
    try:
        lo_f, hi_f = float(lo), float(hi)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 1.0
    if hi_f < lo_f:
        lo_f, hi_f = hi_f, lo_f
    value = (lo_f + hi_f) / 2.0
    # Keep integral bands integral so payloads read like real device output.
    return int(value) if float(value).is_integer() else round(value, 3)


def set_pointer(doc: dict[str, Any], pointer: str, value: Any) -> None:
    """Assign into `doc` at an RFC 6901 JSON pointer, creating parents."""
    if not pointer.startswith("/"):
        raise ValueError(f"pointer must start with '/': {pointer!r}")
    parts = [p.replace("~1", "/").replace("~0", "~") for p in pointer.lstrip("/").split("/")]
    node = doc
    for part in parts[:-1]:
        nxt = node.get(part)
        if not isinstance(nxt, dict):
            nxt = {}
            node[part] = nxt
        node = nxt
    node[parts[-1]] = value


def build(mappings_path: Path) -> list[tuple[str, str]]:
    registry = json.loads(mappings_path.read_text(encoding="utf-8"))
    rules = registry.get("mappings") or registry.get("rules") or []

    topics: dict[str, dict[str, Any]] = {}
    skipped: list[str] = []
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        topic = rule.get("topicFilter") or rule.get("topic")
        if not isinstance(topic, str) or not topic:
            continue
        # A wildcard filter matches topics but is not itself publishable.
        if "+" in topic or "#" in topic:
            skipped.append(topic)
            continue
        extract = rule.get("extract")
        if not isinstance(extract, dict):
            extract = {}
        pointer = extract.get("pointer")
        if not isinstance(pointer, str) or not pointer.startswith("/"):
            skipped.append(f"{topic} ({rule.get('id', '?')}: no JSON pointer)")
            continue
        set_pointer(topics.setdefault(topic, {}), pointer, midpoint(rule.get("normalize")))

    for note in skipped:
        print(f"skipped: {note}", file=sys.stderr)

    return [(t, json.dumps(p, separators=(",", ":"), sort_keys=True)) for t, p in sorted(topics.items())]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mappings", type=Path)
    args = parser.parse_args()

    if not args.mappings.is_file():
        print(f"mappings file not found: {args.mappings}", file=sys.stderr)
        return 2

    fixtures = build(args.mappings)
    if not fixtures:
        print(f"no publishable topics in {args.mappings}", file=sys.stderr)
        return 1

    for topic, payload in fixtures:
        print(f"{topic}\t{payload}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
