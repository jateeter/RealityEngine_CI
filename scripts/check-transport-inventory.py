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
- no link claims `compliant` or `mtls: true` without a probe record (#728) on
  every lane it lists, each agreeing with the claim;
- a `deficiency` (owner-accepted only) names who accepted it, what falls short,
  what compensates, the remedy, and `allows`: the status or mtls value it
  permits, and nothing more; `probeAccepts` names the probe findings it
  accepts (TLS 1.2 or a suite outside the profile on a server that cannot be
  restricted), which the probe stage then records instead of failing.

With --require-compliant (the release gate, #729): every link must be
`compliant`, and a service-to-service link must also have `mtls: true`, except
where an accepted deficiency `allows` otherwise, and such links are listed.
Until then the check reports progress and passes.

A link's `audience` says who is on the other end (owner, 2026-11-12):
- `service` (the default): two RealityEngine entities; mTLS
  (profile authentication.serviceToService).
- `user`: a person's browser or device; it exposes TLS only, server
  authentication at the profile with the user or device authenticated on top
  (profile authentication.usersAndDevices). No client certificate is required.
- `external`: an outside party; TLS only, held to the profile
  (profile externalParties). No client certificate is required.
User-facing and external links must expose TLS and nothing else: plaintext or
an unverified link fails the gate unless an owner deficiency records it.

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
AUDIENCES = {"service", "user", "external"}
OWNERS = {
    "RealityEngine_CI", "RealityEngine_Manager", "RealityEngine_Machines", "RealityEngine_CPP",
    "RealityEngine_LSP", "RealityEngine_Scala", "RealityEngine_Rust", "localAIStack",
    "localOpenClawStack", "localHealthkitBridge", "localAssetStorageStack",
    "OpenCommons-Health---Personal-Information-Management",
}
AEAD = {"TLS_AES_256_GCM_SHA384", "TLS_CHACHA20_POLY1305_SHA256", "TLS_AES_128_GCM_SHA256"}
PQ_HYBRID = {"X25519MLKEM768", "SecP256r1MLKEM768", "SecP384r1MLKEM1024"}
ISSUE = re.compile(r"^[A-Za-z0-9_.-]+#\d+$")  # a GitHub repository name, then #<n>


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
        if link.get("audience", "service") not in AUDIENCES:
            out.append(f"{lid}: audience {link.get('audience')!r} is not one of {sorted(AUDIENCES)}")
        if not isinstance(link.get("mtls"), bool):
            out.append(f"{lid}: mtls must be true or false")
        deficiency = link.get("deficiency")
        if deficiency is not None:
            if not isinstance(deficiency, dict):
                out.append(f"{lid}: deficiency must be an object")
            else:
                for key in ("accepted", "what", "compensation", "remedy", "allows"):
                    if not deficiency.get(key) and key != "allows":
                        out.append(f"{lid}: deficiency.{key} is required")
                allows = deficiency.get("allows")
                if not isinstance(allows, dict) or not allows or set(allows) - {"status", "mtls"}:
                    out.append(f"{lid}: deficiency.allows must name only status and/or mtls")
                elif "owner" not in str(deficiency.get("accepted", "")):
                    out.append(f"{lid}: a deficiency is accepted only by the owner")
                elif allows.get("status") not in (None, *STATUSES) or allows.get("mtls") not in (None, False):
                    out.append(f"{lid}: deficiency.allows has an invalid value")
                accepts = deficiency.get("probeAccepts")
                if accepts is not None and (not isinstance(accepts, list) or not accepts
                                            or set(accepts) - PROBE_ACCEPTABLE):
                    out.append(f"{lid}: deficiency.probeAccepts must list findings from {sorted(PROBE_ACCEPTABLE)}")
                sources = deficiency.get("sources")
                if sources is not None:
                    # Exact occurrences the insecure-transport gate allows for this
                    # deficiency (scripts/check-insecure-transport.py).
                    if (allows or {}).get("status") != "plaintext":
                        out.append(f"{lid}: deficiency.sources is only for a link allowed to be plaintext")
                    elif not isinstance(sources, list) or not sources or not all(
                        isinstance(x, dict) and set(x) == {"file", "pattern", "count"}
                        and isinstance(x["file"], str) and "/" in x["file"]
                        and x["pattern"] in SOURCE_PATTERNS
                        and isinstance(x["count"], int) and x["count"] > 0
                        for x in sources
                    ):
                        out.append(f"{lid}: deficiency.sources must list {{file: <repo>/<path>, pattern, count > 0}}")
        claims = link.get("status") == "compliant" or link.get("mtls") is True
        probe = link.get("probe")
        if claims and not isinstance(probe, dict):
            out.append(f"{lid}: compliant or mtls claimed without a probe record (RealityEngine_CI#728)")
        elif claims:
            # One status describes the link on every lane it lists, so each of
            # them needs its own probe (scripts/transport-probe.py --write).
            lanes = [lane for lane in link.get("lanes", []) if lane in LANES]
            missing = [lane for lane in lanes if not isinstance(probe.get(lane), dict)]
            if missing:
                out.append(f"{lid}: compliant or mtls claimed without a probe record on {', '.join(missing)} "
                           "(RealityEngine_CI#728)")
            else:
                if link.get("status") == "compliant":
                    out += [f"{lid}: claims compliant, but the {lane} probe found {probe[lane].get('verdict')!r}"
                            for lane in lanes if probe[lane].get("verdict") != "compliant"]
                if link.get("mtls") is True:
                    out += [f"{lid}: claims mtls, but the {lane} probe did not observe it"
                            for lane in lanes if probe[lane].get("mtls") is not True]
    return out


# Probe findings (scripts/transport-probe.py) a deficiency may accept, so the
# probe stage records them instead of failing. Plaintext is never one: a
# plaintext link is accepted through allows.status.
PROBE_ACCEPTABLE = {"TLS 1.2 accepted", "a suite outside the profile accepted"}

# The insecure-transport gate's pattern names (scripts/check-insecure-transport.py).
SOURCE_PATTERNS = {"plaintext-url", "plaintext-ws", "curl-insecure", "wget-no-check",
                   "node-reject-unauthorized", "python-verify-off", "go-skip-verify"}


def gate_problems(inventory: dict[str, Any]) -> tuple[list[str], list[str]]:
    """(failures, accepted deficiencies) for the release gate."""
    failures, accepted = [], []
    for link in inventory.get("links", []):
        allows = (link.get("deficiency") or {}).get("allows") or {}
        status_ok = link.get("status") == "compliant" or ("status" in allows and link.get("status") == allows["status"])
        # A user-facing or external link exposes TLS only; mTLS is for services.
        needs_mtls = link.get("audience", "service") == "service"
        mtls_ok = (not needs_mtls or link.get("mtls") is True
                   or ("mtls" in allows and link.get("mtls") is allows["mtls"]))
        audience = "" if not needs_mtls or link.get("mtls") else ", no mTLS"
        if not needs_mtls:
            audience = f", {link['audience']}: TLS only"
        line = f"{link['id']}: {link['status']}{audience} (owner {link['owner']}, {link['issue']})"
        if status_ok and mtls_ok:
            if allows:
                accepted.append(f"{line}: accepted deficiency, {link['deficiency']['accepted']}")
        else:
            failures.append(line)
    return failures, accepted


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
    deficient = sum(1 for link in links if link.get("deficiency"))
    summary = ", ".join(f"{by_status[s]} {s}" for s in ("compliant", "tls", "plaintext", "unverified") if by_status[s])
    print(f"transport-inventory: {len(links)} links under {profile['profileId']}: {summary}; {mtls} with mTLS; "
          f"{deficient} accepted deficienc{'y' if deficient == 1 else 'ies'}")

    if args.require_compliant:
        gaps, accepted = gate_problems(inventory)
        for a in accepted:
            print(f"  {a}")
        if gaps:
            print(f"transport-inventory: release gate FAILS: {len(gaps)} link(s) not compliant (with mTLS between services)", file=sys.stderr)
            for g in gaps:
                print(f"  {g}", file=sys.stderr)
            return 1
        print("transport-inventory: release gate passes: every link compliant, services with mTLS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
