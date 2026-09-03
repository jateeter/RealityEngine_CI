#!/usr/bin/env python3
"""Generate regression run summary, comparison, and optional archive artifacts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import time
from typing import Any


def load_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def status_word(value: Any) -> str:
    if isinstance(value, dict):
        return str(value.get("status") or ("passed" if value.get("ok") else "failed"))
    return str(value or "not-run")


def collect_report_statuses(run_dir: Path) -> dict[str, Any]:
    reports = run_dir / "reports"
    responses = run_dir / "responses"
    manifest = load_json(run_dir / "manifest.json", {})

    service = load_json(reports / "service-inventory.json", {})
    # The parity result. ISRE/OSRE are the observation points the multi-engine
    # equivalence claim is made at; universal-vectors below is a contract check,
    # not a parity measurement (#148, and it diffs a debug projection).
    trajectory = load_json(responses / "trajectory-parity" / "trajectory-summary.json", {})
    universal = load_json(responses / "universal-vectors" / "summary.json", {})
    vector_comparison = load_json(responses / "universal-vectors" / "normalized-comparison.json", {})
    mcp = load_json(reports / "mcp-smoke.json", {})

    mqtt_reports = sorted(reports.glob("mqtt-yuma*.json"))
    openclaw_reports = sorted(reports.glob("openclaw*.json"))

    return {
        "manifest": manifest,
        "build": build_status(manifest),
        "serviceInventory": section_status(service),
        "trajectoryParity": section_status(trajectory, failure_key="failures"),
        "universalVectors": section_status(universal, failure_key="failures"),
        "universalVectorComparison": section_status(vector_comparison, failure_key="failures"),
        "mqtt": aggregate_reports(mqtt_reports),
        "mcp": section_status(mcp, failure_key="failures"),
        "openclaw": aggregate_reports(openclaw_reports),
        "deployment": {"status": "not-run", "reason": "deployment suite is not yet wired into regression-test.sh"},
        "reportFiles": {
            "serviceInventory": rel(run_dir, reports / "service-inventory.json"),
            "trajectoryParity": rel(run_dir, responses / "trajectory-parity" / "trajectory-summary.json"),
            "universalVectors": rel(run_dir, responses / "universal-vectors" / "summary.json"),
            "universalVectorComparison": rel(run_dir, responses / "universal-vectors" / "normalized-comparison.json"),
            "mcp": rel(run_dir, reports / "mcp-smoke.json"),
            "mqtt": [rel(run_dir, path) for path in mqtt_reports],
            "openclaw": [rel(run_dir, path) for path in openclaw_reports],
        },
    }


def rel(root: Path, path: Path) -> str:
    try:
        return str(path.relative_to(root)) if path.exists() else ""
    except ValueError:
        return str(path)


def build_status(manifest: dict[str, Any]) -> dict[str, Any]:
    repos = manifest.get("repos", []) if isinstance(manifest, dict) else []
    build_entries = []
    failures = []
    for repo in repos:
        commands = repo.get("commands", [])
        builds = [item for item in commands if item.get("phase") == "build"]
        status = repo.get("buildStatus")
        if builds and not status:
            status = "passed" if all(item.get("status") == "passed" for item in builds) else "failed"
        if status == "failed":
            failures.append(repo.get("name", "unknown"))
        build_entries.append(
            {
                "name": repo.get("name"),
                "originMainSha": repo.get("originMainSha"),
                "worktreeSha": repo.get("worktreeSha"),
                "buildStatus": status or "not-run",
                "commands": builds,
            }
        )
    overall = "failed" if failures else ("passed" if any(item["buildStatus"] == "passed" for item in build_entries) else "not-run")
    return {"status": overall, "repos": build_entries, "failures": failures}


def section_status(payload: dict[str, Any], failure_key: str = "failures") -> dict[str, Any]:
    if not payload:
        return {"status": "not-run", "failures": []}
    failures = payload.get(failure_key) or []
    status = payload.get("status") or ("failed" if failures else "passed")
    return {"status": status, "failures": failures, "warnings": payload.get("warnings", [])}


def aggregate_reports(paths: list[Path]) -> dict[str, Any]:
    if not paths:
        return {"status": "not-run", "reports": [], "failures": []}
    reports = []
    failures = []
    skipped = 0
    for path in paths:
        payload = load_json(path, {})
        status = payload.get("status", "unknown")
        if status == "skipped":
            skipped += 1
        if status not in ("passed", "skipped"):
            failures.extend(payload.get("failures", []) or payload.get("checks", {}).get("errors", []) or [path.name])
        reports.append({"file": path.name, "status": status, "payload": payload})
    if failures:
        status = "failed"
    elif skipped == len(paths):
        status = "skipped"
    else:
        status = "passed"
    return {"status": status, "reports": reports, "failures": failures}


def failure_key(item: Any) -> str:
    """A failure's identity, stable across runs.

    `compare_runs` diffs failure strings as sets, so anything varying between
    two runs of the same ongoing failure makes it appear as *both* a new failure
    and a resolved one — noise shaped exactly like the churn the comparison
    exists to surface.

    Since #174 the universal-vectors failure line carries the stimulus verdict
    and the per-runtime source counts:

        event-1 parity mismatch: cpp-1+scala-1 | lsp-1 [stimulus DIFFERS — source counts {…}]

    Those counts legitimately move run to run. The bracketed annotation is
    dropped for identity and kept for display, so the diff tracks "this event
    still mismatches with this cluster shape" while the reader still sees the
    detail (#230).

    Bare digit runs are normalised for the same reason — a failure naming a cell
    count or a step index is the same failure at a different depth.
    """
    text = str(item)
    text = re.sub(r"\s*\[[^\]]*\]\s*$", "", text)      # trailing [annotation]
    text = re.sub(r"\b\d+\b", "N", text)                # counts, indices, ports
    return " ".join(text.split())


def load_baseline(history_dir: Path, current_run_id: str, compare_run: str,
                  baseline_status: Path | None) -> tuple[dict[str, Any] | None, str]:
    """The previous run's section statuses, and the id they came from.

    Two sources, in order of preference:

    1. `--baseline-status`, a `regression-status.json` carried forward from the
       previous run. This is what the hosted lane uses: its workspace is fresh
       every run, so there is never a previous run *directory* to find, and the
       comparison reported `not-compared` on every scheduled run since it was
       written (#230). One small file is all `compare_runs` needs, so the whole
       run directory does not have to be persisted.
    2. A previous run directory under `history_dir/runs`, which is what the
       local lane has.
    """
    if baseline_status and baseline_status.is_file():
        payload = load_json(baseline_status, {})
        if payload:
            return payload, str(payload.get("runId") or baseline_status.stem)
    path = find_compare_run(history_dir, current_run_id, compare_run)
    if path is None:
        return None, compare_run
    return collect_report_statuses(path), path.name


def find_compare_run(history_dir: Path, current_run_id: str, compare_run: str) -> Path | None:
    runs_dir = history_dir / "runs"
    if compare_run:
        candidate = runs_dir / compare_run
        return candidate if candidate.is_dir() else None
    candidates: list[tuple[str, Path]] = []
    for path in sorted(runs_dir.glob("*")):
        if not path.is_dir() or path.name == current_run_id:
            continue
        manifest = load_json(path / "manifest.json", {})
        if manifest.get("status") == "completed":
            candidates.append((path.name, path))
    return candidates[-1][1] if candidates else None


def compare_runs(current: dict[str, Any], previous: dict[str, Any] | None, previous_id: str | None) -> dict[str, Any]:
    if previous is None:
        return {"status": "not-compared", "previousRunId": previous_id or "", "changes": [], "newFailures": [], "resolvedFailures": []}
    sections = ["build", "serviceInventory", "trajectoryParity", "universalVectors", "mqtt", "mcp",
                "arbiter", "openclaw", "deployment"]
    changes = []
    new_failures = []
    resolved_failures = []
    for section in sections:
        cur_status = status_word(current.get(section))
        prev_status = status_word(previous.get(section))
        if cur_status != prev_status:
            changes.append({"section": section, "previous": prev_status, "current": cur_status})
        # Keyed, not compared verbatim: an ongoing failure whose message
        # carries run-varying detail would otherwise report as both new and
        # resolved every night (#230). Display keeps the full string.
        cur_failures = {failure_key(f): str(f) for f in current.get(section, {}).get("failures", [])}
        prev_failures = {failure_key(f): str(f) for f in previous.get(section, {}).get("failures", [])}
        for key in sorted(set(cur_failures) - set(prev_failures)):
            new_failures.append({"section": section, "failure": cur_failures[key]})
        for key in sorted(set(prev_failures) - set(cur_failures)):
            resolved_failures.append({"section": section, "failure": prev_failures[key]})
    return {
        "status": "compared",
        "previousRunId": previous_id or "",
        "changes": changes,
        "newFailures": new_failures,
        "resolvedFailures": resolved_failures,
    }


def summary_markdown(run_dir: Path, status: dict[str, Any], comparison: dict[str, Any]) -> str:
    manifest = status.get("manifest", {})
    lines = [
        f"# Regression Test Run {manifest.get('runId', run_dir.name)}",
        "",
        f"- Status: `{manifest.get('status', 'unknown')}`",
        f"- Branch: `{manifest.get('branch', '')}`",
        f"- Run branch: `{manifest.get('worktreeBranch', '')}`",
        f"- Engine spec: `{manifest.get('engineSpec', '')}`",
        f"- Finished at: `{manifest.get('finishedAt', '')}`",
        "",
        "## Results",
        "",
    ]
    for label, key in (
        ("Build", "build"),
        ("Service readiness", "serviceInventory"),
        ("ISRE/OSRE trajectory parity", "trajectoryParity"),
        ("Universal vectors (contract)", "universalVectors"),
        ("MQTT Yuma", "mqtt"),
        ("MCP", "mcp"),
        ("Arbiter conformance", "arbiter"),
        ("OpenClaw", "openclaw"),
        ("Deployment suite", "deployment"),
    ):
        section = status.get(key, {})
        lines.append(f"- {label}: `{section.get('status', 'not-run')}`")
        failures = section.get("failures", [])
        if failures:
            lines.append(f"  - Failures: {len(failures)}")
    lines.extend([
        "",
        "## Comparison",
        "",
        f"- Previous run: `{comparison.get('previousRunId', '')}`",
        f"- Status: `{comparison.get('status', 'not-compared')}`",
        f"- Changed sections: `{len(comparison.get('changes', []))}`",
        f"- New failures: `{len(comparison.get('newFailures', []))}`",
        f"- Resolved failures: `{len(comparison.get('resolvedFailures', []))}`",
        "",
        "## Artifacts",
        "",
        "- `manifest.json`",
        "- `summary.md`",
        "- `reports/`",
        "- `responses/`",
        "- `logs/`",
    ])
    return "\n".join(lines) + "\n"


def archive_run(run_dir: Path, archive_root: Path) -> Path:
    target = archive_root / run_dir.name
    if target.exists():
        shutil.rmtree(target)
    ignore = shutil.ignore_patterns("worktrees", "node_modules", "*.sock")
    shutil.copytree(run_dir, target, ignore=ignore)
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--history-dir", type=Path, required=True)
    parser.add_argument("--compare-run", default="")
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--baseline-status", type=Path,
                        help="regression-status.json from the previous run. The hosted lane has "
                             "no previous run directory — its workspace is fresh every run — so "
                             "this is how it gets a baseline (#230).")
    args = parser.parse_args()

    manifest = load_json(args.run_dir / "manifest.json", {})
    current = collect_report_statuses(args.run_dir)
    previous, previous_id = load_baseline(
        args.history_dir, manifest.get("runId", args.run_dir.name), args.compare_run, args.baseline_status
    )
    comparison = compare_runs(current, previous, previous_id)
    comparison["generatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    # The machine-readable status, written for two consumers that both had to
    # parse summary.md otherwise: the next run's comparison baseline (#230) and
    # the failure-signature the issue filer keys on (#229).
    status_doc = dict(current)
    status_doc["runId"] = manifest.get("runId", args.run_dir.name)
    status_doc["failingSections"] = sorted(
        name for name, block in current.items()
        if isinstance(block, dict) and block.get("status") == "failed"
    )
    write_json(args.run_dir / "reports" / "regression-status.json", status_doc)

    write_json(args.run_dir / "reports" / "regression-comparison.json", comparison)
    (args.run_dir / "summary.md").write_text(summary_markdown(args.run_dir, current, comparison), encoding="utf-8")
    if args.archive:
        target = archive_run(args.run_dir, args.archive)
        comparison["archivePath"] = str(target)
        write_json(args.run_dir / "reports" / "regression-comparison.json", comparison)
    print(args.run_dir / "summary.md")
    print(args.run_dir / "reports" / "regression-comparison.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
