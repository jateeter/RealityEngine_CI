"""The observability contract: every probe point is an API, uniform across engines.

An observer of any aspect of the universe must see the same thing regardless of
which engine produced it or how that engine represents things internally. That
is a property of the *surface*, not of a comparison script — so these rules
apply at every probe point (`/api/state`, `/api/sources`, the push response,
the metrics and semantic surfaces), not only where a parity stage happens to
look.

Three rules, and one thing they are not:

* **Identity is filtered.** An engine-minted id is a representation detail
  leaking through an API. Two observers must not see different values for the
  same observation because two runtimes number things differently.
* **Ordering follows the governing schema.** Uniform presentation is part of
  the API. Nothing here sorts: a runtime that presents the same information in
  a different order has broken the contract, and the comparison must say so.
* **Key sets must match.** `uniformity_violations` measures where they do not.
  A key one engine emits and another omits is a violation to be reported, not
  a difference to be intersected away silently.

Not covered: whether the engines *behave* the same. That is the trajectory
comparison over ISRE/OSRE histories, which needs none of this — vectors carry
no names.

Identity filtering, specifically:

Parity asks whether the runtimes *behave* the same. It has repeatedly been
answered with whether they *name* things the same, which they never do and
never will.

The corpus declares no machine `id`. A machine JSON carries `name`,
`perceptualMapping`, and `sequences`; the id is minted by whichever runtime
loaded it:

    cpp     machine-1787062353690-303854695
    lsp     machine-1U358SX-92K0WAA239X2
    scala   machine-1787062353802-dad8e19e

Three formats, three namespaces, generated independently per process. Any
comparison that reaches a `machineId` therefore reports divergence
unconditionally — on run 20260818T141002Z it split cpp, lsp and scala three
ways on all five events while cpp and lsp were, once identity was stripped,
byte-identical (jateeter/RealityEngine_CI#145).

Sequence and vector ids are the opposite case: the corpus declares them
(`agx-001-urgent-stabilize`, `agx-001-normal`), so they are stable across
runtimes and are the right handle for saying *which* sequence fired. They are
kept deliberately.

What this module does NOT cover: response *shape*. Whether an engine emits a
`dispatch` key at all is a contract question, owned by
`regression-pe-step-contract.py` and `pe-api-equivalence.spec.ts`. Mixing the
two is what let a shape divergence masquerade as a behavioural one.
"""

from __future__ import annotations

from typing import Any

# Minted by the runtime that produced the payload — different on every engine
# for the same corpus and the same event, by construction.
ENGINE_LOCAL_KEYS = frozenset(
    {
        # Machine identity. The corpus declares none; each runtime invents one.
        "machineId",
        "machine_id",
        "machineID",
        # Bare `id` is ambiguous — a corpus vector declares one, and so does a
        # PE source and a Scala push response. Stripped, because the corpus
        # meanings survive under their explicit names below and the runtime
        # meanings do not survive comparison at all.
        "id",
        "sourceId",
        "instanceId",
        "runId",
        "pushId",
        "dispatchId",
        "envelopeId",
        "correlationId",
        "requestId",
        "sessionId",
        # Wall clock and per-process counters.
        "timestamp",
        "createdAt",
        "updatedAt",
        "lastUpdated",
        "generatedAt",
        "startedAt",
        "finishedAt",
        "uptime",
        "uptimeMs",
        "pid",
        # How many pushes this engine has served — a property of the engine's
        # history, not of the event under test.
        "globalStep",
        "stepNumber",
    }
)

# Intermediate surfaces in the RE -> PE(arbitration) -> PE(input space) flow.
#
# Excluded from parity, and for a different reason from identity: these are
# private algorithms that are a focus of learning in the deployed environment
# and are expected to change and morph during training. Holding three runtimes
# to byte equality on a surface that is meant to evolve independently would
# make the parity gate an obstacle to the thing it is supposed to protect.
#
# The exclusion is narrow on purpose. Everything the flow *produces* — the
# assembled input space, the active regions, the event bus writes, the machine
# results — is a public surface and is held to the full contract below.
INTERMEDIATE_SURFACE_KEYS = frozenset({"mergeBatch"})

# Units of measure, explicit or implied, are part of the contract and must
# never be filtered: an engine reporting a region length in cells against one
# reporting bytes is a divergence, not a naming difference. Listed so that
# adding a key to ENGINE_LOCAL_KEYS that carries a unit is an obvious mistake.
UNIT_BEARING_KEYS = frozenset(
    {"offset", "length", "bitsPerElement", "values", "elements", "region", "dimension"}
)

# Corpus-declared identity: stable across runtimes and worth comparing. Listed
# so the intent is explicit rather than implied by absence from the set above.
CORPUS_DECLARED_KEYS = frozenset(
    {
        "machineName",
        "sequenceId",
        "sequenceName",
        "vectorId",
        "outputVectorId",
        "name",
    }
)

