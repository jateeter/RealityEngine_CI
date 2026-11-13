#!/usr/bin/env python3
"""Probe every link of the transport inventory that a running lane serves
(RealityEngine_CI#728, work item 4b of #668).

For each link it can resolve to a listener on the lane, it asks the listener
four questions, with `openssl s_client` (OpenSSL 3.5 or later, for the
post-quantum group names) and a plain socket:

1. TLS 1.3 with the harness's client certificate: which version, cipher suite
   and key-exchange group were negotiated, is the server's certificate verified
   against the lane CA, and does an HTTP request get an answer;
2. TLS 1.3 without a client certificate: is it refused at the handshake (mTLS
   at the handshake), answered 403 (mTLS at the HTTP layer, the PE's choice:
   its device routes stay open), or answered (no mTLS);
3. TLS 1.2: is it refused;
4. plaintext HTTP: is it refused.

The verdict per endpoint is `compliant` when (1) negotiated TLS 1.3 with a
profile suite and a profile group, (3) and (4) were refused and the server's
certificate verified; `tls` when TLS 1.3 was negotiated but something else
fell short; `plaintext` when (4) was answered. mTLS is recorded as observed,
never assumed.

It FAILS (exit 1) when any probed listener answers plaintext or accepts TLS
1.2, or negotiates anything outside the profile: the downgrade and plaintext
conditions #728 names. A missing mTLS is recorded, not failed here; the release
gate (`check-transport-inventory.py --require-compliant`, #729) holds it.

With --write it records each probe in the inventory under the link's
`probe.<lane>`. It changes a link's `status` and `mtls` only when every lane the
link lists has a probe record, from the weakest of them, because one status
describes the link on every lane and an unprobed lane may still be plaintext.

Endpoints come from the running lane, never from literals:
- the instance registry (RE_REGISTRY_URL, else .universe-registry-url): every
  engine instance's RE and PE, and the instance registry itself;
- the universe manifest (/tmp/universe-manifest.json, or --manifest):
  Prometheus, Grafana, the bridge metrics, re-mcp and the OpenAPI portal;
- config/integrations.json: localai-api, Ollama's TLS front, the OpenClaw gateway;
- Manager's backend and frontend at their fixed ports, when they listen;
- --endpoints FILE: listeners the lane knows that the sources above do not
  name, as {"<link id>": [{"url": ..., "path": ...}]} (a containerized lane's
  compose-network services, probed from a container on that network);
- an external link's `probeTargets` in the inventory (host, port, path): the
  outside party's own address, probed on every lane.
A link with no resolvable listener is reported `not-probed` and left as it is.

An external link (`audience: external`, owner 2026-11-12) is probed as the
profile holds outside parties: the probe is a profile client (TLS 1.3, the
profile's suites and groups, no client certificate) verifying the party
against the system trust store (RE_SYSTEM_CA, else OpenSSL's default bundle).
It is `compliant` when that client connects; what else the party's server
accepts (TLS 1.2, other suites) is recorded, not held against the link,
because the profile binds our clients, not the party's server. A party that
answers only below TLS 1.3 is `tls`; one with no TLS at all is `plaintext`.
External verdicts never fail the stage: the release gate holds them.

Usage:
  python3 scripts/transport-probe.py --lane native [--report FILE] [--write]
  python3 scripts/transport-probe.py --apply REPORT [REPORT ...]   # record reports
Env:   RE_HARNESS_TLS_CA / _CERT / _KEY (else the lane PKI's harness), RE_OPENSSL
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

CI_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(CI_DIR / "scripts" / "lib"))
from registry_url import registry_url  # noqa: E402

TIMEOUT = 10
RANK = {"compliant": 3, "tls": 2, "unverified": 1, "plaintext": 0}


# ── The lane's materials ─────────────────────────────────────────────────────

def system_ca() -> str:
    for candidate in (os.environ.get("RE_SYSTEM_CA"), ssl.get_default_verify_paths().openssl_cafile,
                      "/opt/homebrew/etc/openssl@3/cert.pem", "/etc/ssl/certs/ca-certificates.crt"):
        if candidate and Path(candidate).is_file():
            return candidate
    raise SystemExit("transport-probe: no system CA bundle for external links (set RE_SYSTEM_CA)")


def harness(lane: str) -> dict[str, str]:
    pki = Path(os.environ.get("RE_PKI_DIR") or Path.home() / ".reality-engine" / "pki" / lane)
    found = {
        "ca": os.environ.get("RE_HARNESS_TLS_CA") or str(pki / "ca" / "ca.crt"),
        "cert": os.environ.get("RE_HARNESS_TLS_CERT") or str(pki / "issued" / "harness" / "cert.pem"),
        "key": os.environ.get("RE_HARNESS_TLS_KEY") or str(pki / "issued" / "harness" / "key.pem"),
    }
    missing = [f for f in found.values() if not Path(f).is_file()]
    if missing:
        raise SystemExit(f"transport-probe: harness TLS material missing: {', '.join(missing)}")
    return found


def openssl_binary() -> str:
    for candidate in (os.environ.get("RE_OPENSSL"), "/opt/homebrew/opt/openssl@3/bin/openssl",
                      "/usr/local/opt/openssl@3/bin/openssl", shutil.which("openssl")):
        if not candidate or not Path(candidate).exists():
            continue
        version = subprocess.run([candidate, "version"], capture_output=True, text=True).stdout
        m = re.match(r"OpenSSL (\d+)\.(\d+)", version)
        if m and (int(m[1]), int(m[2])) >= (3, 5):
            return candidate
    raise SystemExit("transport-probe: needs OpenSSL 3.5+ (brew install openssl@3) or RE_OPENSSL")


def tls_context(material: dict[str, str]) -> ssl.SSLContext:
    ctx = ssl.create_default_context(cafile=material["ca"])
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(material["cert"], material["key"])
    return ctx


def fetch_json(url: str, ctx: ssl.SSLContext) -> Any:
    with urllib.request.urlopen(url, context=ctx, timeout=TIMEOUT) as r:  # noqa: S310 - lane URLs
        return json.load(r)


# ── Endpoints from the running lane ──────────────────────────────────────────

def endpoint(url: str, path: str = "/") -> dict[str, Any] | None:
    parts = urlsplit(url)
    if not parts.hostname:
        return None
    default = 443 if parts.scheme in ("https", "wss") else 80
    return {"url": url, "scheme": parts.scheme, "host": parts.hostname,
            "port": parts.port or default, "path": path}


def resolve(ctx: ssl.SSLContext, manifest_path: Path, integrations_path: Path,
            manager: tuple[str, ...]) -> dict[str, list[dict[str, Any]]]:
    """Link id -> the listeners that serve it on this lane."""
    targets: dict[str, list[dict[str, Any]]] = {}

    def add(link: str, ep: dict[str, Any] | None) -> None:
        if ep and ep not in targets.setdefault(link, []):
            targets[link].append(ep)

    reg_url = registry_url()
    add("instance-registry", endpoint(reg_url, urlsplit(reg_url).path or "/"))
    try:
        registry = fetch_json(reg_url, ctx)
    except Exception as exc:  # noqa: BLE001 - reported, not fatal
        print(f"transport-probe: instance registry unreadable at {reg_url}: {exc}", file=sys.stderr)
        registry = {}
    for inst in registry.get("instances", []):
        runtime = str(inst.get("runtime", "")).lower()
        if inst.get("role") == "follower" or runtime == "rust":
            add("rust-re-pe", endpoint(inst.get("re_url", ""), "/api/health"))
            add("rust-re-pe", endpoint(inst.get("pe_url", ""), "/api/state"))
            continue
        if runtime not in ("cpp", "lsp", "scala"):
            continue
        re_ep = endpoint(inst.get("re_url", ""), "/api/health")
        add(f"clients-to-{runtime}-re", re_ep)
        add(f"{runtime}-pe-to-re", re_ep)
        # The PE's non-device routes need a client certificate; /api/state is one.
        pe_ep = endpoint(inst.get("pe_url", ""), "/api/state")
        add(f"clients-to-{runtime}-pe", pe_ep)
        # Services that call every engine reach these same listeners.
        for link in ("manager-backend-to-engines", "localai-to-engines"):
            add(link, re_ep)
            add(link, pe_ep)
        add("lifecycle-to-pe", pe_ep)
        # The device routes (HealthKit ingest, /status, /scope) take no client certificate.
        add("iphone-to-pe", endpoint(inst.get("pe_url", ""), "/api/integrations/healthkit/status"))
        add("pim-to-pe-scope", endpoint(inst.get("pe_url", ""), "/api/integrations/healthkit/scope"))

    manifest: dict[str, Any] = {}
    if manifest_path.is_file():
        manifest = json.loads(manifest_path.read_text())
    for link, key, path in (
        ("prometheus-scrape", "prometheus_url", "/-/ready"),
        ("browser-to-grafana-native", "grafana_url", "/api/health"),
        ("bridge-metrics-to-services", "bridge_metrics_url", "/"),
        ("mcp", "mcp_http_url", "/"),
        ("browser-to-openapi-portal", "openapi_swagger_url", "/"),
        ("grafana-to-sources", "prometheus_url", "/-/ready"),
        ("grafana-to-sources", "loki_url", "/ready"),
        ("promtail-to-loki", "loki_url", "/ready"),
        ("openclaw-to-browser-cdp", "openclaw_browser_cdp_url", "/json/version"),
        ("localai-to-qdrant", "qdrant_url", "/healthz"),
        ("localai-to-redis", "redis_url", "/"),
        # Ollama itself, behind its TLS front: plaintext on the host's loopback.
        ("ollama-front-to-ollama", "ollama_url", "/"),
    ):
        url = manifest.get(key)
        if isinstance(url, str) and url.startswith(("http", "ws")) and manifest.get(key.replace("_url", "_started"), True):
            ep = endpoint(url, path)
            if ep and link == "localai-to-redis":
                ep["protocol"] = "redis"
            add(link, ep)

    if integrations_path.is_file():
        for integ in json.loads(integrations_path.read_text()).get("integrations", []):
            kind = str(integ.get("type") or integ.get("id") or "").lower()
            if "localai" in kind and integ.get("baseUrl"):
                add("engines-to-localai", endpoint(integ["baseUrl"], "/health"))
                # Trigger dispatch posts to localAI's /graphql (TRIGGER_GRAPHQL_URL).
                add("pe-trigger-dispatch", endpoint(integ["baseUrl"], "/health"))
            elif "ollama" in kind and integ.get("baseUrl"):
                add("to-ollama", endpoint(integ["baseUrl"], "/"))
            elif ("acp" in kind or "openclaw" in kind) and integ.get("gatewayUrl") and manifest.get("openclaw_started"):
                # Only the lane's own gateway: with --no-openclaw a gateway on
                # that port is the host's, not this lane's.
                add("pe-to-openclaw", endpoint(integ["gatewayUrl"], "/"))
                add("openclaw-webui", endpoint(integ["gatewayUrl"], "/"))

    # The asset storage stack's own service file (localAssetStorageStack
    # scripts/up.js): its CSS and dokieli serve certificates from the stack's CA,
    # named in the file, which the probe verifies them against.
    assets = CI_DIR.parent / "localAssetStorageStack" / "runtime" / "registry.json"
    if assets.is_file():
        stack = json.loads(assets.read_text())
        services, stack_ca = stack.get("services", {}), stack.get("ca")

        def asset(name: str, path: str, ca: str | None = None) -> dict[str, Any] | None:
            ep = endpoint(str((services.get(name) or {}).get("externalUrl") or ""), path)
            if ep and ca:
                ep["ca"] = ca
            return ep
        add("browser-to-assets-css", asset("assets-css", "/", stack_ca))
        add("lifecycle-to-assets-css", asset("assets-css", "/", stack_ca))
        add("browser-to-assets-dokieli", asset("assets-dokieli", "/", stack_ca))
        add("clients-to-lifecycle", asset("lifecycle", "/health"))
        add("openclaw-agents-to-lifecycle", asset("lifecycle", "/health"))

    backend, frontend, ts_pe, proxy_grafana = manager
    if backend:
        add("manager-frontend-to-backend", endpoint(backend, "/api/health"))
    if frontend:
        add("browser-to-manager-frontend", endpoint(frontend, "/"))
    # The docker lane's tls-proxy: Manager's TypeScript PE and Grafana.
    if ts_pe:
        add("manager-ts-pe", endpoint(ts_pe, "/api/health"))
    if proxy_grafana:
        add("browser-to-grafana", endpoint(proxy_grafana, "/api/health"))
    return targets


# ── One listener ─────────────────────────────────────────────────────────────

def listening(ep: dict[str, Any]) -> bool:
    try:
        with socket.create_connection((ep["host"], ep["port"]), timeout=3):
            return True
    except OSError:
        return False


def s_client(openssl: str, ep: dict[str, Any], material: dict[str, str], *, version: str,
             client_cert: bool, suites: str | None = None, groups: str | None = None) -> str:
    # A listener whose certificate another CA issued (the asset stack's) names it.
    args = [openssl, "s_client", "-connect", f"{ep['host']}:{ep['port']}", f"-{version}",
            "-CAfile", ep.get("ca") or material["ca"], "-brief", "-ign_eof"]
    if suites:
        args += ["-ciphersuites", suites]
    if groups:
        args += ["-groups", groups]
    if not re.fullmatch(r"[\d.]+|[0-9a-fA-F:]+", ep["host"]):
        args += ["-servername", ep["host"]]
    if client_cert:
        args += ["-cert", material["cert"], "-key", material["key"]]
    request = f"GET {ep['path']} HTTP/1.1\r\nHost: {ep['host']}\r\nConnection: close\r\n\r\n"
    if ep.get("protocol", "http") != "http":
        request = ""  # MQTT and the like: the handshake is the question
    try:
        done = subprocess.run(args, input=request, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired as exc:
        def text(v: object) -> str:
            return v.decode(errors="replace") if isinstance(v, bytes) else (v if isinstance(v, str) else "")
        return text(exc.stdout) + text(exc.stderr) + "\ntimeout"
    return done.stdout + done.stderr


def parse_session(out: str) -> dict[str, Any]:
    def field(pattern: str) -> str | None:
        m = re.search(pattern, out)
        return m.group(1).strip() if m else None
    status = field(r"(?m)^HTTP/\d(?:\.\d)? (\d{3})")
    return {
        "version": field(r"Protocol version: (\S+)"),
        "cipher": field(r"Ciphersuite: (\S+)"),
        "group": field(r"Negotiated TLS1\.3 group: (\S+)") or field(r"Peer Temp Key: (\S+?),"),
        "verified": field(r"Verification: (.+)") == "OK",
        "http": int(status) if status else None,
        "alert": field(r"alert ([a-z ]+?)(?::|$)"),
        # nginx's answer to a missing client certificate (ssl_verify_client on).
        "certRequired": "No required SSL certificate was sent" in out,
    }


def plaintext_answers(ep: dict[str, Any]) -> bool:
    """True when the listener serves a plaintext request. A TLS server that
    answers it with 400 ("HTTP request to an HTTPS server": Go, nginx) is
    refusing it, not serving it. For a non-HTTP protocol (MQTT), a listener
    that takes a connection and does not start TLS is plaintext."""
    if ep.get("protocol", "http") != "http":
        return False  # decided from the handshakes: no TLS at all is plaintext
    try:
        with socket.create_connection((ep["host"], ep["port"]), timeout=5) as sock:
            sock.sendall(f"GET {ep['path']} HTTP/1.1\r\nHost: {ep['host']}\r\nConnection: close\r\n\r\n".encode())
            sock.settimeout(5)
            data = b""
            while len(data) < 512:
                chunk = sock.recv(512)
                if not chunk:
                    break
                data += chunk
    except OSError:
        return False
    m = re.match(rb"HTTP/\d(?:\.\d)? (\d{3})", data)
    if not m:
        return False
    return not (m.group(1) == b"400" and b"HTTPS" in data.upper())


def probe_external(openssl: str, ep: dict[str, Any], profile: dict[str, Any]) -> dict[str, Any]:
    """An outside party, as the profile holds it: can a profile client reach it?"""
    tls = profile["tls"]
    groups = set(tls["keyExchangeGroups"]["preferred"]) | set(tls["keyExchangeGroups"]["fallback"])
    record: dict[str, Any] = {"endpoint": f"{ep['host']}:{ep['port']}", "path": ep["path"], "external": True}
    if not listening(ep):
        record["verdict"] = "not-listening"
        return record
    material = {"ca": system_ca(), "cert": "", "key": ""}
    suites = ":".join(tls["cipherSuites"])
    offered = ":".join(tls["keyExchangeGroups"]["preferred"] + tls["keyExchangeGroups"]["fallback"])
    prof = parse_session(s_client(openssl, ep, material, version="tls1_3", client_cert=False,
                                  suites=suites, groups=offered))
    tls12 = parse_session(s_client(openssl, ep, material, version="tls1_2", client_cert=False))
    record.update({
        "version": prof["version"] or tls12["version"],
        "cipher": prof["cipher"] or tls12["cipher"],
        "group": prof["group"],
        "serverVerified": prof["verified"] if prof["version"] else tls12["verified"],
        "tls12": "accepted" if tls12["version"] == "TLSv1.2" else "refused",
        "mtls": "none",
    })
    failures = []
    if prof["version"] != "TLSv1.3":
        failures.append("no TLS 1.3 at the profile: " + (f"the party offers {tls12['version']}" if tls12["version"]
                                                         else "the party offers no TLS"))
    elif prof["cipher"] not in tls["cipherSuites"] or prof["group"] not in groups:
        failures.append(f"negotiated {prof['cipher']} / {prof['group']}, outside the profile")
    if record["version"] and not record["serverVerified"]:
        failures.append("the party's certificate did not verify against the system trust store")
    record["failures"] = failures
    if not failures:
        record["verdict"] = "compliant"
    else:
        record["verdict"] = "tls" if record["version"] else "plaintext"
    return record


def probe_endpoint(openssl: str, ep: dict[str, Any], material: dict[str, str],
                   profile: dict[str, Any]) -> dict[str, Any]:
    tls = profile["tls"]
    groups = set(tls["keyExchangeGroups"]["preferred"]) | set(tls["keyExchangeGroups"]["fallback"])
    record: dict[str, Any] = {"endpoint": f"{ep['host']}:{ep['port']}", "path": ep["path"]}
    if not listening(ep):
        record["verdict"] = "not-listening"
        return record
    # As a profile client: the profile's suites and groups, nothing else.
    suites = ":".join(tls["cipherSuites"])
    offered = ":".join(tls["keyExchangeGroups"]["preferred"] + tls["keyExchangeGroups"]["fallback"])
    with_cert = parse_session(s_client(openssl, ep, material, version="tls1_3", client_cert=True,
                                       suites=suites, groups=offered))
    without = parse_session(s_client(openssl, ep, material, version="tls1_3", client_cert=False,
                                     suites=suites, groups=offered))
    tls12 = parse_session(s_client(openssl, ep, material, version="tls1_2", client_cert=True))
    # Does the listener also take a suite outside the profile? (Go's crypto/tls
    # cannot be restricted: an accepted deficiency on its links.)
    weak = parse_session(s_client(openssl, ep, material, version="tls1_3", client_cert=True,
                                  suites="TLS_AES_128_GCM_SHA256"))
    plain = plaintext_answers(ep)
    record.update({
        "version": with_cert["version"],
        "cipher": with_cert["cipher"],
        "group": with_cert["group"],
        "serverVerified": with_cert["verified"],
        "httpWithCertificate": with_cert["http"],
        "tls12": "accepted" if tls12["version"] == "TLSv1.2" else "refused",
        "nonProfileSuite": "accepted" if weak["version"] == "TLSv1.3" else "refused",
        "plaintext": "answered" if plain else "refused",
    })
    if with_cert["version"] != "TLSv1.3" and without["version"] == "TLSv1.3":
        # Server TLS only: the listener does not take this client certificate.
        record.update(version=without["version"], cipher=without["cipher"], group=without["group"],
                      serverVerified=without["verified"])
    # Refused at the handshake: no session, or a session the server closes
    # (an alert or a bare EOF) before answering, where with the certificate
    # it answered.
    refused_alert = re.match(r"(certificate required|handshake failure|bad certificate)", without.get("alert") or "")
    if with_cert["version"] != "TLSv1.3" and without["version"] != "TLSv1.3":
        record["mtls"] = "none"  # no TLS 1.3 session at all: nothing to say about client certificates
    elif without["version"] != "TLSv1.3" or refused_alert or (without["http"] is None and with_cert["http"] is not None):
        record["mtls"] = "handshake"
    elif (without["http"] in (401, 403) and with_cert["http"] != without["http"]) or \
            (without["http"] == 400 and without["certRequired"]):
        # Refused for want of the certificate: with it, the same request is
        # answered otherwise. A 401 both ways is the route's own authentication
        # (a bearer token), not mTLS.
        record["mtls"] = "http"
    else:
        record["mtls"] = "none"
    failures = []
    if plain:
        failures.append("plaintext answered")
    if record["tls12"] == "accepted":
        failures.append("TLS 1.2 accepted")
    if record["version"] != "TLSv1.3":
        failures.append(f"negotiated {record['version'] or 'no TLS'}")
    elif record["cipher"] not in tls["cipherSuites"]:
        failures.append(f"cipher {record['cipher']} outside the profile")
    elif record["group"] not in groups:
        failures.append(f"group {record['group']} outside the profile")
    if not record["serverVerified"]:
        failures.append("server certificate not verified against the lane CA")
    if record["nonProfileSuite"] == "accepted":
        failures.append("a suite outside the profile accepted")
    record["failures"] = failures
    if plain:
        record["verdict"] = "plaintext"
    elif not failures:
        record["verdict"] = "compliant"
    else:
        # Encrypted below the profile (TLS 1.2 only) is still `tls`, not plaintext.
        record["verdict"] = "tls" if record["version"] == "TLSv1.3" or record["tls12"] == "accepted" else "plaintext"
    return record


def link_record(endpoints: list[dict[str, Any]]) -> dict[str, Any] | None:
    """The weakest of a link's probed listeners."""
    probed = [e for e in endpoints if e["verdict"] != "not-listening"]
    if not probed:
        return None
    verdict = min((e["verdict"] for e in probed), key=lambda v: RANK[v])
    mtls = all(e.get("mtls") in ("handshake", "http") for e in probed)
    return {"verdict": verdict, "mtls": mtls, "endpoints": probed}


