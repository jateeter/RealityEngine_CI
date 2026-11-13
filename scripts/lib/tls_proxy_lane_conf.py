#!/usr/bin/env python3
"""Write tls-proxy's nginx config for the lane (RealityEngine_CI#732, #668).

The docker lane's tls-proxy fronts Manager's pair and Grafana; the release
install's (release/config/nginx.conf) fronts Manager's visualizer (#729). Under RE_TLS=on
it serves the lane certificate (lane_tls_docker_manager) at the profile and
reaches its upstreams over the lane's mTLS. The lane config is derived from
nginx/tls-proxy.conf, so the two keep the same servers and routes:

- every listener: the lane certificate, TLS 1.3 only, the profile's suites and
  groups (config/transport-profile.json); the 497 redirect is dropped, so a
  plaintext request is refused (400) rather than answered with a redirect;
- every https upstream: verified against the lane CA, TLS 1.3 at the profile,
  presenting the lane certificate (the engines and Manager's RE require it);
- Grafana, plain upstream before, is reached over https on its OpenSSL front's
  mTLS port, 3443, presenting the lane certificate (docker-compose.
  observability-tls.yml, #729); its 3000 is the browser's;
- the TypeScript PE's server (3004) asks for the lane's client certificate and
  answers 403 without one, except on the HealthKit device routes, which take
  none (the native PEs' rule). Its callers are services (localAI, Manager, the
  harness); browsers reach the PE through 3005.

The two static frontends (visualizer-frontend, perception-engine-frontend)
stay plain upstreams: their nginx serves no TLS yet. That hop is recorded as
not on the lane.

Usage: tls_proxy_lane_conf.py <base.conf> <out.conf>
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

CI_DIR = Path(__file__).resolve().parents[2]
LANE = "/etc/nginx/lane"


DEVICE_ROUTES = "/api/integrations/healthkit/"


def ts_pe_client_certificates(text: str) -> str:
    """The 3004 server: ask for the lane certificate; 403 without it, device routes aside."""
    m = re.search(r"server \{\n(?:(?!\n    server \{).)*?listen 3004 ssl;.*?\n    \}\n", text, flags=re.S)
    if not m:
        return text  # the release's nginx.conf has no TypeScript PE
    block = m.group(0)
    block, n = re.subn(r"(\n(\s*)ssl_certificate_key [^\n]+\n)",
                       rf"\1\2ssl_verify_client      optional;\n\2ssl_client_certificate {LANE}/ca.crt;\n"
                       rf"\2ssl_crl                {LANE}/ca.crl;\n", block, count=1)
    if n != 1:
        raise SystemExit("tls_proxy_lane_conf: the 3004 server has no ssl_certificate_key")
    deny = "            if ($ssl_client_verify != SUCCESS) { return 403; }\n"
    block, n = re.subn(r"(\n        location (?:/ws|/) \{\n)", rf"\1{deny}", block)
    if n != 2:
        raise SystemExit(f"tls_proxy_lane_conf: expected the 3004 server's / and /ws locations, found {n}")
    # The device routes: no client certificate (the iPhone's HealthKit bridge).
    # Same upstream as the server's / (a literal on the dev lane, a variable in
    # the release's config, which resolves at request time).
    upstream = re.search(r"\n        location / \{\n(?:.*\n)*?\s*proxy_pass\s+(\S+);", block)
    if not upstream:
        raise SystemExit("tls_proxy_lane_conf: the 3004 server's / has no proxy_pass")
    device = (f"\n        location {DEVICE_ROUTES} {{\n"
              f"            proxy_pass         {upstream.group(1)};\n"
              "            proxy_ssl_name     perception-engine-backend;\n"
              # The caller's own certificate, as verified here: the TypeScript
              # PE requires one of some sources (HEALTHKIT_CLIENT_CERTIFICATE_REQUIRED),
              # and the proxy's own certificate on this hop must not stand in for it.
              "            proxy_set_header   X-Client-Certificate $ssl_client_verify;\n"
              "            proxy_http_version 1.1;\n"
              "            proxy_set_header   Host              $host;\n"
              "            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;\n"
              "            proxy_set_header   X-Forwarded-Proto https;\n"
              "        }\n")
    block = block.replace("\n        location / {\n", device + "\n        location / {\n", 1)
    return text.replace(m.group(0), block)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    base, out = Path(sys.argv[1]), Path(sys.argv[2])
    tls = json.loads((CI_DIR / "config" / "transport-profile.json").read_text())["tls"]
    suites = ":".join(tls["cipherSuites"])
    groups = ":".join(tls["keyExchangeGroups"]["preferred"] + tls["keyExchangeGroups"]["fallback"])
    text = base.read_text()

    def sub(pattern: str, repl: str, count_min: int = 1) -> None:
        nonlocal text
        text, n = re.subn(pattern, repl, text, flags=re.M)
        if n < count_min:
            raise SystemExit(f"tls_proxy_lane_conf: no match for {pattern!r} in {base}")

    sub(r"^(\s*)ssl_certificate\s+\S+;", rf"\1ssl_certificate     {LANE}/instance/chain.pem;")
    sub(r"^(\s*)ssl_certificate_key\s+\S+;", rf"\1ssl_certificate_key {LANE}/instance/key.pem;")
    sub(r"^(\s*)ssl_protocols\s+[^;]+;",
        rf"\1ssl_protocols       TLSv1.3;\n\1ssl_conf_command    Ciphersuites {suites};\n\1ssl_ecdh_curve      {groups};")
    # Absent from some configs (the release's nginx.conf): optional.
    sub(r"^\s*ssl_ciphers\s+[^;]+;\n", "", 0)
    sub(r"^\s*ssl_prefer_server_ciphers\s+[^;]+;\n", "", 0)
    sub(r"^\s*error_page 497 [^;]+;\n", "", 0)
    sub(r"^(\s*)proxy_ssl_trusted_certificate\s+\S+;",
        rf"\1proxy_ssl_trusted_certificate {LANE}/ca.crt;\n"
        rf"\1proxy_ssl_certificate         {LANE}/instance/chain.pem;\n"
        rf"\1proxy_ssl_certificate_key     {LANE}/instance/key.pem;\n"
        rf"\1proxy_ssl_conf_command        Ciphersuites {suites};")
    sub(r"^(\s*)proxy_ssl_protocols\s+[^;]+;", r"\1proxy_ssl_protocols           TLSv1.3;")
    text = ts_pe_client_certificates(text)
    # Grafana's front serves tls-proxy on 3443 with mTLS; name it for verification.
    sub(r"^(\s*)proxy_pass(\s+)[a-z]+://grafana:3000;", r"\1proxy_pass\2https://grafana:3443;\n\1proxy_ssl_name     grafana;", 0)
    # The release's form: the upstream in a variable (resolved per request).
    sub(r"^(\s*)set \$grafana [a-z]+://grafana:3000;", r"\1set $grafana https://grafana:3443;", 0)
    out.write_text("# Generated by scripts/lib/tls_proxy_lane_conf.py from "
                   f"{base.name} (RealityEngine_CI#732). Do not edit.\n" + text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
