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

An id names an instance within one universe, not across universes running at
the same time: two universes on one lane both have a cpp-1, and they are two
instances (#637). So "<lane>/<id>" keeps its UUID only while no live instance
holds it. A UUID is live while a process holds its engine lock,
<clock>/<uuid>.lock (the POSIX lock every engine takes for its life), or while
another universe's allocation leases it in the gap before its engine takes that
lock. When the recorded UUID is live, the instance being created is a different
one and gets a UUID of its own, recorded durably as "<lane>/<id>#<n>" and reused
the same way -- so every instance still keeps its UUID, and its Lamport clock,
from one universe to the next.

    instance_uuids.py allocate <lane> <id> [<owner-pid>]
                                             print the instance's UUID, allocating one;
                                             <owner-pid> is the universe being started,
                                             which leases the UUID until its engine locks it
    instance_uuids.py holder <uuid>          print the pid holding the instance's
                                             engine lock; exit 1 when none does
    instance_uuids.py live                   print "<uuid> <pid>" for every held lock
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
import struct
import sys
import time
from pathlib import Path

LANES = ("native", "docker")

# How long an allocation reserves a UUID for the universe that asked for it. It
# covers the gap until that universe's engine takes the instance lock -- a boot
# that loads the corpus can take minutes -- and it ends early when the universe
# process exits. Past it, the lock is the only evidence of life.
LEASE_SECONDS = 900


def state_dir() -> Path:
    return Path(os.environ.get("RE_INSTANCE_STATE_DIR")
                or Path.home() / ".reality-engine")


def table_path() -> Path:
    return state_dir() / "instance-uuids.json"


def clock_dir() -> Path:
    # The engines lock in INSTANCE_CLOCK_DIR when it is set; the liveness probe
    # has to look where they lock.
    return Path(os.environ.get("INSTANCE_CLOCK_DIR") or state_dir() / "clock")


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


def _flock_struct() -> tuple[str, int, int, int]:
    """struct flock as this platform lays it out:
    (format, l_type index, l_whence index, l_pid index).

    Linux: l_type, l_whence, l_start, l_len, l_pid, padded to 32 bytes. The BSDs
    and Darwin put the offsets first: l_start, l_len, l_pid, l_type, l_whence.
    """
    if sys.platform.startswith("linux"):
        return "hhqqi4x", 0, 1, 4
    return "qqihh", 3, 4, 2


def lock_holder(uuid: str) -> int | None:
    """The pid holding the instance's engine lock, or None when nothing does.

    Asked with F_GETLK, so the probe never takes the lock itself: taking it, even
    for a moment, could refuse an engine booting in another universe. Engines lock
    with lockf/fcntl (C++, LSP) and FileChannel.tryLock (Scala), all POSIX record
    locks over the whole file, which is what this queries. A lock held inside a
    container is on the VM's side of the bind mount and is not seen here.
    """
    path = clock_dir() / f"{uuid}.lock"
    try:
        fd = os.open(path, os.O_RDWR)
    except FileNotFoundError:
        return None
    except PermissionError:
        fd = os.open(path, os.O_RDONLY)
    try:
        fmt, type_at, whence_at, pid_at = _flock_struct()
        query = [0] * 5
        query[type_at] = fcntl.F_WRLCK
        query[whence_at] = os.SEEK_SET
        answer = struct.unpack(fmt, fcntl.fcntl(fd, fcntl.F_GETLK, struct.pack(fmt, *query)))
    finally:
        os.close(fd)
    if answer[type_at] == fcntl.F_UNLCK:
        return None
    return answer[pid_at] or None


def live_locks() -> dict[str, int]:
    """UUID -> pid for every instance whose engine lock is held right now."""
    held: dict[str, int] = {}
    if clock_dir().is_dir():
        for lock in sorted(clock_dir().glob("*.lock")):
            pid = lock_holder(lock.stem)
            if pid:
                held[lock.stem] = pid
    return held


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _lease_live(lease: dict, now: float) -> bool:
    return now - float(lease.get("at", 0)) < LEASE_SECONDS and _pid_alive(int(lease.get("owner", 0)))


def _siblings(instances: dict[str, str], key: str) -> list[tuple[int, str]]:
    """(n, key) for "<lane>/<id>" (n=1) and each "<lane>/<id>#<n>", in order."""
    found = []
    for k in instances:
        if k == key:
            found.append((1, k))
        elif k.startswith(key + "#") and k[len(key) + 1:].isdigit():
            found.append((int(k[len(key) + 1:]), k))
    return sorted(found)


def duplicates(mapping: dict[str, str]) -> dict[str, list[str]]:
    """UUID -> the keys holding it, for every UUID held by more than one key."""
    holders: dict[str, list[str]] = {}
    for key, value in mapping.items():
        holders.setdefault(value, []).append(key)
    return {u: sorted(keys) for u, keys in holders.items() if len(keys) > 1}


def allocate(lane: str, instance_id: str, owner: int | None = None) -> str:
    """The UUID of the instance <lane>/<id> being created now.

    The UUID recorded for <lane>/<id> when no live instance holds it -- the same
    instance in a later universe. Otherwise another live instance has that id in
    a universe running alongside this one, so this is a different instance: the
    first free sibling UUID, or a new one recorded as <lane>/<id>#<n>.

    `owner` is the pid of the universe being started. It leases the UUID until
    that universe exits or LEASE_SECONDS pass, so a second universe allocating
    the same id before this one's engine has locked it is handed another UUID.
    """
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
        now = time.time()
        leases: dict[str, dict] = {u: lease for u, lease in table.get("leases", {}).items()
                                   if _lease_live(lease, now)}
        changed = leases != table.get("leases", {})

        chosen = None
        passed: list[str] = []
        for _, k in _siblings(instances, key):
            uuid = instances[k]
            pid = lock_holder(uuid)
            lease = leases.get(uuid)
            if pid:
                passed.append(f"{uuid} ({k}) is held by live pid {pid}")
            elif lease and (owner is None or int(lease["owner"]) != owner):
                passed.append(f"{uuid} ({k}) is leased by starting universe pid {lease['owner']}")
            else:
                chosen = k
                break
        if chosen is None:
            siblings = _siblings(instances, key)
            chosen = key if not siblings else f"{key}#{max(siblings[-1][0], 1) + 1}"
            taken = set(instances.values())
            fresh = uuid7()
            while fresh in taken:
                fresh = uuid7()
            instances[chosen] = fresh
            changed = True
        uuid = instances[chosen]
        if passed:
            print(f"instance UUID: {key} is a different instance from the live one(s) -- "
                  + "; ".join(passed) + f" -- so it is {uuid} ({chosen})", file=sys.stderr)
        if owner is not None:
            # One universe creates one <lane>/<id>: what it leased for a sibling
            # on an earlier call is released, so a third universe can have it.
            for _, k in _siblings(instances, key):
                if instances[k] != uuid and int(leases.get(instances[k], {}).get("owner", -1)) == owner:
                    del leases[instances[k]]
            leases[uuid] = {"owner": owner, "at": now}
            changed = True
        if changed:
            if leases:
                table["leases"] = leases
            else:
                table.pop("leases", None)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(table, indent=2, sort_keys=True) + "\n")
            os.replace(tmp, path)
        return uuid


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
    if len(argv) in (3, 4) and argv[0] == "allocate":
        owner = int(argv[3]) if len(argv) == 4 and argv[3] else None
        print(allocate(argv[1], argv[2], owner))
        return 0
    if len(argv) == 2 and argv[0] == "holder":
        pid = lock_holder(argv[1])
        if pid:
            print(pid)
        return 0 if pid else 1
    if len(argv) == 1 and argv[0] == "live":
        for uuid, pid in live_locks().items():
            print(uuid, pid)
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
