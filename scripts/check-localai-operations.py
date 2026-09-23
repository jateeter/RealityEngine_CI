#!/usr/bin/env python3
"""Check the curated localAI allow-list against what localAIStack serves.

`allowedOperations` on the `localai` integration in config/integrations.example.json
is a policy: the operations a Perception Engine may invoke through
POST /api/integrations/localai/invoke (INTEGRATION_ROADMAP.md §6 Q7, SURFACE_SPEC.md
"localAI invoke contract"). It is curated, not derived -- localAIStack serves routes
the PE should not reach -- so it can go stale in one direction only: an operation
listed here that localAIStack no longer serves. That is what this reports.

Exit 0: every listed operation is served. Exit 1: at least one is not, or the list
itself is malformed. Exit 2: localAIStack could not be asked. That is a finding,
not a pass; a check that cannot reach its authority has not checked anything.

Usage:
  scripts/check-localai-operations.py [--config PATH] [--base-url URL]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path

CI_DIR = Path(__file__).resolve().parent.parent


def allowed_operations(config_path: Path) -> list[dict]:
    data = json.loads(config_path.read_text())
    entries = [i for i in data.get("integrations", []) if i.get("kind") == "localai"]
    if len(entries) != 1:
        raise SystemExit(f"FAIL expected exactly one localai integration in {config_path}, found {len(entries)}")
    ops = entries[0].get("allowedOperations")
    if not isinstance(ops, list) or not ops:
        raise SystemExit(f"FAIL {config_path}: localai.allowedOperations is missing or empty")
    return ops


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(CI_DIR / "config" / "integrations.example.json"))
    ap.add_argument("--base-url", default=os.environ.get("LOCAL_AI_API_URL", "http://localhost:4000"))
    args = ap.parse_args()

    ops = allowed_operations(Path(args.config))
    problems: list[str] = []
    seen_ids: set[str] = set()
    seen_routes: set[tuple[str, str]] = set()
    for op in ops:
        oid, method, path = op.get("id"), str(op.get("method", "")).upper(), op.get("path")
        if not oid or not isinstance(path, str) or not path.startswith("/") or method not in ("GET", "POST"):
            problems.append(f"malformed entry {json.dumps(op)}")
            continue
        if oid in seen_ids:
            problems.append(f"duplicate id {oid}")
        if (method, path) in seen_routes:
            problems.append(f"duplicate route {method} {path}")
        seen_ids.add(oid)
        seen_routes.add((method, path))

    url = args.base_url.rstrip("/") + "/openapi.json"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            served = json.load(resp).get("paths", {})
    except Exception as exc:  # noqa: BLE001 -- any failure to ask is the same finding
        print(f"UNAVAILABLE could not read {url}: {exc}")
        return 2

    for method, path in sorted(seen_routes):
        if method.lower() not in {m.lower() for m in served.get(path, {})}:
            problems.append(f"{method} {path} is allowed but localAIStack does not serve it")

    unlisted = sorted(
        f"{m.upper()} {p}" for p, methods in served.items() for m in methods
        if (m.upper(), p) not in seen_routes
    )
    print(f"localAI allow-list: {len(seen_routes)} operation(s) checked against {url}")
    if unlisted:
        # Deliberately not a failure: the list is a policy, and a served route
        # that is not on it is unreachable by design. Printed so a new route is
        # a visible decision rather than a silent one.
        print("  served, not allowed (by policy): " + ", ".join(unlisted))
    for p in problems:
        print(f"  FAIL {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
