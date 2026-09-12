"""re_tls — one TLS trust decision for the verification stages.

WHY THIS EXISTS
---------------
The universe serves its RE/PE surfaces over TLS with certificates from the dev
CA in `certs/ca.crt`. Python's `urllib` trusts the system store, which does not
include that CA, so every stage that reached an engine over https failed with:

    urlopen error [SSL: CERTIFICATE_VERIFY_FAILED] unable to get local issuer certificate

That is a harness problem, and it was being reported as a product finding —
`verify-semantic-parity.sh` turned an unreachable engine into a semantic
`MISMATCH`, and the metrics and audit stages reported drift and an incomplete
chain for the same reason. Three stages, one cause, three misleading verdicts.

`curl` in these same scripts passes `-k`, which is why the shell half of a stage
could reach an engine that its Python half could not.

WHAT IT DOES
------------
Trusts the dev CA when it can be found, which is real verification rather than
switching it off. Falls back to an unverified context only when the CA is
genuinely absent, because a self-signed certificate with no CA to check it
against cannot be verified by anything, and refusing to connect there would turn
a missing file into a parity failure — the same conflation one layer down.

The fallback announces itself on stderr. A stage running unverified should say
so rather than look identical to one that verified.
"""

from __future__ import annotations

import os
import ssl
import sys

_WARNED = False


def ca_path() -> str | None:
    """The dev CA, from RE_CA_CERT or the conventional location under CI_DIR."""
    explicit = os.environ.get("RE_CA_CERT")
    if explicit and os.path.exists(explicit):
        return explicit
    ci_dir = os.environ.get("CI_DIR")
    if ci_dir:
        candidate = os.path.join(ci_dir, "certs", "ca.crt")
        if os.path.exists(candidate):
            return candidate
    # Walk up from this file: scripts/lib/ -> scripts/ -> repo root.
    candidate = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "certs", "ca.crt",
    )
    return candidate if os.path.exists(candidate) else None


def _ca_is_usable(ca: str) -> bool:
    """Can OpenSSL actually verify against this CA?

    The dev CA is generated with `basicConstraints: CA:TRUE` and no `keyUsage`.
    OpenSSL 3 rejects that with "CA cert does not include key usage extension",
    so loading it succeeds and every connection then fails — which reads as an
    unreachable engine rather than a certificate defect. Check up front so the
    fallback is a stated decision instead of a confusing runtime error.
    """
    try:
        import subprocess
        out = subprocess.run(
            ["openssl", "x509", "-in", ca, "-noout", "-ext", "keyUsage"],
            capture_output=True, text=True, timeout=10,
        )
        return "Key Usage" in (out.stdout or "")
    except Exception:  # noqa: BLE001 — no openssl, or an unreadable file
        return False


def tls_context() -> ssl.SSLContext:
    global _WARNED
    ctx = ssl.create_default_context()
    ca = ca_path()
    if ca and _ca_is_usable(ca):
        ctx.load_verify_locations(ca)
        return ctx
    if ca and not _WARNED:
        print(
            f"re_tls: {ca} carries no keyUsage extension, so OpenSSL cannot verify "
            "against it — proceeding unverified. Regenerate with "
            "certs/generate-dev-certs.sh to get a CA that can be verified.",
            file=sys.stderr,
        )
        _WARNED = True
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    if not _WARNED:
        print(
            "re_tls: dev CA not found (set RE_CA_CERT or CI_DIR) — proceeding "
            "without certificate verification",
            file=sys.stderr,
        )
        _WARNED = True
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx
