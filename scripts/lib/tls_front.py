#!/usr/bin/env python3
"""An OpenSSL front for a Go listener: the profile on the public port (RealityEngine_GO#6).

Go's crypto/tls has no TLS 1.3 suite setting, so a Go listener also accepts
TLS_AES_128_GCM_SHA256, which config/transport-profile.json does not. The
suite's pattern for Go services (docs/TRANSPORT_SECURITY.md, 2026-11-12) keeps
the Go listener on loopback and puts an OpenSSL front on the public port. This
is that front for a native process, as lib/obs_front_conf.py's nginx is for
the observability containers:

- the public side is TLS 1.3 only, the profile's AEAD suites and groups
  (X25519MLKEM768 where OpenSSL 3.5+ offers it), a client certificate from
  the lane CA required, and the CRL checked;
- the upstream side is a TLS 1.3 client with the same certificate, verifying
  the Go listener against the lane CA, its address and the CRL. The upstream
  must be a loopback address. Nothing is plaintext on either hop.

It relays bytes, not HTTP, so streams pass through as they are produced.

    tls_front.py --listen 127.0.0.1:PORT --upstream 127.0.0.1:PORT [--pid-file PATH]

Material comes from the runtime contract, all of RE_TLS_CERT, RE_TLS_KEY and
RE_TLS_CA required and RE_TLS_CRL checked when set: the front has no
plaintext mode and no unverified mode.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import ipaddress
import json
import os
import signal
import ssl
import sys
from pathlib import Path

PROFILE = Path(__file__).resolve().parents[2] / "config" / "transport-profile.json"
_CHUNK = 64 * 1024


class FrontError(RuntimeError):
    """The front cannot hold the profile with what it was given."""


def material() -> dict[str, str | None]:
    names = ("RE_TLS_CERT", "RE_TLS_KEY", "RE_TLS_CA")
    found = {n: os.environ.get(n, "") for n in names}
    missing = [n for n, v in found.items() if not v or not os.path.isfile(v)]
    if missing:
        raise FrontError(", ".join(missing) + " unset or not a file; the front has no plaintext mode")
    crl = os.environ.get("RE_TLS_CRL") or None
    if crl and not os.path.isfile(crl):
        raise FrontError(f"RE_TLS_CRL names {crl}, which is not a file")
    return {"cert": found["RE_TLS_CERT"], "key": found["RE_TLS_KEY"], "ca": found["RE_TLS_CA"], "crl": crl}


def profile_tls() -> tuple[list[str], list[str]]:
    """The profile's suites, and its groups in preference order."""
    tls = json.loads(PROFILE.read_text())["tls"]
    groups = tls["keyExchangeGroups"]
    return list(tls["cipherSuites"]), list(groups["preferred"]) + list(groups["fallback"])


def groups_for(groups: list[str], openssl: tuple[int, ...]) -> list[str]:
    """The PQ hybrid needs OpenSSL 3.5+; the fallbacks are always offered."""
    return [g for g in groups if "MLKEM" not in g or openssl >= (3, 5)]


def _harden(ctx: ssl.SSLContext, m: dict[str, str | None]) -> ssl.SSLContext:
    if not (hasattr(ctx, "set_ciphersuites") and hasattr(ctx, "set_groups")):
        raise FrontError("this Python cannot set TLS 1.3 suites and groups (needs Python 3.15+)")
    suites, groups = profile_tls()
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.maximum_version = ssl.TLSVersion.TLSv1_3
    ctx.set_ciphersuites(":".join(suites))  # pyright: ignore[reportAttributeAccessIssue]
    ctx.set_groups(":".join(groups_for(groups, ssl.OPENSSL_VERSION_INFO)))  # pyright: ignore[reportAttributeAccessIssue]
    ctx.load_cert_chain(m["cert"], m["key"])  # type: ignore[arg-type]
    ctx.load_verify_locations(cafile=m["ca"])
    ctx.verify_mode = ssl.CERT_REQUIRED
    if m["crl"]:
        ctx.load_verify_locations(cafile=m["crl"])
        ctx.verify_flags |= ssl.VERIFY_CRL_CHECK_LEAF
    return ctx


def server_context(m: dict[str, str | None]) -> ssl.SSLContext:
    return _harden(ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER), m)


def upstream_context(m: dict[str, str | None]) -> ssl.SSLContext:
    ctx = _harden(ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT), m)
    ctx.check_hostname = True
    return ctx


def loopback(spec: str) -> tuple[str, int]:
    host, sep, port = spec.rpartition(":")
    if not sep or not port.isdigit():
        raise FrontError(f"{spec!r} is not host:port")
    host = host.strip("[]")
    if host == "localhost":
        host = "127.0.0.1"
    if not ipaddress.ip_address(host).is_loopback:
        raise FrontError(f"{host} is not a loopback address; the Go listener stays on loopback")
    return host, int(port)


async def _pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(_CHUNK):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError, OSError, ssl.SSLError):
        pass
    finally:
        with contextlib.suppress(OSError, RuntimeError, ssl.SSLError):
            writer.close()


async def _relay(client_r, client_w, upstream: tuple[str, int], up_ctx: ssl.SSLContext) -> None:
    try:
        up_r, up_w = await asyncio.open_connection(*upstream, ssl=up_ctx, server_hostname=upstream[0])
    except (OSError, ssl.SSLError) as exc:
        print(f"tls_front: upstream {upstream[0]}:{upstream[1]} refused: {exc}", file=sys.stderr)
        client_w.close()
        return
    await asyncio.gather(_pipe(client_r, up_w), _pipe(up_r, client_w))


async def serve(listen: tuple[str, int], upstream: tuple[str, int], pid_file: str | None) -> None:
    m = material()
    srv_ctx, up_ctx = server_context(m), upstream_context(m)
    server = await asyncio.start_server(lambda r, w: _relay(r, w, upstream, up_ctx), *listen, ssl=srv_ctx)
    if pid_file:
        Path(pid_file).write_text(f"{os.getpid()}\n")
    print(f"tls_front: https://{listen[0]}:{listen[1]} -> https://{upstream[0]}:{upstream[1]}", flush=True)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    async with server:
        await stop.wait()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "tls_front").splitlines()[0])
    ap.add_argument("--listen", required=True, help="host:port to serve the profile on (loopback)")
    ap.add_argument("--upstream", required=True, help="the Go listener's host:port (loopback)")
    ap.add_argument("--pid-file")
    args = ap.parse_args(argv)
    try:
        asyncio.run(serve(loopback(args.listen), loopback(args.upstream), args.pid_file))
    except FrontError as exc:
        print(f"tls_front: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
