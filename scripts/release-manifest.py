#!/usr/bin/env python3
"""Pin every repo in the application to a SHA, so a release can be rebuilt exactly.

A release manifest is derived from a *regression run*, not from whatever
happens to be on main. The run already records, per repo, the remote it came
from and the commit the build actually used, so pinning from it means the
pinned set is the set that was certified — the manifest and the evidence for it
come from the same place.

    generate  build a manifest from a regression run
    verify    check a workspace against a manifest

Generating from a run that did not pass is refused rather than defaulted, the
same way the harness refuses a profile violation. A manifest that silently
pinned a red run would be indistinguishable from one that pinned a green run,
which is the property that makes it worth having. `--allow-unverified` overrides
and records the override in the manifest itself.

Examples

    # Pin from a local regression run
    scripts/release-manifest.py generate \\
        --run-dir .regression-tests/runs/gha-31297685782-1 \\
        --version v0.1.0 --out release-manifest.json

    # Pin from a downloaded CI artifact
    scripts/release-manifest.py generate \\
        --manifest ./artifacts/gha-123-1/manifest.json \\
        --version v0.1.0 --out release-manifest.json

    # Confirm a workspace matches
    scripts/release-manifest.py verify --manifest release-manifest.json
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

# The harness's terminal success state, set at scripts/regression-test.sh:819
# when no stage recorded a failure. It writes exactly "completed" or "failed" —
# not "passed", which is the vocabulary used for individual commands and stage
# reports. Any other value is treated as uncertified rather than guessed at: a
# status this tool does not recognise is the case where it must not pin.
CERTIFIED_RUN_STATUS = "completed"


def git(path: Path, *args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), *args], stderr=subprocess.DEVNULL, text=True
        ).strip()
    except Exception:
        return ""


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── generate ────────────────────────────────────────────────────────────────


def stage_reports(run_dir: Path | None) -> dict[str, str]:
    """Per-stage status from the run's reports, when the run directory is at hand.

    The run manifest records build commands but not the live stages, so this
    reads the stage reports directly. Absent reports are reported as absent
    rather than assumed to have passed.
    """
    if run_dir is None:
        return {}
    reports = run_dir / "reports"
    if not reports.is_dir():
        return {}
    out: dict[str, str] = {}
    for report in sorted(reports.glob("*.json")):
        try:
            payload = load_json(report)
        except Exception:
            out[report.stem] = "unreadable"
            continue
        if isinstance(payload, dict):
            status = payload.get("status")
            if isinstance(status, str):
                out[report.stem] = status
            elif payload.get("failures"):
                out[report.stem] = "failed"
            else:
                out[report.stem] = "passed"
    return out


def repo_entries(run_manifest: dict[str, Any]) -> tuple[list[dict[str, Any]], list[str]]:
    """Pin each repo to the commit the build used, flagging anything unpinnable."""
    entries: list[dict[str, Any]] = []
    problems: list[str] = []

    for repo in run_manifest.get("repos", []):
        name = repo.get("name", "")
        # worktreeSha is what was actually built. originMainSha is what the
        # branch pointed at. On a cold start they agree; when they do not, the
        # build used something other than the branch tip and the difference has
        # to be visible rather than averaged away.
        built = repo.get("worktreeSha") or ""
        branch_tip = repo.get("originMainSha") or ""
        sha = built or branch_tip

        if not sha:
            problems.append(f"{name}: no commit recorded, cannot pin")
            continue
        if built and branch_tip and built != branch_tip:
            problems.append(
                f"{name}: built {built[:8]} but origin/main was {branch_tip[:8]}"
            )

        entries.append(
            {
                "name": name,
                "remoteUrl": repo.get("remoteUrl", ""),
                "sha": sha,
                "originMainShaAtRun": branch_tip,
                "buildStatus": repo.get("buildStatus", "unknown"),
            }
        )

    return entries, problems


def cmd_generate(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir).resolve() if args.run_dir else None
    manifest_path = (
        Path(args.manifest).resolve()
        if args.manifest
        else (run_dir / "manifest.json" if run_dir else None)
    )
    if manifest_path is None or not manifest_path.is_file():
        print(f"run manifest not found: {manifest_path}", file=sys.stderr)
        return 2

    run_manifest = load_json(manifest_path)
    run_status = run_manifest.get("status", "unknown")

    certified = run_status == CERTIFIED_RUN_STATUS

    if not certified and not args.allow_unverified:
        print(
            f"refusing to pin from a run with status '{run_status}' "
            f"(certified runs report '{CERTIFIED_RUN_STATUS}').\n"
            "A release manifest asserts the pinned set was certified; pinning a run\n"
            "that did not pass makes it indistinguishable from one that did.\n"
            "Pass --allow-unverified to record a provisional manifest anyway.",
            file=sys.stderr,
        )
        return 2

    entries, problems = repo_entries(run_manifest)
    if problems and not args.allow_unverified:
        for problem in problems:
            print(f"cannot pin cleanly — {problem}", file=sys.stderr)
        return 2

    manifest: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "version": args.version,
        "generatedAt": utc_now(),
        "certifiedBy": {
            "runId": run_manifest.get("runId", ""),
            "status": run_status,
            "profile": run_manifest.get("profile", ""),
            "engineSpec": run_manifest.get("engineSpec", ""),
            "coverage": run_manifest.get("coverage", {}),
            "serviceInventoryStatus": run_manifest.get("serviceInventoryStatus", ""),
            "stages": stage_reports(run_dir),
        },
        "repos": sorted(entries, key=lambda e: e["name"]),
    }
    if not certified or problems:
        manifest["provisional"] = {
            "reason": f"generated with --allow-unverified from a '{run_status}' run",
            "problems": problems,
        }

    out = Path(args.out)
    out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    label = "provisional " if "provisional" in manifest else ""
    print(f"wrote {label}{out} — {len(entries)} repos pinned from run {manifest['certifiedBy']['runId']}")
    for entry in manifest["repos"]:
        print(f"  {entry['name']:26s} {entry['sha'][:12]}")
    return 0


# ── verify ──────────────────────────────────────────────────────────────────


def cmd_verify(args: argparse.Namespace) -> int:
    manifest = load_json(Path(args.manifest))
    workspace = Path(args.workspace).resolve()

    drift: list[str] = []
    missing: list[str] = []
    ok = 0

    for entry in manifest.get("repos", []):
        name = entry["name"]
        pinned = entry["sha"]
        repo_path = workspace / name

        if not (repo_path / ".git").exists():
            missing.append(f"{name}: not checked out at {repo_path}")
            continue

        # A pinned commit only means anything if it is present locally; a
        # checkout that never fetched it would otherwise read as clean drift.
        if git(repo_path, "cat-file", "-t", pinned) != "commit":
            drift.append(f"{name}: pinned commit {pinned[:12]} is not in this checkout")
            continue

        head = git(repo_path, "rev-parse", "HEAD")
        if head != pinned:
            drift.append(f"{name}: HEAD {head[:12]} != pinned {pinned[:12]}")
            continue

        # Only tracked modifications count. Untracked files are build output and
        # editor state — they do not change what the commit contains, and
        # treating them as drift makes every real developer machine look
        # drifted, which trains people to pass --allow-dirty reflexively.
        dirty = git(repo_path, "status", "--porcelain", "--untracked-files=no")
        if dirty and not args.allow_dirty:
            count = len(dirty.splitlines())
            drift.append(
                f"{name}: at the pinned commit but has {count} modified tracked file(s)"
            )
            continue

        ok += 1

    print(f"manifest {manifest.get('version', '?')} from run {manifest.get('certifiedBy', {}).get('runId', '?')}")
    print(f"  matching: {ok}/{len(manifest.get('repos', []))}")
    for item in missing + drift:
        print(f"  DRIFT: {item}")

    if "provisional" in manifest:
        print(f"  NOTE: provisional manifest — {manifest['provisional']['reason']}")

    return 1 if (missing or drift) else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="build a manifest from a regression run")
    gen.add_argument("--run-dir", help="regression run directory (reads manifest.json and reports/)")
    gen.add_argument("--manifest", help="path to a run manifest.json, if the run dir is unavailable")
    gen.add_argument("--version", required=True, help="release version, e.g. v0.1.0")
    gen.add_argument("--out", default="release-manifest.json")
    gen.add_argument(
        "--allow-unverified",
        action="store_true",
        help="pin from a run that did not pass, recording it as provisional",
    )
    gen.set_defaults(func=cmd_generate)

    ver = sub.add_parser("verify", help="check a workspace against a manifest")
    ver.add_argument("--manifest", default="release-manifest.json")
    ver.add_argument("--workspace", default="..", help="directory holding the sibling repos")
    ver.add_argument("--allow-dirty", action="store_true", help="ignore uncommitted changes")
    ver.set_defaults(func=cmd_verify)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
