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
OCS = OPT / "ocs"                  # localOpenClawStack at the release commit

RUNTIMES = ("scala", "cpp", "lsp")
# Host port bands, PE then RE, a stride of 10 per instance: up to 20 instances of
# a type without overlap, and nothing near what macOS holds (5000, 7000).
BAND = {"scala": 6100, "cpp": 6300, "lsp": 6600}
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
}

SPEC_RE = re.compile(r"^(scala|cpp|lsp):([0-9]+)$")


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
            raise SystemExit(f"bad engine spec {part!r}: expected <scala|cpp|lsp>:<count>")
        rt, n = m.group(1), int(m.group(2))
        if rt in counts:
            raise SystemExit(f"{rt} is listed twice in {spec!r}")
        if not 0 <= n <= MAX_PER_RUNTIME:
            raise SystemExit(f"{rt}:{n}: between 0 and {MAX_PER_RUNTIME} instances per engine type")
        counts[rt] = n
    if not any(counts.values()):
        raise SystemExit("the engine spec starts no instance")
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
        write(install / "engines" / f"{inst['id']}.env",
              f"INSTANCE_UUID={inst['instance_uuid']}\nINSTANCE_CLOCK_DIR={CLOCK_DIR}\n")
    held: dict[str, list[str]] = {}
    for inst in insts:
        held.setdefault(inst["instance_uuid"], []).append(inst["id"])
    clash = {u: ids for u, ids in held.items() if len(ids) > 1}
    if clash:
        raise SystemExit(f"two instances share a UUID, which is never allowed: {clash}")


# ── the engine services ──────────────────────────────────────────────────────

def engine_services(insts: list[dict]) -> dict:
    services: dict[str, dict] = {}
    for inst in insts:
        rt, iid = inst["runtime"], inst["id"]
        re_svc, pe_svc = inst["re_service"], inst["pe_service"]
        re_url = f"http://{re_svc}:{RE_PORT}"
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
            "QDRANT_URL": "http://qdrant:6333",
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
            "healthcheck": {"test": ["CMD", "wget", "-qO-", f"http://127.0.0.1:{RE_PORT}/api/health"],
                            "interval": "10s", "timeout": "5s", "retries": 18, "start_period": "30s"},
        }
        pe_env = {
            **corpus_env,
            "LOCAL_AI_API_URL": "http://localai-api:8000",
            "LOCAL_AI_MACHINES_DIR": "/app/localai-machines",
            "INTEGRATIONS_CONFIG": "/app/config/integrations.json",
            "ACP_ENABLED": "true", "ACP_PLATFORM": "OpenClaw", "ACP_SURFACE": "xACP",
            "ACP_GATEWAY_URL": "ws://openclaw-gateway:18789",
            "OPENCLAW_GATEWAY_URL": "ws://openclaw-gateway:18789",
            "ACP_SESSION_KEY": "agent:main:main", "OPENCLAW_ACP_SESSION": "agent:main:main",
            "ACP_TARGET_AGENT": "openclaw",
            "ACP_COMPLETION_SOURCE_MAPPING_ID": "acp-openclaw-completion",
            "OPENCLAW_GATEWAY_TOKEN": "${OPENCLAW_GATEWAY_TOKEN}",
            "HEALTHKIT_BRIDGE_TOKEN": "${HEALTHKIT_BRIDGE_TOKEN}",
            "TRIGGERS_ENABLED": "true", "TRIGGER_DISPATCH_MODE": "dry-run",
            # Ollama runs natively, for the Apple GPU (A6); every PE runtime
            # defaults to localhost, which inside a container is the container.
            "OLLAMA_BASE_URL": "http://host.docker.internal:11434",
            "OLLAMA_MODEL": "${OLLAMA_MODEL:-nemotron-3-nano:4b}",
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
            "healthcheck": {"test": ["CMD", "wget", "-qO-", f"http://127.0.0.1:{PE_PORT}/api/health"],
                            "interval": "10s", "timeout": "5s", "retries": 18, "start_period": "30s"},
        }
        if rt == "cpp":
            re_svc_def["command"] = ["/app/bin/reality_engine_server", str(RE_PORT),
                                     "/app/corpus/machines", "${VECTOR_DIMENSION:-7680}"]
            pe_svc_def["command"] = ["/app/bin/perception_engine_server", str(PE_PORT), re_url,
                                     "http://localai-api:8000", "/app/localai-machines",
                                     "${VECTOR_DIMENSION:-7680}"]
        elif rt == "lsp":
            re_svc_def["command"] = ["reality"]
            re_svc_def["environment"]["REALITY_ENGINE_PORT"] = str(RE_PORT)
            pe_svc_def["command"] = ["perception"]
            pe_env["PERCEPTION_ENGINE_PORT"] = str(PE_PORT)
            pe_env["REALITY_ENGINE_URL"] = re_url
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

