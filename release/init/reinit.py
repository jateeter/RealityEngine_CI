#!/usr/bin/env python3
"""re-init: configure, and serve the instance registry of, a RealityEngine install.

The release bundle's one-shot job (ReleaseRoadmap C1, C2). The installer runs it
with the install directory mounted at /install; it writes everything the
release compose needs there, so nothing is generated on the Mac itself:

  configure --engines cpp:2,lsp:1,scala:1 --version release-v0.0.1 [--images F]
      compose.yml           the fixed services (copied from this image)
      compose.engines.yml   one RE and one PE service per instance in the spec
      .env                  image references, host ports, secrets (0600)
      engines/<id>.env      INSTANCE_UUID and INSTANCE_CLOCK_DIR per instance
      state/                the instance UUID table (#296), kept across runs
      registry/             the instance registry, in two views of the same
                            instances: re-registry.json (host addresses, what
                            registry_url() and the tests resolve) and
                            re-registry.internal.json (container addresses,
                            what Manager, localAI and MCP read)
      config/               Prometheus (with file_sd targets per instance),
                            Loki, Promtail, Grafana, nginx, integrations.json
      certs/                a local CA and a server certificate, made once
      openclaw/             the OpenClaw gateway home: hardened config and the
                            regression agent profile, by localOpenClawStack's
                            own scripts
      release.json          what is installed: version, spec, images

  serve-registry            serve /install/registry over HTTP (the
                            instance-registry service of the compose)

  prepare-volumes           make the shared clock volume writable by the
                            engines' user

  machines-sync [--ref R]   replace the Load Machines catalog with
                            RealityEngine_Machines at a ref (default main),
                            from GitHub, validated first (A8, C6)
  machines-load ...         load catalog machines into every engine instance,
                            through Manager's own load path, then refresh every
                            PE's sources; recorded, so a restart reloads them
  machines-list             the catalog, by domain

The instance UUID table and the secrets are written once and kept: an instance
keeps its UUID, and its Lamport clock, across restarts, spec changes and
upgrades; an instance dropped from the spec keeps its UUID for when it returns.
"""
from __future__ import annotations

import argparse
import datetime
import http.server
import ipaddress
import json
import os
import pathlib
import re
import secrets
import shutil
import subprocess
import sys

OPT = pathlib.Path(os.environ.get("REINIT_OPT", "/opt"))
RELEASE = OPT / "release"          # compose.yml and release config templates
CI = OPT / "ci"                    # RealityEngine_CI files the install needs
ASSETS = OPT / "assets"            # localAssetStorageStack: its provisioning scripts and CSS config
OCS = OPT / "ocs"                  # localOpenClawStack at the release commit

RUNTIMES = ("scala", "cpp", "lsp", "rust")
# Conformance followers (RealityEngine_CI#607): in the install and its instance
# registry with `role: follower`, never a vote (owner, 2026-11-12).
FOLLOWERS = {"rust"}
# Host port bands, PE then RE, a stride of 10 per instance: up to 20 instances of
# a type without overlap, and nothing near what macOS holds (5000, 7000).
BAND = {"scala": 6100, "cpp": 6300, "lsp": 6600, "rust": 6900}
STRIDE = 10
MAX_PER_RUNTIME = 20
RE_PORT, PE_PORT = 3000, 3004          # inside every engine container
CLOCK_DIR = "/var/lib/reality-engine/clock"
LANE = "release"

# Host ports of the fixed services. Each can be overridden in the environment of
# `configure` (the installer passes RE_PORT_<NAME>), so a Mac already using one
# can move it; the defaults are the expected live surfaces of the root CLAUDE.md.
HOST_PORTS = {
    "MANAGER_UI": 5173, "MANAGER_API": 3001, "LOCALAI": 4000, "OPENCLAW": 18789,
    "WEBUI": 8080, "PIM": 8090, "CSS": 13000, "MCP": 7331, "REGISTRY": 5999,
    "GRAFANA": 3002, "PROMETHEUS": 9090, "QDRANT": 4333,
    # The browser sidecar's CDP, for the native gateway: loopback only (#592).
    "BROWSER_CDP": 9222,
    # The asset storage stack's lifecycle API (localAssetStorageStack). Its CSS
    # and dokieli are on ASSETS_FIXED_PORTS, never moved: a pod's URL holds it.
    "LIFECYCLE": 13445,
}
# localAssetStorageStack ROADMAP D7: https://assets-css.localhost:13443/ and
# https://assets-dokieli.localhost:13444/, the same inside and outside.
ASSETS_FIXED_PORTS = {"assets-css": 13443, "assets-dokieli": 13444}
ASSETS_CSS_IMAGE = "solidproject/community-server:7.3.0@sha256:58073541889f0cd113dc482b4ddbb834bcd39463dc077d49fd1cf9f55337c4b6"
# The OpenClaw gateway runs on the Mac (#592); containers reach it here.
GATEWAY_HOST = "host.docker.internal"


def gateway_port() -> int:
    return int(os.environ.get("RE_PORT_OPENCLAW", HOST_PORTS["OPENCLAW"]))

SPEC_RE = re.compile(r"^(scala|cpp|lsp|rust):([0-9]+)$")


# ── helpers ──────────────────────────────────────────────────────────────────

def log(msg: str) -> None:
    print(f"[re-init] {msg}", flush=True)


