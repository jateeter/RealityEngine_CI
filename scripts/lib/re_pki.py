#!/usr/bin/env python3
"""re_pki: the RealityEngine system PKI (RealityEngine_CI#668, #726).

One certificate authority per install. It issues a certificate to every
service and engine instance, for TLS 1.3 and mTLS under
config/transport-profile.json. An engine instance's certificate carries the
URI SAN `urn:uuid:<instance_uuid>` (#296), so a handshake proves which instance
is speaking.

STATE
  $RE_PKI_DIR, default ~/.reality-engine/pki/<lane> (lane: $RE_PKI_LANE, default
  "native"). Kept across universes, like instance UUIDs, and never in a
  repository. Layout:
    ca/ca.key, ca/ca.crt           the CA (key 0600)
    ca/index.txt, serial, crlnumber openssl ca's database
    ca/ca.crl                       the current revocation list
    issued/<name>/key.pem           a leaf key (0600)
    issued/<name>/cert.pem          its certificate
    issued/<name>/chain.pem         cert + CA, for servers that send the chain
    issued/<name>/meta.json         kind, SANs, serial, notAfter

KEYS
  ECDSA P-384 with SHA-384, for the CA and every leaf. Validity and the renewal
  window come from the profile (certificates.ca / certificates.leaf).

COMMANDS
  init                          create the CA if absent (never replaces one)
  issue NAME --kind K [--dns D]... [--ip I]... [--instance-uuid U]
                                issue, or keep a current certificate whose SANs
                                and kind match; re-issue inside the renewal window
                                K: server | client | both
  renew                         re-issue every certificate inside its window
  revoke NAME                   revoke and regenerate the CRL
  crl                           regenerate the CRL
  verify NAME                   verify the chain against the CA and the CRL
  status                        list issued certificates
  paths NAME                    print key, cert, chain and CA paths as JSON

The CA's trust in a browser or OS store is the owner's step. `trust-command`
prints the command to run; this tool never edits a trust store itself.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

CI_DIR = Path(__file__).resolve().parent.parent.parent
PROFILE = CI_DIR / "config" / "transport-profile.json"
CURVE = "secp384r1"
DIGEST = "sha384"
NAME = re.compile(r"^[a-z0-9][a-z0-9.-]{0,62}$")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


class PkiError(Exception):
    pass


def profile() -> dict[str, Any]:
    return json.loads(PROFILE.read_text())["certificates"]


def state_dir() -> Path:
    explicit = os.environ.get("RE_PKI_DIR")
    if explicit:
        return Path(explicit)
    lane = os.environ.get("RE_PKI_LANE", "native")
    if not NAME.match(lane):
        raise PkiError(f"invalid RE_PKI_LANE {lane!r}")
    return Path.home() / ".reality-engine" / "pki" / lane


def leaf_days() -> int:
    override = os.environ.get("RE_PKI_LEAF_DAYS")
    return int(override) if override else int(profile()["leaf"]["validityDays"])


def renew_within_days() -> int:
    return int(profile()["leaf"]["renewWithinDays"])


def run(*args: str, input_text: str | None = None) -> str:
    proc = subprocess.run(list(args), input=input_text, capture_output=True, text=True)
    if proc.returncode != 0:
        raise PkiError(f"{' '.join(args[:3])}… failed: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout


def ca_config(root: Path) -> Path:
    """openssl ca's configuration, regenerated each run from the state dir."""
    ca = root / "ca"
    conf = ca / "openssl-ca.cnf"
    conf.write_text(f"""[ ca ]
default_ca = re_ca

[ re_ca ]
dir               = {ca}
database          = $dir/index.txt
serial            = $dir/serial
crlnumber         = $dir/crlnumber
new_certs_dir     = $dir/newcerts
certificate       = $dir/ca.crt
private_key       = $dir/ca.key
default_md        = {DIGEST}
default_crl_days  = 30
policy            = re_policy
unique_subject    = no
copy_extensions   = none
email_in_dn       = no

[ re_policy ]
commonName        = supplied
organizationName  = optional
""")
    return conf


