#!/usr/bin/env python3
"""The release lane's probe endpoints, from a release install (RealityEngine_CI#729).

transport-probe.py resolves the engines from the install's instance registry.
The rest of a release install's listeners are named here, from the install's
own .env (its RE_PORT_* host ports, its compose project and its images):

- host.json: listeners published on the Mac's loopback, probed from the host;
- network.json: listeners only on the install's compose network (Redis, Loki,
  Prometheus as Grafana reaches it), probed from a container on that network.

It prints the compose network and the image to probe from (the install's
localai-api image, which carries OpenSSL 3.5+), one per line.

Usage: release_probe_endpoints.py <install-dir> <out-dir>
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip().strip("'\"")
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    install, out = Path(sys.argv[1]), Path(sys.argv[2])
    env = env_file(install / ".env")
    if env.get("RE_TLS", "off") != "on":
        print(f"release_probe_endpoints: {install} runs RE_TLS={env.get('RE_TLS', 'off')}; nothing to probe",
              file=sys.stderr)
        return 1

    def host(port_key: str, default: str, path: str) -> list[dict[str, str]]:
        return [{"url": f"https://127.0.0.1:{env.get(port_key, default)}", "path": path}]

    host_eps = {
        "prometheus-scrape": host("RE_PORT_PROMETHEUS", "9090", "/-/ready"),
        "browser-to-grafana-native": host("RE_PORT_GRAFANA", "3002", "/api/health"),
        "mcp": host("RE_PORT_MCP", "7331", "/"),
        "engines-to-localai": host("RE_PORT_LOCALAI", "4000", "/health"),
        "pe-trigger-dispatch": host("RE_PORT_LOCALAI", "4000", "/health"),
        "pe-to-openclaw": host("RE_PORT_OPENCLAW", "18789", "/"),
        "openclaw-webui": host("RE_PORT_OPENCLAW", "18789", "/"),
        "localai-to-qdrant": host("RE_PORT_QDRANT", "4333", "/healthz"),
        "browser-to-openwebui": host("RE_PORT_WEBUI", "8080", "/"),
        "openclaw-to-browser-cdp": host("RE_PORT_BROWSER_CDP", "9222", "/json/version"),
        "pim-to-css": host("RE_PORT_CSS", "13000", "/"),
        "healthkit-to-pim": host("RE_PORT_PIM", "8090", "/api/integrations/healthkit/metrics"),
        # The asset storage stack (owner, 2026-11-12): CSS and dokieli on their
        # fixed ports, the lifecycle on its own.
        "browser-to-assets-css": [{"url": "https://127.0.0.1:13443", "path": "/"}],
        "lifecycle-to-assets-css": [{"url": "https://127.0.0.1:13443", "path": "/"}],
        "browser-to-assets-dokieli": [{"url": "https://127.0.0.1:13444", "path": "/"}],
        "clients-to-lifecycle": host("RE_PORT_LIFECYCLE", "13445", "/health"),
        "openclaw-agents-to-lifecycle": host("RE_PORT_LIFECYCLE", "13445", "/health"),
        # Ollama: through its TLS front (to-ollama), and directly, as Open WebUI
        # reaches it (release-to-ollama) and the front does (ollama-front-to-ollama).
        "to-ollama": [{"url": "https://127.0.0.1:11443", "path": "/"}],
        "release-to-ollama": [{"url": "https://127.0.0.1:11434", "path": "/"}],
        "ollama-front-to-ollama": [{"url": "https://127.0.0.1:11434", "path": "/"}],
    }
    network_eps = {
        "localai-to-redis": [{"url": "https://redis:6379", "path": "/", "protocol": "redis"}],
        "promtail-to-loki": [{"url": "https://loki:3100", "path": "/ready"}],
        "grafana-to-sources": [{"url": "https://loki:3100", "path": "/ready"},
                               {"url": "https://prometheus:9090", "path": "/-/ready"}],
    }
    out.mkdir(parents=True, exist_ok=True)
    (out / "host.json").write_text(json.dumps(host_eps, indent=2) + "\n")
    (out / "network.json").write_text(json.dumps(network_eps, indent=2) + "\n")
    print(env.get("COMPOSE_PROJECT_NAME", "realityengine"))
    image = env.get("RE_IMAGE_LOCALAI_API")
    if not image:
        print("release_probe_endpoints: the install names no RE_IMAGE_LOCALAI_API", file=sys.stderr)
        return 1
    print(image)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
