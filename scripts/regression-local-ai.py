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

  5. With --agent-turn, one ``POST /graph/agent`` turn: it must answer, call a
     tool, and write ``localai_agent_activity`` to every PE. Checks 1-4 prove
     the provider is there; until this one the stage never invoked a graph, so
     the agent's tools node could fail on every turn (localAIStack#145: a
     ToolNode called as a function) while local-ai passed. The write is read as
     each PE's ``lastUpdated`` advancing across the turn, not as ``active``,
     which a 30 s TTL can clear before it is read.

A provider that is merely absent is reported as such rather than silently
passing, because that is the state the hosted lane is already in.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import time
import urllib.request
from pathlib import Path
from typing import Any

AGENT_SENSOR = "localai_agent_activity"
# Names the tool, so the turn reaches the tools node: the corpus localAIStack
# seeds at startup (data/health/documents) answers it.
AGENT_PROMPT = (
    "Use the health_search tool to find what a low heart rate variability "
    "reading suggests about recovery, then answer in two sentences."
)


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


def post_json(url: str, payload: Any, timeout: float) -> tuple[int, Any, str]:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"accept": "application/json", "content-type": "application/json"},
        method="POST",
    )
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


def agent_sensor(pe_url: str, timeout: float) -> tuple[dict[str, Any] | None, str]:
    """The PE's ``localai_agent_activity`` source, or why it could not be read."""
    status, body, err = get_json(f"{pe_url.rstrip('/')}/api/sources", timeout)
    if not (200 <= status < 300):
        return None, err or f"HTTP {status}"
    sources = body if isinstance(body, list) else (body or {}).get("sources", [])
    for src in sources if isinstance(sources, list) else []:
        if isinstance(src, dict) and src.get("sensorId") == AGENT_SENSOR:
            return src, ""
    return None, f"no {AGENT_SENSOR} source registered"


def agent_turn(
    localai_url: str, instances: list[dict[str, str]], timeout: float, failures: list[str]
) -> dict[str, Any]:
    """Check 5: one agent turn, answered, through a tool, written to every PE."""
    before = {i["id"]: agent_sensor(i["pe_url"], 10.0) for i in instances}
    started = time.monotonic()
    status, body, err = post_json(
        f"{localai_url.rstrip('/')}/graph/agent",
        {"messages": [{"role": "user", "content": AGENT_PROMPT}]},
        timeout,
    )
    elapsed = round(time.monotonic() - started, 2)
    answer = str(body.get("answer", "")) if isinstance(body, dict) else ""
    tool_calls = body.get("tool_calls_made", 0) if isinstance(body, dict) else 0
    tool_calls = tool_calls if isinstance(tool_calls, int) else 0
    out: dict[str, Any] = {
        "httpStatus": status,
        "seconds": elapsed,
        "toolCallsMade": tool_calls,
        "answerChars": len(answer.strip()),
        "error": err,
        "sensor": {},
    }
    if not (200 <= status < 300):
        failures.append(f"agent turn failed at {localai_url}/graph/agent: {err or status}")
        return out
    if not answer.strip():
        failures.append("agent turn returned an empty answer")
    if tool_calls < 1:
        failures.append("agent turn called no tool, so the tools node was not exercised")
    for inst in instances:
        prior, _ = before[inst["id"]]
        now, why = agent_sensor(inst["pe_url"], 10.0)
        was = (prior or {}).get("lastUpdated")
        is_ = (now or {}).get("lastUpdated")
        written = now is not None and is_ is not None and (was is None or is_ > was)
        out["sensor"][inst["id"]] = {
            "written": written,
            "active": bool((now or {}).get("active")),
            "lastUpdatedBefore": was,
            "lastUpdatedAfter": is_,
            "error": why,
        }
        if now is None:
            failures.append(f"{inst['id']}: cannot read {AGENT_SENSOR} after the agent turn: {why}")
        elif not written:
            failures.append(f"{inst['id']}: the agent turn did not write {AGENT_SENSOR}")
    return out


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
    parser.add_argument("--agent-turn", action="store_true",
                        help="Also run one /graph/agent turn (check 5).")
    parser.add_argument("--agent-timeout", type=float, default=300.0,
                        help="Seconds the agent turn may take; it waits on the model.")
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
    # A containerized PE reaches the Mac's Ollama as host.docker.internal, a
    # name only containers resolve; from here the same Ollama is --ollama-url.
    if urllib.parse.urlsplit(ollama_base).hostname == "host.docker.internal":
        ollama_base = args.ollama_url
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
                    hint = ""
                    if model.split(":")[0] == "tinyllama-mlx":
                        # Not in the Ollama library: localAIStack builds it.
                        hint = ". Build it: make -C ../localAIStack model-pull ID=tinyllama-mlx"
                    else:
                        hint = f". Pull it: ollama pull {model}"
                    failures.append(
                        f"{instance}: configured for model '{model}', which is not installed "
                        f"(available: {', '.join(installed)}){hint}"
                    )

    # 5 — one agent turn, only once the stack and provider checks have passed:
    # with either down it can only fail for the reason already recorded.
    if args.agent_turn:
        if failures:
            report["agentTurn"] = {"skipped": "earlier local AI checks failed"}
        else:
            report["agentTurn"] = agent_turn(args.localai_url, instances, args.agent_timeout, failures)

    report["status"] = "failed" if failures else "passed"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if failures:
        print("Local AI probe failed:", file=sys.stderr)
        for item in failures:
            print(f"- {item}", file=sys.stderr)
        return 1

    turn = report.get("agentTurn")
    detail = (
        f"; agent turn {turn['seconds']}s, {turn['toolCallsMade']} tool call(s), "
        f"{AGENT_SENSOR} written on {len(turn['sensor'])} PE(s)"
        if turn
        else ""
    )
    print(
        f"PASS local AI: stack ok, {len(instances)} PE(s) reachable, "
        f"model {distinct or ['(unset)']}{detail}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