# ── The inventory ────────────────────────────────────────────────────────────

def record_probe(link: dict[str, Any], lane: str, rec: dict[str, Any], profile_id: str, at: str, run: str) -> None:
    """Record one lane's probe of a link; restate the link's status once every
    lane it lists has one."""
    probe = link.setdefault("probe", {})
    probe[lane] = {"profileId": profile_id, "at": at, "run": run,
                   "verdict": rec["verdict"], "mtls": rec["mtls"],
                   # No address: hosts and free ports belong to the run, and
                   # the report (--report) keeps them.
                   "endpoints": [{k: e.get(k) for k in ("path", "version", "cipher", "group", "mtls",
                                                        "tls12", "nonProfileSuite", "plaintext")
                                  if not (e.get("external") and k in ("nonProfileSuite", "plaintext"))}
                                 for e in rec["endpoints"]]}
    lanes = link.get("lanes", [])
    if all(lane in probe for lane in lanes):
        link["status"] = min((probe[lane]["verdict"] for lane in lanes), key=lambda v: RANK[v])
        link["mtls"] = all(probe[lane]["mtls"] for lane in lanes)


def apply_reports(paths: list[str], inventory_path: Path, profile: dict[str, Any]) -> int:
    """Record probe reports (--report files, from any stage that probes) in the inventory."""
    inventory = json.loads(inventory_path.read_text())
    links = {link["id"]: link for link in inventory["links"]}
    for path in paths:
        report = json.loads(Path(path).read_text())
        if report.get("profileId") != profile["profileId"]:
            raise SystemExit(f"transport-probe: {path} was probed under {report.get('profileId')}, "
                             f"not {profile['profileId']}")
        lane, n = report["lane"], 0
        for lid, rec in report["links"].items():
            if rec.get("verdict") == "not-probed" or lid not in links or lane not in links[lid].get("lanes", []):
                continue
            record_probe(links[lid], lane, rec, report["profileId"], report["at"], report.get("run", ""))
            n += 1
        print(f"transport-probe: {path}: {n} link(s) recorded for the {lane} lane")
    inventory_path.write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + "\n")
    return 0


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lane", default=os.environ.get("RE_PKI_LANE", "native"), choices=["native", "docker", "release"])
    ap.add_argument("--inventory", default=str(CI_DIR / "config" / "transport-inventory.json"))
    ap.add_argument("--profile", default=str(CI_DIR / "config" / "transport-profile.json"))
    ap.add_argument("--manifest", default=os.environ.get("UNIVERSE_MANIFEST", "/tmp/universe-manifest.json"))
    ap.add_argument("--integrations", default=os.environ.get("INTEGRATIONS_CONFIG", str(CI_DIR / "config" / "integrations.json")))
    ap.add_argument("--manager-backend", default="https://127.0.0.1:3001", help="'' to skip")
    ap.add_argument("--manager-frontend", default="https://127.0.0.1:5173", help="'' to skip")
    ap.add_argument("--manager-ts-pe", default="https://127.0.0.1:3004", help="tls-proxy's TypeScript PE; '' to skip")
    ap.add_argument("--proxy-grafana", default="https://127.0.0.1:3000", help="Grafana through tls-proxy; '' to skip")
    ap.add_argument("--endpoints", help="extra listeners per link: {link id: [{url, path}]}")
    ap.add_argument("--only-endpoints", action="store_true",
                    help="probe only the --endpoints listeners (a pass from a container on a compose network)")
    ap.add_argument("--external-only", action="store_true",
                    help="probe only the external links (outside parties are the same from every lane)")
    ap.add_argument("--no-external", action="store_true",
                    help="leave the external links out (offline tests)")
    ap.add_argument("--report", help="write the probe report (JSON) here")
    ap.add_argument("--run", default=os.environ.get("RE_RUN_ID", ""), help="the run id recorded with each probe")
    ap.add_argument("--write", action="store_true", help="record the probes in the inventory")
    ap.add_argument("--apply", nargs="+", metavar="REPORT",
                    help="record these probe reports in the inventory, and probe nothing")
    args = ap.parse_args()
    if args.apply:
        return apply_reports(args.apply, Path(args.inventory), json.loads(Path(args.profile).read_text()))

    material = harness(args.lane)
    openssl = openssl_binary()
    profile = json.loads(Path(args.profile).read_text())
    inventory_path = Path(args.inventory)
    inventory = json.loads(inventory_path.read_text())
    targets: dict[str, list[dict[str, Any]]] = {}
    if not (args.only_endpoints or args.external_only):
        targets = resolve(tls_context(material), Path(args.manifest), Path(args.integrations),
                          (args.manager_backend, args.manager_frontend, args.manager_ts_pe, args.proxy_grafana))
    if args.endpoints:
        for lid, eps in json.loads(Path(args.endpoints).read_text()).items():
            for e in eps:
                ep = endpoint(e["url"], e.get("path", "/"))
                for key in ("protocol", "ca"):
                    if ep and e.get(key):
                        ep[key] = e[key]
                if ep and ep not in targets.setdefault(lid, []):
                    targets[lid].append(ep)
    externals = {link["id"] for link in inventory["links"] if link.get("audience") == "external"}
    for link in [] if args.only_endpoints or args.no_external else inventory["links"]:
        for pt in link.get("probeTargets", []) if link["id"] in externals else []:
            targets.setdefault(link["id"], []).append(
                {"url": f"{pt['host']}:{pt['port']}", "scheme": "tls", "host": pt["host"], "port": int(pt["port"]),
                 "path": pt.get("path", "/"), "protocol": pt.get("protocol", "http")})
    at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    report: dict[str, Any] = {"profileId": profile["profileId"], "lane": args.lane, "at": at,
                              "run": args.run, "links": {}}
    failed: list[str] = []
    for link in inventory["links"]:
        lid = link["id"]
        if args.lane not in link.get("lanes", []):
            continue
        if ((args.only_endpoints and lid not in targets) or (args.external_only and lid not in externals)
                or (args.no_external and lid in externals)):
            continue  # another pass probes it
        probe_one = (lambda ep: probe_external(openssl, ep, profile)) if lid in externals else \
            (lambda ep: probe_endpoint(openssl, ep, material, profile))
        eps = [probe_one(ep) for ep in targets.get(lid, [])]
        rec = link_record(eps)
        if rec is None:
            report["links"][lid] = {"verdict": "not-probed",
                                    "reason": "no listener resolved on this lane" if not eps else "nothing listening"}
            continue
        allows = (link.get("deficiency") or {}).get("allows") or {}
        if allows:
            rec["deficiency"] = allows
        for e in rec["endpoints"]:
            for f in e.get("failures", []):
                # Plaintext and a downgrade fail the stage, unless the owner
                # accepted that link at that status; a non-profile suite does
                # only where nothing was accepted for the link.
                fatal = f.startswith(("plaintext", "TLS 1.2", "negotiated", "cipher", "group"))
                if f.startswith("a suite outside"):
                    fatal = not allows
                if allows.get("status") == "plaintext" and f.startswith(("plaintext", "negotiated no TLS")):
                    fatal = False
                # A finding the owner's deficiency names (Qdrant's TLS 1.2) is recorded, not failed.
                if any(f.startswith(a) for a in (link.get("deficiency") or {}).get("probeAccepts", [])):
                    fatal = False
                if e.get("external"):
                    fatal = False  # the release gate holds an outside party, not the lane
                if fatal:
                    failed.append(f"{lid} ({e['endpoint']}): {f}")
        report["links"][lid] = rec
        if args.write:
            record_probe(link, args.lane, rec, profile["profileId"], at, args.run)

    counts: dict[str, int] = {}
    for rec in report["links"].values():
        counts[rec["verdict"]] = counts.get(rec["verdict"], 0) + 1
    report["counts"] = counts
    report["failures"] = failed
    for lid, rec in sorted(report["links"].items()):
        mt = "" if rec["verdict"] == "not-probed" else (", mTLS" if rec.get("mtls") else ", no mTLS")
        print(f"  {lid:34} {rec['verdict']}{mt}")
    print(f"transport-probe ({args.lane}): " + ", ".join(f"{n} {v}" for v, n in sorted(counts.items())))
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2) + "\n")
    if args.write:
        inventory_path.write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + "\n")
    if failed:
        print("transport-probe: FAIL — plaintext or a downgrade on the lane:", file=sys.stderr)
        for f in failed:
            print(f"  {f}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
