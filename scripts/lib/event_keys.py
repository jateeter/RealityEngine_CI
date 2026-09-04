"""Reading machine structure while the Reality Event rename is in flight.

RealityEngine_CI#220 layer 1 renames the three keys that describe a machine's
event structure, in the corpus and in every engine response that echoes one:

    vectors        -> events
    outputVectors  -> outputEvents
    nextVectorIds  -> nextEventIds
    outputVectorIds -> outputEventIds

The corpus moved in layer 1b (RealityEngine_Machines#105). The engines' emitted
spelling moves in the same wave as this module. Readers here accept both, and
layer 1c deletes the module when the tolerance retires.

## Why this exists at all

Because these reads fail silently. Every one of them is a `.get()` with an
empty default, so a reader looking for a key that is no longer there does not
raise — it gets an empty list and produces a well-formed, wrong answer.

That is not a hypothetical. The corpus rewrite landed with this repository's
tooling unconverted, and six standalone corpus readers went quiet at once:
`ces-sta-check`, `ces-diff`, `cesgen-contracts`, `cesgen-oracles`,
`backfill-governance` and `migrate-bits-per-element` would each have reported a
clean corpus with nothing in it. `RealityEngine_Machines` hit the same thing one
layer earlier, where a generator silently emptied `semantic-bus-registry.json`
of 1276 lines while reporting success.

There is a JavaScript twin at `scripts/lib/eventKeys.mjs`; keep them in step.
"""
from __future__ import annotations

from typing import Any

__all__ = ["sequence_events", "output_events", "next_event_ids", "output_event_ids"]


def _as_list(value: Any) -> list:
    return value if isinstance(value, list) else []


def _either(node: Any, canonical: str, legacy: str) -> list:
    """Canonical spelling first, legacy second, empty list last.

    Always a list, so callers do not repeat an isinstance guard — and note that
    an empty result is indistinguishable from a genuinely empty machine, which
    is exactly why corpus-load counts get compared before and after any change
    that touches these keys.
    """
    if not isinstance(node, dict):
        return []
    value = node.get(canonical)
    return _as_list(value if value is not None else node.get(legacy))


def sequence_events(sequence: Any) -> list:
    """The events of a critical event sequence."""
    return _either(sequence, "events", "vectors")


def output_events(event: Any) -> list:
    """The output events a Reality Event fires when it matches."""
    return _either(event, "outputEvents", "outputVectors")


def next_event_ids(event: Any) -> list:
    """The ids of the events this one arms."""
    return _either(event, "nextEventIds", "nextVectorIds")


def output_event_ids(sequence: Any) -> list:
    """The ids of the events in a sequence that carry outputs."""
    return _either(sequence, "outputEventIds", "outputVectorIds")
