// Reading machine structure while the Reality Event rename is in flight.
//
// RealityEngine_CI#220 layer 1 renames the keys that describe a machine's event
// structure, in the corpus and in every engine response that echoes one:
//
//     vectors         -> events
//     outputVectors   -> outputEvents
//     nextVectorIds   -> nextEventIds
//     outputVectorIds -> outputEventIds
//
// The corpus moved in layer 1b (RealityEngine_Machines#105). The engines' emitted
// spelling moves in the same wave as this module. Readers here accept both, and
// layer 1c deletes the module when the tolerance retires.
//
// Why this exists: these reads fail silently. Every one is a `?? []`, so a
// reader looking for a key that is no longer there does not throw — it gets an
// empty array and produces a well-formed, wrong answer. The corpus rewrite
// landed with this repository's tooling unconverted and six standalone corpus
// readers went quiet at once, each ready to report a clean corpus with nothing
// in it.
//
// There is a Python twin at `scripts/lib/event_keys.py`; keep them in step.

const asArray = (value) => (Array.isArray(value) ? value : []);

// Canonical spelling first, legacy second, empty array last. Always an array,
// so callers do not repeat an Array.isArray guard.
const either = (node, canonical, legacy) => {
  if (!node || typeof node !== 'object') return [];
  return asArray(node[canonical] ?? node[legacy]);
};

/** The events of a critical event sequence. */
export const sequenceEvents = (sequence) => either(sequence, 'events', 'vectors');

/** The output events a Reality Event fires when it matches. */
export const outputEvents = (event) => either(event, 'outputEvents', 'outputVectors');

/** The ids of the events this one arms. */
export const nextEventIds = (event) => either(event, 'nextEventIds', 'nextVectorIds');

/** The ids of the events in a sequence that carry outputs. */
export const outputEventIds = (sequence) => either(sequence, 'outputEventIds', 'outputVectorIds');
