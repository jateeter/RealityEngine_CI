#!/usr/bin/env python3
"""Run real HTTP document/RAG connectors with explicitly synthetic entity assets.

No engine lifecycle is controlled here. Native parity is a separate CI gate.
Source passages, runtime credentials, entity assets and vector data stay outside
Git. Never equate representative controls with all-IFRS financial acceptance.
"""
import argparse
from importlib.util import spec_from_file_location, module_from_spec
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time
import uuid

import httpx


def write(path, value, private=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")
    if private:
        path.chmod(0o600)


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--machines", type=Path, required=True)
    parser.add_argument("--localai", type=Path, required=True)
    parser.add_argument("--openclaw", type=Path, required=True)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--live-model", action="store_true")
    parser.add_argument("--openclaw-bin", type=Path, help="Installed OpenClaw entrypoint; execute a private gateway/tool proof")
    parser.add_argument("--index-state", type=Path, help="Persistent private parent for evidence/ and qdrant/; reuse vectors, never model answers")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    out.chmod(0o700)
    runtime = out / "runtime"; runtime.mkdir(mode=0o700)
    assets = args.machines / "machine_factory/domains/ifrs-accounting"
    source_spec = spec_from_file_location("ifrs_control_sources", assets / "tools/accounting_controls.py")
    control_sources = module_from_spec(source_spec); source_spec.loader.exec_module(control_sources)
    package = json.loads((assets / "acceptance/synthetic/accounting-package.json").read_text())
    assert package["synthetic"] and package["evidenceClass"] == "synthetic"
    foundation = json.loads((assets / "acceptance/synthetic/foundation-cases.json").read_text())
    assert foundation["synthetic"]
    # Pin each fixture to its own reporting scope, including pre-effective periods.
    # The synthetic operator record is never treated as independently reviewed.
    policy = json.loads((assets / "acceptance/synthetic/policy-cases.json").read_text())
    assert policy["synthetic"]
    foundation["cases"].extend(policy["cases"])
    lease = json.loads((assets / "acceptance/synthetic/lease-compliance-cases.json").read_text())
    assert lease["synthetic"]
    foundation["cases"].extend(lease["cases"])
    disclosure = json.loads((assets / "acceptance/synthetic/source-disclosure-cases.json").read_text())
    assert disclosure["synthetic"]
    foundation["cases"].extend(disclosure["cases"])
    reporting = json.loads((assets / "acceptance/synthetic/reporting-cases.json").read_text())
    assert reporting["synthetic"]
    foundation["cases"].extend(reporting["cases"])
    for case in foundation["cases"]:
        case["period"] = case["facts"].get("periodStart", "2027")[:4]
        entity = next(e for e in package["entities"] if e["entityId"] == case["entityId"])
        if case["period"] not in entity["periods"]:
            entity["periods"].append(case["period"])
        package["cases"].append(case)
    for entity_id, period in sorted({(c["entityId"], c["period"]) for c in foundation["cases"]}):
        package["supportingRecords"].append(dict(recordId="SYNTHETIC-FOUNDATION-RECORD", entityId=entity_id, period=period,
                                                  synthetic=True, description="Fictional operator judgments for foundation control paths; independent review required"))
    package["supportingRecords"].append(dict(recordId="SYNTHETIC-POLICY-RECORD", entityId="SYNTHETIC-ASTER-SERVICES", period="2027", synthetic=True,
                                              description="Fictional operator policy judgments; independent accounting review required"))
    package["supportingRecords"].append(dict(recordId="SYNTHETIC-LEASE-RECORD", entityId="SYNTHETIC-ASTER-SERVICES", period="2027", synthetic=True,
                                              description="Fictional lease contract and reviewed-judgment reference for development cases; not independent review"))
    package["supportingRecords"].append(dict(recordId="SYNTHETIC-SOURCE-RECORD", entityId="SYNTHETIC-ASTER-SERVICES", period="2027", synthetic=True,
                                              description="Fictional source/disclosure judgments for development acceptance; independent review required"))
    package["supportingRecords"].append(dict(recordId="SYNTHETIC-REPORTING-RECORD", entityId="SYNTHETIC-ASTER-SERVICES", period="2027", synthetic=True,
                                              description="Fictional dividend resolutions, financing movements, supplier terms and comparative reporting records; independent review required"))
    graph = json.loads((assets / "accounting-workflow-graph.json").read_text())
    catalog = {a["assetTypeId"]: a for a in json.loads((assets / "document-asset-catalog.json").read_text())["assetTypes"]}
    source = json.loads((args.bundle / "ingestion-manifest.json").read_text())
    processes, logs = [], []
    receipt = {"evidenceClass": "synthetic", "accountingAcceptance": "REPRESENTATIVE_DEVELOPMENT_CASES_ONLY", "nativeParity": "NOT_MEASURED_HERE", "independentAccountingReview": "REQUIRED", "phases": {}, "artifacts": []}
    def fingerprints():
        paths = list((args.machines / "machines/domains/ifrs-accounting").glob("*.json"))
        paths += [assets / name for name in ["document-asset-catalog.json", "accounting-workflow-graph.json", "runbook-resolution.json", "acceptance/synthetic/accounting-package.json", "acceptance/synthetic/foundation-cases.json", "foundation-source-dispositions.json", "acceptance/synthetic/policy-cases.json", "policy-source-dispositions.json", "semantic-amendments.json", "acceptance/synthetic/lease-compliance-cases.json", "lease-compliance-source-dispositions.json", "acceptance/synthetic/source-disclosure-cases.json", "source-disclosure-dispositions.json", "acceptance/synthetic/reporting-cases.json", "reporting-source-dispositions.json", "tools/reporting_controls.py", "source-reference-map.json", "source-requirements.json", "tools/compliance_evidence.py", "tools/document_workflow.py", "tools/accounting_controls.py"]]
        paths += [args.localai / path for path in ["services/api/core/domain_evidence.py", "services/api/core/entity_evidence.py", "services/api/routers/domain_evidence.py"]]
        paths += [args.openclaw / path for path in ["document-workflows/service.py", "document-workflows/worker.py", "plugins/ifrs-documents/index.mjs", "plugins/ifrs-documents/openclaw.plugin.json"]]
        paths += [Path(__file__).resolve()]
        roots = [args.machines.resolve(), args.localai.resolve(), args.openclaw.resolve(), Path(__file__).resolve().parents[1]]
        return {root.name + "/" + str(path.resolve().relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths for root in roots if path.resolve().is_relative_to(root)}
    receipt["inputSHA256"] = fingerprints()
    receipt["repositoryCommits"] = {path.name: subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path, text=True).strip() for path in [args.machines, args.localai, args.openclaw, Path(__file__).resolve().parents[1]]}
    def spawn(command, cwd, env, name):
        stream = (out / (name + ".log")).open("wb"); logs.append(stream)
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        processes.append(process)
        return process
    def wait(url, process):
        for _ in range(100):
            if process.poll() is not None:
                raise RuntimeError("Connector exited before readiness")
            try:
                if httpx.get(url + "/openapi.json", timeout=2).status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            time.sleep(.2)
        raise RuntimeError("Connector readiness timed out")
    try:
        token = secrets.token_urlsafe(32)
        rag_url, doc_url = "http://127.0.0.1:" + str(port()), "http://127.0.0.1:" + str(port())
        index_state = args.index_state.resolve() if args.index_state else runtime
        env = dict(os.environ, IFRS_EVIDENCE_TOKEN=token, IFRS_EVIDENCE_STATE_DIR=str(index_state / "evidence"),
                   IFRS_QDRANT_PATH=str(index_state / "qdrant"), IFRS_EVIDENCE_BUNDLE=str(args.bundle.resolve()),
                   IFRS_EVIDENCE_PORT=rag_url.rsplit(":", 1)[1], IFRS_ENTITY_CONNECTOR_CONFIG=str(runtime / "entity-connector.json"))
        process = spawn([sys.executable, str(args.localai / "scripts/ifrs-evidence-api.py")], args.localai, env, "evidence-api")
        wait(rag_url, process)
        rag = httpx.Client(base_url=rag_url, headers={"Authorization": "Bearer " + token}, timeout=600)
        def post(client, path, data=None):
            response = client.post(path, json=data)
            response.raise_for_status()
            return response.json()
        census = post(rag, "/rag/evidence/reconcile")
        repeat = post(rag, "/rag/evidence/reconcile")
        assert census["documents"] == source["totalDocuments"] and repeat["added"] == 0 and repeat["removed"] == 0
        write(out / "index-census.json", {"first": census, "repeat": repeat})
        receipt["phases"]["manifestAndRealEmbedding"] = "PASS"
        queries, section_receipts = [], {}
        for doc in source["documents"]:
            if doc["documentRole"] != "standard_source":
                continue
            query = dict(domain="ifrs-accounting", documentRole="standard_source", edition=doc["edition"], question="Return this section's complete source context for independent review.", documentId=doc["documentId"], sectionId=doc["sectionId"], sourceSHA256=doc["sourceSHA256"], method="exact-source", limit=50, indexSnapshot=census["indexSnapshot"])
            result = post(rag, "/rag/evidence/retrieve", query)
            assert result["passages"] and all(p["documentId"] == doc["documentId"] and p["sourceSHA256"] == doc["sourceSHA256"] for p in result["passages"])
            assert all(hashlib.sha256(p["text"].encode()).hexdigest() == p["textSHA256"] for p in result["passages"])
            queries.append(result); section_receipts[doc["sectionId"]] = result
        write(out / "source-retrieval.json", queries)
        receipt["phases"]["sourceSectionRetrieval"] = {"result": "PASS", "sections": len(queries), "paragraphAttribution": "REMAINS_UNVERIFIED"}
        contexts = []
        for entity in package["entities"]:
            for period in entity["periods"]:
                contexts.append(dict(entityId=entity["entityId"], period=period, evidenceClass="synthetic",
                                     factsFingerprint=hashlib.sha256(json.dumps(package, sort_keys=True).encode()).hexdigest(), sourceFingerprint=census["sourceFingerprint"],
                                     policyFingerprint="synthetic-policy-v1", indexSnapshot=census["indexSnapshot"], unresolvedRequirements=package["unresolvedRequirements"],
                                     evidenceRefAllowlist=["synthetic:source-review-control", "synthetic:new-source-review"] + [q["interactionId"] for q in queries] + [r["recordId"] for r in package["supportingRecords"] if r["entityId"] == entity["entityId"] and r["period"] == period],
                                     evidenceRecords=[r for r in package["supportingRecords"] if r["entityId"] == entity["entityId"] and r["period"] == period],
                                     factsByCase={c["caseId"]: {"control": c["control"], "facts": c["facts"]} for c in package["cases"] if c["entityId"] == entity["entityId"] and c["period"] == period}))
        context = contexts[0]
        scopes = [[c["entityId"], c["period"]] for c in contexts]
        principals = [{"name": "synthetic-operator", "role": "operator", "token": secrets.token_urlsafe(32), "scopes": scopes},
                      {"name": "synthetic-projection", "role": "projection", "token": secrets.token_urlsafe(32), "scopes": scopes}]
        for mid in sorted(set(graph["assetStewards"].values())):
            principals.append(dict(name=mid, role="agent", machineId=mid, token=secrets.token_urlsafe(32), scopes=scopes))
        for name in sorted({a["reviewerName"] for a in catalog.values()}):
            principals.append(dict(name=name, role="reviewer", token=secrets.token_urlsafe(32), scopes=scopes))
        write(runtime / "principals.json", principals, private=True)
        write(runtime / "entity-connector.json", dict(url=doc_url, token=principals[1]["token"], scopes=contexts, evidenceClass="synthetic", stateDirectory=str(runtime / "entity-projection")), private=True)
        env.update(IFRS_WORKFLOW_PRINCIPALS=str(runtime / "principals.json"), IFRS_ASSETS_DIR=str(assets.resolve()),
                   IFRS_MACHINES_DIR=str((args.machines / "machines/domains/ifrs-accounting").resolve()), IFRS_DOCUMENT_STATE_DIR=str(runtime / "documents"), IFRS_RAG_URL=rag_url)
        process = spawn([sys.executable, "-m", "uvicorn", "service:configured_app", "--factory", "--host", "127.0.0.1", "--port", doc_url.rsplit(":", 1)[1]], args.openclaw / "document-workflows", env, "document-api")
        wait(doc_url, process)
        client = httpx.Client(base_url=doc_url, timeout=120)
        def actor(asset):
            return next(p for p in principals if p.get("machineId") == graph["assetStewards"][asset])
        def command(op, arguments, principal, ctx=context, dispatch=None):
            response = client.post("/tools/execute", headers={"Authorization": "Bearer " + principal["token"]}, json=dict(dispatchId=dispatch or str(uuid.uuid4()), operation=op, context=ctx, arguments=arguments))
            response.raise_for_status()
            return response.json()
        for ctx in contexts:
            command("event", {"event": dict(type="period-opened", entityId=ctx["entityId"], period=ctx["period"], eventId="synthetic-open"), "applicableAssetTypeIds": list(catalog)}, principals[0], ctx)
        source_content = dict(edition=source["documents"][0]["edition"], sourceFiles=[d["documentId"] for d in source["documents"] if d["documentRole"] == "standard_source"], sourceHashes=[d["sourceSHA256"] for d in source["documents"] if d["documentRole"] == "standard_source"], authorityClasses=["operative text and commentary remain distinct"], sourceGaps=census["sourceGaps"])
        histories = []
        for asset in ["SOURCE-REGISTER", "RAG-RECEIPTS"]:
            content = source_content if asset == "SOURCE-REGISTER" else {key: {"synthetic": True, "interactionRefs": [section_receipts["01"]["interactionId"]], "indexSnapshot": census["indexSnapshot"]} for key in catalog[asset]["requiredFields"]}
            if asset == "RAG-RECEIPTS":
                content["unresolved"] = []
            request = dict(assetTypeId=asset, content=content, evidenceRefs=["synthetic:source-review-control", section_receipts["01"]["interactionId"]], expectedRevision=0)
            head = command("draft", request, actor(asset))["result"]
            command("request-review", dict(assetTypeId=asset, expectedRevision=head["revision"]), actor(asset))
            evidence = section_receipts["01"]
            review = dict(ownerName=catalog[asset]["ownerName"], reviewerName=catalog[asset]["reviewerName"], evidenceChecked=True, citationsChecked=True, reconciliationsChecked=True, unresolvedItems=[], revision=head["revision"], contentHash=head["contentHash"], ragReceipt=dict(interactionId=evidence["interactionId"], sourceHash=evidence["passages"][0]["sourceSHA256"], sourceFingerprint=census["sourceFingerprint"], indexSnapshot=census["indexSnapshot"], verifiedPassageRefs=[p["chunkId"] for p in evidence["passages"]], citationVerified=True))
            reviewer = next(p for p in principals if p["role"] == "reviewer" and p["name"] == catalog[asset]["reviewerName"])
            histories.append(command("approve", dict(assetTypeId=asset, review=review, interactionId=evidence["interactionId"]), reviewer))
        receipt["phases"]["initialSyntheticReviewLifecycle"] = "PASS_SEPARATE_TEST_REVIEWER_PRINCIPALS"
        post(rag, "/rag/evidence/entity/reconcile")
        projected = post(rag, "/rag/evidence/entity/retrieve", dict(entityId=context["entityId"], period=context["period"], assetTypeId="RAG-RECEIPTS"))
        assert projected["head"]["status"] == "APPROVED" and projected["evidenceClass"] == "synthetic"
        receipt["phases"]["currentSyntheticProjection"] = "PASS"
        calculations, reporting_artifacts = [], []
        reporting_targets = set()
        for case in package["cases"]:
            section = control_sources.source_section(case["control"], case["facts"])
            case_context = next(c for c in contexts if c["entityId"] == case["entityId"] and c["period"] == case["period"])
            result = command("calculate", dict(caseId=case["caseId"], interactionId=section_receipts[section]["interactionId"]), actor("SOURCE-REGISTER"), case_context)
            for key, value in case["expected"].items():
                assert result["result"]["determination"][key] == value, case["caseId"]
            if case in foundation["cases"]:
                wrong_section = "03" if section == "01" else "01"
                denied = client.post("/tools/execute", headers={"Authorization": "Bearer " + actor("SOURCE-REGISTER")["token"]},
                                     json=dict(dispatchId=str(uuid.uuid4()), operation="calculate", context=case_context,
                                               arguments=dict(caseId=case["caseId"], interactionId=section_receipts[wrong_section]["interactionId"])))
                assert denied.status_code == 409, (case["caseId"], denied.status_code)
            if case["control"] == "section-3-compliance-evidence-screen":
                screen = result["result"]["determination"]
                assert screen["requirementCount"] == len(json.loads((assets / "source-requirements.json").read_text())["controls"])
                assert screen["blockerCount"] > 0 and not screen["releasePerformed"]
                assert any(b["reason"] == "OPEN_OR_UNASSESSED_ACCOUNTING_REQUIREMENTS" for b in screen["blockers"])
                receipt["phases"]["canonicalComplianceBlocksUnreviewedScope"] = "PASS_REAL_CANONICAL_READ_NOT_CALLER_STATUSES"
            if case.get("expectedDraftAssetTypeId"):
                aid = case["expectedDraftAssetTypeId"]
                before = command("inspect", dict(assetTypeId=aid), actor(aid), case_context)
                head = command("draft-from-case", dict(assetTypeId=aid, caseId=case["caseId"], interactionId=section_receipts[section]["interactionId"], expectedRevision=before["head"]["revision"] if before["head"] else 0, changeReason="Synthetic reporting case " + case["caseId"]), actor(aid), case_context)["result"]
                artifact = command("inspect", dict(assetTypeId=aid), actor(aid), case_context)
                assert head["status"] == "DRAFT" and artifact["revision"]["content"]["typedProducerReceipt"]["caseId"] == case["caseId"]
                assert artifact["revision"]["content"]["unresolved"] == []
                reporting_artifacts.append(dict(caseId=case["caseId"], assetTypeId=aid, artifact=artifact))
                reporting_targets.add(aid)
            calculations.append(result)
        write(out / "synthetic-accounting-cases.json", calculations)
        write(out / "typed-reporting-artifacts.json", reporting_artifacts)
        receipt["phases"]["ownedTypedReportingDrafts"] = {"result": "PASS", "cases": len(reporting_artifacts), "assetTypes": sorted(reporting_targets), "independentReview": "REQUIRED"}
        receipt["phases"]["representativeAccountingControls"] = {"result": "PASS", "cases": len(calculations), "scope": "SYNTHETIC_ADVISORY_CONTROLS"}
        if args.openclaw_bin:
            receipt["gatewayVersion"] = json.loads((args.openclaw_bin.parent / "package.json").read_text())["version"]
            agent_id = "ifrs-document-verifier"
            reporting_agent_id = "ifrs-reporting-verifier"
            gateway_token = secrets.token_urlsafe(32)
            gateway_port = port()
            gateway_url = "http://127.0.0.1:" + str(gateway_port)
            model = "ollama/nemotron-3-nano:4b-mlx"
            private_tools = runtime / "gateway-tools.json"
            write(private_tools, {"url": doc_url, "agents": {agent_id: {"token": actor("SOURCE-REGISTER")["token"], "context": context}, reporting_agent_id: {"token": actor("DIVIDEND-REGISTER")["token"], "context": context}}}, private=True)
            workspace = runtime / "gateway-workspace"; workspace.mkdir()
            (workspace / "AGENTS.md").write_text("You verify synthetic IFRS document connectors. Use the installed ifrs_document_* and ifrs_source_retrieve tools. Never approve, post or release. Never invent a tool result. Native completion channels are outside this task.\n")
            gateway_config = {"gateway": {"mode": "local", "bind": "loopback", "port": gateway_port, "auth": {"mode": "token"}, "http": {"endpoints": {"chatCompletions": {"enabled": True}}}},
                              "models": {"providers": {"ollama": {"api": "ollama", "baseUrl": os.environ.get("OLLAMA_BASE_URL", "http://127.0.0.1:11434"), "apiKey": "ollama-local", "params": {"num_ctx": 16384}, "models": [{"id": "nemotron-3-nano:4b-mlx", "name": "IFRS synthetic verification"}]}}},
                              "agents": {"ownership": "explicit", "defaults": {"model": {"primary": model}, "modelPolicy": {"allow": [model]}, "systemAgent": {"agentId": "main"}, "heartbeat": {"agentId": "main"}},
                                         "entries": {"main": {"workspace": str(workspace), "model": {"primary": model}}, agent_id: {"workspace": str(workspace), "model": {"primary": model}, "sandbox": {"mode": "off"}}, reporting_agent_id: {"workspace": str(workspace), "model": {"primary": model}, "sandbox": {"mode": "off"}}}},
                              "talk": {"agentId": "main"}, "tools": {"allow": ["ifrs_document_inspect", "ifrs_document_resource", "ifrs_source_retrieve", "ifrs_document_draft", "ifrs_eligibility_draft", "ifrs_reporting_draft", "ifrs_document_tasks", "ifrs_accounting_calculate", "ifrs_document_request_review"]},
                              "plugins": {"allow": ["ifrs-documents", "ollama"], "load": {"paths": [str((args.openclaw / "plugins/ifrs-documents").resolve())]}, "entries": {"ifrs-documents": {"enabled": True, "config": {"configurationFile": str(private_tools)}}}}}
            write(runtime / "openclaw.json", gateway_config, private=True)
            gateway_env = dict(env, OPENCLAW_STATE_DIR=str(runtime / "gateway-state"), OPENCLAW_CONFIG_PATH=str(runtime / "openclaw.json"), OPENCLAW_GATEWAY_TOKEN=gateway_token, OLLAMA_API_KEY="ollama-local")
            gateway = spawn([str(args.openclaw_bin), "gateway", "--port", str(gateway_port), "--bind", "loopback"], args.openclaw, gateway_env, "gateway")
            for _ in range(120):
                if gateway.poll() is not None:
                    raise RuntimeError("Private gateway exited; inspect gateway.log")
                try:
                    if httpx.get(gateway_url + "/healthz", timeout=2).status_code == 200:
                        break
                except httpx.HTTPError:
                    pass
                time.sleep(.5)
            else:
                raise RuntimeError("Private gateway readiness timed out")
            response = httpx.post(gateway_url + "/v1/chat/completions", headers={"Authorization": "Bearer " + gateway_token},
                                  json={"model": "openclaw:" + agent_id, "stream": False, "user": "ifrs-synthetic-" + str(uuid.uuid4()), "messages": [{"role": "user", "content": "Call ifrs_document_inspect now with assetTypeId SOURCE-REGISTER. Report the revision and status returned by the tool. This is synthetic connector verification, not accounting approval."}]}, timeout=240)
            response.raise_for_status()
            write(out / "gateway-agent-observation.json", response.json())
            import sqlite3
            with sqlite3.connect(runtime / "documents/documents.sqlite") as db:
                reads = [json.loads(row[0]) for row in db.execute("SELECT body FROM events") if json.loads(row[0]).get("type") == "DOCUMENT_TOOL_READ" and json.loads(row[0]).get("principal") == actor("SOURCE-REGISTER")["name"]]
            assert reads, "The model did not actually invoke the bound document tool"
            write(out / "gateway-tool-audit.json", reads)
            receipt["phases"]["gatewayAgentTools"] = "PASS_REAL_GATEWAY_AND_MODEL_TOOL_CALL"
            import importlib.util
            worker_spec = importlib.util.spec_from_file_location("ifrs_document_worker", args.openclaw / "document-workflows/worker.py")
            worker = importlib.util.module_from_spec(worker_spec); worker_spec.loader.exec_module(worker)
            worker_result = worker.dispatch(dict(stateDirectory=str(runtime / "worker"), documentURL=doc_url, gatewayURL=gateway_url,
                                                 gatewayToken=gateway_token, operatorToken=principals[0]["token"], context=context,
                                                 assetRoutes={"ELIGIBILITY-MEMO": {"agentId": agent_id, "token": actor("ELIGIBILITY-MEMO")["token"]}}), limit=1)
            write(out / "gateway-document-task.json", worker_result)
            receipt["phases"]["proactiveDocumentTask"] = [attempt["status"] for attempt in worker_result["attempts"]]
            assert worker_result["attempts"] and worker_result["attempts"][-1]["status"] == "ARTIFACT_OBSERVED_REVIEW_REQUIRED", "Gateway task did not create a canonical owned draft after bounded retries; no narrative-only pass"
            drafted = command("inspect", {"assetTypeId": "ELIGIBILITY-MEMO"}, actor("ELIGIBILITY-MEMO"))
            assert drafted["head"]["status"] == "DRAFT" and drafted["revision"]["evidenceClass"] == "synthetic"
            assert drafted["revision"]["content"]["conclusion"] == "ELIGIBLE_SUBJECT_TO_REVIEW", "Agent draft contradicts the independently specified synthetic eligibility case"
            reporting_result = worker.dispatch(dict(stateDirectory=str(runtime / "reporting-worker"), documentURL=doc_url, gatewayURL=gateway_url,
                                                  gatewayToken=gateway_token, operatorToken=principals[0]["token"], context=context,
                                                  assetRoutes={"DIVIDEND-REGISTER": {"agentId": reporting_agent_id, "token": actor("DIVIDEND-REGISTER")["token"], "caseId": "SYNTHETIC-REPORTING-DIVIDEND"}}), limit=1)
            write(out / "gateway-reporting-task.json", reporting_result)
            receipt["phases"]["proactiveReportingTask"] = [a["status"] for a in reporting_result["attempts"]]
            assert reporting_result["attempts"] and reporting_result["attempts"][-1]["status"] == "ARTIFACT_OBSERVED_REVIEW_REQUIRED", "No canonical server-derived reporting artifact; narrative is not completion"
            reported = command("inspect", dict(assetTypeId="DIVIDEND-REGISTER"), actor("DIVIDEND-REGISTER"))
            assert reported["revision"]["content"]["typedProducerReceipt"]["caseId"] == "SYNTHETIC-REPORTING-DIVIDEND"
            assert reported["revision"]["content"]["advisoryDetermination"]["unrecognisedProposedDeclaredAmount"] == "1000.00"
            write(out / "gateway-reporting-artifact.json", reported)
        wrong = client.post("/tools/execute", headers={"Authorization": "Bearer " + actor("SOURCE-REGISTER")["token"]}, json=dict(dispatchId="self-approve", operation="approve", context=context, arguments={}))
        assert wrong.status_code == 403
        revised = command("draft", dict(assetTypeId="SOURCE-REGISTER", content={**source_content, "sourceGaps": source_content["sourceGaps"] + ["synthetic source-update event"]}, evidenceRefs=["synthetic:new-source-review"], expectedRevision=1, changeReason="synthetic upstream maintenance"), actor("SOURCE-REGISTER"))
        blocked = rag.post("/rag/evidence/entity/retrieve", json=dict(entityId=context["entityId"], period=context["period"], assetTypeId="RAG-RECEIPTS"))
        assert blocked.status_code == 409  # stale projection fails before delivery catches up
        post(rag, "/rag/evidence/entity/reconcile")
        assert rag.post("/rag/evidence/entity/retrieve", json=dict(entityId=context["entityId"], period=context["period"], assetTypeId="RAG-RECEIPTS")).status_code == 409
        for aid in reporting_targets:
            assert command("inspect", dict(assetTypeId=aid), actor(aid))["head"]["status"] == "STALE", "Source update failed to invalidate typed reporting draft"
        receipt["phases"]["typedReportingStalePropagation"] = "PASS"
        histories.append(revised)
        write(out / "document-lifecycle.json", histories)
        receipt["phases"]["deployedSyntheticLifecycleAndProjection"] = "PASS"
        receipt["phases"]["representativeAccountingControls"] = {"result": "PASS", "cases": len(calculations), "scope": "SYNTHETIC_ADVISORY_CONTROLS"}
        if args.live_model:
            query = {**section_receipts["01"]["request"], "question": "An entity has public accountability. Local law permits the SME standard. Can its statements claim conformity? Explain the applicable condition and cite the provided chunk IDs. Do not confuse a prohibition with permission."}
            observation = post(rag, "/rag/evidence/query", query)
            write(out / "live-model-observation.json", observation)
            receipt["phases"]["liveModel"] = {"generationStatus": observation["generationStatus"], "accountingCorrectness": "REQUIRES_INDEPENDENT_REVIEW"}
        receipt["phases"].setdefault("gatewayAgentTools", "NOT_EXECUTED_BY_THIS_COMMAND")
        receipt["result"] = "PASS_CONNECTOR_SCOPE_ONLY"
    except Exception as exc:
        receipt["result"] = "FAIL"
        receipt["error"] = type(exc).__name__ + ": " + str(exc)
        raise
    finally:
        for process in reversed(processes):
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
        for stream in logs:
            stream.close()
        receipt["artifacts"] = [{"path": p.name, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(out.glob("*.json"))]
        changed_inputs = fingerprints() != receipt["inputSHA256"]
        if changed_inputs:
            receipt["result"] = "FAIL"
            receipt["inputIntegrity"] = "SOURCE_CHANGED_DURING_VERIFICATION"
        else:
            receipt["inputIntegrity"] = "UNCHANGED"
        write(out / "receipt.json", receipt)
        print(json.dumps({"result": receipt["result"], "evidenceClass": "synthetic", "receipt": str(out / "receipt.json")}))
        if changed_inputs:
            raise RuntimeError("Source changed during verification; rerun on committed inputs")


if __name__ == "__main__":
    main()
