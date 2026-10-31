"""Conformance followers: runtimes measured against the quorum, never voting in it.

docs/QUORUM_CONTRACT.md section 1, "Conformance followers" (#607). A follower --
today RealityEngine_Rust -- is an instance carrying `"role": "follower"`. It is
held against what the three voters agree on and reported, but it can neither
form nor break a quorum:

- `voters()` is what every comparison stage reads. A follower in the instance
  data it is given is dropped there, before any composition or verdict, so a
  2-1 split among the voters stays a disagreement whatever the follower says.
- `follower_verdict()` is how the follower lane (`scripts/rust-conformance.sh`)
  reads one stage. It runs the stage twice -- the voters alone, then the voters
  with the follower presented as one more instance -- and judges the follower
  by the pair. The stage's own comparison is reused unchanged, so "agrees"
  means exactly what parity means for the voters.
- `declared_unsupported()` reads SURFACE_SPEC.md's ruled answer for a route a
  runtime does not implement (501 with `participation: "unsupported"`), so a
  surface the follower lacks is reported as that, never as "QUORUM NOT FORMED".

Usable as a module and as a CLI:

    followers.py split <registry.json> <voters.json> <joint.json>
        write the voters-only registry and the joint one (followers presented
        as ordinary instances); print the follower ids
    followers.py probe <re_url> <METHOD> <path>
        print "unsupported" when the route declares it, else "supported"
    followers.py verdict <voters_exit> <joint_exit> [unsupported-surface...]
        print the follower's verdict for one stage
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Iterable
from urllib import error, request

FOLLOWER = "follower"

# The closed set a follower's result for one stage can take.
AGREES = "agrees"              # the voters agree and the follower agrees with them
DIFFERS = "differs"            # the voters agree and the follower does not
UNSUPPORTED = "unsupported"    # the follower declares a surface the stage needs unimplemented
NOT_COMPARED = "not-compared"  # the voters do not agree: there is nothing to follow
VERDICTS = (AGREES, DIFFERS, UNSUPPORTED, NOT_COMPARED)


def is_follower(instance: dict[str, Any]) -> bool:
    return instance.get("role") == FOLLOWER


def voters(instances: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """The instances that vote. A follower never does (QUORUM_CONTRACT.md section 1)."""
    return [i for i in instances if not is_follower(i)]


def followers(instances: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    return [i for i in instances if is_follower(i)]


def follower_verdict(voters_exit: int, joint_exit: int, unsupported: Iterable[str] = ()) -> str:
    """One stage's result for a follower, from the stage's two runs.

    The voters' run decides first. When the voters themselves do not agree there
    is no agreed behaviour to hold the follower to, so it is not compared --
    and the stage's verdict stays the voters' disagreement whatever the follower
    did. Only then does a declared-unsupported surface, and then the joint run,
    say anything about the follower.
    """
    if voters_exit != 0:
        return NOT_COMPARED
    if list(unsupported):
        return UNSUPPORTED
    return AGREES if joint_exit == 0 else DIFFERS


def declared_unsupported(re_url: str, method: str, path: str, timeout: int = 30) -> bool:
    """Whether the route answers SURFACE_SPEC.md's ruled `unsupported` declaration.

    `path` is concrete (`probe` for a parameter). Only the ruled shape counts: a
    501 whose body says `participation: "unsupported"`. Anything else -- a 2xx,
    a 400 for the probe's empty input, a 404 for an absent resource -- means the
    route is there, and the stage itself judges what it answers.
    """
    body = b"{}" if method in ("POST", "PUT", "PATCH") else None
    req = request.Request(f"{re_url.rstrip('/')}{path}", data=body, method=method,
                          headers={"Content-Type": "application/json"})
    try:
        with request.urlopen(req, timeout=timeout):
            return False
    except error.HTTPError as exc:
        if exc.code != 501:
            return False
        try:
            payload = json.loads(exc.read().decode("utf-8"))
        except ValueError:
            return False
        return isinstance(payload, dict) and payload.get("participation") == "unsupported"


def split_registry(document: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any], list[str]]:
    """(voters-only document, joint document, follower ids).

    The joint document lists every instance with the role removed, so a stage
    that does not know about followers compares the follower as one more
    runtime. That run is only ever read through `follower_verdict`.
    """
    instances = document.get("instances", [])
    voters_doc = {**document, "instances": voters(instances)}
    joint = [{k: v for k, v in i.items() if k != "role"} for i in instances]
    return voters_doc, {**document, "instances": joint}, [i["id"] for i in followers(instances)]


def main(argv: list[str]) -> int:
    if len(argv) >= 4 and argv[0] == "split":
        document = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
        voters_doc, joint, ids = split_registry(document)
        Path(argv[2]).write_text(json.dumps(voters_doc, indent=2))
        Path(argv[3]).write_text(json.dumps(joint, indent=2))
        print("\n".join(ids))
        return 0
    if len(argv) == 4 and argv[0] == "probe":
        print(UNSUPPORTED if declared_unsupported(argv[1], argv[2], argv[3]) else "supported")
        return 0
    if len(argv) >= 3 and argv[0] == "verdict":
        print(follower_verdict(int(argv[1]), int(argv[2]), argv[3:]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