def registries(insts: list[dict], ip: str, ports: dict[str, int]) -> tuple[dict, dict]:
    started = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def entry(inst: dict, re_url: str, pe_url: str, re_port: int, pe_port: int) -> dict:
        # The shape of scripts/registry.sh registry_add, so every reader of the
        # native instance registry reads this one unchanged.
        return {"id": inst["id"], "runtime": inst["runtime"], "re_url": re_url, "pe_url": pe_url,
                "re_port": re_port, "pe_port": pe_port, "pid_re": None, "pid_pe": None,
                "instance_uuid": inst["instance_uuid"], "started_at": started, "status": "running"}

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
        entry(i, f"http://localhost:{i['re_port']}", f"http://localhost:{i['pe_port']}", i["re_port"], i["pe_port"])
        for i in insts], "services": {
        "manager_backend": svc(f"https://localhost:{ports['MANAGER_API']}"),
        "manager_frontend": svc(f"https://localhost:{ports['MANAGER_UI']}"),
        "localai_api": svc(f"http://localhost:{ports['LOCALAI']}"),
        "qdrant": svc(f"http://localhost:{ports['QDRANT']}"),
        "openclaw_gateway": svc(f"http://localhost:{ports['OPENCLAW']}"),
        "mcp": svc(f"http://localhost:{ports['MCP']}"),
        "registry": svc(f"http://localhost:{ports['REGISTRY']}"),
    }}
    internal = {"host": ip, "lane": LANE, "instances": [
        entry(i, f"http://{i['re_service']}:{RE_PORT}", f"http://{i['pe_service']}:{PE_PORT}", RE_PORT, PE_PORT)
        for i in insts], "services": {
        "manager_backend": svc("https://visualizer-backend:3001"),
        "localai_api": svc("http://localai-api:8000"),
        "qdrant": svc("http://qdrant:6333"),
        "openclaw_gateway": svc("http://openclaw-gateway:18789"),
        "mcp": svc("http://mcp:7331"),
        "registry": svc("http://registry:8000"),
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


def integrations() -> dict:
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
                         "gatewayUrl": "ws://openclaw-gateway:18789", "sessionKey": "agent:main:main",
                         "targetAgent": "openclaw", "completionSourceMappingId": "acp-openclaw-completion"})
        if item.get("kind") == "mqtt":
            item["enabled"] = False      # no MQTT-parity claim in this release (A11)
    return data


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


def configure_openclaw(install: pathlib.Path, sec: dict[str, str]) -> None:
    """The gateway home, made by localOpenClawStack's own scripts at the release
    commit: the hardened config (harden-config.sh), the regression corpus's
    agents (sync-machine-agents.sh, profile `regression`), and the check
    (verify-openclaw-config.sh). The scripts work on <repo>/openclaw, so that is
    pointed at the install's openclaw/ for the run."""
    home = install / "openclaw"
    home.mkdir(parents=True, exist_ok=True)
    link = OCS / "openclaw"
    if link.is_symlink() or link.exists():
        if link.is_symlink() or link.is_file():
            link.unlink()
        else:
            shutil.rmtree(link)
    link.symlink_to(home)
    env_file = OCS / ".env"
    env_file.write_text(
        f"OPENCLAW_GATEWAY_TOKEN={sec['OPENCLAW_GATEWAY_TOKEN']}\n"
        "OPENCLAW_GATEWAY_PORT=18789\n"
        "OLLAMA_BASE_URL=http://host.docker.internal:11434\n"
        "OPENCLAW_DEFAULT_MODEL=ollama/nemotron-3-nano:4b\n"
        "LOCAL_OWNER=1000\nLOCAL_GROUP=1000\n")
    profile = agent_profile(install)
    env = {**os.environ, "OPENCLAW_AGENT_PROFILE": profile}
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
    total = json.loads(pathlib.Path(index).read_text()).get("total")
    write_json(install / "openclaw-agents.json", {"profile": profile, "agents": total})
    env_file.unlink(missing_ok=True)
    # The gateway runs as the node user (1000); it must own its home.
    for root, dirs, files in os.walk(home):
        for n in dirs + files:
            try:
                os.lchown(os.path.join(root, n), 1000, 1000)
            except OSError:
                pass
    os.chown(home, 1000, 1000)
    os.chmod(home, 0o700)
    log(f"OpenClaw configured with profile {profile.split('/')[-1]} ({total} machine agents)")