def init() -> Path:
    root = state_dir()
    ca = root / "ca"
    if (ca / "ca.crt").exists() and (ca / "ca.key").exists():
        return root
    if (ca / "ca.crt").exists() or (ca / "ca.key").exists():
        raise PkiError(f"{ca} holds half a CA (key or certificate missing); refusing to replace it")
    (ca / "newcerts").mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    (ca / "index.txt").touch()
    (ca / "serial").write_text(os.urandom(16).hex() + "\n")
    (ca / "crlnumber").write_text("1000\n")
    key = ca / "ca.key"
    run("openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", f"ec_paramgen_curve:{CURVE}", "-out", str(key))
    os.chmod(key, 0o600)
    days = str(profile()["ca"]["validityDays"])
    run("openssl", "req", "-x509", "-new", "-key", str(key), f"-{DIGEST}", "-days", days,
        "-subj", f"/O=RealityEngine/CN=RealityEngine Install CA {root.name}",
        "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign",
        "-addext", "subjectKeyIdentifier=hash",
        "-out", str(ca / "ca.crt"))
    ca_config(root)
    crl()
    return root


def require_ca() -> Path:
    root = state_dir()
    if not (root / "ca" / "ca.crt").exists():
        raise PkiError(f"no CA at {root / 'ca'}; run `re_pki.py init` first")
    ca_config(root)
    return root


def sans(dns: list[str], ips: list[str], instance_uuid: str | None) -> list[str]:
    out = [f"DNS:{d}" for d in dns] + [f"IP:{i}" for i in ips]
    if instance_uuid:
        out.append(f"URI:urn:uuid:{instance_uuid}")
    return out


def not_after(cert: Path) -> dt.datetime:
    text = run("openssl", "x509", "-in", str(cert), "-noout", "-enddate").strip().split("=", 1)[1]
    return dt.datetime.strptime(text, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)


def serial_of(cert: Path) -> str:
    return run("openssl", "x509", "-in", str(cert), "-noout", "-serial").strip().split("=", 1)[1].upper()


def issue(name: str, kind: str, dns: list[str], ips: list[str], instance_uuid: str | None, force: bool = False) -> dict[str, Any]:
    if not NAME.match(name):
        raise PkiError(f"invalid certificate name {name!r}")
    if kind not in ("server", "client", "both"):
        raise PkiError(f"kind must be server, client or both, got {kind!r}")
    if instance_uuid and not UUID.match(instance_uuid):
        raise PkiError(f"instance uuid {instance_uuid!r} is not a lowercase UUID")
    if kind in ("server", "both") and not (dns or ips):
        raise PkiError("a server certificate needs at least one --dns or --ip")
    root = require_ca()
    out = root / "issued" / name
    want = {"kind": kind, "sans": sans(dns, ips, instance_uuid)}
    meta_path = out / "meta.json"
    if meta_path.exists() and not force:
        meta = json.loads(meta_path.read_text())
        current = {"kind": meta["kind"], "sans": meta["sans"]} == want
        fresh = not_after(out / "cert.pem") - dt.datetime.now(dt.timezone.utc) > dt.timedelta(days=renew_within_days())
        revoked = meta.get("revoked", False)
        if current and fresh and not revoked:
            return meta | {"action": "kept"}
        if not revoked and (out / "cert.pem").exists():
            revoke_cert(root, out / "cert.pem")  # superseded: the old certificate stops being valid
    out.mkdir(parents=True, exist_ok=True)
    key = out / "key.pem"
    run("openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", f"ec_paramgen_curve:{CURVE}", "-out", str(key))
    os.chmod(key, 0o600)
    eku = {"server": "serverAuth", "client": "clientAuth", "both": "serverAuth,clientAuth"}[kind]
    ext_lines = [
        "basicConstraints=critical,CA:FALSE",
        "keyUsage=critical,digitalSignature",
        f"extendedKeyUsage={eku}",
        "subjectKeyIdentifier=hash",
        "authorityKeyIdentifier=keyid",
    ]
    if want["sans"]:
        ext_lines.append("subjectAltName=" + ",".join(want["sans"]))
    with tempfile.TemporaryDirectory() as tmp:
        csr = Path(tmp) / "req.csr"
        ext = Path(tmp) / "ext.cnf"
        ext.write_text("[ leaf ]\n" + "\n".join(ext_lines) + "\n")
        run("openssl", "req", "-new", "-key", str(key), f"-{DIGEST}", "-subj", f"/O=RealityEngine/CN={name}", "-out", str(csr))
        run("openssl", "ca", "-batch", "-config", str(root / "ca" / "openssl-ca.cnf"), "-notext",
            "-days", str(leaf_days()), "-extfile", str(ext), "-extensions", "leaf",
            "-in", str(csr), "-out", str(out / "cert.pem"))
    (out / "chain.pem").write_text((out / "cert.pem").read_text() + (root / "ca" / "ca.crt").read_text())
    meta = {
        "name": name, **want, "instanceUuid": instance_uuid,
        "serial": serial_of(out / "cert.pem"),
        "notAfter": not_after(out / "cert.pem").isoformat(),
        "revoked": False,
    }
    meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    return meta | {"action": "issued"}