def write(path: pathlib.Path, text: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def write_json(path: pathlib.Path, data, mode: int | None = None) -> None:
    write(path, json.dumps(data, indent=2) + "\n", mode)


def parse_spec(spec: str) -> list[tuple[str, int]]:
    """'cpp:2,lsp:1,scala:1' -> [('scala', 1), ('cpp', 2), ('lsp', 1)] in band order."""
    counts: dict[str, int] = {}
    for part in [p.strip() for p in spec.split(",") if p.strip()]:
        m = SPEC_RE.match(part)
        if not m:
            raise SystemExit(f"bad engine spec {part!r}: expected <scala|cpp|lsp|rust>:<count>")
        rt, n = m.group(1), int(m.group(2))
        if rt in counts:
            raise SystemExit(f"{rt} is listed twice in {spec!r}")
        if not 0 <= n <= MAX_PER_RUNTIME:
            raise SystemExit(f"{rt}:{n}: between 0 and {MAX_PER_RUNTIME} instances per engine type")
        counts[rt] = n
    if not any(n for rt, n in counts.items() if rt not in FOLLOWERS):
        raise SystemExit("the engine spec starts no voting instance")
    return [(rt, counts.get(rt, 0)) for rt in RUNTIMES if counts.get(rt, 0)]


def instances(spec: list[tuple[str, int]]) -> list[dict]:
    out = []
    for rt, n in spec:
        for i in range(1, n + 1):
            pe = BAND[rt] + (i - 1) * STRIDE
            iid = f"{rt}-{i}"
            out.append({"id": iid, "runtime": rt, "pe_port": pe, "re_port": pe + 1,
                        "re_service": f"engine-{iid}-re", "pe_service": f"engine-{iid}-pe"})
    return out


def host_ip() -> str:
    """The Mac's LAN address as seen from a container, for the HealthKit bridge
    and other LAN clients. Docker Desktop does not expose it, so the installer
    passes it as HOST_IP; failing that, the registry's host field is loopback."""
    ip = os.environ.get("HOST_IP", "").strip()
    try:
        ipaddress.ip_address(ip)
        return ip
    except ValueError:
        return "127.0.0.1"


# ── the instance UUIDs (#296) ────────────────────────────────────────────────

def allocate_uuids(install: pathlib.Path, insts: list[dict]) -> None:
    """Allocate a UUID per instance in the install's table, through CI's own
    allocator, and write the env file each instance's services load."""
    os.environ["RE_INSTANCE_STATE_DIR"] = str(install / "state")
    sys.path.insert(0, str(CI / "scripts" / "lib"))
    import instance_uuids  # noqa: E402  (CI's allocator, unchanged)

    if LANE not in instance_uuids.LANES:
        instance_uuids.LANES = (*instance_uuids.LANES, LANE)
    for inst in insts:
        inst["instance_uuid"] = instance_uuids.allocate(LANE, inst["id"])
        # A unique MQTT client id per instance (scripts/lib/pe-env.sh
        # mqtt_client_id): two PEs sharing one evict each other on a broker.
        client_id = f"re-pe-{inst['id']}-{inst['instance_uuid'].replace('-', '')[-8:]}"
        write(install / "engines" / f"{inst['id']}.env",
              f"INSTANCE_UUID={inst['instance_uuid']}\nINSTANCE_CLOCK_DIR={CLOCK_DIR}\n"
              f"MQTT_CLIENT_ID={client_id}\n")
    held: dict[str, list[str]] = {}
    for inst in insts:
        held.setdefault(inst["instance_uuid"], []).append(inst["id"])
    clash = {u: ids for u, ids in held.items() if len(ids) > 1}
    if clash:
        raise SystemExit(f"two instances share a UUID, which is never allowed: {clash}")


# ── the engine services ──────────────────────────────────────────────────────

def engine_services(insts: list[dict], tls: bool = False) -> dict:
    services: dict[str, dict] = {}
    scheme = "https" if tls else "http"
    for inst in insts:
        rt, iid = inst["runtime"], inst["id"]
        re_svc, pe_svc = inst["re_service"], inst["pe_service"]
        re_url = f"{scheme}://{re_svc}:{RE_PORT}"
        common = {
            "restart": "unless-stopped",
            "networks": ["realityengine"],
            "extra_hosts": ["host.docker.internal:host-gateway"],
            "env_file": [{"path": f"./engines/{iid}.env", "required": True}],
            "labels": {"org.realityengine.instance": iid, "org.realityengine.runtime": rt},
            "logging": {"driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}},
        }
        corpus_env = {
            "MACHINES_DIR": "/app/corpus/machines",
            "SEMANTICS_MANIFEST": "/app/corpus/semantics/abox-manifest.json",
            "VECTOR_DIMENSION": "${VECTOR_DIMENSION:-7680}",
            "QDRANT_URL": f"{scheme}://qdrant:6333",
            "INSTANCE_ID": iid,
        }
        re_svc_def = {
            **common,
            "image": f"${{RE_IMAGE_{rt.upper()}}}",
            "environment": dict(corpus_env),
            "volumes": ["corpus-boot:/app/corpus:ro", f"engine-clock:{CLOCK_DIR}"],
            "ports": [f"{inst['re_port']}:{RE_PORT}"],
            "depends_on": {"corpus": {"condition": "service_completed_successfully"},
                           "prepare": {"condition": "service_completed_successfully"},
                           "qdrant": {"condition": "service_healthy"}},
            "healthcheck": {"test": health(RE_PORT, tls),
                            "interval": "10s", "timeout": "5s", "retries": 18, "start_period": "30s"},
        }
        pe_env = {
            **corpus_env,
            "LOCAL_AI_API_URL": f"{scheme}://localai-api:8000",
            "LOCAL_AI_MACHINES_DIR": "/app/localai-machines",
            "INTEGRATIONS_CONFIG": "/app/config/integrations.json",
            "ACP_ENABLED": "true", "ACP_PLATFORM": "OpenClaw", "ACP_SURFACE": "xACP",
            "ACP_GATEWAY_URL": f"{'wss' if tls else 'ws'}://{GATEWAY_HOST}:{gateway_port()}",
            "OPENCLAW_GATEWAY_URL": f"{'wss' if tls else 'ws'}://{GATEWAY_HOST}:{gateway_port()}",
            "ACP_SESSION_KEY": "agent:main:main", "OPENCLAW_ACP_SESSION": "agent:main:main",
            "ACP_TARGET_AGENT": "openclaw",
            "ACP_COMPLETION_SOURCE_MAPPING_ID": "acp-openclaw-completion",
            "OPENCLAW_GATEWAY_TOKEN": "${OPENCLAW_GATEWAY_TOKEN}",
            "HEALTHKIT_BRIDGE_TOKEN": "${HEALTHKIT_BRIDGE_TOKEN}",
            "TRIGGERS_ENABLED": "true", "TRIGGER_DISPATCH_MODE": "dry-run",
            # Ollama runs natively, for the Apple GPU (A6); every PE runtime
            # defaults to localhost, which inside a container is the container.
            "OLLAMA_BASE_URL": "http://host.docker.internal:11434",
            "OLLAMA_MODEL": "${OLLAMA_MODEL:-nemotron-3-nano:4b-mlx}",
        }
        pe_svc_def = {
            **common,
            "image": f"${{RE_IMAGE_{'SCALA_PE' if rt == 'scala' else rt.upper()}}}",
            "environment": pe_env,
            "volumes": ["corpus-boot:/app/corpus:ro", "localai-machines:/app/localai-machines:ro",
                        "./config/integrations.json:/app/config/integrations.json:ro"],
            "ports": [f"{inst['pe_port']}:{PE_PORT}"],
            # restart: a PE must restart when its RE is recreated (an image
            # upgrade): it holds sources derived from the RE's machines, and a
            # PE that outlived its RE kept them for ids the new RE no longer has.
            "depends_on": {re_svc: {"condition": "service_healthy", "restart": True}},
            "healthcheck": {"test": health(PE_PORT, tls),
                            "interval": "10s", "timeout": "5s", "retries": 18, "start_period": "30s"},
        }
        if tls:
            # The instance's certificate on both of its services (#729): each
            # serves TLS 1.3 with mTLS, and the PE calls its RE with it.
            for d in (re_svc_def, pe_svc_def):
                d["environment"].update(TLS_ENV)
                d["volumes"] = d["volumes"] + tls_mounts(iid)
        if rt == "cpp":
            re_svc_def["command"] = ["/app/bin/reality_engine_server", str(RE_PORT),
                                     "/app/corpus/machines", "${VECTOR_DIMENSION:-7680}"]
            pe_svc_def["command"] = ["/app/bin/perception_engine_server", str(PE_PORT), re_url,
                                     f"{scheme}://localai-api:8000", "/app/localai-machines",
                                     "${VECTOR_DIMENSION:-7680}"]
        elif rt == "lsp":
            re_svc_def["command"] = ["reality"]
            re_svc_def["environment"]["REALITY_ENGINE_PORT"] = str(RE_PORT)
            pe_svc_def["command"] = ["perception"]
            pe_env["PERCEPTION_ENGINE_PORT"] = str(PE_PORT)
            pe_env["REALITY_ENGINE_URL"] = re_url
        elif rt == "rust":
            # One image, both binaries (RealityEngine_CI docker/rust/Dockerfile).
            re_svc_def["command"] = ["/app/bin/reality-engine"]
            re_svc_def["environment"]["REALITY_ENGINE_PORT"] = str(RE_PORT)
            pe_svc_def["command"] = ["/app/bin/perception-engine"]
            pe_env.update({"PERCEPTION_ENGINE_PORT": str(PE_PORT), "RE_URL": re_url})
        else:  # scala
            re_svc_def["environment"]["PORT"] = str(RE_PORT)
            re_svc_def["environment"]["JAVA_TOOL_OPTIONS"] = "${ENGINE_SCALA_RE_JAVA_OPTS:--Xmx3g}"
            pe_env.update({"PORT": str(PE_PORT), "PERCEPTION_ENGINE_PORT": str(PE_PORT),
                           "REALITY_ENGINE_URL": re_url, "DATA_PATH": "/app/data", "FRESH_START": "true",
                           "JAVA_TOOL_OPTIONS": "${ENGINE_SCALA_PE_JAVA_OPTS:--Xmx2g}"})
        services[re_svc] = re_svc_def
        services[pe_svc] = pe_svc_def
    # localAI registers its machines and sensors with every engine when it
    # starts, and does not retry a PE that was not up yet: on a fresh `up` it
    # could start first and leave the PEs without its RAG sensors. It waits for
    # every PE of the spec (compose merges this with its own depends_on).
    # restart: likewise localAI restarts whenever a PE is recreated, so it
    # registers again with the new one; otherwise the new PE lacked its sensors.
    services["localai-api"] = {"depends_on": {i["pe_service"]: {"condition": "service_healthy", "restart": True}
                                              for i in insts}}
    return services


def yaml_dump(data, indent: int = 0) -> str:
    """A small YAML writer for the compose overlay: dicts, lists and scalars,
    every scalar quoted, so no value is ever read back as another type."""
    pad = "  " * indent
    lines: list[str] = []
    if isinstance(data, dict):
        for k, v in data.items():
            if isinstance(v, (dict, list)) and v:
                lines.append(f"{pad}{k}:")
                lines.append(yaml_dump(v, indent + 1))
            else:
                lines.append(f"{pad}{k}: {scalar(v)}")
    elif isinstance(data, list):
        for v in data:
            if isinstance(v, dict) and v:
                first, *rest = yaml_dump(v, indent + 1).splitlines()
                lines.append(f"{pad}- {first.strip()}")
                lines.extend(rest)
            elif isinstance(v, list) and v:
                lines.append(f"{pad}-")
                lines.append(yaml_dump(v, indent + 1))
            else:
                lines.append(f"{pad}- {scalar(v)}")
    return "\n".join(lines)


def scalar(v) -> str:
    if v == {} or v == []:
        return "{}" if v == {} else "[]"
    if isinstance(v, bool):
        return "true" if v else "false"
    return json.dumps(str(v))


# ── the instance registry, in two views ──────────────────────────────────────

def registries(insts: list[dict], ip: str, ports: dict[str, int], tls: bool = False) -> tuple[dict, dict]:
    eng = "https" if tls else "http"   # the engines and the registry, as TLS reaches them (#729)
    started = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def entry(inst: dict, re_url: str, pe_url: str, re_port: int, pe_port: int) -> dict:
        # The shape of scripts/registry.sh registry_add, so every reader of the
        # native instance registry reads this one unchanged.
        return {"id": inst["id"], "runtime": inst["runtime"], "re_url": re_url, "pe_url": pe_url,
                "re_port": re_port, "pe_port": pe_port, "pid_re": None, "pid_pe": None,
                "instance_uuid": inst["instance_uuid"], "started_at": started, "status": "running",
                **({"role": "follower"} if inst["runtime"] in FOLLOWERS else {})}

    # The `services` block is the native instance registry's contract
    # (scripts/registry.sh registry_set_service; startUniverse.sh publishes
    # these names), {name: {url, port}}, so every live spec that resolves a
    # support service from the instance registry finds it here too.
    def svc(url: str) -> dict:
        try:
            port = int(url.rsplit(":", 1)[-1].split("/")[0])
        except ValueError:
            port = 0
        return {"url": url, "port": port}

    host = {"host": ip, "lane": LANE, "instances": [
        entry(i, f"{eng}://localhost:{i['re_port']}", f"{eng}://localhost:{i['pe_port']}", i["re_port"], i["pe_port"])
        for i in insts], "services": {
        "manager_backend": svc(f"https://localhost:{ports['MANAGER_API']}"),
        "manager_frontend": svc(f"https://localhost:{ports['MANAGER_UI']}"),
        "localai_api": svc(f"http://localhost:{ports['LOCALAI']}"),
        "qdrant": svc(f"http://localhost:{ports['QDRANT']}"),
        "openclaw_gateway": svc(f"http://localhost:{ports['OPENCLAW']}"),
        "mcp": svc(f"http://localhost:{ports['MCP']}"),
        "registry": svc(f"{eng}://localhost:{ports['REGISTRY']}"),
    }}
    internal = {"host": ip, "lane": LANE, "instances": [
        entry(i, f"{eng}://{i['re_service']}:{RE_PORT}", f"{eng}://{i['pe_service']}:{PE_PORT}", RE_PORT, PE_PORT)
        for i in insts], "services": {
        "manager_backend": svc("https://visualizer-backend:3001"),
        "localai_api": svc("http://localai-api:8000"),
        "qdrant": svc("http://qdrant:6333"),
        "openclaw_gateway": svc(f"http://{GATEWAY_HOST}:{gateway_port()}"),
        "mcp": svc("http://mcp:7331"),
        "registry": svc(f"{eng}://registry:8000"),
    }}
    return host, internal


# ── configuration files ──────────────────────────────────────────────────────

def file_sd(insts: list[dict]) -> tuple[list, list]:
    re_t, pe_t = [], []
    for i in insts:
        labels = {"runtime": i["runtime"], "engine": i["runtime"], "instance": i["id"], "source": "registry"}
        re_t.append({"targets": [f"{i['re_service']}:{RE_PORT}"], "labels": {**labels, "component": "reality-engine"}})
        pe_t.append({"targets": [f"{i['pe_service']}:{PE_PORT}"], "labels": {**labels, "component": "perception-engine"}})
    return re_t, pe_t


def integrations(tls: bool = False) -> dict:
    """CI's integration registry template, with every address the container
    network's (startUniverse.sh ensure_ci_integrations_config does the same
    for the native lane, with host addresses)."""
    data = json.loads((CI / "config" / "integrations.example.json").read_text())
    for item in data.get("integrations", []):
        for key in ("baseUrl",):
            if isinstance(item.get(key), str):
                item[key] = item[key].replace("http://localhost:4000", "http://localai-api:8000")
        td = item.get("triggerDispatch")
        if isinstance(td, dict) and isinstance(td.get("url"), str):
            td["url"] = td["url"].replace("http://localhost:4000", "http://localai-api:8000")
        if item.get("id") == "openclaw-xacp" or item.get("kind") in ("acp", "openclaw-acp"):
            item.update({"enabled": True, "platform": "OpenClaw", "surface": "xACP",
                         "gatewayUrl": f"{'wss' if tls else 'ws'}://{GATEWAY_HOST}:{gateway_port()}", "sessionKey": "agent:main:main",
                         "targetAgent": "openclaw", "completionSourceMappingId": "acp-openclaw-completion"})
        if item.get("kind") == "mqtt":
            item["enabled"] = False      # no MQTT-parity claim in this release (A11)
    return data


# ── the install's PKI (RealityEngine_CI#729, #668) ───────────────────────────
#
# One CA per install, issued by the suite's re_pki.py (ECDSA P-384, the
# transport profile's validities), under <install>/pki: the release lane's
# counterpart of ~/.reality-engine/pki/<lane>. Every engine instance gets a
# certificate (kind both, its compose names, urn:uuid:<instance_uuid>), as do
# the instance registry, Manager's pair and the CLI's harness. Issued on every
# configure, whether or not TLS is on, so turning it on needs no other step;
# re_pki keeps a current certificate and re-issues one inside its renewal window.
RE_PKI = CI / "scripts" / "lib" / "re_pki.py"
TLS_DIR = "/run/re-tls"   # where a container finds its certificate, the CA and the CRL


def pki(install: pathlib.Path, insts: list[dict], ip: str) -> None:
    env = {**os.environ, "RE_PKI_DIR": str(install / "pki")}

    def run(*a: str) -> None:
        subprocess.run([sys.executable, str(RE_PKI), *a], check=True, capture_output=True, env=env)

    run("init")
    run("renew")
    ips = sorted({"127.0.0.1", ip})
    ip_args = [x for a in ips for x in ("--ip", a)]
    for i in insts:
        run("issue", i["id"], "--kind", "both", "--dns", "localhost", "--dns", f"{i['id']}.localhost",
            "--dns", i["re_service"], "--dns", i["pe_service"], "--dns", GATEWAY_HOST,
            "--instance-uuid", i["instance_uuid"], *ip_args)
    run("issue", "registry", "--kind", "server", "--dns", "localhost", "--dns", "registry",
        "--dns", GATEWAY_HOST, *ip_args)
    run("issue", "manager", "--kind", "both", "--dns", "localhost", "--dns", "visualizer-backend",
        "--dns", "visualizer-frontend", "--dns", "tls-proxy", "--dns", GATEWAY_HOST, *ip_args)
    run("issue", "harness", "--kind", "client")
    # localAIStack's services and re-mcp (#729), named as the compose network
    # and the host reach them.
    run("issue", "localai-api", "--kind", "both", "--dns", "localhost", "--dns", "localai-api",
        "--dns", GATEWAY_HOST, *ip_args)
    run("issue", "localai-qdrant", "--kind", "both", "--dns", "localhost", "--dns", "qdrant", *ip_args)
    run("issue", "localai-redis", "--kind", "both", "--dns", "localhost", "--dns", "redis", *ip_args)
    run("issue", "pim-css", "--kind", "server", "--dns", "localhost", "--dns", "css.localhost", "--dns", "css", *ip_args)
    run("issue", "pim", "--kind", "both", "--dns", "localhost", "--dns", "pim", "--dns", GATEWAY_HOST, *ip_args)
    # Observability (#729): the dev lane's names, the compose network's.
    run("issue", "obs-loki", "--kind", "server", "--dns", "loki", "--dns", "localhost", "--ip", "127.0.0.1")
    run("issue", "obs-promtail", "--kind", "client")
    run("issue", "obs-prometheus", "--kind", "both", "--dns", "prometheus", "--dns", "localhost", "--ip", "127.0.0.1")
    run("issue", "obs-grafana", "--kind", "both", "--dns", "grafana", "--dns", "localhost", "--ip", "127.0.0.1")
    run("issue", "bridge-metrics", "--kind", "both", "--dns", "bridge-metrics", "--dns", "localhost", "--ip", "127.0.0.1")
    # The native gateway and its browser sidecar (localOpenClawStack#92's
    # layout under pki/openclaw: gateway/ browser/ ca.crt ca.crl, relative links
    # so they resolve both in re-init's container and on the Mac).
    run("issue", "openclaw-gateway", "--kind", "both", "--dns", "localhost", "--dns", GATEWAY_HOST, *ip_args)
    run("issue", "openclaw-browser", "--kind", "server", "--dns", "localhost", "--dns", "browser", *ip_args)
    oc = install / "pki" / "openclaw"
    oc.mkdir(parents=True, exist_ok=True)
    for link, target in (("gateway", "../issued/openclaw-gateway"), ("browser", "../issued/openclaw-browser"),
                         ("ca.crt", "../ca/ca.crt"), ("ca.crl", "../ca/ca.crl")):
        if (oc / link).is_symlink() or (oc / link).exists():
            (oc / link).unlink()
        (oc / link).symlink_to(target)
    run("issue", "re-mcp", "--kind", "both", "--dns", "localhost", "--dns", "mcp", "--dns", GATEWAY_HOST, *ip_args)
    # The asset storage stack, named as its scripts/up.js issues them.
    run("issue", "assets-css", "--kind", "both", "--dns", "assets-css.localhost", "--dns", "assets-css", "--ip", "127.0.0.1")
    run("issue", "assets-dokieli", "--kind", "server", "--dns", "assets-dokieli.localhost", "--dns", "assets-dokieli",
        "--ip", "127.0.0.1")
    run("issue", "lifecycle", "--kind", "both", "--dns", "lifecycle", "--dns", "localhost", "--ip", "127.0.0.1")
    run("crl")
    log("issued the install's lane certificates (pki/)")


# The registry's health check on the lane: a TLS 1.3 read presenting the
# install's harness certificate (mounted for this), verified against the CA.
REGISTRY_TLS_HEALTH = (
    "import ssl,urllib.request;c=ssl.create_default_context(cafile='/run/re-tls/ca.crt');"
    "c.load_cert_chain('/run/re-tls/harness/cert.pem','/run/re-tls/harness/key.pem');"
    "urllib.request.urlopen('https://localhost:8000/re-registry.json',timeout=3,context=c)")


def node_tls_health(port: int, path: str) -> str:
    """A Node one-liner that GETs https://127.0.0.1:PORT/PATH presenting the
    service's own lane certificate, for images without a client-certificate
    capable wget (Alpine's BusyBox)."""
    return ("const f=require('fs');require('https').get({host:'127.0.0.1',port:%d,path:'%s',"
            "ca:f.readFileSync(process.env.RE_TLS_CA),cert:f.readFileSync(process.env.RE_TLS_CERT),"
            "key:f.readFileSync(process.env.RE_TLS_KEY)},r=>process.exit(r.statusCode===200?0:1))"
            ".on('error',()=>process.exit(1))" % (port, path))


LANE_CLIENT = (f"ca_file: {TLS_DIR}/ca.crt, cert_file: {TLS_DIR}/service/chain.pem, "
               f"key_file: {TLS_DIR}/service/key.pem, min_version: TLS13")


def observability_tls_services(install: pathlib.Path) -> dict:
    """Loki, Promtail, Prometheus, Grafana and the bridge exporter on the lane,
    as docker-compose.observability-tls.yml puts the dev lane's (#730, #729).
    Promtail's and Prometheus's lane configs are derived from the release's own,
    so they keep the release's jobs and targets: every scrape and the push go
    over https with the lane certificate."""
    cfg = install / "config"
    prom = (RELEASE / "config" / "prometheus.yml").read_text()
    prom = re.sub(r"^(  - job_name:\s*.+)$",
                  lambda m: m.group(1) + f"\n    scheme: https\n    tls_config: {{{LANE_CLIENT}}}", prom, flags=re.M)
    write(cfg / "prometheus.lane.yml", "# Generated by re-init from prometheus.yml (#729). Do not edit.\n" + prom)
    tail = (RELEASE / "config" / "promtail.yml").read_text()
    tail, n = re.subn(r"tls_config:\n(\s+)insecure_skip_verify:\s*true",
                      lambda m: f"tls_config:\n{m.group(1)}ca_file: {TLS_DIR}/ca.crt\n{m.group(1)}cert_file: {TLS_DIR}/service/chain.pem\n"
                                f"{m.group(1)}key_file: {TLS_DIR}/service/key.pem\n{m.group(1)}server_name: loki", tail)
    if n != 1:
        raise SystemExit("re-init: release/config/promtail.yml has no insecure tls_config to replace")
    write(cfg / "promtail.lane.yml", "# Generated by re-init from promtail.yml (#729). Do not edit.\n" + tail)
    for name in ("prometheus-web.lane.yml", "prometheus-health.lane.yml", "grafana-datasources.lane.yml"):
        shutil.copyfile(CI / "config" / name, cfg / name)
    # The Go services behind OpenSSL fronts (#729), as the dev lane's overlay:
    # each listens on its container's loopback, and an nginx front in its
    # network namespace serves the public port at the profile.
    subprocess.run([sys.executable, str(CI / "scripts" / "lib" / "obs_front_conf.py"), str(cfg / "fronts")], check=True)
    svc = lambda name: [f"./pki/issued/{name}:{TLS_DIR}/service:ro", f"./pki/ca/ca.crt:{TLS_DIR}/ca.crt:ro"]
    m = re.search(r"^  tls-proxy:\n(?:    .*\n)*?    image: (\S+)", (RELEASE / "compose.yml").read_text(), flags=re.M)
    if not m:
        raise SystemExit("re-init: release/compose.yml names no tls-proxy image for the observability fronts")
    front = lambda name, issued: {
        "image": m.group(1), "network_mode": f"service:{name}", "depends_on": [name], "restart": "unless-stopped",
        "volumes": [f"./config/fronts/{name}.conf:/etc/nginx/nginx.conf:ro", f"./pki/issued/{issued}:{TLS_DIR}/service:ro",
                    f"./pki/ca/ca.crt:{TLS_DIR}/ca.crt:ro", f"./pki/ca/ca.crl:{TLS_DIR}/ca.crl:ro"]}
    return {
        "loki-front": front("loki", "obs-loki"),
        "prometheus-front": front("prometheus", "obs-prometheus"),
        "grafana-front": front("grafana", "obs-grafana"),
        "loki": {
            "environment": {"LOKI_TLS_CERT": f"{TLS_DIR}/service/chain.pem", "LOKI_TLS_KEY": f"{TLS_DIR}/service/key.pem",
                            "LOKI_HTTP_ADDRESS": "127.0.0.1", "LOKI_HTTP_PORT": "3101",
                            "LOKI_TLS_CLIENT_AUTH": "NoClientCert", "LOKI_TLS_MIN_VERSION": "VersionTLS13"},
            "volumes": svc("obs-loki"),
            "healthcheck": {"test": ["CMD-SHELL", "nc -z 127.0.0.1 3100"]}},
        "promtail": {
            "volumes": ["./config/promtail.lane.yml:/etc/promtail/promtail.yml:ro", *svc("obs-promtail")]},
        "prometheus": {
            "command": ["--config.file=/etc/prometheus/prometheus.yml", "--web.config.file=/etc/prometheus/web.yml",
                        "--storage.tsdb.retention.time=7d", "--web.listen-address=127.0.0.1:9091"],
            "volumes": ["./config/prometheus.lane.yml:/etc/prometheus/prometheus.yml:ro",
                        "./config/prometheus-web.lane.yml:/etc/prometheus/web.yml:ro",
                        "./config/prometheus-health.lane.yml:/etc/prometheus/health-client.yml:ro",
                        *svc("obs-prometheus")],
            "healthcheck": {"test": ["CMD", "promtool", "check", "healthy", "--url=https://localhost:9090",
                                     "--http.config.file=/etc/prometheus/health-client.yml"]}},
        "grafana": {
            "environment": {"GF_SERVER_PROTOCOL": "https", "GF_SERVER_CERT_FILE": f"{TLS_DIR}/service/chain.pem",
                            "GF_SERVER_CERT_KEY": f"{TLS_DIR}/service/key.pem", "GF_SERVER_MIN_TLS_VERSION": "TLS1.3",
                            "GF_SERVER_ROOT_URL": "https://localhost:${RE_PORT_GRAFANA:-3002}",
                            "GF_SERVER_HTTP_ADDR": "127.0.0.1", "GF_SERVER_HTTP_PORT": "3001"},
            "volumes": ["./config/grafana-datasources.lane.yml:/etc/grafana/provisioning/datasources/datasources.yml:ro",
                        *svc("obs-grafana")],
            "healthcheck": {"test": ["CMD", "curl", "-fsS", "--cacert", f"{TLS_DIR}/ca.crt", "-o", "/dev/null",
                                     "https://localhost:3000/api/health"]}},
        "bridge-metrics": {
            "environment": {**TLS_ENV, "LOCALAI_API_URL": "https://localai-api:8000", "QDRANT_URL": "https://qdrant:6333",
                            "OPENCLAW_GATEWAY_URL": "https://host.docker.internal:${RE_PORT_OPENCLAW:-18789}"},
            "volumes": tls_mounts("bridge-metrics")},
    }


def pim_tls_services() -> dict:
    """PIM and its Solid Community Server on the lane, as PIM's
    docker-compose.tls.yml puts them (PIM#86, #729): CSS terminates TLS 1.3
    itself (css-https.json); it does not verify client certificates, so PIM ->
    CSS is TLS without mTLS (the owner-accepted pim-to-css deficiency). PIM
    serves https and reaches the PEs (its scope push) over the lane's mTLS."""
    css = "https://css.localhost:13000"
    ca = [f"./pki/ca/ca.crt:{TLS_DIR}/ca.crt:ro"]
    return {
        "css": {
            "command": ["-c", "/config/css-https.json", "-f", "/data", "-p", "13000", "-b", f"{css}/",
                        "--httpsKey", f"{TLS_DIR}/service/key.pem", "--httpsCert", f"{TLS_DIR}/service/chain.pem"],
            "environment": {"NODE_OPTIONS": "--tls-min-v1.3 --tls-cipher-list=TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
                            "NODE_EXTRA_CA_CERTS": f"{TLS_DIR}/ca.crt"},
            "volumes": ["./config/css-https.json:/config/css-https.json:ro",
                        f"./pki/issued/pim-css:{TLS_DIR}/service:ro", *ca],
            "healthcheck": {"test": ["CMD", "node", "-e",
                                     "require('https').get({host:'127.0.0.1',port:13000,path:'/',servername:'css.localhost',"
                                     "minVersion:'TLSv1.3',ca:require('fs').readFileSync('/run/re-tls/ca.crt')},"
                                     "r=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1))"]}},
        "pim-bootstrap": {
            "environment": {"CSS_BASE_URL": f"{css}/", "NODE_EXTRA_CA_CERTS": f"{TLS_DIR}/ca.crt",
                            "NODE_OPTIONS": "--tls-min-v1.3"},
            "volumes": ca},
        "pim": {
            "environment": {**TLS_ENV, "SOLID_POD_SERVER_URL": css, "SOLID_OIDC_ISSUER": css,
                            "SOLID_POD_BASE_URL": f"{css}/owner/",
                            "SOLID_REDIRECT_URL": "https://localhost:${RE_PORT_PIM:-8090}/callback"},
            "volumes": tls_mounts("pim"),
            "healthcheck": {"test": ["CMD", "node", "-e",
                                     "require('https').get({host:'127.0.0.1',port:8080,path:'/livez',servername:'localhost',"
                                     "minVersion:'TLSv1.3',ca:require('fs').readFileSync('/run/re-tls/ca.crt')},"
                                     "r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]}},
    }


def localai_tls_services() -> dict:
    """localAIStack on the lane, as its docker-compose.tls.yml puts it (#729):
    Qdrant and Redis serve TLS 1.3 with client certificates required, and the
    API serves and calls on the lane. Ollama stays plain http in this release:
    owner decision 2026-11-12, an accepted v0.0.2 deficiency (there is no host
    front for it on a release Mac)."""
    svc_tls = lambda name: [f"./pki/issued/{name}:{TLS_DIR}/service:ro", f"./pki/ca/ca.crt:{TLS_DIR}/ca.crt:ro"]
    return {
        "qdrant": {
            "environment": {"QDRANT__SERVICE__ENABLE_TLS": "true",
                            "QDRANT__SERVICE__VERIFY_HTTPS_CLIENT_CERTIFICATE": "true",
                            "QDRANT__TLS__CERT": f"{TLS_DIR}/service/chain.pem",
                            "QDRANT__TLS__KEY": f"{TLS_DIR}/service/key.pem",
                            "QDRANT__TLS__CA_CERT": f"{TLS_DIR}/ca.crt"},
            "volumes": svc_tls("localai-qdrant")},
        "redis": {
            "command": ["redis-server", "--appendonly", "yes", "--maxmemory", "512mb",
                        "--maxmemory-policy", "allkeys-lru", "--port", "0", "--tls-port", "6379",
                        "--tls-cert-file", f"{TLS_DIR}/service/chain.pem", "--tls-key-file", f"{TLS_DIR}/service/key.pem",
                        "--tls-ca-cert-file", f"{TLS_DIR}/ca.crt", "--tls-auth-clients", "yes",
                        "--tls-protocols", "TLSv1.3",
                        "--tls-ciphersuites", "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256"],
            "volumes": svc_tls("localai-redis"),
            "healthcheck": {"test": ["CMD", "redis-cli", "--tls", "--cacert", f"{TLS_DIR}/ca.crt",
                                     "--cert", f"{TLS_DIR}/service/chain.pem", "--key", f"{TLS_DIR}/service/key.pem",
                                     "-h", "localhost", "ping"]}},
        "localai-api": {
            "environment": {**TLS_ENV, "REDIS_URL": "rediss://redis:6379",
                            "RE_REGISTRY_URL": "https://registry:8000/re-registry.internal.json",
                            "RE_SSL_VERIFY": "true"},
            "volumes": tls_mounts("localai-api")},
    }


def tls_mounts(name: str) -> list[str]:
    """A service's certificate, the CA and the CRL, read-only; never the CA key."""
    return [f"./pki/issued/{name}:{TLS_DIR}/instance:ro",
            f"./pki/ca/ca.crt:{TLS_DIR}/ca.crt:ro", f"./pki/ca/ca.crl:{TLS_DIR}/ca.crl:ro"]


TLS_ENV = {"RE_TLS_CERT": f"{TLS_DIR}/instance/chain.pem", "RE_TLS_KEY": f"{TLS_DIR}/instance/key.pem",
           "RE_TLS_CA": f"{TLS_DIR}/ca.crt", "RE_TLS_CRL": f"{TLS_DIR}/ca.crl"}


def health(port: int, tls: bool) -> list[str]:
    """An engine's health check: with TLS on it presents the instance's own
    certificate (the engines require one), with GNU wget in the images."""
    if not tls:
        return ["CMD", "wget", "-qO-", f"http://127.0.0.1:{port}/api/health"]
    return ["CMD", "wget", "-qO-", f"--ca-certificate={TLS_DIR}/ca.crt",
            f"--certificate={TLS_DIR}/instance/chain.pem", f"--private-key={TLS_DIR}/instance/key.pem",
            f"https://127.0.0.1:{port}/api/health"]


def certificates(install: pathlib.Path, ip: str) -> None:
    """A local CA and a server certificate for localhost, the Mac's LAN address
    and the container names behind TLS. Made once; remade only when missing or
    when it does not cover the current LAN address (the iPhone reaches the PE by
    it)."""
    d = install / "certs"
    crt = d / "server.crt"
    if crt.exists():
        san = subprocess.run(["openssl", "x509", "-in", str(crt), "-noout", "-ext", "subjectAltName"],
                             capture_output=True, text=True).stdout
        if f"IP Address:{ip}" in san:
            return
        log(f"server certificate does not cover {ip}; re-issuing it from the existing CA")
    d.mkdir(parents=True, exist_ok=True)
    ca_key, ca_crt = d / "ca.key", d / "ca.crt"
    if not (ca_key.exists() and ca_crt.exists()):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256", "-days", "3650",
                        "-keyout", str(ca_key), "-out", str(ca_crt),
                        "-subj", "/CN=RealityEngine Local CA/O=RealityEngine"],
                       check=True, capture_output=True)
    names = ["localhost", "visualizer-backend", "visualizer-frontend", "tls-proxy", "loki", "registry"]
    ips = sorted({"127.0.0.1", ip})
    ext = d / "server.ext"
    ext.write_text("subjectAltName=" + ",".join([f"DNS:{n}" for n in names] + [f"IP:{a}" for a in ips])
                   + "\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n")
    key, csr = d / "server.key", d / "server.csr"
    subprocess.run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-sha256", "-keyout", str(key),
                    "-out", str(csr), "-subj", "/CN=localhost/O=RealityEngine"], check=True, capture_output=True)
    subprocess.run(["openssl", "x509", "-req", "-in", str(csr), "-CA", str(ca_crt), "-CAkey", str(ca_key),
                    "-CAcreateserial", "-days", "825", "-sha256", "-extfile", str(ext), "-out", str(crt)],
                   check=True, capture_output=True)
    csr.unlink(missing_ok=True)
    ext.unlink(missing_ok=True)
    for f in (ca_key, key):
        os.chmod(f, 0o644)   # read by the containers' own users; the install dir is the user's
    log("issued the local CA and server certificate")


def secrets_env(install: pathlib.Path) -> dict[str, str]:
    """Generated once and kept: changing them would lock the user out of
    Open WebUI, the OpenClaw gateway and the Solid pod."""
    path = install / "state" / "secrets.json"
    have = json.loads(path.read_text()) if path.exists() else {}
    want = {
        "HEALTHKIT_BRIDGE_TOKEN": lambda: secrets.token_urlsafe(32),
        "OPENCLAW_GATEWAY_TOKEN": lambda: secrets.token_urlsafe(32),
        "WEBUI_SECRET_KEY": lambda: secrets.token_urlsafe(32),
        "WEBUI_ADMIN_EMAIL": lambda: "admin@realityengine.local",
        "WEBUI_ADMIN_PASSWORD": lambda: secrets.token_urlsafe(18),
        "GRAFANA_ADMIN_PASSWORD": lambda: secrets.token_urlsafe(18),
        "CSS_ACCOUNT_EMAIL": lambda: "owner@realityengine.local",
        "CSS_ACCOUNT_PASSWORD": lambda: secrets.token_urlsafe(18),
        # The lifecycle API's service tokens (localAssetStorageStack: 32 bytes or more).
        "ASSETS_ADMIN_TOKEN": lambda: secrets.token_urlsafe(33),
        "ASSETS_REGISTRAR_TOKEN": lambda: secrets.token_urlsafe(33),
        "ASSETS_ENGINE_TOKEN": lambda: secrets.token_urlsafe(33),
    }
    changed = False
    for k, make in want.items():
        if not have.get(k):
            have[k] = make()
            changed = True
    if changed:
        write_json(path, have, 0o600)
    return have


def image_refs(version: str, images_file: pathlib.Path | None, registry: str) -> dict[str, str]:
    """RE_IMAGE_<NAME> per first-party image: by digest when an images file is
    given (a release, A2), else by tag (a local or dev install)."""
    catalog = json.loads((RELEASE / "images.json").read_text())
    pinned = {}
    if images_file and images_file.exists():
        for i in json.loads(images_file.read_text()).get("images", []):
            if i.get("digest"):
                pinned[i["name"]] = f"{i['ref']}@{i['digest']}"
    refs = {}
    for img in catalog["images"]:
        key = "RE_IMAGE_" + img["name"].removeprefix("re-").replace("-", "_").upper()
        refs[key] = pinned.get(img["name"], f"{registry}/{img['name']}:{version}")
    return refs


def deployed_manifest(install: pathlib.Path) -> pathlib.Path:
    """The deployed corpus as a manifest: the shipped regression corpus plus
    every machine loaded since (machines-load). OpenClaw's agents follow it, as
    they follow the deployed corpus on every lane."""
    return install / "state" / "deployed-corpus.txt"


def agent_profile(install: pathlib.Path) -> str:
    m = deployed_manifest(install)
    return f"manifest:{m}" if m.exists() else "regression"


def host_install(install: pathlib.Path) -> dict:
    """The install directory as the Mac sees it, and the user who owns it.

    The native gateway's config names its own paths, which are the Mac's, not
    /install. `configure` is told them (HOST_INSTALL_DIR, HOST_UID, HOST_GID) and
    records them, so `machines-load`, run without them, regenerates the same."""
    path = install / "state" / "host-install.json"
    have = json.loads(path.read_text()) if path.exists() else {}
    for key, var in (("dir", "HOST_INSTALL_DIR"), ("uid", "HOST_UID"), ("gid", "HOST_GID")):
        if os.environ.get(var):
            have[key] = int(os.environ[var]) if key != "dir" else os.environ[var]
    if not have.get("dir"):
        raise SystemExit("HOST_INSTALL_DIR is not set: run re-init through `realityengine`")
    write_json(path, have)
    return have


def configure_openclaw(install: pathlib.Path, sec: dict[str, str], tls: bool = False) -> None:
    """The native gateway's home (RealityEngine_CI#592), made by
    localOpenClawStack's own scripts at the release commit: the hardened config
    (harden-config.sh), the deployed corpus's agents (sync-machine-agents.sh) and
    the check (verify-openclaw-config.sh), in the `entries` format of OpenClaw >=
    2026.10 with the Mac's paths. It is generated here because only re-init can
    resolve the agent profile against the machine catalog, a Docker volume.

    The gateway itself is the Mac's own openclaw, which `realityengine up` starts
    as a LaunchAgent with <install>/ocs/scripts/native-gateway.sh --no-generate;
    this copies those scripts and the sandbox image's Dockerfile there."""
    host = host_install(install)
    ports = {k: int(os.environ.get(f"RE_PORT_{k}", v)) for k, v in HOST_PORTS.items()}
    home = install / "openclaw"
    home.mkdir(parents=True, exist_ok=True)
    host_home = f"{host['dir'].rstrip('/')}/openclaw"
    env_file = OCS / ".env"
    env_file.write_text(f"OPENCLAW_GATEWAY_TOKEN={sec['OPENCLAW_GATEWAY_TOKEN']}\n"
                        "OPENCLAW_DEFAULT_MODEL=ollama/nemotron-3-nano:4b-mlx\n")
    profile = agent_profile(install)
    env = {**os.environ, "OPENCLAW_AGENT_PROFILE": profile, "OPENCLAW_SCHEMA": "entries",
           "OPENCLAW_STATE_DIR": str(home), "OPENCLAW_HOME_DIR": host_home,
           "OPENCLAW_GATEWAY_BIND": "loopback", "OPENCLAW_GATEWAY_PORT": str(ports["OPENCLAW"]),
           "OLLAMA_BASE_URL": "http://127.0.0.1:11434",
           "OPENCLAW_BROWSER_CDP_URL": f"{'https' if tls else 'http'}://127.0.0.1:{ports['BROWSER_CDP']}"}
    if tls:
        # On the lane (#729): harden-config.sh writes gateway.tls from the TLS
        # directory, checked here at re-init's path and rewritten below to the
        # Mac's, where the gateway runs. Ollama stays plain http (owner, 2026-11-12).
        env["OPENCLAW_TLS_DIR"] = str(install / "pki" / "openclaw")
    if profile.startswith("manifest:"):
        # Loaded machines resolve against the catalog the installer synced.
        env["OPENCLAW_CORPUS_MACHINES_ROOT"] = "/volumes/catalog/machines"
    p = subprocess.run(["bash", str(OCS / "scripts" / "agent-profile.sh"), profile],
                       capture_output=True, text=True, env=env)
    if p.returncode != 0 and profile != "regression":
        # A machine synced from a newer RealityEngine_Machines than this release
        # has no agent in the release's agent corpus. Keep the agents of the
        # shipped corpus rather than failing, and say which.
        log("OpenClaw: some loaded machines have no agent in this release's agent corpus; "
            "keeping the regression agents. " + (p.stderr.strip().splitlines() or [""])[-1][:200])
        profile, env["OPENCLAW_AGENT_PROFILE"] = "regression", "regression"
        p = subprocess.run(["bash", str(OCS / "scripts" / "agent-profile.sh"), "regression"],
                           capture_output=True, text=True, env=env)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        raise SystemExit("OpenClaw agent profile failed")
    index = p.stdout.strip()
    env["OPENCLAW_AGENT_INDEX_PATH"] = index
    for script in ("harden-config.sh", "sync-machine-agents.sh", "verify-openclaw-config.sh"):
        p = subprocess.run(["bash", str(OCS / "scripts" / script)], capture_output=True, text=True, env=env,
                           cwd=str(OCS))
        if p.returncode != 0:
            sys.stderr.write(p.stdout + p.stderr)
            raise SystemExit(f"OpenClaw {script} failed")
    env_file.unlink(missing_ok=True)
    if tls:
        cfg_path = home / "openclaw.json"
        cfg = json.loads(cfg_path.read_text())
        mac = f"{host['dir'].rstrip('/')}/pki/openclaw"
        for k in ("certPath", "keyPath", "caPath"):
            if k in cfg.get("gateway", {}).get("tls", {}):
                cfg["gateway"]["tls"][k] = cfg["gateway"]["tls"][k].replace(str(install / "pki" / "openclaw"), mac)
        write_json(cfg_path, cfg)
    total = json.loads(pathlib.Path(index).read_text()).get("total")
    write_json(install / "openclaw-agents.json", {"profile": profile, "agents": total})

    # What the Mac runs: the scripts, the vendored sandbox Dockerfile, and the
    # token, which native-gateway-run.sh reads from this .env at start.
    ocs = install / "ocs"
    for sub in ("scripts", "docker"):
        if (ocs / sub).exists():
            shutil.rmtree(ocs / sub)
        shutil.copytree(OCS / sub, ocs / sub)
    write(ocs / ".env", f"OPENCLAW_GATEWAY_TOKEN={sec['OPENCLAW_GATEWAY_TOKEN']}\n"
                        f"OPENCLAW_GATEWAY_PORT={ports['OPENCLAW']}\n", 0o600)
    # The Mac's user owns all of it: the gateway runs as that user, and its home
    # and the scripts are private to it.
    uid, gid = host.get("uid", 0), host.get("gid", 0)
    for top in (home, ocs):
        for root, dirs, files in os.walk(top):
            for n in dirs + files:
                try:
                    os.lchown(os.path.join(root, n), uid, gid)
                except OSError:
                    pass
        os.chown(top, uid, gid)
        os.chmod(top, 0o700)
    log(f"OpenClaw configured with profile {profile.split('/')[-1]} ({total} machine agents), "
        f"home {host_home}")


def assets_files(install: pathlib.Path, ports: dict[str, int]) -> None:
    """localAssetStorageStack's provisioning scripts, the lifecycle sources they
    import, and CSS's config, into <install>/assets; and the stack's own service
    file, runtime/registry.json, as its scripts/up.js writes it."""
    root = install / "assets"
    for sub in ("scripts", "lifecycle/src", "css"):
        (root / sub).mkdir(parents=True, exist_ok=True)
    for name in ("accounts.js", "grant-assets.js"):
        shutil.copyfile(ASSETS / "scripts" / name, root / "scripts" / name)
    for f in (ASSETS / "lifecycle" / "src").glob("*.js"):
        shutil.copyfile(f, root / "lifecycle" / "src" / f.name)
    shutil.copyfile(ASSETS / "css" / "config.json", root / "css" / "config.json")
    write(root / "package.json", '{"type": "module"}\n')
    write_json(root / "runtime" / "registry.json", {
        "schemaVersion": 2,
        "updatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ca": "/pki/ca.crt",
        "services": {
            "assets-css": {"internalUrl": "https://assets-css.localhost:13443/", "externalUrl": "https://assets-css.localhost:13443/"},
            "assets-dokieli": {"internalUrl": "https://assets-dokieli.localhost:13444/",
                               "externalUrl": "https://assets-dokieli.localhost:13444/"},
            "lifecycle": {"internalUrl": "https://lifecycle:8443/", "externalUrl": f"https://localhost:{ports['LIFECYCLE']}/"},
        }})


def assets_services(ports: dict[str, int]) -> dict:
    """The asset storage stack (localAssetStorageStack's docker-compose.yml) in
    the install (owner, 2026-11-12): assets-css (Solid Community Server, its
    pinned upstream image), assets-dokieli and the lifecycle API (release images
    re-dokieli and re-lifecycle), each on the install's PKI, TLS 1.3 only.
    Accounts are provisioned before `up` by the CLI (accounts.js, as up.js
    does); assets-grant gives the lifecycle service access to each person's
    assets/ container once CSS is up (grant-assets.js)."""
    hardening = {"cap_drop": ["ALL"], "security_opt": ["no-new-privileges:true"], "restart": "unless-stopped"}
    labels = {"org.realityengine.stack": "localassetstoragestack"}
    pki = lambda name: [f"./pki/issued/{name}:/pki/self:ro", "./pki/ca/ca.crt:/pki/ca.crt:ro"]
    css_health = ("require('https').get({host:'127.0.0.1',port:13443,path:'/',servername:'assets-css.localhost',"
                  "minVersion:'TLSv1.3'},r=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1))")
    return {
        "assets-css": {
            **hardening, "labels": labels, "image": ASSETS_CSS_IMAGE,
            "command": ["-c", "/config/config.json", "-f", "/data", "-b", "https://assets-css.localhost:13443/",
                        "-p", "13443", "--httpsKey", "/pki/self/key.pem", "--httpsCert", "/pki/self/chain.pem",
                        "--seedConfig", "/run/secrets/assets-css-seed"],
            "environment": {"NODE_OPTIONS": "--tls-min-v1.3 --tls-cipher-list=TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
                            "NODE_EXTRA_CA_CERTS": "/pki/ca.crt"},
            "volumes": ["assets-css-data:/data", "./assets/css/config.json:/config/config.json:ro", *pki("assets-css")],
            "secrets": ["assets-css-seed"],
            "ports": [f"127.0.0.1:{ASSETS_FIXED_PORTS['assets-css']}:13443"],
            "networks": {"realityengine": {"aliases": ["assets-css.localhost"]}},
            "healthcheck": {"test": ["CMD", "node", "-e", css_health], "interval": "10s", "timeout": "5s",
                            "retries": 12, "start_period": "20s"}},
        "assets-dokieli": {
            **hardening, "labels": labels, "image": "${RE_IMAGE_DOKIELI}", "read_only": True, "tmpfs": ["/tmp"],
            "volumes": pki("assets-dokieli"),
            "ports": [f"127.0.0.1:{ASSETS_FIXED_PORTS['assets-dokieli']}:13444"],
            "networks": {"realityengine": {"aliases": ["assets-dokieli.localhost"]}}},
        "lifecycle": {
            **hardening, "labels": labels, "image": "${RE_IMAGE_LIFECYCLE}", "read_only": True,
            "environment": {
                "ADMIN_TOKEN": "${ASSETS_ADMIN_TOKEN}", "REGISTRAR_TOKEN": "${ASSETS_REGISTRAR_TOKEN}",
                "ENGINE_TOKEN": "${ASSETS_ENGINE_TOKEN}", "CSS_ORIGIN": "https://assets-css.localhost:13443",
                "REGISTRY_FILE": "/registry/registry.json", "ROLES_FILE": "/registry/roles.json",
                # The install's instance registry, for continuation rule 7; the
                # lifecycle presents its certificate to it and to the PEs.
                "RE_REGISTRY_URL": "https://registry:8000/re-registry.internal.json",
                "SERVICE_ACCOUNT_FILE": "/run/secrets/assets-lifecycle-account",
                "TLS_KEY_FILE": "/pki/self/key.pem", "TLS_CERT_FILE": "/pki/self/chain.pem",
                "NODE_EXTRA_CA_CERTS": "/pki/ca.crt"},
            "volumes": ["assets-lifecycle-data:/data", "./assets/runtime:/registry:ro", *pki("lifecycle")],
            "secrets": ["assets-lifecycle-account"],
            "ports": [f"127.0.0.1:{ports['LIFECYCLE']}:8443"],
            "networks": ["realityengine"],
            "depends_on": {"assets-css": {"condition": "service_healthy"}}},
        # One-shot: each person's assets/ container and inbox ACLs, the profile's
        # pim:storage (grant-assets.js; idempotent, so every `up` runs it).
        "assets-grant": {
            "image": "${RE_IMAGE_LIFECYCLE}", "restart": "no", "user": "0:0",
            "working_dir": "/opt/lass",
            "command": ["node", "--dns-result-order=ipv4first", "/opt/lass/scripts/grant-assets.js"],
            "environment": {"NODE_EXTRA_CA_CERTS": "/pki/ca.crt"},
            # .secrets read-write: grant-assets.js keeps each person's client
            # credentials there (lifecycle/src/identity.js provision).
            "volumes": ["./assets:/opt/lass:ro", "./assets/.secrets:/opt/lass/.secrets",
                        "./pki/ca/ca.crt:/pki/ca.crt:ro"],
            "networks": ["realityengine"],
            "depends_on": {"assets-css": {"condition": "service_healthy"}}},
        # Manager's workflow instantiation runs each step against the lifecycle.
        "visualizer-backend": {
            "environment": {"INSTANTIATION_ENABLED": "true", "LIFECYCLE_URL": "https://lifecycle:8443/",
                            "LIFECYCLE_ENGINE_TOKEN_FILE": "/run/assets/engine-token"},
            "volumes": ["./state/lifecycle-engine-token:/run/assets/engine-token:ro"],
            "depends_on": {"lifecycle": {"condition": "service_healthy"}}},
    }


def copy_config(install: pathlib.Path) -> None:
    cfg = install / "config"
    (cfg / "grafana").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(CI / "config" / "loki-config.yml", cfg / "loki.yml")
    shutil.copyfile(CI / "config" / "grafana-datasources.yml", cfg / "grafana" / "datasources.yml")
    shutil.copyfile(CI / "config" / "grafana-dashboards.yml", cfg / "grafana" / "dashboards.yml")
    if (cfg / "dashboards").exists():
        shutil.rmtree(cfg / "dashboards")
    shutil.copytree(CI / "config" / "dashboards", cfg / "dashboards")
    # css-https.json: OpenCommons-Health PIM's config/css-https.json, vendored
    # (the init image does not carry PIM); CSS on the TLS switch reads it (#729).
    for name in ("prometheus.yml", "promtail.yml", "nginx.conf", "css-https.json"):
        shutil.copyfile(RELEASE / "config" / name, cfg / name)
    # Run by the bridge-metrics service: the same exporter as the native lane's.
    shutil.copyfile(CI / "scripts" / "bridge-metrics-exporter.mjs", cfg / "bridge-metrics-exporter.mjs")
    shutil.copyfile(CI / "mcp" / "src" / "lane-tls.js", cfg / "lane-tls.js")


# ── commands ─────────────────────────────────────────────────────────────────

def cmd_configure(args) -> int:
    install = pathlib.Path(args.install)
    install.mkdir(parents=True, exist_ok=True)
    spec = parse_spec(args.engines)
    insts = instances(spec)
    ip = host_ip()
    ports = {k: int(os.environ.get(f"RE_PORT_{k}", v)) for k, v in HOST_PORTS.items()}

    allocate_uuids(install, insts)
    tls = args.tls == "on"
    pki(install, insts, ip)
    log("instances: " + ", ".join(f"{i['id']} (PE {i['pe_port']}, RE {i['re_port']})" for i in insts))

    shutil.copyfile(RELEASE / "compose.yml", install / "compose.yml")
    write(install / "compose.engines.yml",
          "# Generated by re-init from the engine spec " + args.engines + ". Do not edit:\n"
          "# `realityengine up --engines=...` regenerates it.\n"
          + yaml_dump({"services": engine_services(insts, tls)}) + "\n")
    compose_files = ["compose.yml", "compose.engines.yml", "compose.assets.yml"]
    assets_files(install, ports)
    write(install / "compose.assets.yml",
          "# Generated by re-init: the asset storage stack (localAssetStorageStack). Do not edit.\n"
          + yaml_dump({"services": assets_services(ports),
                       "secrets": {"assets-css-seed": {"file": "./assets/.secrets/css-seed.json"},
                                   "assets-lifecycle-account": {"file": "./assets/.secrets/lifecycle-account.json"}},
                       "volumes": {"assets-css-data": {}, "assets-lifecycle-data": {}}}) + "\n")
    tls_overlay = install / "compose.tls.yml"
    if tls:
        # The services this release has on the lane so far (#729): the instance
        # registry, Manager's visualizer backend and tls-proxy here; the engines
        # carry theirs in compose.engines.yml.
        (install / "config").mkdir(parents=True, exist_ok=True)   # a fresh install has none yet
        subprocess.run([sys.executable, str(CI / "scripts" / "lib" / "tls_proxy_lane_conf.py"),
                        str(RELEASE / "config" / "nginx.conf"), str(install / "config" / "nginx.lane.conf")],
                       check=True, capture_output=True)
        write(tls_overlay, "# Generated by re-init (RE_TLS=on, RealityEngine_CI#729). Do not edit.\n"
              + yaml_dump({"services": {
                  "registry": {
                      "environment": {**TLS_ENV, "RE_TLS_SERVER_CONF_DIR": "/tmp"},
                      "volumes": tls_mounts("registry") + ["./pki/issued/harness:/run/re-tls/harness:ro"],
                      # The registry requires a client certificate; it presents the harness's.
                      "healthcheck": {"test": ["CMD", "python3", "-c", REGISTRY_TLS_HEALTH]}},
                  # The lane certificate wins over certs/ (Manager's laneTls); it reads
                  # the instance registry and reaches the engines with it.
                  "visualizer-backend": {
                      "environment": {**TLS_ENV, "RE_REGISTRY_URL": "https://registry:8000/re-registry.internal.json"},
                      "volumes": tls_mounts("manager")},
                  "tls-proxy": {
                      "volumes": ["./config/nginx.lane.conf:/etc/nginx/nginx.conf:ro",
                                  "./pki/issued/manager:/etc/nginx/lane/instance:ro",
                                  "./pki/ca/ca.crt:/etc/nginx/lane/ca.crt:ro"]},
                  **localai_tls_services(),
                  **pim_tls_services(),
                  # The gateway's browser sidecar: CDP behind nginx with TLS 1.3 and
                  # mTLS (localOpenClawStack's docker-compose.tls.yml); the nginx ->
                  # Chromium hop inside it is the accepted browser-cdp-proxy deficiency.
                  "browser": {
                      "volumes": ["./ocs/docker/browser/cdp-proxy-tls.conf:/etc/nginx/cdp-proxy.conf:ro",
                                  f"./pki/issued/openclaw-browser:{TLS_DIR}/browser:ro",
                                  f"./pki/ca/ca.crt:{TLS_DIR}/ca.crt:ro", f"./pki/ca/ca.crl:{TLS_DIR}/ca.crl:ro"]},
                  # Open WebUI itself stays plain http (owner, 2026-11-12); the
                  # gateway it calls serves only https on the lane, so it trusts the CA.
                  "open-webui": {
                      "environment": {"OPENAI_API_BASE_URL": "https://host.docker.internal:${RE_PORT_OPENCLAW:-18789}/v1",
                                      "SSL_CERT_FILE": f"{TLS_DIR}/ca.crt", "REQUESTS_CA_BUNDLE": f"{TLS_DIR}/ca.crt"},
                      "volumes": [f"./pki/ca/ca.crt:{TLS_DIR}/ca.crt:ro"]},
                  **observability_tls_services(install),
                  "mcp": {
                      "environment": {**TLS_ENV, "RE_REGISTRY_URL": "https://registry:8000/re-registry.internal.json"},
                      "volumes": tls_mounts("re-mcp"),
                      # The image's own check is plain http; on the lane re-mcp requires
                      # a client certificate, so Node presents re-mcp's.
                      "healthcheck": {"test": ["CMD", "node", "-e", node_tls_health(7331, "/healthz")]}},
              }}) + "\n")
        compose_files.append("compose.tls.yml")
    elif tls_overlay.exists():
        tls_overlay.unlink()

    host_reg, internal_reg = registries(insts, ip, ports, tls)
    write_json(install / "registry" / "re-registry.json", host_reg)
    write_json(install / "registry" / "re-registry.internal.json", internal_reg)

    copy_config(install)
    re_t, pe_t = file_sd(insts)
    write_json(install / "config" / "file_sd" / "reality-engine-targets.json", re_t)
    write_json(install / "config" / "file_sd" / "perception-engine-targets.json", pe_t)
    write_json(install / "config" / "integrations.json", {
        **integrations(tls),
        "assetStorage": {"lifecycleUrl": "https://lifecycle:8443/", "cssUrl": "https://assets-css.localhost:13443/",
                         "dokieliUrl": "https://assets-dokieli.localhost:13444/"}})
    certificates(install, ip)

    sec = secrets_env(install)
    # Manager's copy of the lifecycle's engine token, mounted read-only.
    write(install / "state" / "lifecycle-engine-token", sec["ASSETS_ENGINE_TOKEN"], 0o600)
    if not args.skip_openclaw:
        configure_openclaw(install, sec, tls)

    images_file = pathlib.Path(args.images) if args.images else None
    refs = image_refs(args.version, images_file, args.registry)
    pe_urls = ",".join(f"{'https' if tls else 'http'}://{i['pe_service']}:{PE_PORT}" for i in insts)
    env_lines = [
        "# Generated by re-init. Do not edit: `realityengine up` regenerates it.",
        f"COMPOSE_PROJECT_NAME={args.project}",
        "COMPOSE_FILE=" + ":".join(compose_files),
        f"RE_TLS={'on' if tls else 'off'}",
        f"RE_VERSION={args.version}",
        f"RE_ENGINES={args.engines}",
        f"HOST_IP={ip}",
        f"HEALTHKIT_PE_SCOPE_URLS={pe_urls}",
        *[f"RE_PORT_{k}={v}" for k, v in ports.items()],
        *[f"{k}={v}" for k, v in sorted(refs.items())],
        *[f"{k}={v}" for k, v in sorted(sec.items())],
    ]
    write(install / ".env", "\n".join(env_lines) + "\n", 0o600)

    # What the host's Ollama / OpenClaw / Node were when this install was
    # configured, as the CLI's preflight recorded it (#592). Absent when the
    # preflight did not run (an older CLI, or re-init driven directly).
    host_services = None
    hs = install / "state" / "host-services.json"
    if hs.is_file():
        try:
            host_services = json.loads(hs.read_text(encoding="utf-8"))
        except ValueError:
            host_services = {"error": "state/host-services.json is not valid JSON"}

    write_json(install / "release.json", {
        "host_services": host_services,
        "version": args.version, "engines": args.engines, "lane": LANE,
        "tls": {"enabled": tls, "profile": json.loads((CI / "config" / "transport-profile.json").read_text())["profileId"]},
        "instances": [{k: i[k] for k in ("id", "runtime", "instance_uuid", "re_port", "pe_port")} for i in insts],
        "images": refs, "images_file": str(images_file) if images_file else None,
        "configured_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    log(f"configured {len(insts)} instance(s) in {install}")
    return 0


def cmd_serve_registry(args) -> int:
    root = pathlib.Path(args.dir)
    if os.environ.get("RE_TLS_CERT"):
        # On the lane (#729): TLS 1.3 with mTLS at the transport profile, the
        # suite's own listener (scripts/lib/re_tls_server.py), not a second copy.
        cmd = [sys.executable, str(CI / "scripts" / "lib" / "re_tls_server.py"), "serve-static", str(root),
               str(args.port), "--cert", os.environ["RE_TLS_CERT"], "--key", os.environ["RE_TLS_KEY"],
               "--ca", os.environ["RE_TLS_CA"]]
        if os.environ.get("RE_TLS_CRL"):
            cmd += ["--crl", os.environ["RE_TLS_CRL"]]
        log(f"serving the instance registry from {root} on :{args.port} (TLS 1.3, mTLS)")
        os.execv(sys.executable, cmd)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(root), **kw)

        def log_message(self, format, *args):  # noqa: A002 (the base class's name)
            pass

        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

    log(f"serving the instance registry from {root} on :{args.port}")
    http.server.ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
    return 0


def cmd_prepare_volumes(args) -> int:
    clock = pathlib.Path(args.clock)
    clock.mkdir(parents=True, exist_ok=True)
    # Each engine runs as its image's own user; the clock must be writable by
    # all of them or the engine (correctly) refuses to boot. As instance_uuids.py
    # docker_env does for the Docker lane.
    os.chmod(clock, 0o1777)
    log(f"clock volume ready at {clock}")
    return 0


# ── dynamic machine loading (A8, C6) ─────────────────────────────────────────

MACHINES_REPO = "jateeter/RealityEngine_Machines"


def internal_registry_url() -> str:
    """The instance registry as the compose network reaches it."""
    return f"{'https' if install_tls() else 'http'}://registry:8000/re-registry.internal.json"


def install_tls() -> bool:
    """Whether the install at /install has its TLS switch on (.env RE_TLS=on)."""
    env = pathlib.Path("/install/.env")
    return env.is_file() and "\nRE_TLS=on\n" in "\n" + env.read_text() + "\n"


def http_json(url: str, data=None, timeout: int = 120, method: str | None = None):
    import ssl
    import urllib.request
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method or ("POST" if body is not None else "GET"),
                                 headers={"Content-Type": "application/json", "User-Agent": "re-init"})
    ctx = ssl.create_default_context()
    if install_tls():
        # The install's TLS switch (#729): the install CA, and the CLI's harness
        # certificate for the services that require one (the engines, the registry).
        ctx.load_verify_locations("/install/pki/ca/ca.crt")
        ctx.load_cert_chain("/install/pki/issued/harness/cert.pem", "/install/pki/issued/harness/key.pem")
    else:
        ca = pathlib.Path("/install/certs/ca.crt")
        if ca.exists():
            ctx.load_verify_locations(str(ca))
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def cmd_machines_sync(args) -> int:
    """Replace the catalog with RealityEngine_Machines at a ref. Validated in a
    scratch directory first: every machine file parses as JSON and every
    filename is unique across the corpus (the corpus addressing contract), so a
    broken ref never replaces a working catalog."""
    import io
    import tarfile
    import tempfile
    import urllib.request

    import urllib.error

    catalog = pathlib.Path(args.catalog)
    try:
        commit = http_json(f"https://api.github.com/repos/{MACHINES_REPO}/commits/{args.ref}")["sha"]
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{MACHINES_REPO} has no ref {args.ref!r} (GitHub answered {e.code}); "
                         "the catalog is unchanged") from None
    except urllib.error.URLError as e:
        raise SystemExit(f"cannot reach GitHub ({e.reason}); the catalog is unchanged") from None
    log(f"RealityEngine_Machines {args.ref} is {commit[:12]}; downloading")
    req = urllib.request.Request(f"https://codeload.github.com/{MACHINES_REPO}/tar.gz/{commit}",
                                 headers={"User-Agent": "re-init"})
    with urllib.request.urlopen(req, timeout=300) as r:
        blob = r.read()
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            for m in tar.getmembers():
                parts = m.name.split("/", 1)
                if len(parts) < 2:
                    continue
                rel = parts[1]
                if not (rel.startswith("machines/") or rel == "semantics/abox-manifest.json"):
                    continue
                if not (m.isfile() or m.isdir()) or ".." in rel.split("/"):
                    continue
                m.name = rel
                tar.extract(m, root, filter="data")
        files = sorted((root / "machines").rglob("*.json"))
        if not files:
            raise SystemExit(f"{args.ref}: no machines found; the catalog is unchanged")
        names: dict[str, str] = {}
        bad = []
        for f in files:
            try:
                json.loads(f.read_text())
            except ValueError as e:
                bad.append(f"{f.relative_to(root)}: {e}")
            if f.name in names:
                bad.append(f"{f.relative_to(root)}: filename also used by {names[f.name]}")
            names[f.name] = str(f.relative_to(root))
        if bad:
            raise SystemExit(f"{args.ref}: {len(bad)} invalid machine file(s); the catalog is unchanged:\n  "
                             + "\n  ".join(bad[:20]))
        catalog.mkdir(parents=True, exist_ok=True)
        for child in catalog.iterdir():
            shutil.rmtree(child) if child.is_dir() else child.unlink()
        shutil.copytree(root / "machines", catalog / "machines")
        if (root / "semantics").exists():
            shutil.copytree(root / "semantics", catalog / "semantics")
    write_json(catalog / ".source.json", {"repo": MACHINES_REPO, "ref": args.ref, "commit": commit,
                                         "machines": len(files),
                                         "synced_at": datetime.datetime.now(datetime.timezone.utc)
                                         .strftime("%Y-%m-%dT%H:%M:%SZ")})
    log(f"catalog now RealityEngine_Machines {commit[:12]}: {len(files)} machine file(s)")
    return 0


