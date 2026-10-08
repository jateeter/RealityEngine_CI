#!/usr/bin/env python3
"""Order and retain regression run directories by when they ran.

Run ids are free-form (`main-1007`, `pr544-1639`, `build-1008`, a timestamp),
so ordering by name is not ordering by time. Every place that chose "the
newest" runs did exactly that -- `ls | sort -r` in prune_run_history and
retain_history, `sorted(glob)` in regression-report.py's comparison baseline --
and on 2026-10-08 a build-only run `build-1008`, keeping two runs, kept
`pr544-1639` (2026-10-05) and deleted `main-1007` (2026-10-07): the newest
green local-lane run and the release candidate (docs/MVP_ROADMAP.md, step 7).
The same ordering had compared `main-1007` against `pr544-1639` instead of
`main-1006`.

A run's time is its manifest's `finishedAt`, else `startedAt`, else the
directory's mtime.

A run is *certifying* when it completed and ran the live stages: it started a
universe and tested it. That run is both the comparison baseline and the
release candidate (D3), so retention never removes the newest one, whatever
its position, and a build-only run is never the baseline. Manifests record
`phases` since this change; for an older manifest, a run that started a
universe left `reports/service-inventory.json`.

    run_history.py order <runs-dir> [--exclude ID]
    run_history.py prune <runs-dir> --keep N [--exclude ID]
        prints the run ids to remove, one per line
    run_history.py baseline <runs-dir> [--exclude ID]
        prints the comparison baseline's run id, if any
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def _manifest(run: Path) -> dict:
    try:
        return json.loads((run / "manifest.json").read_text(encoding="utf-8"))
    except Exception:
        return {}


def _parse_time(value: object) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()
    except ValueError:
        return None


def run_time(run: Path) -> float:
    m = _manifest(run)
    for key in ("finishedAt", "startedAt"):
        t = _parse_time(m.get(key))
        if t is not None:
            return t
    return run.stat().st_mtime


def ran_live_stages(run: Path) -> bool:
    phases = _manifest(run).get("phases")
    if isinstance(phases, dict) and "liveTests" in phases:
        return bool(phases.get("liveTests"))
    # Older manifests: only a run that started a universe inventories it.
    return (run / "reports" / "service-inventory.json").is_file()


def is_certifying(run: Path) -> bool:
    return _manifest(run).get("status") == "completed" and ran_live_stages(run)


def runs_newest_first(runs_dir: Path, exclude: str | None = None) -> list[Path]:
    if not runs_dir.is_dir():
        return []
    runs = [p for p in runs_dir.iterdir() if p.is_dir() and p.name != exclude]
    # Name breaks ties, so the order is stable.
    return sorted(runs, key=lambda p: (run_time(p), p.name), reverse=True)


def to_prune(runs_dir: Path, keep: int, exclude: str | None = None) -> list[Path]:
    """Runs to remove, keeping the newest `keep` (counting `exclude`, the run
    in progress, when given) and always the newest certifying run."""
    runs = runs_newest_first(runs_dir, exclude)
    keep_old = keep - 1 if exclude else keep
    kept = set(p.name for p in runs[:max(keep_old, 0)])
    newest_certifying = next((p for p in runs if is_certifying(p)), None)
    if newest_certifying is not None:
        kept.add(newest_certifying.name)
    return [p for p in runs if p.name not in kept]


def baseline(runs_dir: Path, exclude: str | None = None) -> Path | None:
    """The run to compare against: the newest certifying run, else the newest
    completed one."""
    runs = runs_newest_first(runs_dir, exclude)
    for p in runs:
        if is_certifying(p):
            return p
    for p in runs:
        if _manifest(p).get("status") == "completed":
            return p
    return None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("order", "prune", "baseline"):
        sp = sub.add_parser(name)
        sp.add_argument("runs_dir", type=Path)
        sp.add_argument("--exclude", default=None)
        if name == "prune":
            sp.add_argument("--keep", type=int, required=True)
    args = ap.parse_args(argv)

    if args.cmd == "order":
        for p in runs_newest_first(args.runs_dir, args.exclude):
            print(p.name)
    elif args.cmd == "prune":
        if args.keep <= 0:
            return 0
        for p in to_prune(args.runs_dir, args.keep, args.exclude):
            print(p.name)
    else:
        b = baseline(args.runs_dir, args.exclude)
        if b is not None:
            print(b.name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
