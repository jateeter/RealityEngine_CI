#!/usr/bin/env python3
"""re_tls_server — CI's own listeners, held to the transport profile (#668, #732).

The engines and services implement the runtime contract themselves
(docs/TRANSPORT_SECURITY.md). This module is for the few listeners CI runs
itself, today the instance registry shim: a server context built from
config/transport-profile.json with nothing loosened.

- TLS 1.3 only (minimum and maximum).
- mTLS: a client must present a certificate from the lane CA (CERT_REQUIRED),
  and the lane CRL is checked against it when RE_TLS_CRL names one.
- Cipher suites and key-exchange groups from the profile. Python's ssl module
  exposes neither for TLS 1.3, so they are set through an OpenSSL config file
  written next to the certificates and named by OPENSSL_CONF before OpenSSL
  starts: `serve-static` re-executes itself once with it set. The PQ hybrid
  group is listed only when the linked OpenSSL is 3.5 or newer; older builds
  (hosted runners carry 3.0) negotiate a profile fallback group.

Usage:
  re_tls_server.py serve-static DIR PORT --cert CHAIN --key KEY --ca CA [--crl CRL] [--bind ADDR]
  re_tls_server.py openssl-conf          print the OpenSSL config this module uses
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

PROFILE = Path(__file__).resolve().parents[2] / "config" / "transport-profile.json"
_CONF_MARK = "RE_TLS_SERVER_CONF"


def _profile_tls() -> dict:
    return json.loads(PROFILE.read_text())["tls"]


def _pq_capable() -> bool:
    import ssl  # imported late: OPENSSL_CONF must be set before the first import
    return ssl.OPENSSL_VERSION_INFO[:2] >= (3, 5)


def openssl_conf_text(pq: bool) -> str:
    tls = _profile_tls()
    groups = list(tls["keyExchangeGroups"]["fallback"])
    if pq:
        groups = list(tls["keyExchangeGroups"]["preferred"]) + groups
    return (
        "# Written by scripts/lib/re_tls_server.py from config/transport-profile.json.\n"
        "openssl_conf = re_tls_init\n\n"
        "[re_tls_init]\nssl_conf = re_tls_ssl\n\n"
        "[re_tls_ssl]\nsystem_default = re_tls_profile\n\n"
        "[re_tls_profile]\n"
        "MinProtocol = TLSv1.3\n"
        "MaxProtocol = TLSv1.3\n"
        f"Ciphersuites = {':'.join(tls['cipherSuites'])}\n"
        f"Groups = {':'.join(groups)}\n"
    )


def server_context(cert: str, key: str, ca: str, crl: str | None = None):
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.maximum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(cert, key)
    ctx.load_verify_locations(cafile=ca)
    ctx.verify_mode = ssl.CERT_REQUIRED
    if crl:
        ctx.load_verify_locations(cafile=crl)
        ctx.verify_flags |= ssl.VERIFY_CRL_CHECK_LEAF
    return ctx


def user_facing_context(cert: str, key: str):
    """A browser-facing listener (the OpenAPI portal, #730): TLS 1.3 at the
    profile, server authentication only. A browser has no lane certificate;
    user and device authentication sit on top (the transport profile)."""
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.maximum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(cert, key)
    return ctx


def ensure_profile(script: str, cert: str) -> None:
    """Re-exec `script` once with OPENSSL_CONF naming the profile's config, so
    the TLS 1.3 suites and groups Python cannot set itself are the profile's.
    The config is written next to the certificate."""
    if os.environ.get(_CONF_MARK) == "1":
        return
    conf = Path(cert).resolve().parent / "openssl-transport.cnf"
    conf.write_text(openssl_conf_text(_pq_capable()))
    env = dict(os.environ, OPENSSL_CONF=str(conf), **{_CONF_MARK: "1"})
    os.execve(sys.executable, [sys.executable, os.path.abspath(script), *sys.argv[1:]], env)


def _ensure_conf(cert: str) -> None:
    """Re-exec this module once with OPENSSL_CONF naming the profile's config."""
    ensure_profile(__file__, cert)


def serve_static(directory: str, port: int, bind: str, ctx) -> None:
    import http.server

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=directory, **kw)

        def log_message(self, format, *args):  # noqa: A002 — quiet, as the plaintext shim is
            pass

    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True

        def get_request(self):
            sock, addr = super().get_request()
            return ctx.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr

        def handle_error(self, request, client_address):
            # A refused handshake (no client certificate, TLS 1.2, plaintext)
            # is the profile doing its job, not a server fault worth a traceback.
            pass

    class TlsHandler(Handler):
        def setup(self):
            self.request.do_handshake()
            super().setup()

    Server((bind, port), TlsHandler).serve_forever()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve-static")
    s.add_argument("directory")
    s.add_argument("port", type=int)
    s.add_argument("--cert", required=True)
    s.add_argument("--key", required=True)
    s.add_argument("--ca", required=True)
    s.add_argument("--crl")
    s.add_argument("--bind", default="0.0.0.0")
    sub.add_parser("openssl-conf")
    args = p.parse_args(argv)
    if args.cmd == "openssl-conf":
        print(openssl_conf_text(_pq_capable()), end="")
        return 0
    _ensure_conf(args.cert)
    ctx = server_context(args.cert, args.key, args.ca, args.crl)
    serve_static(os.path.abspath(args.directory), args.port, args.bind, ctx)
    return 0


if __name__ == "__main__":
    sys.exit(main())