def revoke_cert(root: Path, cert: Path) -> None:
    run("openssl", "ca", "-config", str(root / "ca" / "openssl-ca.cnf"), "-revoke", str(cert))
    crl()


def revoke(name: str) -> dict[str, Any]:
    root = require_ca()
    out = root / "issued" / name
    meta_path = out / "meta.json"
    if not meta_path.exists():
        raise PkiError(f"no certificate named {name!r}")
    meta = json.loads(meta_path.read_text())
    if not meta.get("revoked"):
        revoke_cert(root, out / "cert.pem")
        meta["revoked"] = True
        meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    return meta


def crl() -> Path:
    root = state_dir()
    ca_config(root)
    out = root / "ca" / "ca.crl"
    run("openssl", "ca", "-config", str(root / "ca" / "openssl-ca.cnf"), "-gencrl", "-out", str(out))
    return out


def verify(name: str) -> str:
    root = require_ca()
    cert = root / "issued" / name / "cert.pem"
    if not cert.exists():
        raise PkiError(f"no certificate named {name!r}")
    crl()
    proc = subprocess.run(["openssl", "verify", "-crl_check", "-CAfile", str(root / "ca" / "ca.crt"),
                           "-CRLfile", str(root / "ca" / "ca.crl"), str(cert)], capture_output=True, text=True)
    if proc.returncode != 0:
        raise PkiError(f"{name}: {proc.stdout.strip() or proc.stderr.strip()}")
    return proc.stdout.strip()


def renew() -> list[dict[str, Any]]:
    root = require_ca()
    results = []
    for meta_path in sorted((root / "issued").glob("*/meta.json")):
        meta = json.loads(meta_path.read_text())
        if meta.get("revoked"):
            continue
        dns = [s[4:] for s in meta["sans"] if s.startswith("DNS:")]
        ips = [s[3:] for s in meta["sans"] if s.startswith("IP:")]
        results.append(issue(meta["name"], meta["kind"], dns, ips, meta.get("instanceUuid")))
    return results


def status() -> list[dict[str, Any]]:
    root = require_ca()
    return [json.loads(p.read_text()) for p in sorted((root / "issued").glob("*/meta.json"))]


def paths(name: str) -> dict[str, str]:
    root = require_ca()
    out = root / "issued" / name
    if not (out / "cert.pem").exists():
        raise PkiError(f"no certificate named {name!r}")
    return {"key": str(out / "key.pem"), "cert": str(out / "cert.pem"),
            "chain": str(out / "chain.pem"), "ca": str(root / "ca" / "ca.crt"), "crl": str(root / "ca" / "ca.crl")}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init")
    p = sub.add_parser("issue")
    p.add_argument("name")
    p.add_argument("--kind", required=True)
    p.add_argument("--dns", action="append", default=[])
    p.add_argument("--ip", action="append", default=[])
    p.add_argument("--instance-uuid")
    p.add_argument("--force", action="store_true")
    sub.add_parser("renew")
    sub.add_parser("crl")
    sub.add_parser("status")
    sub.add_parser("trust-command")
    for cmd in ("revoke", "verify", "paths"):
        sub.add_parser(cmd).add_argument("name")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "init":
            print(f"re_pki: CA ready at {init() / 'ca' / 'ca.crt'}")
        elif args.cmd == "issue":
            m = issue(args.name, args.kind, args.dns, args.ip, args.instance_uuid, args.force)
            print(f"re_pki: {m['action']} {m['name']} ({m['kind']}) serial {m['serial']} until {m['notAfter']}")
        elif args.cmd == "renew":
            for m in renew():
                print(f"re_pki: {m['action']} {m['name']} until {m['notAfter']}")
        elif args.cmd == "revoke":
            print(f"re_pki: revoked {revoke(args.name)['name']}")
        elif args.cmd == "crl":
            print(f"re_pki: CRL at {crl()}")
        elif args.cmd == "verify":
            print(f"re_pki: {verify(args.name)}")
        elif args.cmd == "status":
            print(json.dumps(status(), indent=2))
        elif args.cmd == "paths":
            print(json.dumps(paths(args.name)))
        elif args.cmd == "trust-command":
            ca = require_ca() / "ca" / "ca.crt"
            print(f"sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain {ca}")
    except PkiError as e:
        print(f"re_pki: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
