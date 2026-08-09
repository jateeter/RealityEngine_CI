#!/usr/bin/env python3
"""Probe the local AI surfaces the local lane exists to exercise.

The hosted lane refuses Ollama and localAIStack, so nothing on it can say
whether those work. The local lane starts them — and until this stage existed,
started them and then tested nothing, which meant `--profile local` bought a
slower run rather than more coverage.

Three things are checked, and they fail for different reasons:

  1. localAIStack answers its health endpoint.
  2. Every PE reports Ollama as reachable. A PE that answers with
     `reachable: false` is the interesting failure — the provider is supposed
     to be up on this lane, so a well-formed "not reachable" is still a defect.
  3. Every PE agrees on which model it is configured for. Runtimes disagreeing
     about the model would make any downstream comparison meaningless.
  4. The model each PE is configured for is actually installed. `reachable`
     only proves Ollama's HTTP surface answers — on the first live run of this
     probe all three PEs reported reachable while pointing at models the local
     Ollama did not have, so every dispatch would have failed against a stage
     that passed.

A provider that is merely absent is reported as such rather than silently
passing, because that is the state the hosted lane is already in.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def get_json(url: str, timeout: float) -> tuple[int, Any, str]:
    req = urllib.request.Request(url, headers={"accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            body = res.read().decode("utf-8", "replace")
            try:
                return res.status, json.loads(body), ""
            except json.JSONDecodeError:
                return res.status, None, f"non-JSON body: {body[:200]}"
    except urllib.error.HTTPError as err:
        return err.code, None, f"HTTP {err.code}"
    except Exception as err:  # noqa: BLE001 — any transport failure is a result
        return 0, None, str(err)


def load_instances(registry: Path) -> list[dict[str, str]]:
    try:
        payload = json.loads(registry.read_text(encoding="utf-8"))
    except Exception as err:  # noqa: BLE001
        raise SystemExit(f"cannot read registry {registry}: {err}")
    return [
        {"id": i.get("id", ""), "runtime": i.get("runtime", ""), "pe_url": i.get("pe_url", "")}
        for i in payload.get("instances", [])
        if i.get("pe_url")
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=Path("/tmp/re-registry/re-registry.json"))
    parser.add_argument("--localai-url", default="http://localhost:4000")
    parser.add_argument("--ollama-url", default="http://localhost:11434",
                        help="Fallback when no PE reports an Ollama baseUrl.")
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    failures: list[str] = []
    report: dict[str, Any] = {
        "status": "passed",
        "localAiUrl": args.localai_url,
        "stack": {},
        "providers": [],
        "failures": failures,
    }

    # 1 — the stack itself
    status, body, err = get_json(f"{args.localai_url.rstrip('/')}/health", args.timeout)
    report["stack"] = {"httpStatus": status, "ok": 200 <= status < 300, "error": err, "body": body}
    if not (200 <= status < 300):
        failures.append(f"localAIStack health failed at {args.localai_url}: {err or status}")

    # 2 and 3 — every PE's view of the provider
    instances = load_instances(args.registry)
    if not instances:
        failures.append("no PE instances in the registry")

    models: dict[str, str] = {}
    for inst in instances:
        url = f"{inst['pe_url'].rstrip('/')}/api/integrations/ollama/status"
        status, body, err = get_json(url, args.timeout)
        reachable = bool(body.get("reachable")) if isinstance(body, dict) else False
        model = str(body.get("model", "")) if isinstance(body, dict) else ""

        report["providers"].append(
            {
                "instance": inst["id"],
                "runtime": inst["runtime"],
                "httpStatus": status,
                "reachable": reachable,
                "model": model,
                "baseUrl": (body.get("baseUrl") if isinstance(body, dict) else "") or "",
                "error": err or (body.get("error") if isinstance(body, dict) else "") or "",
            }
        )

        if not (200 <= status < 300):
            failures.append(f"{inst['id']}: ollama status endpoint failed: {err or status}")
        elif not reachable:
            # The lane started Ollama, so an orderly "not reachable" is a
            # defect, not an acceptable answer.
            detail = body.get("error") if isinstance(body, dict) else ""
            failures.append(f"{inst['id']}: reports Ollama unreachable on a lane that starts it: {detail}")
        elif model:
            models[inst["id"]] = model

    distinct = sorted(set(models.values()))
    report["modelAgreement"] = {"models": models, "distinct": distinct}
    if len(distinct) > 1:
        failures.append(f"runtimes disagree on the Ollama model: {models}")

    # 4 — the configured model has to exist. A PE can report reachable:true
    # against an Ollama that has never pulled the model it is set to use, and
    # then fail every dispatch. Ask Ollama directly rather than trusting the
    # PE's own view of itself.
    base_urls = {
        p["instance"]: (p.get("baseUrl") or "")
        for p in report["providers"]
        if p.get("baseUrl")
    }
    ollama_base = next(iter(base_urls.values()), "") or args.ollama_url
    installed: list[str] = []
    if ollama_base and distinct:
        status, body, err = get_json(f"{ollama_base.rstrip('/')}/api/tags", args.timeout)
        if isinstance(body, dict):
            installed = [str(m.get("name", "")) for m in body.get("models", []) if m.get("name")]
        report["installedModels"] = installed
        if not installed:
            failures.append(f"could not list installed models at {ollama_base}: {err or status}")
        else:
            # Ollama reports "name" and "name:latest" interchangeably.
            def present(model: str) -> bool:
                return any(
                    tag == model or tag.split(":")[0] == model.split(":")[0]
                    for tag in installed
                )

            for instance, model in sorted(models.items()):
                if not present(model):
                    failures.append(
                        f"{instance}: configured for model '{model}', which is not installed "
                        f"(available: {', '.join(installed)})"
                    )

    report["status"] = "failed" if failures else "passed"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if failures:
        print("Local AI probe failed:", file=sys.stderr)
        for item in failures:
            print(f"- {item}", file=sys.stderr)
        return 1

    print(f"PASS local AI: stack ok, {len(instances)} PE(s) reachable, model {distinct or ['(unset)']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
