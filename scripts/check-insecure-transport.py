#!/usr/bin/env python3
"""Fail a new plaintext endpoint or disabled certificate check (RealityEngine_CI#668, #727).

Every link between RealityEngine entities is TLS 1.3 (ENGINEERING_CONTRACT.md,
config/transport-profile.json). Code and configuration written before that
rule still carry plaintext URLs and disabled verification; they are recorded,
per file and per pattern, in config/insecure-transport-baseline.json, and each
is retired by its repository's TLS issue (config/transport-inventory.json).

This check scans the tracked code and configuration of every focus-set
repository and fails when a file's count for any pattern **exceeds** its
baseline, or a file not in the baseline has any. A count below the baseline
is progress; the check says so, and `--write` records it, so the baseline only
shrinks. Documentation (`*.md`) and generated OpenAPI documents are not scanned:
they describe endpoints rather than open them.

Not transport, never counted: XML/RDF/JSON-Schema namespace URIs and license
URLs (w3.org, json-schema.org, purl.org, xmlns.com, schema.org, apache.org
licenses), which are identifiers that no client connects to.

Usage:
  python3 scripts/check-insecure-transport.py            # check
  python3 scripts/check-insecure-transport.py --write    # record (shrink) the baseline
  python3 scripts/check-insecure-transport.py --root DIR # workspace root (default: CI's parent)
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

CI_DIR = Path(__file__).resolve().parent.parent
BASELINE = CI_DIR / "config" / "insecure-transport-baseline.json"
REPOS = [
    "RealityEngine_CI", "RealityEngine_Manager", "RealityEngine_Machines", "RealityEngine_CPP",
    "RealityEngine_LSP", "RealityEngine_Scala", "RealityEngine_Rust", "localAIStack",
    "localOpenClawStack", "localHealthkitBridge", "localAssetStorageStack",
]
SUFFIXES = {".sh", ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".yml", ".yaml", ".conf",
            ".lisp", ".asd", ".scala", ".sbt", ".cpp", ".hpp", ".h", ".cc", ".rs", ".swift",
            ".toml", ".ini", ".cnf"}
NAMES = {"Dockerfile", ".env.example", "Makefile"}
SKIP_PARTS = {"node_modules", "vendor", "openapi", "dist", "build", "target", ".git", "quicklisp"}
NAMESPACES = re.compile(
    r"http://(www\.w3\.org|json-schema\.org|purl\.org|xmlns\.com|schema\.org|www\.apache\.org/licenses"
    r"|www\.opengis\.net|ns\.adobe\.com|www\.iana\.org/assignments)\b")
# Files whose occurrences define or exercise the check and open no connection:
# the checker's own patterns, and its test's fixtures (the profile's "named test
# fixture" exception). Nothing else is ever added here.
NAMED_FIXTURES = {
    "scripts/check-insecure-transport.py",
    "scripts/tests/test-insecure-transport.sh",
    # Sends plaintext to the TLS registry shim to prove it is refused (#732).
    "scripts/tests/test-registry-tls.sh",
}
PATTERNS: dict[str, re.Pattern[str]] = {
    "plaintext-url": re.compile(r"\bhttp://"),
    "plaintext-ws": re.compile(r"\bws://"),
    "curl-insecure": re.compile(r"\bcurl\b[^\n|;&]*\s(-k|--insecure)\b"),
    "wget-no-check": re.compile(r"--no-check-certificate"),
    "node-reject-unauthorized": re.compile(r"rejectUnauthorized\s*:\s*false|NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*['\"]?0"),
    "python-verify-off": re.compile(r"verify\s*=\s*False|_create_unverified_context|CERT_NONE|check_hostname\s*=\s*False"),
    "go-skip-verify": re.compile(r"InsecureSkipVerify\s*:\s*true"),
}


def scanned(path: str) -> bool:
    p = Path(path)
    if any(part in SKIP_PARTS for part in p.parts):
        return False
    return p.suffix in SUFFIXES or p.name in NAMES


def count_file(text: str) -> Counter[str]:
    counts: Counter[str] = Counter()
    for line in text.splitlines():
        cleaned = NAMESPACES.sub("", line)
        for name, pattern in PATTERNS.items():
            counts[name] += len(pattern.findall(cleaned))
    return Counter({k: v for k, v in counts.items() if v})


def blobs_at(base: Path, ref: str) -> dict[str, str]:
    """Path -> text for every scanned file at `ref`, read from git, not the working tree."""
    listing = subprocess.run(["git", "-C", str(base), "ls-tree", "-r", "-z", ref],
                             capture_output=True, check=True).stdout.decode()
    wanted = []
    for entry in listing.split("\0"):
        if not entry:
            continue
        meta, rel = entry.split("\t", 1)
        mode, kind, sha = meta.split()
        if kind == "blob" and mode != "120000" and scanned(rel):
            wanted.append((rel, sha))
    if not wanted:
        return {}
    batch = subprocess.run(["git", "-C", str(base), "cat-file", "--batch"],
                           input="\n".join(sha for _, sha in wanted).encode() + b"\n",
                           capture_output=True, check=True).stdout
    out, pos = {}, 0
    for rel, _ in wanted:
        header_end = batch.index(b"\n", pos)
        size = int(batch[pos:header_end].split()[2])
        body = batch[header_end + 1: header_end + 1 + size]
        out[rel] = body.decode("utf-8", errors="replace")
        pos = header_end + 1 + size + 1
    return out


def scan(root: Path, ref: str | None = None) -> tuple[dict[str, dict[str, int]], list[str]]:
    """Counts per file. Reads the working tree, or `ref` (e.g. origin/main) from git."""
    found: dict[str, dict[str, int]] = {}
    missing = []
    for repo in REPOS:
        base = root / repo
        if not (base / ".git").exists():
            missing.append(repo)
            continue
        if ref and repo != "RealityEngine_CI":
            # The repository running the check is scanned as checked out, so a
            # change that adds occurrences is counted in its own baseline.
            texts = blobs_at(base, ref)
        else:
            files = subprocess.run(["git", "-C", str(base), "ls-files", "-z"], capture_output=True, check=True).stdout
            texts = {}
            for rel in files.decode().split("\0"):
                if rel and scanned(rel):
                    try:
                        texts[rel] = (base / rel).read_text(encoding="utf-8", errors="replace")
                    except (OSError, IsADirectoryError):
                        continue
        for rel, text in texts.items():
            if repo == "RealityEngine_CI" and rel in NAMED_FIXTURES:
                continue
            counts = count_file(text)
            if counts:
                found[f"{repo}/{rel}"] = dict(sorted(counts.items()))
    return dict(sorted(found.items())), missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--root", type=Path, default=CI_DIR.parent)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--ref", help="scan this git ref (e.g. origin/main) in every sibling repository instead of its working tree; RealityEngine_CI is always scanned as checked out")
    args = parser.parse_args()

    found, missing = scan(args.root.resolve(), args.ref)
    if missing:
        print(f"insecure-transport: FAIL: {len(missing)} repositor{'y' if len(missing) == 1 else 'ies'} not "
              f"scanned under {args.root}: {', '.join(missing)}. Check them out beside RealityEngine_CI.", file=sys.stderr)
        return 1
    baseline = json.loads(args.baseline.read_text())["files"] if args.baseline.exists() else {}

    grown, shrunk = [], 0
    for path, counts in found.items():
        before = baseline.get(path, {})
        for name, n in counts.items():
            if n > before.get(name, 0):
                grown.append(f"{path}: {name} {before.get(name, 0)} -> {n}")
    for path, counts in baseline.items():
        for name, n in counts.items():
            if found.get(path, {}).get(name, 0) < n:
                shrunk += n - found.get(path, {}).get(name, 0)

    total = sum(sum(c.values()) for c in found.values())
    if args.write:
        if grown and args.baseline.exists():
            print("insecure-transport: refusing to write a baseline that grows:", file=sys.stderr)
            for g in grown:
                print(f"  {g}", file=sys.stderr)
            return 1
        args.baseline.write_text(json.dumps({
            "schemaVersion": "1.0.0",
            "purpose": "Insecure-transport occurrences recorded before the TLS 1.3 rule (RealityEngine_CI#668, #727). Counts only shrink: scripts/check-insecure-transport.py fails any increase, and --write records a decrease.",
            "files": found,
        }, indent=2) + "\n")
        print(f"insecure-transport: baseline written: {total} occurrence(s) in {len(found)} file(s)")
        return 0

    if grown:
        print(f"insecure-transport: FAIL: {len(grown)} new insecure-transport occurrence(s). Use https/wss and keep "
              "certificate verification on (config/transport-profile.json); trust the install CA, never disable checks.",
              file=sys.stderr)
        for g in grown:
            print(f"  {g}", file=sys.stderr)
        return 1
    note = f"; {shrunk} retired since the baseline: run with --write to record it" if shrunk else ""
    print(f"insecure-transport: OK: {total} recorded occurrence(s) in {len(found)} file(s), none new{note}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
