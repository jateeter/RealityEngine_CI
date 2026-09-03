"""One definition of a defined starting state (RealityEngine_CI#211).

`POST {pe}/api/reset` is layer-local: it resets the Perception Engine and does
not touch the Reality Engine's Critical Event Sequence state, its ISRE/OSRE
histories or its step counter. That is the settled contract — every runtime
already implements it, and a PE that reached into the RE would make reset a
cross-service side effect on a surface whose rule is that the PE does not own
the RE. See SURFACE_SPEC.md, "Reset is layer-local".

The consequence is that **a defined starting point costs two calls, and the
obligation is the caller's**. Resetting one half leaves the other holding
whatever earlier traffic armed, and a stage that then compares runtimes is
comparing accumulated history rather than a defined start:

* A PE-only reset produced an apparent 6-event step-0 divergence across three
  runtimes, six of them `isInitial: false`. After a full reset all three agreed
  exactly, with zero non-initial events active — which is the contract. The
  whole divergence was residue (#211).
* The mirror case is just as costly and was live in this repo: stages that reset
  the RE and left PE run state alone, so `globalStep`, the persistent vector and
  the test cursors carried over between stages.

Stated once here because it was previously restated in three stages and omitted
in two, which is how the asymmetry survived. Mirrors `parity_identity.py`: the
rule lives in one place and every probe point applies it.

No HTTP of its own — the caller passes its poster, so this stays testable
without a live universe and each stage keeps its own timeouts and error shape.
"""

from __future__ import annotations

from typing import Any, Callable, Iterable

# (status, payload) — the shape every regression stage's poster already returns.
Poster = Callable[[str, Any], tuple[int, Any]]


def reset_pair(
    post: Poster,
    re_url: str | None,
    pe_url: str | None,
    label: str,
) -> list[str]:
    """Return the engine to a defined starting state. Returns failure strings.

    Both halves are attempted even when the first fails: a partial reset is
    worth reporting in full, and stopping at the first error would leave the
    caller unable to tell "the RE refused" from "the RE refused and so did the
    PE". A missing url is reported rather than skipped silently — a stage that
    thinks it reset and did not is the exact failure this module exists to
    prevent.
    """
    failures: list[str] = []

    if re_url:
        status, _ = post(f"{re_url}/api/engine/reset", {})
        if not 200 <= status < 300:
            failures.append(f"{label}: POST /api/engine/reset returned {status}")
    else:
        failures.append(f"{label}: no re_url — RE state was not reset")

    if pe_url:
        status, _ = post(f"{pe_url}/api/reset", {})
        if not 200 <= status < 300:
            failures.append(f"{label}: POST /api/reset returned {status}")
    else:
        failures.append(f"{label}: no pe_url — PE run state was not reset")

    return failures


def reset_instances(
    post: Poster,
    instances: Iterable[dict[str, Any]],
    re_key: str = "re",
    pe_key: str = "pe",
    id_key: str = "id",
) -> list[str]:
    """`reset_pair` across a registry listing. Returns every failure string.

    The url keys are parameters because the stages disagree on them — the
    registry calls them `re_url`/`pe_url` and the parity modules carry them as
    `re`/`pe`. Renaming either would be a wider change than this contract needs.
    """
    failures: list[str] = []
    for instance in instances:
        failures.extend(
            reset_pair(
                post,
                instance.get(re_key),
                instance.get(pe_key),
                str(instance.get(id_key, "<unidentified>")),
            )
        )
    return failures
