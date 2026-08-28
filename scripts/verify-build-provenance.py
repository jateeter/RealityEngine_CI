#!/usr/bin/env python3
"""Refuse to run a parity test against an engine that is not built from its source.

A parity sweep compares three runtimes and attributes every difference to the
engines. That attribution is only sound if all three are running the code you
think they are. When one is not, the sweep still produces a clean-looking result
— it just answers a different question, and nothing in the output says so.

This has cost real time. On 2026-08-22 a three-engine run reported Scala writing
cells C++ and LSP did not; the divergence was investigated, filed, and the
engines' source read closely. Both Scala jars predated that morning's merge:

    RealityEngine_Scala HEAD  fe8daf1  13:38:30
    perception-engine.jar              07:59:36   <- 5h39m stale
    reality-engine.jar                 13:08:02   <- 30m  stale

`startUniverse.sh` launches each repo's checked-in artifact, while the
regression harness rebuilds inside throwaway worktrees, so a stale main-repo
artifact survives a "rebuilt everything" run untouched. C++ and LSP were current
(LSP has no compiled artifact at all — SBCL loads the .lisp files at start), so
the comparison was current-vs-current-vs-yesterday and read as an engine defect.

The check is deliberately cheap and mechanical:

  git      the repo is on the expected branch, has no uncommitted source, and
           is not behind its remote. A dirty tree means the artifact cannot
           correspond to any commit; being behind means it corresponds to the
           wrong one.
  mtime    every declared artifact is newer than the newest tracked source file
           it is built from, and newer than the HEAD commit timestamp.

mtime is a weak proof and is used deliberately: it is cheap enough to run before
every launch, and it catches the failure that actually happens — someone merged,
and nobody rebuilt. It does not catch a rebuild from a different tree, and does
not try to.

Interpreted runtimes declare no artifacts. For those the git checks are the whole
check, which is correct: their source *is* what runs.

Usage:
    ./scripts/verify-build-provenance.py                 # report, exit 1 on any failure
    ./scripts/verify-build-provenance.py --warn-only     # report, always exit 0
    ./scripts/verify-build-provenance.py --repos cpp,scala
    ./scripts/verify-build-provenance.py --no-fetch      # skip the remote comparison
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

WS = Path(__file__).resolve().parent.parent.parent

# repo key -> (directory, [artifacts], [source globs])
# Artifacts are what startUniverse.sh actually launches, not what a build
# happens to produce. An engine with no artifact runs from source.
TARGETS: dict[str, dict] = {
    "cpp": {
        "dir": "RealityEngine_CPP",
        "artifacts": ["bin/reality_engine_server", "bin/perception_engine_server"],
        # Repo-wide fallback, kept for any artifact without an entry below.
        "sources": ["src/**/*.cpp", "src/**/*.hpp", "include/**/*.hpp"],
        # Per binary, from the Makefile link rules:
        #
        #   bin/reality_engine_server:    $(SRC_OBJ) src/reality_engine_server.o
        #   bin/perception_engine_server: $(SRC_OBJ) src/perception_engine_server.o
        #   SRC := reality arbiter http sta_checker mqtt_client mqtt_mapping mqtt_bridge
        #
        # The shared SRC set appears in both lists — correct and intended. What
        # this stops is an edit to src/perception_engine_server.cpp marking the
        # *Reality Engine* binary stale, which it does not link (#195).
        "artifact_sources": {
            "bin/reality_engine_server": [
                "src/reality.cpp", "src/arbiter.cpp", "src/http.cpp", "src/sta_checker.cpp",
                "src/mqtt_client.cpp", "src/mqtt_mapping.cpp", "src/mqtt_bridge.cpp",
                "src/reality_engine_server.cpp", "include/**/*.hpp",
            ],
            "bin/perception_engine_server": [
                "src/reality.cpp", "src/arbiter.cpp", "src/http.cpp", "src/sta_checker.cpp",
                "src/mqtt_client.cpp", "src/mqtt_mapping.cpp", "src/mqtt_bridge.cpp",
                "src/perception_engine_server.cpp", "include/**/*.hpp",
            ],
        },
    },
    "scala": {
        "dir": "RealityEngine_Scala",
        "artifacts": [
            "target/scala-2.13/reality-engine.jar",
            "perception-engine/target/scala-2.13/perception-engine.jar",
        ],
        "sources": ["src/main/scala/**/*.scala", "perception-engine/src/main/scala/**/*.scala"],
        # Two separate sbt builds with their own build.sbt and project/. The RE
        # jar is not produced by the PE build and does not depend on its
        # sources, so an edit under perception-engine/ must not mark it stale.
        "artifact_sources": {
            "target/scala-2.13/reality-engine.jar": ["src/main/scala/**/*.scala"],
            "perception-engine/target/scala-2.13/perception-engine.jar": [
                "perception-engine/src/main/scala/**/*.scala"],
        },
    },
    "lsp": {
        "dir": "RealityEngine_LSP",
        # This used to read "SBCL loads the .lisp files at start, so there is
        # nothing to go stale", with artifacts: []. That stopped being true.
        #
        # `make build` has always run save-lisp-and-die into bin/reality-engine-lsp,
        # and RealityEngine_LSP#62 made start.sh *launch* that image by default:
        # LSP_LAUNCH_MODE=auto prefers the binary when it is present, executable
        # and no older than src/, and falls back to a source load otherwise.
        #
        # So LSP acquired exactly the staleness this gate exists to catch, on
        # the one engine nobody would think to suspect — while the gate reported
        # "ok lsp: runs from source" and verified nothing at all.
        #
        # Optional, not required: a source-mode run legitimately has no image,
        # and demanding one would fail every lane that does not build it. But a
        # *stale* image is not benign, because auto mode will prefer it.
        "artifacts": [],
        "optional_artifacts": ["bin/reality-engine-lsp"],
        "sources": ["src/**/*.lisp"],
    },
    "machines": {"dir": "RealityEngine_Machines", "artifacts": [], "sources": []},
    "manager": {"dir": "RealityEngine_Manager", "artifacts": [], "sources": []},
    "localai": {"dir": "localAIStack", "artifacts": [], "sources": []},
    "openclaw": {"dir": "localOpenClawStack", "artifacts": [], "sources": []},
}


def git(repo: Path, *args: str) -> tuple[int, str]:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True, check=False
    )
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def newest_source(repo: Path, globs: list[str]) -> tuple[float, Path | None]:
    newest, where = 0.0, None
    for pattern in globs:
        for path in repo.glob(pattern):
            if not path.is_file():
                continue
            mtime = path.stat().st_mtime
            if mtime > newest:
                newest, where = mtime, path
    return newest, where


def head_commit_time(repo: Path) -> float:
    code, out = git(repo, "log", "-1", "--format=%ct")
    try:
        return float(out) if code == 0 else 0.0
    except ValueError:
        return 0.0


def source_commit_time(repo: Path, globs: list[str]) -> float:
    """Newest commit that touched any of `globs`.

    Not HEAD. Comparing an artifact against HEAD fails it after *any* commit,
    including a docs-only or CI-only merge that changed nothing the artifact is
    built from — which marked all three engines stale after a MACHINE_CONCEPT.md
    consolidation that touched no engine source (#195).

    The property this preserves is the one the gate exists for: a merge that
    changes engine source still moves the deadline, so an artifact built before
    it is still reported stale. That is the 2026-08-22 incident, where two Scala
    jars predated a merge by hours and a parity run attributed the resulting
    divergence to the engines.

    Falls back to HEAD when git cannot answer, which keeps the check
    conservative rather than silently permissive.
    """
    if not globs:
        return head_commit_time(repo)
    code, out = git(repo, "log", "-1", "--format=%ct", "--", *globs)
    if code != 0:
        return head_commit_time(repo)
    try:
        return float(out.strip()) if out.strip() else 0.0
    except ValueError:
        return head_commit_time(repo)


def artifact_sources(spec: dict, rel: str) -> list[str]:
    """Source globs a specific artifact is built from.

    `sources` stays the repo-wide fallback for artifacts with no entry, so a
    spec that has not been broken out behaves exactly as before.
    """
    per = spec.get("artifact_sources") or {}
    return per.get(rel) or (spec.get("sources") or [])


def ago(seconds: float) -> str:
    seconds = max(0, int(seconds))
    if seconds < 90:
        return f"{seconds}s"
    if seconds < 5400:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}m"


def check_repo(key: str, spec: dict, branch: str, fetch: bool, lane: str) -> list[str]:
    repo = WS / spec["dir"]
    failures: list[str] = []

    # A repository is `.git` as a directory (ordinary clone) or as a *file*
    # holding a `gitdir:` pointer (a `git worktree add` checkout). The harness
    # cold-starts into worktrees, so testing only for a directory rejected every
    # repo it builds — the gate failed closed on every hosted regression run
    # from 2026-08-24 onward, and the lane looked like it ran while never
    # starting a universe (#173).
    git_entry = repo / ".git"
    is_worktree = git_entry.is_file()
    if not (git_entry.is_dir() or is_worktree):
        # The e2e lane fetches siblings as tarballs and runs the engines as
        # containers, so there is no checkout and no local artifact to inspect.
        # Nothing here applies, and failing would only teach people to bypass it.
        if lane == "hosted":
            return []
        return [f"{key}: {repo} is not a git repository"]

    code, current = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if code != 0:
        return [f"{key}: cannot read HEAD ({current})"]
    # A harness worktree is deliberately on its own run-scoped branch
    # (`Regression-Test-gha-<run-id>`), so asserting `main` here would reject
    # the very trees the harness just built. What the gate is actually for —
    # that the artifact corresponds to the source beside it — is unaffected and
    # still enforced below: dirty-source and both artifact-freshness checks run
    # for worktrees exactly as they do for a clone.
    if not is_worktree and current != branch:
        failures.append(f"{key}: on '{current}', expected '{branch}'")

    # Only source counts as dirty. A generated artifact or a scratch file is not
    # evidence that the build is wrong, and failing on it would train people to
    # pass --warn-only, which defeats the check.
    _, porcelain = git(repo, "status", "--porcelain=v1")
    dirty = [
        line[3:]
        for line in porcelain.splitlines()
        if line[3:].endswith((".cpp", ".hpp", ".scala", ".lisp", ".py", ".ts", ".tsx"))
    ]
    if dirty:
        failures.append(
            f"{key}: {len(dirty)} uncommitted source file(s) — the artifact cannot "
            f"correspond to a commit: {', '.join(dirty[:3])}"
        )

    # Same reasoning as the branch check: a run-scoped worktree branch has no
    # meaningful ahead/behind relationship with origin/main, and the harness
    # created it from a known commit moments earlier.
    if fetch and not is_worktree:
        git(repo, "fetch", "--quiet", "origin", branch)
        code, counts = git(repo, "rev-list", "--left-right", "--count", f"origin/{branch}...HEAD")
        if code == 0 and "\t" in counts:
            behind, ahead = (int(x) for x in counts.split("\t")[:2])
            if behind:
                failures.append(
                    f"{key}: {behind} commit(s) behind origin/{branch} — running the wrong code"
                )
            if ahead:
                failures.append(f"{key}: {ahead} unpushed commit(s) ahead of origin/{branch}")

    now = time.time()

    required = list(spec.get("artifacts") or [])
    # Optional artifacts are launch *options*: absent is a supported state, but
    # a stale one is exactly as dangerous as a stale required artifact, because
    # the launcher will prefer it. Verified for freshness when present, never
    # required. See the `lsp` entry in TARGETS.
    optional = list(spec.get("optional_artifacts") or [])

    for rel in required + optional:
        art = repo / rel
        if not art.exists():
            if rel in optional:
                continue
            # Containerised lanes never materialise these paths. Only the lane
            # that launches them locally can meaningfully require them.
            if lane == "hosted":
                continue
            failures.append(f"{key}: artifact missing — {rel} (build it before launching)")
            continue
        # Resolved per artifact, not once per repo. One repo-wide "newest
        # source" marked bin/reality_engine_server stale for an edit to
        # src/perception_engine_server.cpp — a translation unit it does not
        # link — and demanded a rebuild `make` correctly refused to perform
        # (#195).
        globs = artifact_sources(spec, rel)
        src_mtime, src_path = newest_source(repo, globs)
        commit_time = source_commit_time(repo, globs)

        art_mtime = art.stat().st_mtime
        if src_mtime and art_mtime < src_mtime:
            failures.append(
                f"{key}: {rel} is {ago(src_mtime - art_mtime)} older than "
                f"{src_path.relative_to(repo) if src_path else 'its source'} — rebuild"
            )
        if commit_time and art_mtime < commit_time:
            failures.append(
                f"{key}: {rel} is {ago(commit_time - art_mtime)} older than the last "
                f"commit touching its sources ({ago(now - commit_time)} ago) — rebuild"
            )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repos", default="", help="comma-separated subset; default is all")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--warn-only", action="store_true", help="report but always exit 0")
    parser.add_argument("--no-fetch", action="store_true", help="skip the origin comparison")
    parser.add_argument("--lane", choices=("local", "hosted"), default="local",
                        help="local launches native artifacts and is fully checked; hosted runs "
                             "containers from tarball checkouts, where neither a git state nor a "
                             "local artifact exists to verify")
    args = parser.parse_args()

    keys = [k.strip() for k in args.repos.split(",") if k.strip()] or list(TARGETS)
    unknown = [k for k in keys if k not in TARGETS]
    if unknown:
        print(f"[fail] unknown repo key(s): {', '.join(unknown)}", file=sys.stderr)
        return 2

    print(f"build provenance — lane={args.lane} branch={args.branch} repos={len(keys)}")
    all_failures: list[str] = []
    for key in keys:
        failures = check_repo(key, TARGETS[key], args.branch, not args.no_fetch, args.lane)
        all_failures.extend(failures)
        if failures:
            for f in failures:
                print(f"  FAIL {f}")
        else:
            spec = TARGETS[key]
            repo = WS / spec["dir"]
            arts = len(spec.get("artifacts") or [])
            # Count only the optional artifacts that actually exist — those are
            # the ones freshness was checked against. Reporting a fixed count
            # would claim verification that did not happen, which is how
            # "ok lsp: runs from source" hid an unchecked launch image.
            opt_present = [
                rel for rel in (spec.get("optional_artifacts") or []) if (repo / rel).exists()
            ]
            checked = arts + len(opt_present)
            if args.lane == "hosted":
                note = "hosted lane — containerised, nothing local to verify"
            elif checked:
                note = f"{checked} artifact(s) current"
                if opt_present:
                    note += f" (incl. optional: {', '.join(opt_present)})"
            else:
                note = "no artifact present — runs from source"
            print(f"  ok   {key}: {note}")

    if not all_failures:
        print("\n[ok]   every engine is built from its current source")
        return 0

    print(
        f"\n[fail] {len(all_failures)} provenance problem(s). A parity result from this "
        "state attributes build skew to the engines.",
        file=sys.stderr,
    )
    if args.warn_only:
        print("[warn] --warn-only: continuing anyway", file=sys.stderr)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
