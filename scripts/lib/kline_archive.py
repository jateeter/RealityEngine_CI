#!/usr/bin/env python3
"""The K-line historical archive (RealityEngine_CI#603; owner, 2026-11-27).

An engine's K-line store is bounded (`klineStoreMaxBytes`, `isreStoreMaxBytes`):
once a sealed segment is exported, the engine may evict it. This archive is where
exported history is kept. It lives outside every repository, as the secrets home
does:

    $RE_KLINE_ARCHIVE_DIR             when set
    $RE_INSTANCE_STATE_DIR/kline-archive
    ~/.reality-engine/kline-archive   (the default)

    <root>/catalog.jsonl                         one line per archived bundle, append-only
    <root>/<participant uuid>/klines/<first>-<last>-<sha8>.jsonl   re-kline-bundle/1 (an RE)
    <root>/<participant uuid>/isre/<first>-<last>-<sha8>.jsonl     re-isre-bundle/1 (a PE)

A bundle is kept exactly as its engine exported it: the header line, then each
record as its segment stored it. It is written only after its header's `sha256`
is verified against its body (the hex SHA-256 of everything after the header
line), atomically, and is then read-only (0444). Nothing is ever deleted: no stop,
uninstall or purge touches the archive (a K-line, like any existence
observation, is persistent).

Exports are incremental per participant and kind. The next export starts one
commit after the newest one the catalog holds (`since` for K-lines, by
`close.commit`; `from` for compositions, by `re.commit`), so running this
repeatedly never archives a record twice. One known gap: a K-line's
`re-kline-event/1` sustain-end line travels with the K-line, so a sustain-end
recorded after its K-line was archived is not archived again.

Usage:
  kline_archive.py export --registry FILE|URL [--instance ID ...] [--kind klines|isre]
  kline_archive.py list [--instance ID]
  kline_archive.py verify
  kline_archive.py root
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path
from typing import Any
from urllib import error, parse, request

sys.path.insert(0, str(Path(__file__).resolve().parent))

KINDS = {
    # kind: (format, export path, cursor field, record format, commit of a record)
    "klines": ("re-kline-bundle/1", "/api/klines/export", "since", "re-kline/1",
               lambda r: (r.get("close") or {}).get("commit")),
    "isre": ("re-isre-bundle/1", "/api/isre-composition/export", "from", "re-isre-composition/1",
             lambda r: (r.get("re") or {}).get("commit")),
}


def root() -> Path:
    if os.environ.get("RE_KLINE_ARCHIVE_DIR"):
        return Path(os.environ["RE_KLINE_ARCHIVE_DIR"])
    state = os.environ.get("RE_INSTANCE_STATE_DIR") or str(Path.home() / ".reality-engine")
    return Path(state) / "kline-archive"


def catalog(base: Path) -> list[dict]:
    path = base / "catalog.jsonl"
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def cursor(entries: list[dict], participant: str, kind: str) -> int:
    """The first commit not yet archived for PARTICIPANT's KIND."""
    lasts = [e["lastCommit"] for e in entries if e["participant"] == participant and e["kind"] == kind]
    return max(lasts) + 1 if lasts else 0


def split_bundle(text: str) -> tuple[dict, str]:
    head, sep, body = text.partition("\n")
    if not sep:
        raise ValueError("a bundle has a header line and a body")
    return json.loads(head), body


def verified(text: str, fmt: str) -> tuple[dict, str]:
    header, body = split_bundle(text)
    if header.get("format") != fmt:
        raise ValueError(f"expected {fmt}, got {header.get('format')!r}")
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    if header.get("sha256") != digest:
        raise ValueError(f"sha256 {header.get('sha256')} does not match the body ({digest})")
    lines = [line for line in body.split("\n") if line]
    if header.get("count") != len(lines):
        raise ValueError(f"count {header.get('count')} but {len(lines)} lines")
    return header, body


def write_sealed(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o444)
    os.replace(tmp, path)


def append_catalog(base: Path, entry: dict) -> None:
    base.mkdir(parents=True, exist_ok=True)
    with open(base / "catalog.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n")
        f.flush()
        os.fsync(f.fileno())


def post_text(url: str, payload: dict, timeout: int = 300) -> tuple[int, str]:
    req = request.Request(url, data=json.dumps(payload).encode(), method="POST",
                          headers={"content-type": "application/json"})
    try:
        with request.urlopen(req, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8")
    except error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")


def load_registry(source: str) -> dict:
    if parse.urlsplit(source).scheme in ("https", "http"):  # an instance registry URL, else a file
        with request.urlopen(source, timeout=30) as response:
            return json.loads(response.read())
    return json.loads(Path(source).read_text(encoding="utf-8"))


def get_json(url: str, timeout: int = 30) -> Any:
    with request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read())