def loaded_path() -> pathlib.Path:
    return pathlib.Path("/install/state/loaded-machines.json")


def cmd_machines_load(args) -> int:
    """Load through Manager's POST /api/corpus/load, the Load Machines modal's
    own path, with allEngines, so every instance receives the same machines and
    the engines stay in parity. Then each PE re-derives its sources from its RE."""
    state = json.loads(loaded_path().read_text()) if loaded_path().exists() else {"domains": [], "machineIds": []}
    if args.replay:
        domains, ids = state["domains"], state["machineIds"]
        if not domains and not ids:
            log("nothing loaded beyond the shipped corpus")
            return 0
    else:
        domains = [d if d.startswith(("domains/", "corpus/")) else f"domains/{d}" for d in args.domain]
        ids = list(args.machine)
        if args.all:
            domains = ["domains"]
        if not domains and not ids:
            raise SystemExit("name machines (--machine), domains (--domain) or --all")
    res = http_json(f"{args.manager}/api/corpus/load",
                    {"domains": domains, "machineIds": ids, "allEngines": True}, timeout=1800)
    for e in res.get("engines", []):
        log(f"{e['engine']}: loaded {e['loaded']}, already present {e['skipped']}, failed {e['failed']}")
    failed = sum(e["failed"] for e in res.get("engines", []))
    reg = http_json(getattr(args, "registry", None) or internal_registry_url())
    for inst in reg.get("instances", []):
        try:
            http_json(f"{inst['pe_url']}/api/sources/bootstrap-from-machines", {}, timeout=120)
            log(f"{inst['id']}: PE sources refreshed")
        except Exception as e:  # noqa: BLE001 - reported, and counted as a failure
            log(f"{inst['id']}: PE source refresh failed: {e}")
            failed += 1
    if not args.replay:
        state["domains"] = sorted(set(state["domains"]) | set(domains))
        state["machineIds"] = sorted(set(state["machineIds"]) | set(ids))
        # Catalog paths of what was loaded, for OpenClaw's agents. Entries from
        # the extra roots (corpus/<category>, localAI's own) carry no agent.
        loaded_files = {r["relFile"] for r in res.get("results", [])
                        if r.get("relFile") and r.get("status") in ("loaded", "skipped")}
        state["files"] = sorted(set(state.get("files", [])) | loaded_files)
        write_json(loaded_path(), state)
        boot = [ln.strip() for ln in (CI / "config" / "regression-corpus.txt").read_text().splitlines()
                if ln.strip() and not ln.lstrip().startswith("#")]
        write(deployed_manifest(pathlib.Path("/install")),
              "# Generated by re-init machines-load: the shipped regression corpus plus every\n"
              "# machine loaded since. OpenClaw's agents follow it.\n"
              + "\n".join(dict.fromkeys(boot + [f for f in state["files"] if not f.startswith("corpus/")])) + "\n")
        sec = secrets_env(pathlib.Path("/install"))
        configure_openclaw(pathlib.Path("/install"), sec)
        log("OpenClaw's agents now follow the deployed corpus; the gateway restarts to load them")
    return 1 if failed else 0


