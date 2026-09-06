#!/usr/bin/env python3
"""Cross-runtime parity for `POST /api/engine/process` — RealityEngine_CI#254 item 3.

This route is documented as processing all currently active Reality Events across
the universe, and until this stage **nothing compared it across runtimes**. That
absence is not a gap in coverage; it is how two separate defects survived, and
both were found by hand rather than by the suite:

  Scala walked SEQUENCES instead of machines, returning per-sequence
  `assertedOutputs` tagged with `sequenceId` — a different response shape, with
  its arbiters never running on this route (RealityEngine_Scala#92 territory,
  fixed in jateeter/RealityEngine_Scala#95's predecessor).

  C++ walked the SERVER REGISTRY, whose machine copies carry
  `transitionsInhibited`, so every machine returned "matched nothing" and the
  route could never emit an output. On the corpus, LSP returned 167 outputs and
  Scala 167; C++ returned **0** — and #254's own table called C++ "the reference
  implementation for iteration". It iterated correctly; every machine refused to
  transition.

A route that returns a well-formed empty result is indistinguishable from a
universe where nothing fired, which this corpus produces routinely. Only a
comparison finds it. Hence this stage.

WHAT IT ASSERTS

  count parity     every runtime emits the same NUMBER of outputs for one input.
                   This alone separates 0 from 167 and is the check that would
                   have caught both defects above on the day they landed.

  value parity     the resolved output vectors agree as a MULTISET, after engine
                   identity is stripped. Order is deliberately not compared.

                   What this response exists to establish is that the runtimes
                   interned the same machines and produced the same results from
                   them. The sequence carries none of that: it is whatever each
                   runtime's container or sort happened to yield — C++ and LSP
                   read a map keyed by a filename-derived id, Scala sorts by
                   (domain, name, id) because its own ids are a timestamp and a
                   UUID. A receiver that cares about order sorts on arrival,
                   which costs it nothing and costs three engines a shared
                   canonical key they would otherwise have to agree on and
                   maintain.

                   An earlier revision compared the ordered sequence and failed
                   on exactly that difference. It was measuring the runtimes'
                   internal iteration, not their agreement.

  inhibition parity
                   every runtime reports the same `transitionsInhibited` state
                   for the same machine set. The flag is not on the wire and the
                   response carries no error either way, so a runtime whose
                   default differs answers the same request with zero outputs
                   instead of many and looks exactly like a universe in which
                   nothing fired (SURFACE_SPEC, `transitionsInhibited`).

  non-vacuity      agreement on zero is a pass ONLY when the runtimes also agree
                   they were inhibited — then zero is the correct answer and
                   parity holds. Otherwise three runtimes independently returned
                   nothing, which is the vacuous pass this stage exists to
                   prevent, and it is reported as a failure.

  universal application
                   the route accepts a Universal Reality Event and decomposes it,
                   each machine receiving the slice at its own
                   perceptualMapping.input (SURFACE_SPEC, "The input may be
                   universal or machine-space, and length says which").

                   This was a recorded probe rather than a gate while the
                   behaviour was missing: all three read `body["vector"]` and
                   passed it to every machine, so a universal event matched
                   nothing and returned empty everywhere — consistent, therefore
                   not a parity failure, and filed as RealityEngine_CI#267. That
                   landed, so it is gated now.

                   The stimulus is the corpus's own: each machine's first
                   `inputSequences` step written at that machine's input offset.
                   A zero vector would not do — it fires nothing, so gating on it
                   would assert that nothing happens, which is what the route did
                   when it was broken.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any
from urllib import error, request

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from parity_identity import strip_engine_identity  # noqa: E402
from reset_contract import reset_instances  # noqa: E402


def post(url: str, body: dict[str, Any], timeout: int = 300) -> tuple[int, Any]:
    """(status, payload) — the shape every regression stage's poster returns.

    reset_contract.Poster is typed to it, and returning the bare payload here
    made reset_instances raise `not enough values to unpack` before a single
    comparison ran.
    """
    payload = json.dumps(body).encode("utf-8")
    req = request.Request(url, data=payload,
                          headers={"Content-Type": "application/json"}, method="POST")
    try:
        with request.urlopen(req, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read().decode("utf-8"))
        except Exception:
            return exc.code, None


def declared_dimension(re_url: str, timeout: int = 30) -> int | None:
    """The runtime's own space width, from GET /api/runtime/vector-space.

    Asked rather than assumed. Length is what selects decomposition, so a
    stimulus built to the wrong width is not a universal event at all — it is an
    ordinary machine-space call that matches nothing and returns zero outputs.
    That is indistinguishable from the #267 defect this stage gates on, so a
    hardcoded width can fail the lane for a bug that is not there. It did: the
    default was 16944 against a corpus whose space is 16934.
    """
    try:
        with request.urlopen(f"{re_url}/api/runtime/vector-space", timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (error.URLError, OSError, ValueError):
        return None
    value = payload.get("dimension")
    return value if isinstance(value, int) else None


def load_instances(registry_path: Path) -> list[dict[str, str]]:
    """RE/PE base URLs per runtime, from the runtime registry.

    Reads snake_case with a camelCase fallback, matching the other stages:
    the registry writes `re_url`/`pe_url` and regression-service-inventory.py
    re-emits it camelCased.
    """
    document = json.loads(registry_path.read_text(encoding="utf-8"))
    out = []
    for instance in document.get("instances", []):
        re_url = instance.get("re_url") or instance.get("reUrl") or ""
        pe_url = instance.get("pe_url") or instance.get("peUrl") or ""
        if not re_url:
            continue
        out.append({"id": instance.get("id") or instance.get("instanceId") or re_url,
                    "re_url": re_url.rstrip("/"), "pe_url": pe_url.rstrip("/")})
    return out


def outputs_of(response: Any) -> list[Any]:
    """The route wraps its payload as {result: {...}} on every runtime."""
    result = response.get("result") if isinstance(response, dict) else None
    body = result if isinstance(result, dict) else response
    outputs = body.get("outputs") if isinstance(body, dict) else None
    return outputs if isinstance(outputs, list) else []


def signature(outputs: list[Any]) -> list[Any]:
    """Order-independent comparison key: the output vectors as a sorted multiset.

    Sorted here so the comparison is over CONTENT rather than over each
    runtime's iteration order — the receiver's sort, done once in the harness.
    Duplicates are kept: two machines legitimately presenting the same vector is
    a different result from one machine presenting it, and a set would lose that.

    `id` is minted per runtime and `timestamp` is wall clock, so both differ by
    construction and comparing them would report divergence on every run.
    """
    return sorted(json.dumps(strip_engine_identity(o).get("vector"), sort_keys=True)
                  for o in outputs)


def universal_stimulus(machines_root: Path, dimension: int) -> list[float]:
    """A universal vector that actually fires machines, from the corpus itself.

    Each machine's first `inputSequences` step, written at that machine's
    declared input offset. That is the corpus stating how it expects to be
    driven, so the stimulus stays correct as the corpus changes rather than
    encoding a fixture here.
    """
    vector = [0.0] * dimension
    # Scoped to `machines/`, not the repo root: the root also holds package.json,
    # generated registries and manifests, some of which are arrays rather than
    # objects. Scanning everything and calling .get on the result raises on the
    # first one.
    corpus = machines_root / "machines" if (machines_root / "machines").is_dir() else machines_root
    for path in sorted(corpus.rglob("*.json")):
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            continue
        if not isinstance(document, dict):
            continue
        machine = document.get("machine")
        if not isinstance(machine, dict):
            continue
        mapping = (machine.get("perceptualMapping") or {}).get("input") or {}
        offset, length = mapping.get("offset"), mapping.get("length")
        sequences = machine.get("inputSequences") or []
        if offset is None or not length or not sequences:
            continue
        steps = sequences[0].get("events") or []
        if not steps:
            continue
        for index, value in enumerate(steps[0][:length]):
            if offset + index < dimension:
                try:
                    vector[offset + index] = float(value)
                except (TypeError, ValueError):
                    continue
    return vector


def cluster(values: dict[str, Any]) -> str:
    """`a+b | c` — which runtimes agreed with which, for the failure line."""
    groups: dict[str, list[str]] = {}
    for name, value in values.items():
        groups.setdefault(json.dumps(value, sort_keys=True), []).append(name)
    return " | ".join("+".join(sorted(members)) for members in groups.values())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--vector", default="1,1,1,1",
                        help="machine-space stimulus, comma separated. The default "
                             "matches the widest input region in the corpus and "
                             "fires 167 machines.")
    parser.add_argument("--universal-dimension", type=int, default=None,
                        help="override the universal stimulus width. Default: ask each "
                             "runtime via /api/runtime/vector-space, since length is what "
                             "selects decomposition and a wrong width silently degrades "
                             "the probe into an ordinary machine-space call")
    parser.add_argument("--machines", type=Path, required=True,
                        help="RealityEngine_Machines root — the universal stimulus is "
                             "built from the corpus's own inputSequences")
    args = parser.parse_args()

    instances = load_instances(args.registry)
    report: dict[str, Any] = {"status": "passed", "instances": [i["id"] for i in instances],
                              "counts": {}, "inhibited": {}, "failures": [], "universalProbe": {}}
    if len(instances) < 2:
        report["failures"].append(
            f"parity needs at least two runtimes; the registry lists {len(instances)}")
        report["status"] = "failed"
        args.out.write_text(json.dumps(report, indent=2))
        print("\n".join(report["failures"]), file=sys.stderr)
        return 1

    stimulus = [float(v) for v in args.vector.split(",") if v.strip()]

    # Reset both halves on every runtime so the comparison starts from one
    # state. reset_contract owns what a reset means; restating it here is how
    # the pair got out of step in five other stages.
    # The url keys are passed explicitly: reset_instances defaults to `re`/`pe`,
    # which the parity modules use, while this stage carries the registry's own
    # `re_url`/`pe_url`. Defaulting would silently reset nothing — `.get` on a
    # missing key returns None and reset_pair treats that as "no half to reset".
    report["failures"].extend(
        reset_instances(post, instances, re_key="re_url", pe_key="pe_url"))

    signatures: dict[str, Any] = {}
    for instance in instances:
        try:
            _status, response = post(f"{instance['re_url']}/api/engine/process", {"vector": stimulus})
        except (error.URLError, OSError, ValueError) as exc:
            report["failures"].append(f"{instance['id']}: /api/engine/process failed: {exc}")
            continue
        outputs = outputs_of(response)
        report["counts"][instance["id"]] = len(outputs)
        signatures[instance["id"]] = signature(outputs)

    # Inhibition state, read rather than inferred.
    #
    # `transitionsInhibited` is not on the step wire and an inhibited machine
    # reports no error, so its effect is invisible in the response: a runtime
    # that inhibits where the others do not returns zero outputs and looks like
    # a universe in which nothing fired. The only way to tell is to ask.
    for instance in instances:
        # Read from /api/engine/config, which SURFACE_SPEC declares as THE
        # pathway for runtime controls. A runtime that answers 404 there has not
        # implemented the control, which is a conformance fact rather than a
        # transport error — recorded as `reported: 0` so it shows up in the
        # split check below rather than as an exception.
        try:
            with request.urlopen(
                f"{instance['re_url']}/api/engine/config/transitionsInhibited",
                timeout=300,
            ) as response:
                control = json.loads(response.read().decode("utf-8"))
        except error.HTTPError as exc:
            if exc.code == 404:
                report["inhibited"][instance["id"]] = {"total": 0, "inhibited": 0, "reported": 0}
            else:
                report["inhibited"][instance["id"]] = f"error: {exc}"
            continue
        except (error.URLError, OSError, ValueError) as exc:
            report["inhibited"][instance["id"]] = f"error: {exc}"
            continue
        value = control.get("value") or {}
        report["inhibited"][instance["id"]] = {
            "total": len(value),
            "inhibited": sum(1 for v in value.values() if v is True),
            "reported": len(value),
            # The declared default travels with the control, so a runtime that
            # holds a different one is caught here rather than through its
            # effects on some later output count.
            "default": control.get("default"),
            "scope": control.get("scope"),
        }

    # The defaults must agree, and that is checked directly rather than deduced
    # from output counts (SURFACE_SPEC, `transitionsInhibited`).
    states = {k: v for k, v in report["inhibited"].items() if isinstance(v, dict)}
    if len(states) > 1:
        # The DECLARED default and scope must agree before the values can mean
        # anything: two runtimes reporting 0 inhibited out of 1328 agree on
        # nothing if one of them defaults to true.
        declared = {k: (v.get("default"), v.get("scope"))
                    for k, v in states.items() if v["reported"] > 0}
        if len(set(declared.values())) > 1:
            report["failures"].append(
                f"runtimes disagree on the declared default or scope of "
                f"transitionsInhibited {declared}: {cluster(declared)}")

        shapes = {k: (v["inhibited"], v["total"]) for k, v in states.items()}
        if len(set(shapes.values())) > 1:
            report["failures"].append(
                f"runtimes disagree on how many machines are inhibited {shapes}: "
                f"{cluster(shapes)}")
        # A runtime that never reports the field has not implemented it. That is
        # a conformance gap even when its behaviour happens to match, because
        # nothing then holds it to the default.
        #
        # Fails on a SPLIT, not on all-absent. While no runtime reports the flag
        # there is nothing to compare and failing would make this a stage that is
        # red on every run — which is a stage everyone learns to ignore, and the
        # reason regression-reset-contract.py is deliberately unwired until its
        # contract lands. The moment one runtime implements it the split appears
        # and this arms itself, which is the point at which the comparison starts
        # being able to say something.
        missing = [k for k, v in states.items() if v["reported"] == 0 and v["total"] > 0]
        if missing and len(missing) == len(states):
            report["inhibitionReporting"] = (
                "no runtime reports transitionsInhibited; the default cannot be gated "
                "until at least one does (SURFACE_SPEC, `transitionsInhibited`)")
        if missing and len(missing) != len(states):
            report["failures"].append(
                f"runtimes do not all report transitionsInhibited; absent on {missing}. "
                "The contract requires every runtime to implement it and default it "
                "to false — a default that is not reported is not gated.")

    counts = report["counts"]
    if counts and len(set(counts.values())) > 1:
        report["failures"].append(
            f"runtimes disagree on how many outputs the route produces {counts}: "
            f"{cluster(counts)}")
    elif counts and set(counts.values()) == {0}:
        # Zero is the CORRECT answer when every machine reached is inhibited —
        # `true` means accept the event and do not pass it forward, so no
        # transitions and no outputs is conformant, not broken. Agreement on
        # zero is therefore a pass in exactly that case, and a vacuous pass in
        # every other. The response cannot tell them apart, so read the flag.
        inhibited = report["inhibited"]
        known = {k: v for k, v in inhibited.items() if isinstance(v, dict)}
        if known and all(v.get("total", 0) > 0 and v["inhibited"] == v["total"]
                         for v in known.values()) and len(known) == len(counts):
            report["zeroExplainedBy"] = "every machine inhibited on every runtime"
        else:
            report["failures"].append(
                "every runtime returned 0 outputs and they are not all inhibited "
                f"{inhibited} — the stimulus fired nothing, so this run proves no "
                "parity. Check the stimulus is machine-space and matches a corpus "
                "input region.")

    if len(signatures) > 1 and len({json.dumps(s, sort_keys=True) for s in signatures.values()}) > 1:
        report["failures"].append(
            f"runtimes agree on output count but not on the output VALUES "
            f"(compared order-independently, so this is a genuine content "
            f"difference): {cluster(signatures)}")

    # Universal application — gated, since RealityEngine_CI#267 landed.
    #
    # Width comes from the runtimes themselves unless overridden. Two runtimes
    # that disagree about how wide the space is cannot be given one stimulus that
    # is universal to both, so that disagreement is reported as itself rather
    # than surfacing later as a mysterious count difference.
    dimensions = {i["id"]: declared_dimension(i["re_url"]) for i in instances}
    report["declaredDimension"] = dimensions
    if args.universal_dimension is not None:
        width = args.universal_dimension
    else:
        known = {d for d in dimensions.values() if d is not None}
        if len(known) > 1:
            report["failures"].append(
                f"runtimes declare different space widths {dimensions}: no single vector "
                "is universal to all of them")
        if not known:
            report["failures"].append(
                "no runtime reported a dimension on /api/runtime/vector-space; the "
                "universal probe cannot be built, and a guessed width would test nothing")
        width = min(known) if known else 0

    universal = universal_stimulus(args.machines, width) if width else []
    for instance in instances:
        if not universal:
            report["universalProbe"][instance["id"]] = "skipped: no declared width"
            continue
        try:
            _status, response = post(f"{instance['re_url']}/api/engine/process", {"vector": universal})
            report["universalProbe"][instance["id"]] = len(outputs_of(response))
        except (error.URLError, OSError, ValueError) as exc:
            report["universalProbe"][instance["id"]] = f"error: {exc}"

    probe = {k: v for k, v in report["universalProbe"].items() if isinstance(v, int)}
    if probe and set(probe.values()) == {0}:
        # The failure #267 described: a universal event decomposed by nobody,
        # every machine compared against a vector thousands of cells wider than
        # its input region, and a well-formed empty result. Agreement on zero
        # here is agreement that the route ignores the shape it exists to take.
        report["failures"].append(
            f"every runtime returned 0 outputs for a UNIVERSAL vector {probe} — the "
            "route is not decomposing it (SURFACE_SPEC, \"The input may be universal "
            "or machine-space\"; RealityEngine_CI#267)")
    elif len(set(probe.values())) > 1:
        report["failures"].append(
            f"runtimes disagree on how many outputs a universal vector produces "
            f"{probe}: {cluster(probe)}")

    if report["failures"]:
        report["status"] = "failed"

    args.out.write_text(json.dumps(report, indent=2))
    print(f"engine-process parity: {report['status']}  counts={report['counts']}")
    print(f"  universal application (decomposed per machine, gated, width={width}): "
          f"{report['universalProbe']}")
    for failure in report["failures"]:
        print(f"  FAIL {failure}", file=sys.stderr)
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
