#!/usr/bin/env python3
"""Check the transport profile and the link inventory (RealityEngine_CI#668, #725).

config/transport-profile.json is the TLS profile every link must meet.
config/transport-inventory.json lists every link between RealityEngine
entities, its status today and the issue that brings it to the profile.

Checks, always:
- the profile is well formed: TLS 1.3 only, AEAD suites only, at least one
  post-quantum hybrid group preferred;
- every link is well formed: a unique id, a status from the defined set, lanes
  from the defined set, an owner in the focus set, and an implementation
  issue written <repo>#<n>;
- no link claims `compliant` or `mtls: true` without a probe record (#728).

With --require-compliant (the release gate, #729): every link must be
`compliant` with `mtls: true`. Until then the check reports progress and
passes.

Usage:
  python3 scripts/check-transport-inventory.py
  python3 scripts/check-transport-inventory.py --require-compliant
  python3 scripts/check-transport-inventory.py --profile P --inventory I   # tests
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import sys
from pathlib import Path
from typing import Any

CI_DIR = Path(__file__).resolve().parent.parent
STATUSES = {"plaintext", "tls", "compliant", "unverified"}
LANES = {"native", "docker", "release"}
OWNERS = {
    "RealityEngine_CI", "RealityEngine_Manager", "RealityEngine_Machines", "RealityEngine_CPP",
    "RealityEngine_LSP", "RealityEngine_Scala", "RealityEngine_Rust", "localAIStack",
    "localOpenClawStack", "localHealthkitBridge", "localAssetStorageStack",
}
AEAD = {"TLS_AES_256_GCM_SHA384", "TLS_CHACHA20_POLY1305_SHA256", "TLS_AES_128_GCM_SHA256"}
PQ_HYBRID = {"X25519MLKEM768", "SecP256r1MLKEM768", "SecP384r1MLKEM1024"}
ISSUE = re.compile(r"^[A-Za-z_]+#\d+$")


def profile_problems(profile: dict[str, Any]) -> list[str]:
    out = []
    raw_tls = profile.get("tls")
    tls: dict[str, Any] = raw_tls if isinstance(raw_tls, dict) else {}
    if tls.get("versions") != ["TLSv1.3"]:
        out.append(f"profile: tls.versions must be exactly [\"TLSv1.3\"], got {tls.get('versions')!r}")
    suites = tls.get("cipherSuites") or []
    if not suites or any(s not in AEAD for s in suites):
        out.append(f"profile: cipherSuites must be non-empty TLS 1.3 AEAD suites, got {suites!r}")
    raw_groups = tls.get("keyExchangeGroups")
    groups: dict[str, Any] = raw_groups if isinstance(raw_groups, dict) else {}
    if not set(groups.get("preferred") or []) & PQ_HYBRID:
        out.append("profile: keyExchangeGroups.preferred must include a post-quantum hybrid group")
    if not profile.get("profileId"):
        out.append("profile: profileId is required (a release records the profile it was certified under)")
    return out


def link_problems(inventory: dict[str, Any]) -> list[str]:
    out = []
    links = inventory.get("links")
    if not isinstance(links, list) or not links:
        return ["inventory: links must be a non-empty list"]
    seen = collections.Counter(str(link.get("id")) for link in links)
    out += [f"inventory: duplicate link id {i!r}" for i, n in seen.items() if n > 1]
    for link in links:
        lid = link.get("id") or "<no id>"
        for key in ("id", "from", "to", "protocol", "owner", "issue", "status"):
            if not link.get(key):
                out.append(f"{lid}: {key} is required")
        if link.get("status") and link["status"] not in STATUSES:
            out.append(f"{lid}: status {link['status']!r} is not one of {sorted(STATUSES)}")
        lanes = link.get("lanes")
        if not isinstance(lanes, list) or not lanes or any(lane not in LANES for lane in lanes):
            out.append(f"{lid}: lanes must be a non-empty subset of {sorted(LANES)}")
        if link.get("owner") and link["owner"] not in OWNERS:
            out.append(f"{lid}: owner {link['owner']!r} is not a focus-set repository")
        if link.get("issue") and not ISSUE.match(str(link["issue"])):
            out.append(f"{lid}: issue must be written <repo>#<n>, got {link['issue']!r}")
        if not isinstance(link.get("mtls"), bool):
            out.append(f"{lid}: mtls must be true or false")
        claims = link.get("status") == "compliant" or link.get("mtls") is True
        if claims and not isinstance(link.get("probe"), dict):
            out.append(f"{lid}: compliant or mtls claimed without a probe record (RealityEngine_CI#728)")
    return out


def gate_problems(inventory: dict[str, Any]) -> list[str]:
    return [
        f"{link['id']}: {link['status']}{'' if link.get('mtls') else ', no mTLS'} (owner {link['owner']}, {link['issue']})"
        for link in inventory.get("links", [])
        if link.get("status") != "compliant" or link.get("mtls") is not True
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profile", type=Path, default=CI_DIR / "config" / "transport-profile.json")
    parser.add_argument("--inventory", type=Path, default=CI_DIR / "config" / "transport-inventory.json")
    parser.add_argument("--require-compliant", action="store_true")
    args = parser.parse_args()

    profile = json.loads(args.profile.read_text())
    inventory = json.loads(args.inventory.read_text())
    problems = profile_problems(profile) + link_problems(inventory)
    if problems:
        print(f"transport-inventory: {len(problems)} problem(s)", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1

    links = inventory["links"]
    by_status = collections.Counter(link["status"] for link in links)
    mtls = sum(1 for link in links if link["mtls"])
    summary = ", ".join(f"{by_status[s]} {s}" for s in ("compliant", "tls", "plaintext", "unverified") if by_status[s])
    print(f"transport-inventory: {len(links)} links under {profile['profileId']}: {summary}; {mtls} with mTLS")

    if args.require_compliant:
        gaps = gate_problems(inventory)
        if gaps:
            print(f"transport-inventory: release gate FAILS: {len(gaps)} link(s) not compliant with mTLS", file=sys.stderr)
            for g in gaps:
                print(f"  {g}", file=sys.stderr)
            return 1
        print("transport-inventory: release gate passes: every link compliant with mTLS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
