#!/usr/bin/env python3
"""tls_front.py (RealityEngine_GO#6): the profile in front, TLS behind, nothing plaintext.

A throwaway CA (re_pki.py under a temporary RE_PKI_DIR, a named test fixture)
issues a service certificate and a client certificate. An upstream TLS 1.3 +
mTLS echo server that also accepts TLS_AES_128_GCM_SHA256 stands in for a Go
listener; the front sits before it. Checks:

- material is all or nothing, and an upstream off loopback is refused;
- a lane client reaches the upstream through the front;
- the front refuses a client without a certificate, TLS 1.2, and a suite
  outside the profile, which the upstream itself would have accepted.
Starts nothing beyond loopback listeners in this process.
"""

from __future__ import annotations

import asyncio
import os
import socket
import ssl
import subprocess
import sys
import tempfile
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))
import tls_front  # noqa: E402  # pyright: ignore[reportMissingImports]

FAILURES: list[str] = []


def check(name: str, cond: bool) -> None:
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        FAILURES.append(name)


def pki(root: str) -> dict[str, str]:
    env = {**os.environ, "RE_PKI_DIR": root}
    run = lambda *a: subprocess.run([sys.executable, str(LIB / "re_pki.py"), *a], env=env, check=True,  # noqa: E731
                                    capture_output=True, text=True)
    run("init")
    run("issue", "svc", "--kind", "both", "--dns", "localhost", "--ip", "127.0.0.1")
    run("issue", "client", "--kind", "client")
    issued, ca = Path(root) / "issued", Path(root) / "ca"
    return {"cert": str(issued / "svc" / "chain.pem"), "key": str(issued / "svc" / "key.pem"),
            "ca": str(ca / "ca.crt"), "crl": str(ca / "ca.crl"),
            "client_cert": str(issued / "client" / "cert.pem"), "client_key": str(issued / "client" / "key.pem")}


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def client_ctx(m: dict[str, str], *, cert: bool = True, tls12: bool = False, suite: str | None = None) -> ssl.SSLContext:
    ctx = ssl.create_default_context(cafile=m["ca"])
    if tls12:
        ctx.minimum_version = ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    else:
        ctx.minimum_version = ctx.maximum_version = ssl.TLSVersion.TLSv1_3
    if suite:
        ctx.set_ciphersuites(suite)  # pyright: ignore[reportAttributeAccessIssue]
    if cert:
        ctx.load_cert_chain(m["client_cert"], m["client_key"])
    return ctx


async def attempt(port: int, ctx: ssl.SSLContext) -> bytes | None:
    try:
        r, w = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", port, ssl=ctx, server_hostname="127.0.0.1"), 5)
        w.write(b"ping")
        await w.drain()
        data = await asyncio.wait_for(r.read(4), 5)
        w.close()
        return data or None
    except (OSError, ssl.SSLError, asyncio.TimeoutError, ConnectionError):
        return None


async def scenario(m: dict[str, str]) -> None:
    material = {"cert": m["cert"], "key": m["key"], "ca": m["ca"], "crl": m["crl"]}
    # The upstream: TLS 1.3 + mTLS, any TLS 1.3 suite, as a Go listener behaves.
    up_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    up_ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    up_ctx.load_cert_chain(m["cert"], m["key"])
    up_ctx.load_verify_locations(cafile=m["ca"])
    up_ctx.verify_mode = ssl.CERT_REQUIRED

    async def echo(r, w):
        w.write(await r.read(4))
        await w.drain()
        w.close()

    upstream = await asyncio.start_server(echo, "127.0.0.1", 0, ssl=up_ctx)
    up_port = upstream.sockets[0].getsockname()[1]
    front_port = free_port()
    os.environ.update({"RE_TLS_CERT": m["cert"], "RE_TLS_KEY": m["key"], "RE_TLS_CA": m["ca"], "RE_TLS_CRL": m["crl"]})
    task = asyncio.create_task(tls_front.serve(("127.0.0.1", front_port), ("127.0.0.1", up_port), None))
    await asyncio.sleep(0.5)
    try:
        aes128 = "TLS_AES_128_GCM_SHA256"
        check("the upstream alone accepts a suite outside the profile (the defect the front exists for)",
              await attempt(up_port, client_ctx(m, suite=aes128)) == b"ping")
        check("a lane client reaches the upstream through the front",
              await attempt(front_port, client_ctx(m)) == b"ping")
        check("the front refuses a client without a certificate", await attempt(front_port, client_ctx(m, cert=False)) is None)
        check("the front refuses TLS 1.2", await attempt(front_port, client_ctx(m, tls12=True)) is None)
        check("the front refuses a suite outside the profile", await attempt(front_port, client_ctx(m, suite=aes128)) is None)
        ctx = tls_front.server_context(material)
        check("the front offers only the profile's TLS 1.3 suites",
              {c["name"] for c in ctx.get_ciphers() if c["protocol"] == "TLSv1.3"} <= set(tls_front.profile_tls()[0]))
    finally:
        task.cancel()
        upstream.close()


def main() -> int:
    for k in ("RE_TLS_CERT", "RE_TLS_KEY", "RE_TLS_CA", "RE_TLS_CRL"):
        os.environ.pop(k, None)
    try:
        tls_front.material()
        check("missing material refuses", False)
    except tls_front.FrontError:
        check("missing material refuses", True)
    try:
        tls_front.loopback("192.0.2.1:8443")
        check("an upstream off loopback is refused", False)
    except tls_front.FrontError:
        check("an upstream off loopback is refused", True)
    check("localhost reads as 127.0.0.1", tls_front.loopback("localhost:1") == ("127.0.0.1", 1))
    if not hasattr(ssl.SSLContext, "set_ciphersuites"):
        print("skip: this Python cannot set TLS 1.3 suites (needs 3.15+)")
        return 0 if not FAILURES else 1
    with tempfile.TemporaryDirectory() as root:
        asyncio.run(scenario(pki(root)))
    print(f"\n{len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