def copy_config(install: pathlib.Path) -> None:
    cfg = install / "config"
    (cfg / "grafana").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(CI / "config" / "loki-config.yml", cfg / "loki.yml")
    shutil.copyfile(CI / "config" / "grafana-datasources.yml", cfg / "grafana" / "datasources.yml")
    shutil.copyfile(CI / "config" / "grafana-dashboards.yml", cfg / "grafana" / "dashboards.yml")
    if (cfg / "dashboards").exists():
        shutil.rmtree(cfg / "dashboards")
    shutil.copytree(CI / "config" / "dashboards", cfg / "dashboards")
    for name in ("prometheus.yml", "promtail.yml", "nginx.conf"):
        shutil.copyfile(RELEASE / "config" / name, cfg / name)


# ── commands ─────────────────────────────────────────────────────────────────

def cmd_configure(args) -> int:
    install = pathlib.Path(args.install)
    install.mkdir(parents=True, exist_ok=True)
    spec = parse_spec(args.engines)
    insts = instances(spec)
    ip = host_ip()
    ports = {k: int(os.environ.get(f"RE_PORT_{k}", v)) for k, v in HOST_PORTS.items()}

    allocate_uuids(install, insts)
    log("instances: " + ", ".join(f"{i['id']} (PE {i['pe_port']}, RE {i['re_port']})" for i in insts))

    shutil.copyfile(RELEASE / "compose.yml", install / "compose.yml")
    write(install / "compose.engines.yml",
          "# Generated by re-init from the engine spec " + args.engines + ". Do not edit:\n"
          "# `realityengine up --engines=...` regenerates it.\n"
          + yaml_dump({"services": engine_services(insts)}) + "\n")

    host_reg, internal_reg = registries(insts, ip, ports)
    write_json(install / "registry" / "re-registry.json", host_reg)
    write_json(install / "registry" / "re-registry.internal.json", internal_reg)

    copy_config(install)
    re_t, pe_t = file_sd(insts)
    write_json(install / "config" / "file_sd" / "reality-engine-targets.json", re_t)
    write_json(install / "config" / "file_sd" / "perception-engine-targets.json", pe_t)
    write_json(install / "config" / "integrations.json", integrations())
    certificates(install, ip)

    sec = secrets_env(install)
    if not args.skip_openclaw:
        configure_openclaw(install, sec)

    images_file = pathlib.Path(args.images) if args.images else None
    refs = image_refs(args.version, images_file, args.registry)
    pe_urls = ",".join(f"http://{i['pe_service']}:{PE_PORT}" for i in insts)
    env_lines = [
        "# Generated by re-init. Do not edit: `realityengine up` regenerates it.",
        f"COMPOSE_PROJECT_NAME={args.project}",
        "COMPOSE_FILE=compose.yml:compose.engines.yml",
        f"RE_VERSION={args.version}",
        f"RE_ENGINES={args.engines}",
        f"HOST_IP={ip}",
        f"HEALTHKIT_PE_SCOPE_URLS={pe_urls}",
        *[f"RE_PORT_{k}={v}" for k, v in ports.items()],
        *[f"{k}={v}" for k, v in sorted(refs.items())],
        *[f"{k}={v}" for k, v in sorted(sec.items())],
    ]
    write(install / ".env", "\n".join(env_lines) + "\n", 0o600)

    write_json(install / "release.json", {
        "version": args.version, "engines": args.engines, "lane": LANE,
        "instances": [{k: i[k] for k in ("id", "runtime", "instance_uuid", "re_port", "pe_port")} for i in insts],
        "images": refs, "images_file": str(images_file) if images_file else None,
        "configured_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    log(f"configured {len(insts)} instance(s) in {install}")
    return 0


def cmd_serve_registry(args) -> int:
    root = pathlib.Path(args.dir)

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


def http_json(url: str, data=None, timeout: int = 120, method: str | None = None):
    import ssl
    import urllib.request
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method or ("POST" if body is not None else "GET"),
                                 headers={"Content-Type": "application/json", "User-Agent": "re-init"})
    ctx = ssl.create_default_context()
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
    reg = http_json(args.registry)
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
    ml.add_argument("--registry", default="http://registry:8000/re-registry.internal.json")
    mls = sub.add_parser("machines-list")
    mls.add_argument("--manager", default="https://visualizer-backend:3001")
    mls.add_argument("--catalog", default="/volumes/catalog")
    args = ap.parse_args(argv)
    return {"configure": cmd_configure, "serve-registry": cmd_serve_registry,
            "prepare-volumes": cmd_prepare_volumes, "machines-sync": cmd_machines_sync,
            "machines-load": cmd_machines_load, "machines-list": cmd_machines_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
