#!/usr/bin/env python3
"""Validate deployed regression services and write a service inventory report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import ssl
import sys
import time
from typing import Any
from urllib import error, request


DEFAULT_OPTIONAL_SERVICES = {
    "grafana": "http://localhost:3002/api/health",
    "prometheus": "http://localhost:9090/-/ready",
    "bridge-metrics": "http://localhost:7342/healthz",
    "localai": "http://localhost:4000/health",
    "ollama": "http://localhost:11434/api/tags",
}


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_engine_spec(spec: str) -> dict[str, int]:
    expected: dict[str, int] = {}
    if not spec.strip():
        raise SystemExit("empty engine spec")
    for part in spec.split(","):
        name, sep, raw_count = part.partition(":")
        if not sep:
            raise SystemExit(f"invalid engine spec item {part!r}; expected runtime:count")
        runtime = name.strip()
        try:
            count = int(raw_count)
        except ValueError as exc:
            raise SystemExit(f"invalid engine count in {part!r}") from exc
        if not runtime or count < 0:
            raise SystemExit(f"invalid engine spec item {part!r}")
        expected[runtime] = expected.get(runtime, 0) + count
    return expected


def probe(url: str, timeout: int, insecure_tls: bool) -> dict[str, Any]:
    started = time.monotonic()
    req = request.Request(url, method="GET", headers={"accept": "application/json,*/*"})
    context = ssl._create_unverified_context() if insecure_tls and url.startswith("https://") else None
    try:
        with request.urlopen(req, timeout=timeout, context=context) as resp:
            raw = resp.read(2048).decode("utf-8", errors="replace")
            elapsed_ms = int((time.monotonic() - started) * 1000)
            return {
                "url": url,
                "ok": 200 <= resp.status < 300,
                "status": resp.status,
                "elapsedMs": elapsed_ms,
                "bodyPreview": raw[:512],
            }
    except error.HTTPError as exc:
        raw = exc.read(2048).decode("utf-8", errors="replace")
        elapsed_ms = int((time.monotonic() - started) * 1000)
        return {
            "url": url,
            "ok": False,
            "status": exc.code,
            "elapsedMs": elapsed_ms,
            "error": raw[:512] or exc.reason,
        }
    except Exception as exc:
        elapsed_ms = int((time.monotonic() - started) * 1000)
        return {
            "url": url,
            "ok": False,
            "status": None,
            "elapsedMs": elapsed_ms,
            "error": str(exc),
        }


def runtime_checks(instances: list[dict[str, Any]], expected: dict[str, int], timeout: int, insecure_tls: bool) -> tuple[list[dict[str, Any]], list[str]]:
    failures: list[str] = []
    checks: list[dict[str, Any]] = []
    running = [item for item in instances if item.get("status", "running") == "running"]

    for runtime, expected_count in sorted(expected.items()):
        active = [item for item in running if item.get("runtime") == runtime]
        if len(active) != expected_count:
            failures.append(f"runtime {runtime} expected {expected_count} running instance(s), found {len(active)}")
        for item in active:
            entry = {
                "id": item.get("id"),
                "runtime": runtime,
                "status": item.get("status", "running"),
                "reUrl": item.get("re_url"),
                "peUrl": item.get("pe_url"),
                "checks": {},
            }
            for surface, key in (("re", "re_url"), ("pe", "pe_url")):
                base = str(item.get(key) or "").rstrip("/")
                if not base:
                    result = {"ok": False, "url": "", "error": f"missing {key}"}
                else:
                    result = probe(f"{base}/api/health", timeout, insecure_tls)
                entry["checks"][surface] = result
                if not result.get("ok"):
                    failures.append(f"{runtime}/{item.get('id')}/{surface} health failed: {result.get('error') or result.get('status')}")
            checks.append(entry)

    unexpected = sorted({str(item.get("runtime")) for item in running if item.get("runtime") not in expected})
    for runtime in unexpected:
        failures.append(f"unexpected running runtime in registry: {runtime}")

    return checks, failures


def service_check(name: str, url: str, required: bool, timeout: int, insecure_tls: bool) -> dict[str, Any]:
    result = probe(url, timeout, insecure_tls)
    result.update({"name": name, "required": required})
    return result


def swagger_proxy_checks(swagger_url: str, expected: dict[str, int], timeout: int, insecure_tls: bool) -> tuple[list[dict[str, Any]], list[str]]:
    checks: list[dict[str, Any]] = []
    failures: list[str] = []
    base = swagger_url.rstrip("/")
    for runtime, count in sorted(expected.items()):
        if count <= 0:
            continue
        for surface in ("re", "pe"):
            url = f"{base}/proxy/{runtime}/{surface}/api/health"
            result = service_check(f"swagger-proxy-{runtime}-{surface}", url, True, timeout, insecure_tls)
            checks.append(result)
            if not result.get("ok"):
                failures.append(f"Swagger proxy {runtime}/{surface} health failed: {result.get('error') or result.get('status')}")
    return checks, failures


def update_manifest(manifest_path: Path | None, report_path: Path, status: str) -> None:
    if manifest_path is None or not manifest_path.is_file():
        return
    manifest = load_json(manifest_path)
    artifacts = manifest.setdefault("artifacts", {})
    artifacts["serviceInventory"] = str(report_path)
    manifest["serviceInventoryStatus"] = status
    write_json(manifest_path, manifest)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=Path("/tmp/re-registry/re-registry.json"))
    parser.add_argument("--engine-spec", default="cpp:1,lsp:1,scala:1")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--mcp-url", default="http://127.0.0.1:7331")
    parser.add_argument("--swagger-url", default="http://127.0.0.1:8088")
    parser.add_argument("--openclaw-url", default="http://localhost:18789")
    parser.add_argument("--require-openclaw", action="store_true")
    parser.add_argument("--require-service", action="append", default=[], choices=sorted(DEFAULT_OPTIONAL_SERVICES))
    parser.add_argument("--timeout", type=int, default=5)
    parser.add_argument("--insecure-tls", action="store_true")
    args = parser.parse_args()

    expected = parse_engine_spec(args.engine_spec)
    failures: list[str] = []
    warnings: list[str] = []
    try:
        registry = load_json(args.registry)
    except Exception as exc:
        report = {
            "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "registryPath": str(args.registry),
            "engineSpec": args.engine_spec,
            "expectedRuntimes": expected,
            "status": "failed",
            "failures": [f"could not read registry {args.registry}: {exc}"],
            "warnings": [],
        }
        write_json(args.out, report)
        update_manifest(args.manifest, args.out, "failed")
        print(report["failures"][0], file=sys.stderr)
        return 1

    instances = registry.get("instances", [])
    if not isinstance(instances, list):
        failures.append("registry does not contain an instances array")
        instances = []

    runtime_report, runtime_failures = runtime_checks(instances, expected, args.timeout, args.insecure_tls)
    failures.extend(runtime_failures)

    service_checks: list[dict[str, Any]] = []
    mcp_health = service_check("mcp-http", f"{args.mcp_url.rstrip('/')}/healthz", True, args.timeout, args.insecure_tls)
    service_checks.append(mcp_health)
    if not mcp_health.get("ok"):
        failures.append(f"MCP HTTP health failed: {mcp_health.get('error') or mcp_health.get('status')}")

    swagger_health = service_check("openapi-swagger", f"{args.swagger_url.rstrip('/')}/healthz", True, args.timeout, args.insecure_tls)
    service_checks.append(swagger_health)
    if not swagger_health.get("ok"):
        failures.append(f"OpenAPI Swagger health failed: {swagger_health.get('error') or swagger_health.get('status')}")

    swagger_report, swagger_failures = swagger_proxy_checks(args.swagger_url, expected, args.timeout, args.insecure_tls)
    service_checks.extend(swagger_report)
    failures.extend(swagger_failures)

    required_optionals = set(args.require_service)
    for name, url in DEFAULT_OPTIONAL_SERVICES.items():
        result = service_check(name, url, name in required_optionals, args.timeout, args.insecure_tls)
        service_checks.append(result)
        if not result.get("ok"):
            message = f"{name} readiness failed: {result.get('error') or result.get('status')}"
            if result["required"]:
                failures.append(message)
            else:
                warnings.append(message)

    openclaw_result = service_check("openclaw", f"{args.openclaw_url.rstrip('/')}/healthz", args.require_openclaw, args.timeout, args.insecure_tls)
    service_checks.append(openclaw_result)
    if not openclaw_result.get("ok"):
        message = f"OpenClaw readiness failed: {openclaw_result.get('error') or openclaw_result.get('status')}"
        if args.require_openclaw:
            failures.append(message)
        else:
            warnings.append(message)

    report = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "registryPath": str(args.registry),
        "engineSpec": args.engine_spec,
        "expectedRuntimes": expected,
        "registryInstances": instances,
        "runtimeChecks": runtime_report,
        "serviceChecks": service_checks,
        "status": "failed" if failures else "passed",
        "failures": failures,
        "warnings": warnings,
    }
    write_json(args.out, report)
    update_manifest(args.manifest, args.out, report["status"])

    if failures:
        print("service inventory failed:", file=sys.stderr)
        for item in failures:
            print(f"- {item}", file=sys.stderr)
        print(args.out, file=sys.stderr)
        return 1
    print(f"PASS service inventory: {len(runtime_report)} runtime instance(s), {len(service_checks)} service check(s)")
    if warnings:
        print(f"WARN service inventory: {len(warnings)} optional readiness warning(s)")
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
