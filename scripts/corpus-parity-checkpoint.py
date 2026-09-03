#!/usr/bin/env python3
"""Reconstruct the corpus resident at iteration N of a parity loop run.

`test-corpus-parity-loop.sh --resume` reuses a *running* universe and skips
iterations already recorded. That is the only resume there is, and it is the one
that does not help when the universe is gone — which is the case that matters,
because the interesting failures appear hundreds of iterations in and the
universe rarely survives to be resumed.

RealityEngine_CI#167 is the worked example. The loop halted at iteration 862
after 6h27m, and reaching that state again meant replaying ~808 incremental API
loads at roughly six and a half hours. From the issue:

    `--resume` needs a live universe it never had. Reaching iteration 862 again
    means replaying ~808 incremental loads, roughly 6.5 hours, and the harness
    has no checkpoint mechanism. Any serious attempt likely needs one — the
    ability to snapshot engine state at iteration N and resume from it would
    turn a 6.5-hour bisect into minutes, and would pay for itself immediately
    here.

The investigation got there anyway, by hand: "an 807-machine manifest — the
exact set resident at iteration 861, reconstructed from the run log — was
boot-loaded onto a fresh universe". That reproduction ran in minutes and is what
exonerated the machine originally suspected. This tool is that reconstruction,
automated, so the next investigation does not have to rebuild it under pressure.

**What this is not.** It reconstructs the corpus — which machines were resident
— not engine state. A boot-loaded universe at 808 machines is not byte-identical
to one that reached 808 by incremental load, and #167 turns on exactly that
difference: the same machine set reproduced cleanly when boot-loaded, which is
why "accumulated state surviving reset" is its leading hypothesis. Use this to
make a corpus hypothesis cheap to test, and read a clean result as "not a
function of corpus content", never as "not reproducible".

Usage:

    # What was resident when it stopped, and where it stopped
    corpus-parity-checkpoint.py summary --results /tmp/.../corpus-parity-loop.jsonl

    # The manifest to boot-load, as of just before iteration 862
    corpus-parity-checkpoint.py manifest --results ... --before 862 --out repro.txt

    # ...and the command that boots it
    corpus-parity-checkpoint.py command --results ... --before 862 --out repro.txt
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

# Statuses where the machine was loaded and stayed loaded. A `skipped` iteration
# never loaded its machine, so including it would manufacture a corpus the run
# never had — the failure this tool exists to avoid, one level down.
RESIDENT_STATUSES = {"pass", "fail", "non-binary", "guardrail", "capacity"}


def load_records(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise SystemExit(f"no results file at {path}")
    records: list[dict[str, Any]] = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            # A run killed mid-write leaves a partial final line. That is the
            # normal shape of the file this tool is pointed at, so it is skipped
            # with a note rather than treated as corruption.
            print(f"note: skipping unparseable line {lineno} (run interrupted mid-write?)",
                  file=sys.stderr)
    if not records:
        raise SystemExit(f"{path} carried no usable iteration records")
    return records


def resident_at(records: list[dict[str, Any]], before: int | None) -> list[str]:
    """Corpus-relative machine files resident before iteration `before`.

    In `cumulative` mode — the mode every long sweep runs in — each iteration
    adds one machine and never removes it, so residency is every machine loaded
    by an earlier iteration. `isolated` mode removes each machine before the
    next, and a manifest reconstructed from it would describe a corpus that
    never existed at once; refused rather than silently wrong.
    """
    resident: list[str] = []
    for record in records:
        index = record.get("index")
        if before is not None and isinstance(index, int) and index >= before:
            break
        if record.get("status") in RESIDENT_STATUSES and record.get("machineFile"):
            resident.append(str(record["machineFile"]))
    # Dedupe preserving load order: the order machines arrived is the one thing
    # a boot-load cannot reproduce, but keeping it makes the manifest diffable
    # against the run log.
    seen: set[str] = set()
    ordered: list[str] = []
    for rel in resident:
        if rel not in seen:
            seen.add(rel)
            ordered.append(rel)
    return ordered


def detect_mode(records: list[dict[str, Any]]) -> str | None:
    for record in records:
        mode = record.get("mode")
        if isinstance(mode, str):
            return mode
    return None


def first_failure(records: list[dict[str, Any]]) -> dict[str, Any] | None:
    return next((r for r in records if r.get("status") in {"fail", "error"}), None)


def cmd_summary(args: argparse.Namespace) -> int:
    records = load_records(args.results)
    tally: dict[str, int] = {}
    for record in records:
        tally[str(record.get("status"))] = tally.get(str(record.get("status")), 0) + 1

    print(f"records         {len(records)}")
    print(f"mode            {detect_mode(records) or '<not recorded>'}")
    print(f"status tally    {json.dumps(tally, sort_keys=True)}")
    print(f"resident at end {len(resident_at(records, None))} machine(s)")

    failure = first_failure(records)
    if not failure:
        print("first failure   none — every recorded iteration passed")
        return 0

    index = failure.get("index")
    print()
    print(f"first failure   iteration {index}  {failure.get('machineFile')}")
    for section in ("trajectoryParity", "loadParity", "sourceParity", "capacity", "guardrail"):
        block = failure.get(section) or {}
        for item in (block.get("failures") or [])[:4]:
            print(f"                {section}: {item}")
    if isinstance(index, int):
        print()
        print(f"reproduce the state it failed from ({len(resident_at(records, index))} machines):")
        print(f"  {Path(__file__).name} manifest --results {args.results} --before {index} --out repro.txt")
    return 0


def cmd_manifest(args: argparse.Namespace) -> int:
    records = load_records(args.results)
    mode = detect_mode(records)
    if mode == "isolated" and not args.force:
        raise SystemExit(
            "refusing: this run was in `isolated` mode, where each machine is removed before the "
            "next is loaded. A manifest built from it describes a corpus that never existed at "
            "once. Pass --force if you know what you are reconstructing."
        )

    resident = resident_at(records, args.before)
    if not resident:
        raise SystemExit(f"no machines were resident before iteration {args.before}")

    header = [
        "# Corpus resident during a parity loop run, reconstructed by "
        f"{Path(__file__).name}.",
        f"# source:  {args.results}",
        f"# before:  iteration {args.before}" if args.before is not None else "# before:  end of run",
        f"# count:   {len(resident)}",
        "#",
        "# Boot-loaded, not incrementally loaded. Engine state differs from a run that",
        "# reached this corpus one machine at a time — see RealityEngine_CI#167, where",
        "# that difference is the leading hypothesis rather than a caveat.",
    ]
    body = "\n".join(header + resident) + "\n"

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(body, encoding="utf-8")
        print(f"{len(resident)} machine(s) -> {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(body)
    return 0


def cmd_command(args: argparse.Namespace) -> int:
    records = load_records(args.results)
    resident = resident_at(records, args.before)
    manifest = args.out or Path("repro-manifest.txt")
    print(f"# {len(resident)} machine(s) resident before iteration {args.before}")
    print(f"python3 scripts/{Path(__file__).name} manifest \\")
    print(f"  --results {args.results} --before {args.before} --out {manifest}")
    print()
    print("# --no-local-ai matters: the localAI bridge registers ten localai/* machines")
    print("# the original run never had, and they reproduce RealityEngine_Scala#54 instead.")
    print("./startUniverse.sh \\")
    print("  --engines=cpp:1,lsp:1,scala:1 \\")
    print("  --machine-load=runtime \\")
    print("  --machine-corpus=standard-deployment \\")
    print(f"  --machine-corpus-manifest={manifest} \\")
    print("  --pe-source-bootstrap=off \\")
    print("  --no-openclaw --no-local-ai --warn-only")
    print()
    print("# Then drive the machine that failed, at the depth it failed:")
    failure = first_failure(records)
    if failure:
        print(f"#   machine: {failure.get('machineFile')}")
    print("python3 scripts/regression-corpus-parity-loop.py \\")
    print("  --registry http://127.0.0.1:5999/re-registry.json \\")
    print("  --machines-root ../RealityEngine_Machines/machines \\")
    print("  --out /tmp/repro.json --mode cumulative --stop-on-fail")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    for name, handler, needs_before in (
        ("summary", cmd_summary, False),
        ("manifest", cmd_manifest, True),
        ("command", cmd_command, True),
    ):
        p = sub.add_parser(name, help=handler.__doc__ or name)
        p.add_argument("--results", type=Path, required=True,
                       help="corpus-parity-loop.jsonl from the run being reconstructed")
        if needs_before:
            p.add_argument("--before", type=int, default=None,
                           help="reconstruct the corpus as of just before this iteration index; "
                                "omit for the whole run")
            p.add_argument("--out", type=Path, help="write the manifest here instead of stdout")
            p.add_argument("--force", action="store_true",
                           help="build a manifest even from an `isolated`-mode run")
        p.set_defaults(handler=handler)

    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