def participant_of(url: str, kind: str) -> str:
    """The participant UUID, from its clock route (read-only). An export is never
    used to find it: exporting marks the engine's segments exported, which lets
    its budget evict them, so the archive exports only what it then keeps."""
    clock = get_json(url.rstrip("/") + ("/api/engine/clock" if kind == "klines" else "/api/clock"))
    return str(clock.get("instance") or "").lower()


def archive_one(base: Path, entries: list[dict], instance: dict, kind: str) -> dict:
    """Export KIND from one instance from its cursor and archive it. A result line."""
    fmt, route, field, record_format, commit_of = KINDS[kind]
    url = (instance.get("re_url") if kind == "klines" else instance.get("pe_url")) or ""
    line = {"instance": instance.get("id"), "kind": kind}
    if not url:
        return {**line, "result": "no-url"}
    participant = participant_of(url, kind)
    if not participant:
        return {**line, "result": "the participant names no instance on its clock route"}
    start = cursor(entries, participant, kind)
    status, text = post_text(url.rstrip("/") + route, {field: start})
    if status != 200:
        return {**line, "participant": participant, "result": f"export {status}"}
    header, body = verified(text, fmt)
    if str((header.get("source") or {}).get("instance") or "").lower() != participant:
        raise ValueError(f"the bundle's source.instance is not {participant}")
    records = [json.loads(r) for r in body.split("\n") if r]
    commits = [commit_of(r) for r in records if r.get("format") == record_format and commit_of(r) is not None]
    if not commits:
        return {**line, "participant": participant, "result": "nothing new", "from": start}
    first, last = int(min(commits)), int(max(commits))
    rel = Path(participant) / kind / f"{first:012d}-{last:012d}-{header['sha256'][:8]}.jsonl"
    write_sealed(base / rel, text)
    entry = {
        "kind": kind, "format": fmt, "participant": participant,
        "instanceId": instance.get("id"), "runtime": instance.get("runtime"),
        "file": str(rel), "bytes": len(text.encode("utf-8")), "count": header["count"],
        "records": len(commits), "sha256": header["sha256"], "firstCommit": first, "lastCommit": last,
        "header": header, "archivedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    append_catalog(base, entry)
    entries.append(entry)
    return {**line, "participant": participant, "result": "archived", "records": len(commits),
            "commits": [first, last], "file": str(rel)}


def cmd_export(args: argparse.Namespace) -> int:
    import re_tls  # noqa: E402 -- the lane CA and harness certificate when RE_TLS=on (#732)
    re_tls.install_lane_opener()
    base = root()
    entries = catalog(base)
    document = load_registry(args.registry)
    kinds = [args.kind] if args.kind else list(KINDS)
    failed = False
    for instance in document.get("instances", []):
        if args.instance and instance.get("id") not in args.instance:
            continue
        for kind in kinds:
            try:
                line = archive_one(base, entries, instance, kind)
            except (ValueError, OSError, error.URLError) as exc:
                line = {"instance": instance.get("id"), "kind": kind, "result": f"refused: {exc}"}
            print(json.dumps(line, sort_keys=True))
            failed |= line["result"].startswith(("refused", "export ", "the bundle"))
    return 1 if failed else 0


def cmd_list(args: argparse.Namespace) -> int:
    for e in catalog(root()):
        if args.instance and e.get("instanceId") not in args.instance:
            continue
        print(f"{e['archivedAt']}  {e.get('instanceId') or '?':10} {e['kind']:6} commits {e['firstCommit']}..{e['lastCommit']}"
              f"  {e['records']} records  {e['bytes']} B  {e['file']}")
    return 0


def cmd_verify(_: argparse.Namespace) -> int:
    base = root()
    bad = 0
    entries = catalog(base)
    for e in entries:
        path = base / e["file"]
        try:
            header, _ = verified(path.read_text(encoding="utf-8"), e["format"])
            if header["sha256"] != e["sha256"]:
                raise ValueError("the file's sha256 is not the catalog's")
        except (OSError, ValueError) as exc:
            bad += 1
            print(f"BAD {e['file']}: {exc}")
    print(f"kline-archive: {len(entries) - bad} of {len(entries)} bundles verified at {base}")
    return 1 if bad else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    e = sub.add_parser("export", help="export every participant's new records into the archive")
    e.add_argument("--registry", required=True, help="an instance registry file or URL")
    e.add_argument("--instance", action="append", help="only this instance id (repeatable)")
    e.add_argument("--kind", choices=sorted(KINDS))
    e.set_defaults(func=cmd_export)
    lst = sub.add_parser("list", help="the catalog")
    lst.add_argument("--instance", action="append")
    lst.set_defaults(func=cmd_list)
    sub.add_parser("verify", help="re-verify every archived bundle").set_defaults(func=cmd_verify)
    sub.add_parser("root", help="print the archive directory").set_defaults(func=lambda _: print(root()) or 0)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
