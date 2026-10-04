#!/usr/bin/env python3
"""Instance UUID allocation (RealityEngine_CI#296).

A UUID identifies an **instance** -- cpp-1, lsp-2 -- never an engine type or
an image, and no two instances of any engine type may share one. The
allocation is CI's, made where instances are created, and it is durable: an
instance id keeps its UUID across universes, so its Lamport clock
(instance UUID + a counter that never resets) and any K-line anchored to it
carry on.

The table lives at $RE_INSTANCE_STATE_DIR/instance-uuids.json (default
~/.reality-engine/), keyed by "<lane>/<id>" -- the native and Docker lanes are
different instance sets that happen to reuse the same ids. Each instance's
clock is kept beside it, in $RE_INSTANCE_STATE_DIR/clock/, which is what the
engine's INSTANCE_CLOCK_DIR points at.

    instance_uuids.py allocate <lane> <id>   print the instance's UUID, allocating one
    instance_uuids.py clock-dir              print the clock directory
    instance_uuids.py docker-env <id>        allocate docker/<id> and write the env
                                             file its compose service loads
    instance_uuids.py check-registry <file>  refuse an instance registry in which
                                             two instances share a UUID

Allocation is a read-modify-write under an exclusive lock on the table, written
by rename, and refuses a table that already maps two instances to one UUID --
a duplicate is never resolved by picking one.
"""

from __future__ import annotations

import fcntl
import json
import os
import secrets
import sys
import time
from pathlib import Path

LANES = ("native", "docker")


def state_dir() -> Path:
    return Path(os.environ.get("RE_INSTANCE_STATE_DIR")
                or Path.home() / ".reality-engine")


def table_path() -> Path:
    return state_dir() / "instance-uuids.json"


def clock_dir() -> Path:
    return state_dir() / "clock"


def uuid7() -> str:
    """A version-7 UUID: 48-bit Unix ms, version, 74 random bits, RFC variant.

    Written out rather than taken from uuid.uuid7, which only exists from
    Python 3.14 and the hosted lane runs older interpreters.
    """
    value = (time.time_ns() // 1_000_000) << 80
    value |= 0x7 << 76
    value |= secrets.randbits(12) << 64
    value |= 0b10 << 62
    value |= secrets.randbits(62)
    h = f"{value:032x}"
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def duplicates(mapping: dict[str, str]) -> dict[str, list[str]]:
    """UUID -> the keys holding it, for every UUID held by more than one key."""
    holders: dict[str, list[str]] = {}
    for key, value in mapping.items():
        holders.setdefault(value, []).append(key)
    return {u: sorted(keys) for u, keys in holders.items() if len(keys) > 1}


def allocate(lane: str, instance_id: str) -> str:
    if lane not in LANES:
        raise SystemExit(f"lane must be one of {', '.join(LANES)}, got {lane!r}")
    if not instance_id:
        raise SystemExit("an instance id is required")
    path = table_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    key = f"{lane}/{instance_id}"
    with open(path.with_suffix(".lock"), "a") as lock:
        fcntl.lockf(lock, fcntl.LOCK_EX)
        table = json.loads(path.read_text()) if path.exists() else {"version": 1, "instances": {}}
        instances: dict[str, str] = table.setdefault("instances", {})
        clash = duplicates(instances)
        if clash:
            raise SystemExit(
                f"{path}: two instances share a UUID, which is never allowed: "
                + "; ".join(f"{u} held by {', '.join(k)}" for u, k in clash.items()))
        if key not in instances:
            taken = set(instances.values())
            fresh = uuid7()
            while fresh in taken:
                fresh = uuid7()
            instances[key] = fresh
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(table, indent=2, sort_keys=True) + "\n")
            os.replace(tmp, path)
        return instances[key]


DOCKER_CLOCK_DIR = "/var/lib/reality-engine/clock"


def docker_env(instance_id: str) -> str:
    """Allocate docker/<id> and write <state>/docker/<id>.env, which that
    instance's compose service loads (env_file). The UUID lives in a file rather
    than in startUniverse.sh's environment so that any tool recreating the
    container -- not only startUniverse.sh -- presents the same UUID instead of
    letting the engine mint a new one. The clock directory it names is the
    container side of the <state>/clock-docker bind mount."""
    uuid = allocate("docker", instance_id)
    path = state_dir() / "docker" / f"{instance_id}.env"
    path.parent.mkdir(parents=True, exist_ok=True)
    (state_dir() / "clock-docker").mkdir(parents=True, exist_ok=True)
    # The container's user is not the host's; the clock must be writable by it
    # or the engine (correctly) refuses to boot.
    os.chmod(state_dir() / "clock-docker", 0o1777)
    path.write_text(f"INSTANCE_UUID={uuid}\nINSTANCE_CLOCK_DIR={DOCKER_CLOCK_DIR}\n")
    return uuid


def check_registry(registry_file: str) -> list[str]:
    """Failures: two instances in one instance registry holding the same UUID."""
    document = json.loads(Path(registry_file).read_text())
    held = {i.get("id", "?"): i["instance_uuid"]
            for i in document.get("instances", []) if i.get("instance_uuid")}
    return [f"instance UUID {u} is held by {', '.join(ids)}: two instances may not share a UUID"
            for u, ids in duplicates(held).items()]


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "allocate":
        print(allocate(argv[1], argv[2]))
        return 0
    if len(argv) == 2 and argv[0] == "docker-env":
        print(docker_env(argv[1]))
        return 0
    if len(argv) == 1 and argv[0] == "clock-dir":
        print(clock_dir())
        return 0
    if len(argv) == 2 and argv[0] == "check-registry":
        failures = check_registry(argv[1])
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1 if failures else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