def strip_engine_identity(value: Any, extra_keys: frozenset[str] | None = None) -> Any:
    """Recursively drop engine-local keys, keeping everything else.

    A filter rather than a whitelist: whitelisting is how the previous
    signature ended up comparing `machineId` and nothing else useful — the
    kept-key list happened to include an identity and exclude the region
    offsets that carry the actual behaviour.
    """
    drop = (ENGINE_LOCAL_KEYS | (extra_keys or frozenset())) - UNIT_BEARING_KEYS

    if isinstance(value, dict):
        return {k: strip_engine_identity(v, extra_keys) for k, v in value.items() if k not in drop}
    if isinstance(value, list):
        return [strip_engine_identity(v, extra_keys) for v in value]
    return value


def shared_keys(payloads: dict[str, Any]) -> set[str]:
    """Top-level keys every payload carries, in canonical event spelling.

    Canonicalised first (#220 layer 2): a runtime part-way through the rename
    emits `inputEvent` where its peers still emit `inputVector`, and comparing
    the raw spellings would report the migration as an asymmetric key set.
    """
    dicts = [p for p in payloads.values() if isinstance(p, dict)]
    if not dicts:
        return set()
    common = set(dicts[0])
    for d in dicts[1:]:
        common &= set(d)
    return common


def shape_only_keys(payloads: dict[str, Any]) -> dict[str, list[str]]:
    """Keys some runtimes emit and others do not, per runtime.

    Reported, never compared. cpp emits `dispatch`; lsp emits `valuesPacked`
    inside each merge record; scala emits a top-level `id`. Those are contract
    questions — whether a runtime is *required* to emit the key — and answering
    them inside a behavioural comparison is what made a missing optional field
    look like a behavioural divergence.

    The rule this implements is SURFACE_SPEC.md, "The observable boundary":
    byte equivalence is a property of the observable interface, and internal
    augmentation is filtered at that boundary rather than replicated across
    runtimes. Cited rather than restated — this function arrived at the right
    behaviour locally, before the rule was written down anywhere, and
    `valuesPacked` was filed as a defect (RealityEngine_CI#208) by a reader who
    had this comment and no contract to check it against.
    """
    common = shared_keys(payloads)
    extras: dict[str, list[str]] = {}
    for name, payload in payloads.items():
        if isinstance(payload, dict):
            # Canonical spelling, matching `common` — otherwise a runtime that
            # has completed the #220 rename reports every renamed key as an
            # extra, and one that has not reports every old key as an extra.
            only = sorted(set(payload) - common)
            if only:
                extras[name] = only
    return extras


def uniformity_violations(payloads: dict[str, Any]) -> list[str]:
    """Where the observability contract is broken, as gate-ready findings.

    `shape_only_keys` reports the raw asymmetry; this states it as violations,
    because under "every probe point is an API" a key that only some engines
    emit is a defect rather than a difference to accommodate. Kept separate
    from the value comparison so a shape break is never reported as a
    behavioural one.
    """
    extras = shape_only_keys(payloads)
    others = sorted(payloads)
    return [
        f"{name} emits {key!r}, absent from " + ", ".join(o for o in others if o != name)
        for name, keys in sorted(extras.items())
        for key in keys
    ]


def parity_signature(payload: Any, keys: set[str] | None = None) -> Any:
    """One runtime's comparable behaviour: identity removed, everything else intact.

    Ordering is preserved deliberately. Content, ordering, and units of measure
    are all part of the contract, so a runtime that emits the same regions in a
    different order has diverged and the comparison must say so. An earlier
    draft sorted `activeRegions` to make cpp and lsp agree; that hid a real
    three-way ordering divergence rather than reporting it.

    `keys` restricts the top level to what every compared runtime emits; pass
    `shared_keys(payloads)`.
    """
    value = payload
    if isinstance(value, dict):
        value = {k: v for k, v in value.items() if k not in INTERMEDIATE_SURFACE_KEYS}
        if keys is not None:
            value = {k: v for k, v in value.items() if k in keys}
    return strip_engine_identity(value)


def corpus_identity(machine: dict[str, Any]) -> str | None:
    """The handle a machine is comparable by across runtimes: its name."""
    return machine.get("name") or machine.get("machineName")


def machine_domains(names: list[str]) -> dict[str, int]:
    """Machine counts per corpus domain, derived from `domains/<domain>/` paths.

    Machine validation across engines is a question about the corpus — which
    domains loaded and how many machines each holds — and is answerable without
    touching a single runtime-minted id.
    """
    counts: dict[str, int] = {}
    for name in names:
        parts = str(name).replace("\\", "/").split("/")
        domain = parts[parts.index("domains") + 1] if "domains" in parts[:-1] else "core"
        counts[domain] = counts.get(domain, 0) + 1
    return counts