def cmd_machines_list(args) -> int:
    tree = http_json(f"{args.manager}/api/corpus/tree")
    src = pathlib.Path(args.catalog) / ".source.json"
    origin = json.loads(src.read_text()) if src.exists() else {"commit": "the release corpus"}
    print(f"catalog: {tree['totalMachines']} machine(s), from {origin.get('commit', '')[:12] or origin}")
    print(f"active engine holds {tree.get('engineMachineCount')}")
    for node in tree.get("tree", []):
        for child in node.get("children", []):
            print(f"  {child['key']:42} {child['count']:5}")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="reinit", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("configure")
    c.add_argument("--install", default="/install")
    c.add_argument("--engines", default="cpp:1,lsp:1,scala:1")
    c.add_argument("--version", required=True)
    c.add_argument("--images", default=None, help="images file with digests (a release)")
    c.add_argument("--registry", default="ghcr.io/jateeter")
    c.add_argument("--project", default="realityengine")
    c.add_argument("--skip-openclaw", action="store_true")
    c.add_argument("--tls", choices=("on", "off"), default=os.environ.get("RE_TLS", "on"),
                   help="every service on TLS 1.3, with mTLS between services (#729, #668); on by "
                        "default. Ollama and Open WebUI stay plain http (owner, 2026-11-12)")
    s = sub.add_parser("serve-registry")
    s.add_argument("--dir", default="/install/registry")
    s.add_argument("--port", type=int, default=8000)
    p = sub.add_parser("prepare-volumes")
    p.add_argument("--clock", default=CLOCK_DIR)
    ms = sub.add_parser("machines-sync")
    ms.add_argument("--ref", default="main")
    ms.add_argument("--catalog", default="/volumes/catalog")
    ml = sub.add_parser("machines-load")
    ml.add_argument("--domain", action="append", default=[])
    ml.add_argument("--machine", action="append", default=[])
    ml.add_argument("--all", action="store_true")
    ml.add_argument("--replay", action="store_true", help="reload what was loaded before")
    ml.add_argument("--manager", default="https://visualizer-backend:3001")
    ml.add_argument("--registry", default=None, help="default: the internal instance registry, https with TLS on")
    mls = sub.add_parser("machines-list")
    mls.add_argument("--manager", default="https://visualizer-backend:3001")
    mls.add_argument("--catalog", default="/volumes/catalog")
    args = ap.parse_args(argv)
    return {"configure": cmd_configure, "serve-registry": cmd_serve_registry,
            "prepare-volumes": cmd_prepare_volumes, "machines-sync": cmd_machines_sync,
            "machines-load": cmd_machines_load, "machines-list": cmd_machines_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
