#!/usr/bin/env python3
"""Runtime-aware OpenAPI/Swagger portal for RealityEngine.

The checked-in OpenAPI documents remain generated contract artifacts. This
server rewrites the served `servers:` block to same-origin proxy URLs and
forwards those proxy requests to the active RE registry.
"""

from __future__ import annotations

import argparse
import http.client
import json
import mimetypes
import os
from pathlib import Path
import posixpath
import re
from socketserver import ThreadingMixIn
from typing import Optional
from urllib.parse import unquote, urlparse
from http.server import BaseHTTPRequestHandler, HTTPServer


RUNTIMES = {"cpp", "lsp", "scala"}
SURFACES = {"re", "pe"}
SPEC_RE = re.compile(r"^/([a-z]+)-(re|pe)\.yaml$")
PROXY_RE = re.compile(r"^/proxy/([a-z]+)/(re|pe)(/.*)?$")
HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def load_registry(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return {"instances": []}
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid registry JSON at {path}: {exc}") from exc


def target_for(registry_path: Path, runtime: str, surface: str) -> Optional[str]:
    registry = load_registry(registry_path)
    key = "re_url" if surface == "re" else "pe_url"
    for instance in registry.get("instances", []):
        if instance.get("runtime") == runtime and instance.get("status", "running") == "running":
            url = instance.get(key)
            if url:
                return str(url).rstrip("/")
    fallback_runtime = os.environ.get("OPENAPI_SWAGGER_FALLBACK_RUNTIME", "scala")
    if runtime == fallback_runtime:
        fallback = os.environ.get("RE_URL" if surface == "re" else "PE_URL")
        if fallback:
            return fallback.rstrip("/")
    return None


def rewrite_servers(spec_text: str, runtime: str, surface: str, request_prefix: str) -> str:
    proxy_url = f"{request_prefix}/proxy/{runtime}/{surface}"
    replacement = (
        "servers:\n"
        f"- url: {proxy_url}\n"
        f"  description: Active {runtime.upper()} {surface.upper()} via same-origin Swagger proxy\n"
    )
    lines = spec_text.splitlines(keepends=True)
    out: list[str] = []
    i = 0
    replaced = False
    while i < len(lines):
        line = lines[i]
        if not replaced and line == "servers:\n":
            out.append(replacement)
            i += 1
            while i < len(lines) and (lines[i].startswith("- ") or lines[i].startswith("  ")):
                i += 1
            replaced = True
            continue
        out.append(line)
        i += 1
    if not replaced:
        out.append("\n")
        out.append(replacement)
    return "".join(out)


class Handler(BaseHTTPRequestHandler):
    server_version = "RealityEngineOpenAPI/1.0"

    @property
    def docroot(self) -> Path:
        return self.server.docroot  # type: ignore[attr-defined]

    @property
    def registry_path(self) -> Path:
        return self.server.registry_path  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        if self._serve_health():
            return
        if self._serve_registry():
            return
        if self._serve_rewritten_spec():
            return
        if self._proxy():
            return
        self._serve_static()

    def do_HEAD(self) -> None:
        if self.path == "/healthz":
            self._send_bytes(200, b"", "application/json", head_only=True)
            return
        self.do_GET()

    def do_POST(self) -> None:
        self._proxy_or_404()

    def do_PUT(self) -> None:
        self._proxy_or_404()

    def do_PATCH(self) -> None:
        self._proxy_or_404()

    def do_DELETE(self) -> None:
        self._proxy_or_404()

    def do_OPTIONS(self) -> None:
        match = PROXY_RE.match(urlparse(self.path).path)
        if not match:
            self._send_json(404, {"error": "not found"})
            return
        self.send_response(204)
        self._send_cors_headers()
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "accept,authorization,content-type")
        self.send_header("Access-Control-Max-Age", "600")
        self.end_headers()

    def _proxy_or_404(self) -> None:
        if not self._proxy():
            self._send_json(404, {"error": "not found"})

    def _request_prefix(self) -> str:
        host = self.headers.get("Host", "127.0.0.1")
        proto = self.headers.get("X-Forwarded-Proto", "http")
        return f"{proto}://{host}"

    def _serve_health(self) -> bool:
        if urlparse(self.path).path != "/healthz":
            return False
        self._send_json(200, {"status": "ok", "registry": str(self.registry_path)})
        return True

    def _serve_registry(self) -> bool:
        if urlparse(self.path).path != "/registry.json":
            return False
        self._send_json(200, load_registry(self.registry_path))
        return True

    def _serve_rewritten_spec(self) -> bool:
        parsed = urlparse(self.path)
        match = SPEC_RE.match(parsed.path)
        if not match:
            return False
        runtime, surface = match.groups()
        if runtime not in RUNTIMES or surface not in SURFACES:
            return False
        path = self.docroot / f"{runtime}-{surface}.yaml"
        if not path.is_file():
            self._send_json(404, {"error": f"missing spec {path.name}"})
            return True
        spec_text = path.read_text(encoding="utf-8")
        rewritten = rewrite_servers(spec_text, runtime, surface, self._request_prefix())
        self._send_bytes(200, rewritten.encode("utf-8"), "application/yaml; charset=utf-8")
        return True

    def _proxy(self) -> bool:
        parsed = urlparse(self.path)
        match = PROXY_RE.match(parsed.path)
        if not match:
            return False
        runtime, surface, suffix = match.groups()
        if runtime not in RUNTIMES or surface not in SURFACES:
            self._send_json(404, {"error": "unknown runtime or surface"})
            return True
        target_base = target_for(self.registry_path, runtime, surface)
        if not target_base:
            self._send_json(503, {"error": f"no active {runtime}/{surface} target in registry"})
            return True

        suffix = suffix or "/"
        query = f"?{parsed.query}" if parsed.query else ""
        target = urlparse(f"{target_base}{suffix}{query}")
        body = self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
        conn_cls = http.client.HTTPSConnection if target.scheme == "https" else http.client.HTTPConnection
        port = target.port
        conn = conn_cls(target.hostname, port, timeout=30)
        try:
            headers = self._forward_headers(target.netloc)
            target_path = target.path or "/"
            if target.query:
                target_path = f"{target_path}?{target.query}"
            conn.request(self.command, target_path, body=body, headers=headers)
            resp = conn.getresponse()
            resp_body = resp.read()
            self.send_response(resp.status, resp.reason)
            for key, value in resp.getheaders():
                if key.lower() not in HOP_BY_HOP_HEADERS:
                    self.send_header(key, value)
            self._send_cors_headers()
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(resp_body)
        except OSError as exc:
            self._send_json(502, {"error": "proxy request failed", "detail": str(exc)})
        finally:
            conn.close()
        return True

    def _forward_headers(self, target_host: str) -> dict[str, str]:
        headers: dict[str, str] = {"Host": target_host}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in HOP_BY_HOP_HEADERS or lower == "host":
                continue
            headers[key] = value
        return headers

    def _serve_static(self) -> None:
        parsed = urlparse(self.path)
        rel = unquote(parsed.path.lstrip("/")) or "index.html"
        rel = posixpath.normpath("/" + rel).lstrip("/")
        if rel.startswith("../") or rel == ".." or rel.startswith("/"):
            self._send_json(403, {"error": "forbidden"})
            return
        path = self.docroot / rel
        if path.is_dir():
            path = path / "index.html"
        if not path.is_file():
            self._send_json(404, {"error": "not found"})
            return
        ctype = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        self._send_bytes(200, path.read_bytes(), ctype)

    def _send_json(self, status: int, payload: object) -> None:
        self._send_bytes(status, json.dumps(payload, indent=2).encode("utf-8"), "application/json; charset=utf-8")

    def _send_bytes(self, status: int, body: bytes, content_type: str, head_only: bool = False) -> None:
        self.send_response(status)
        self._send_cors_headers()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head_only and self.command != "HEAD":
            self.wfile.write(body)

    def _send_cors_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")

    def log_message(self, fmt: str, *args: object) -> None:
        if os.environ.get("OPENAPI_SWAGGER_QUIET") == "true":
            return
        super().log_message(fmt, *args)


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve RealityEngine OpenAPI docs with registry-aware proxy support.")
    parser.add_argument("--port", type=int, default=8088)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--docroot", type=Path, required=True)
    parser.add_argument("--registry", type=Path, default=Path("/tmp/re-registry/re-registry.json"))
    args = parser.parse_args()

    if not (args.docroot / "index.html").is_file():
        raise SystemExit(f"missing portal: {args.docroot / 'index.html'}")

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.docroot = args.docroot
    server.registry_path = args.registry
    print(f"Serving {args.docroot} on http://{args.host}:{args.port}/", flush=True)
    print(f"  Swagger portal : http://{args.host}:{args.port}/", flush=True)
    print(f"  Runtime registry: {args.registry}", flush=True)
    print(f"  Proxy pattern  : http://{args.host}:{args.port}/proxy/{{cpp,lsp,scala}}/{{re,pe}}/...", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
