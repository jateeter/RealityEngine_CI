#!/usr/bin/env python3
"""Pin every repo in the application to a SHA, so a release can be rebuilt exactly.

A release manifest is derived from a *regression run*, not from whatever
happens to be on main. The run already records, per repo, the remote it came
from and the commit the build actually used, so pinning from it means the
pinned set is the set that was certified — the manifest and the evidence for it
come from the same place.

    generate   build a manifest from a regression run
    verify     check a workspace against a manifest
    check      check a manifest is eligible to be cut (ReleaseRoadmap E4)
    published  check the remotes and the registry against a manifest

A release manifest pins three things (RELEASE.md, What a release is):

  - every repo, at the commit the certifying run built;
  - every release image, by digest, from the candidate images file
    (`--images`), each built from its repo's pinned commit;
  - the evidence: the certifying run on those images (the local-containerized
    lane, E1) and the native local lane at the same commits (F1), each with its
    structured stage results and every omission's recorded reason.

Generating from a run that did not pass is refused rather than defaulted, the
same way the harness refuses a profile violation. A manifest that silently
pinned a red run would be indistinguishable from one that pinned a green run,
which is the property that makes it worth having. `--allow-unverified` overrides
and records the override in the manifest itself.

Examples

    # Pin from a local regression run
    scripts/release-manifest.py generate \\
        --run-dir .regression-tests/runs/gha-31297685782-1 \\
        --version release-v0.0.1 --out release-manifest.json

    # Pin from a downloaded CI artifact
    scripts/release-manifest.py generate \\
        --manifest ./artifacts/gha-123-1/manifest.json \\
        --version release-v0.0.1 --out release-manifest.json

    # A release: E1's run pins, the candidate's images, the native lane
    scripts/release-manifest.py generate \\
        --run-dir .regression-tests/runs/e1-rc6-cert-20261029a \\
        --images release/candidates/release-v0.0.1-rc6.images.json \\
        --native-run-dir .regression-tests/runs/f1-native-rc6-20261029a \\
        --omission healthkit-bridge="A10: no iPhone on the certifying Mac" \\
        --version release-v0.0.1 --out releases/release-v0.0.1.json

    # Confirm a workspace matches
    scripts/release-manifest.py verify --manifest release-manifest.json

    # Before tagging: no remote tag or registry tag in the way (cut-release.sh)
    scripts/release-manifest.py published --manifest M --expect absent-or-equal
    # After publishing: every tag and image resolves to the manifest (F4)
    scripts/release-manifest.py published --manifest M --expect equal
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
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


# Application releases are tagged release-vN.M.Z (release-vN.M.Z-rcN for a
# candidate): D1 in docs/MVP_ROADMAP.md. A plain vN.M.Z is a component's own
# release and would collide across repos. `untagged` is the placeholder every
# regression run uses for the candidate manifest it emits (regression-test.sh);
# it is accepted here and refused by cut-release.sh, so it can never be cut.
RELEASE_VERSION_RE = re.compile(r"^release-v\d+\.\d+\.\d+(-rc\d+)?$")
UNTAGGED = "untagged"


# ── evidence: structured stage results, omissions, images ──────────────────

# Stages a release cannot be cut without, on either lane. Their names are the
# keys of `stages` in the run's reports/regression-status.json, the structured
# record; stage-results.tsv is never read, because it records a skipped stage's
# wrapper exit as success. pim-mirror is required by decision D2
# (MVP_ROADMAP.md, 2026-09-25).
REQUIRED_STAGES = (
    "service-inventory",
    "trajectory-parity",
    "universal-vectors",
    "machine-set-parity",
    "export-parity",
    "pe-step-contract",
    "engine-process-parity",
    "mcp",
    "openclaw",
    "local-ai",
    "pim-mirror",
)
CERTIFYING_LANE = "local-containerized"
NATIVE_LANE = "local"
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def stage_results(run_dir: Path | None) -> dict[str, dict[str, str]]:
    """Every stage and section result from reports/regression-status.json.

    Stages come from its `stages` map; the summary's sections that are not
    stages (the deployment suite, for one) are added as `section:<key>`, so
    the manifest carries everything the run summary reports.
    """
    if run_dir is None:
        return {}
    path = run_dir / "reports" / "regression-status.json"
    if not path.is_file():
        return {}
    status = load_json(path)
    out: dict[str, dict[str, str]] = {}
    for name, block in (status.get("stages") or {}).items():
        entry = {"status": str(block.get("status", "not-run"))}
        if block.get("reason"):
            entry["reason"] = str(block["reason"])
        out[name] = entry
    for key in ("build", "deployment"):
        section = status.get(key)
        if isinstance(section, dict):
            out[f"section:{key}"] = {"status": str(section.get("status", "not-run"))}
    return out


def parse_pairs(values: list[str] | None, flag: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for value in values or []:
        name, sep, reason = value.partition("=")
        if not sep or not name.strip() or not reason.strip():
            raise SystemExit(f"{flag} takes NAME=REASON, got {value!r}")
        out[name.strip()] = reason.strip()
    return out


def lane_evidence(run_dir: Path, omissions: dict[str, str]) -> dict[str, Any]:
    run = load_json(run_dir / "manifest.json")
    results = stage_results(run_dir)
    return {
        "runId": run.get("runId", ""),
        "status": run.get("status", "unknown"),
        "profile": run.get("profile", ""),
        "engineSpec": run.get("engineSpec", ""),
        "stageResults": results,
        "omissions": {k: v for k, v in omissions.items() if k in results},
    }


def images_entries(path: Path) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    raw = path.read_bytes()
    doc = json.loads(raw)
    entries = [
        {
            "name": i.get("name", ""),
            "repo": i.get("repo", ""),
            "revision": i.get("revision", ""),
            "ref": i.get("ref", ""),
            "digest": i.get("digest") or "",
        }
        for i in doc.get("images", [])
    ]
    meta = {
        "tag": doc.get("tag", ""),
        "registry": doc.get("registry", ""),
        "platform": doc.get("platform", ""),
        "pushed": bool(doc.get("pushed")),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }
    return sorted(entries, key=lambda e: e["name"]), meta


def lane_problems(label: str, lane: dict[str, Any], profile: str) -> list[str]:
    problems: list[str] = []
    run_id = lane.get("runId", "?")
    if lane.get("profile") != profile:
        problems.append(f"{label}: run {run_id} is profile '{lane.get('profile')}', not '{profile}'")
    if lane.get("status") != CERTIFIED_RUN_STATUS:
        problems.append(f"{label}: run {run_id} status is '{lane.get('status')}', not '{CERTIFIED_RUN_STATUS}'")
    results = lane.get("stageResults") or {}
    if not results:
        problems.append(f"{label}: run {run_id} has no structured stage results (reports/regression-status.json)")
        return problems
    omissions = lane.get("omissions") or {}
    for name in REQUIRED_STAGES:
        if name not in results:
            problems.append(f"{label}: required stage {name} is missing from run {run_id}")
    for name, entry in sorted(results.items()):
        status = entry.get("status")
        required = name in REQUIRED_STAGES or "parity" in name
        if status == "passed":
            continue
        if status == "failed" or required:
            why = " (required; D2)" if name == "pim-mirror" else " (required)" if required else ""
            problems.append(f"{label}: stage {name} is {status}{why}")
        elif name not in omissions:
            problems.append(
                f"{label}: stage {name} is {status} with no recorded decision; "
                f"pass --omission {name}=REASON if the release accepts it")
    return problems


def eligibility(manifest: dict[str, Any]) -> list[str]:
    """Why this manifest may not be cut; empty when it may (ReleaseRoadmap E4)."""
    problems: list[str] = []
    version = manifest.get("version", "")
    if not RELEASE_VERSION_RE.match(version):
        return [f"version '{version}' is not an application release tag"]
    if "provisional" in manifest:
        problems.append(f"provisional manifest: {manifest['provisional'].get('reason', '')}")

    certified = manifest.get("certifiedBy") or {}
    if not certified.get("stageResults"):
        problems.append("the E1 lane is missing: certifiedBy records no structured stage results")
    else:
        problems += lane_problems("E1", certified, CERTIFYING_LANE)

    for name, status in sorted((certified.get("stages") or {}).items()):
        if status in ("failed", "unreadable"):
            problems.append(f"E1: report {name} is {status}")

    final = "-rc" not in version
    native = certified.get("native")
    if native:
        problems += lane_problems("native", native, NATIVE_LANE)
        drift = native.get("drift") or {}
        for name, entry in sorted(drift.items()):
            if not entry.get("reason"):
                problems.append(
                    f"native: {name} ran at {entry.get('sha', '?')[:12]}, not the pin; "
                    f"pass --native-drift {name}=REASON if the release accepts it")
    elif final:
        problems.append("the native lane is missing: a release needs --native-run-dir (F1)")

    pins = {r["name"]: r["sha"] for r in manifest.get("repos", [])}
    images = manifest.get("images") or []
    if not images:
        problems.append("no images: a release includes its images (A2); generate with --images")
    for image in images:
        name = image.get("name", "?")
        if not DIGEST_RE.match(image.get("digest", "")):
            problems.append(f"image {name}: no digest")
        repo = image.get("repo", "")
        if repo not in pins:
            problems.append(f"image {name}: built from {repo or '?'}, which the manifest does not pin")
        elif image.get("revision") != pins[repo]:
            problems.append(
                f"image {name}: revision {str(image.get('revision'))[:12]} differs from "
                f"{repo}'s pin {pins[repo][:12]}")
    meta = manifest.get("imagesFile") or {}
    if images and not meta.get("pushed"):
        problems.append(f"images file {meta.get('tag', '?')} was not pushed to a registry")
    return problems


def cmd_generate(args: argparse.Namespace) -> int:
    if args.version != UNTAGGED and not RELEASE_VERSION_RE.match(args.version):
        print(f"--version {args.version!r} is not an application release tag: expected "
              "release-vN.M.Z or release-vN.M.Z-rcN (or 'untagged' for a run's candidate). "
              "See RELEASE.md, Tag conventions.", file=sys.stderr)
        return 2
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

    omissions = parse_pairs(args.omission, "--omission")
    certified_by: dict[str, Any] = {
        "runId": run_manifest.get("runId", ""),
        "status": run_status,
        "profile": run_manifest.get("profile", ""),
        "engineSpec": run_manifest.get("engineSpec", ""),
        "coverage": run_manifest.get("coverage", {}),
        "serviceInventoryStatus": run_manifest.get("serviceInventoryStatus", ""),
        "stages": stage_reports(run_dir),
    }
    results = stage_results(run_dir)
    if results:
        certified_by["stageResults"] = results
        certified_by["omissions"] = {k: v for k, v in omissions.items() if k in results}

    pins = {e["name"]: e["sha"] for e in entries}
    if args.native_run_dir:
        native_dir = Path(args.native_run_dir).resolve()
        native = lane_evidence(native_dir, omissions)
        reasons = parse_pairs(args.native_drift, "--native-drift")
        drift: dict[str, Any] = {}
        for repo in load_json(native_dir / "manifest.json").get("repos", []):
            name, sha = repo.get("name", ""), repo.get("worktreeSha") or ""
            if name in pins and sha != pins[name]:
                drift[name] = {"sha": sha}
                if name in reasons:
                    drift[name]["reason"] = reasons[name]
        native["drift"] = drift
        certified_by["native"] = native

    manifest: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "version": args.version,  # validated in main(): release-vN.M.Z[-rcN]
        "generatedAt": utc_now(),
        "certifiedBy": certified_by,
        "repos": sorted(entries, key=lambda e: e["name"]),
    }

    if args.images:
        images, meta = images_entries(Path(args.images))
        manifest["images"] = images
        manifest["imagesFile"] = meta
        # The certifying run must have run exactly these images: the
        # containerized lane records what it installed in reports/images.json.
        ran = run_dir / "reports" / "images.json" if run_dir else None
        if ran and ran.is_file():
            ran_digests = {i["name"]: i.get("digest") for i in load_json(ran).get("images", [])}
            for image in images:
                if ran_digests.get(image["name"]) != image["digest"]:
                    problems.append(
                        f"image {image['name']}: run {certified_by['runId']} ran "
                        f"{str(ran_digests.get(image['name']))[:19]}, not {image['digest'][:19]}")
        elif certified_by["profile"] == CERTIFYING_LANE:
            problems.append(f"run {certified_by['runId']} recorded no reports/images.json")

    if args.version != UNTAGGED:
        problems += [p for p in eligibility(manifest) if not p.startswith("provisional")]
    if problems and not args.allow_unverified:
        for problem in problems:
            print(f"not eligible — {problem}", file=sys.stderr)
        return 2

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


# ── check ───────────────────────────────────────────────────────────────────


def cmd_check(args: argparse.Namespace) -> int:
    manifest = load_json(Path(args.manifest))
    problems = eligibility(manifest)
    if problems:
        print(f"{manifest.get('version', '?')} is not eligible to be cut:", file=sys.stderr)
        for problem in problems:
            print(f"  REFUSED: {problem}", file=sys.stderr)
        return 1
    certified = manifest["certifiedBy"]
    print(f"{manifest['version']} is eligible: {len(manifest['repos'])} repos, "
          f"{len(manifest['images'])} images, E1 run {certified['runId']}"
          + (f", native run {certified['native']['runId']}" if certified.get("native") else ""))
    return 0


# ── published ───────────────────────────────────────────────────────────────


def remote_tag(repo_path: Path, tag: str) -> str | None:
    """The commit `tag` names on origin, None when origin has no such tag."""
    out = subprocess.run(
        ["git", "-C", str(repo_path), "ls-remote", "--tags", "origin",
         f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"],
        capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"git ls-remote failed: {out.stderr.strip()[:200]}")
    refs = dict(reversed(line.split("\t", 1)) for line in out.stdout.splitlines() if "\t" in line)
    return refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")


def registry_digest(ref: str) -> str | None:
    """The digest `ref` resolves to in its registry, None when it has none.

    RE_IMAGETOOLS replaces `docker buildx imagetools`, for tests.
    """
    tool = shlex.split(os.environ.get("RE_IMAGETOOLS", "docker buildx imagetools"))
    out = subprocess.run([*tool, "inspect", "--format", "{{.Manifest.Digest}}", ref],
                         capture_output=True, text=True)
    if out.returncode == 0:
        return out.stdout.strip() or None
    if re.search(r"not found|MANIFEST_UNKNOWN|manifest unknown|no such manifest", out.stderr, re.I):
        return None
    raise RuntimeError(f"cannot inspect {ref}: {out.stderr.strip()[:200]}")


def cmd_published(args: argparse.Namespace) -> int:
    """Remote tags and registry tags against the manifest.

    absent-or-equal (before tagging): nothing carries the tag at a different
    commit or digest, and each candidate digest is still in the registry.
    equal (after publishing, F4): every repo's origin and every image carry the
    tag, at the manifest's commit and digest. A partial publication fails.
    """
    manifest = load_json(Path(args.manifest))
    workspace = Path(args.workspace).resolve()
    version = manifest["version"]
    want_equal = args.expect == "equal"
    errors: list[str] = []
    ok = 0

    for entry in manifest.get("repos", []):
        name, sha = entry["name"], entry["sha"]
        try:
            found = remote_tag(workspace / name, version)
        except RuntimeError as exc:
            errors.append(f"{name}: {exc}")
            continue
        if found is None:
            if want_equal:
                errors.append(f"{name}: origin has no {version}")
            else:
                ok += 1
        elif found != sha:
            errors.append(f"{name}: origin has {version} at {found[:12]}, manifest pins {sha[:12]}")
        else:
            ok += 1

    for image in manifest.get("images", []):
        ref, digest = image["ref"], image["digest"]
        try:
            if not want_equal and registry_digest(f"{ref}@{digest}") != digest:
                errors.append(f"{image['name']}: candidate digest {digest[:19]} is not in {ref}")
                continue
            found = registry_digest(f"{ref}:{version}")
        except RuntimeError as exc:
            errors.append(f"{image['name']}: {exc}")
            continue
        if found is None:
            if want_equal:
                errors.append(f"{image['name']}: {ref}:{version} does not exist")
            else:
                ok += 1
        elif found != digest:
            errors.append(f"{image['name']}: {ref}:{version} is {found[:19]}, manifest pins {digest[:19]}")
        else:
            ok += 1

    total = len(manifest.get("repos", [])) + len(manifest.get("images", []))
    print(f"{version} ({args.expect}): {ok}/{total} repo tags and images as expected")
    for error in errors:
        print(f"  ERROR: {error}")
    return 1 if errors else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="build a manifest from a regression run")
    gen.add_argument("--run-dir", help="regression run directory (reads manifest.json and reports/)")
    gen.add_argument("--manifest", help="path to a run manifest.json, if the run dir is unavailable")
    gen.add_argument("--version", required=True,
                     help="application release tag: release-vN.M.Z or release-vN.M.Z-rcN")
    gen.add_argument("--out", default="release-manifest.json")
    gen.add_argument("--images", help="the candidate images file (release/candidates/<tag>.images.json)")
    gen.add_argument("--native-run-dir", help="the native local-lane run at the same commits (F1)")
    gen.add_argument("--omission", action="append", metavar="STAGE=REASON",
                     help="accept a skipped or not-run stage, recording why (repeatable)")
    gen.add_argument("--native-drift", action="append", metavar="REPO=REASON",
                     help="accept the native run at another commit of REPO, recording why (repeatable)")
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

    chk = sub.add_parser("check", help="check a manifest is eligible to be cut (E4)")
    chk.add_argument("--manifest", required=True)
    chk.set_defaults(func=cmd_check)

    pub = sub.add_parser("published", help="check remote tags and registry tags against a manifest")
    pub.add_argument("--manifest", required=True)
    pub.add_argument("--workspace", default="..", help="directory holding the sibling repos")
    pub.add_argument("--expect", choices=("absent-or-equal", "equal"), default="absent-or-equal")
    pub.set_defaults(func=cmd_published)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
