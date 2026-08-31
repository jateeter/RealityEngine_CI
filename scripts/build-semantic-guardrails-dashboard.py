#!/usr/bin/env python3
"""Generate the Semantic Guardrails Grafana dashboard.

The dashboard visualizes the auditable surface of the OWL semantic guardrails
(RealityEngine_Machines docs/SEMANTIC_AUDIT_CONTRACT.md) across the four
integration paths that feed the Perception Engine: HealthKit bridge, MQTT,
MCP/OpenAI + OpenClaw (ACP), and localAIStack.

It is written as a generator rather than hand-maintained JSON so panel layout
stays consistent and the file can be regenerated deterministically:

  python3 scripts/build-semantic-guardrails-dashboard.py --write
  python3 scripts/build-semantic-guardrails-dashboard.py --check   # CI drift gate
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
OUTPUT = REPO_ROOT / "config" / "dashboards" / "semantic-guardrails.json"

PROM = {"type": "prometheus", "uid": "prometheus"}


def target(expr: str, legend: str, ref: str = "A") -> dict:
    return {"datasource": PROM, "editorMode": "code", "expr": expr,
            "legendFormat": legend, "range": True, "refId": ref}


def stat(panel_id: int, title: str, description: str, targets: list[dict],
         grid: dict, *, unit: str | None = None, mappings: list | None = None,
         steps: list | None = None, text_mode: str = "auto") -> dict:
    defaults: dict = {
        "mappings": mappings or [],
        "thresholds": {"mode": "absolute",
                       "steps": steps or [{"color": "text", "value": None}]},
    }
    if unit:
        defaults["unit"] = unit
    return {
        "datasource": PROM,
        "description": description,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "gridPos": grid,
        "id": panel_id,
        "options": {
            "colorMode": "background" if mappings or steps else "value",
            "graphMode": "none",
            "justifyMode": "center",
            "orientation": "auto",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "textMode": text_mode,
        },
        "targets": targets,
        "title": title,
        "type": "stat",
    }


def timeseries(panel_id: int, title: str, description: str, targets: list[dict],
               grid: dict, *, unit: str | None = None,
               max_value: float | None = None,
               min_value: float | None = None,
               fill: int = 0) -> dict:
    defaults: dict = {
        "custom": {
            "drawStyle": "line",
            "fillOpacity": fill,
            "lineInterpolation": "linear",
            "lineWidth": 2,
            "pointSize": 5,
            "showPoints": "auto",
        },
        "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
    }
    if unit:
        defaults["unit"] = unit
    if max_value is not None:
        defaults["max"] = max_value
    if min_value is not None:
        defaults["min"] = min_value
    return {
        "datasource": PROM,
        "description": description,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "gridPos": grid,
        "id": panel_id,
        "options": {
            "legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "bottom"},
            "tooltip": {"mode": "multi", "sort": "none"},
        },
        "targets": targets,
        "title": title,
        "type": "timeseries",
    }


def row(panel_id: int, title: str, y: int) -> dict:
    return {"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
            "id": panel_id, "panels": [], "title": title, "type": "row"}


def build() -> dict:
    panels: list[dict] = []

    # ── Row 1: corpus semantics availability ────────────────────────────────
    panels.append(row(1, "Corpus Semantics — is the guardrail armed?", 0))
    panels.append(stat(
        2, "Semantics Manifest",
        "1 when the PE resolved RealityEngine_Machines semantics/abox-manifest.json. "
        "At 0 no runtime record can carry a corpus IRI and every guardrail below is blind.",
        [target("max(semantic_manifest_available)", "manifest")],
        {"h": 5, "w": 5, "x": 0, "y": 1},
        mappings=[{"options": {"0": {"text": "MISSING"}, "1": {"text": "ARMED"}}, "type": "value"}],
        steps=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
    ))
    panels.append(stat(
        3, "Machines With Semantic Identity",
        "Machines carrying an ABox IRI + content hash in the manifest.",
        [target("max(semantic_manifest_machines)", "machines")],
        {"h": 5, "w": 5, "x": 5, "y": 1},
    ))
    panels.append(stat(
        4, "Escalations From Non-RED Determinations",
        "Escalation-class dispatches (emergency-dispatch, urgent-intervention) whose "
        "determination carried an explicit non-RED RAG status. This contradicts the "
        "re:EscalationDetermination axiom and must stay at zero. 'unstated' is excluded: "
        "the axiom is open-world, so an absent status is consistent.",
        [target('sum(semantic_escalation_dispatches_total{rag!="RED",rag!="unstated"})', "violations")],
        {"h": 5, "w": 7, "x": 10, "y": 1},
        steps=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
    ))
    panels.append(stat(
        5, "Audit Buffer Depth",
        "re:PerceptionEvent records held in the PE ring buffer (capacity 1000). "
        "Pinned at capacity means older evidence is being evicted.",
        [target("max(semantic_audit_buffer_records)", "records")],
        {"h": 5, "w": 7, "x": 17, "y": 1},
    ))

    # ── Row 2: per-integration corpus join health ───────────────────────────
    panels.append(row(10, "Integration Ingress — HealthKit · MQTT · MCP/OpenAI · localAIStack", 6))
    panels.append(timeseries(
        11, "Perception Event Rate by Integration",
        "re:PerceptionEvent records per second, attributed to the upstream that produced "
        "the write. This is the ingress volume each integration contributes to the "
        "universal Reality Event.",
        [target("sum by (integration) (rate(semantic_perception_events_total[5m]))", "{{integration}}")],
        {"h": 8, "w": 12, "x": 0, "y": 7}, unit="reqps", fill=10,
    ))
    panels.append(timeseries(
        12, "Corpus Join Rate by Integration",
        "Share of each integration's writes that resolved to a corpus ABox IRI. Below 1 "
        "means the PE is writing into regions it cannot describe semantically — those "
        "events are unauditable. A new integration typically starts low until its "
        "machines are added to the corpus.",
        [target(
            "sum by (integration) (rate(semantic_perception_events_iri_joined_total[5m]))\n"
            "/ clamp_min(sum by (integration) (rate(semantic_perception_events_total[5m])), 0.0001)",
            "{{integration}}")],
        {"h": 8, "w": 12, "x": 12, "y": 7}, unit="percentunit",
        min_value=0, max_value=1, fill=0,
    ))

    # ── Row 3: dispatch guardrails ──────────────────────────────────────────
    panels.append(row(20, "Dispatch Guardrails — what actions fired, and on what evidence", 15))
    panels.append(timeseries(
        21, "Escalation Dispatches by RAG Status",
        "Escalation-class actions dispatched, split by the RAG status of the determination "
        "behind them. RED is the expected path. 'unstated' is open-world consistent but "
        "worth watching as a corpus data-quality signal. Any other series is a live "
        "violation of re:EscalationDetermination.",
        [target("sum by (rag) (rate(semantic_escalation_dispatches_total[5m]))", "{{rag}}")],
        {"h": 8, "w": 12, "x": 0, "y": 16}, unit="reqps", fill=10,
    ))
    panels.append(timeseries(
        22, "Dispatch Records — Total vs Corpus-Joined",
        "Dispatch ledger records created, and how many carry a resolvable machine IRI. "
        "A widening gap means dispatches are firing that an auditor cannot trace back to "
        "the determination that caused them.",
        [target("rate(semantic_dispatch_records_total[5m])", "created", "A"),
         target("rate(semantic_dispatch_records_iri_joined_total[5m])", "corpus-joined", "B")],
        {"h": 8, "w": 12, "x": 12, "y": 16}, unit="reqps",
    ))

    # ── Row 4: integration transport health (existing metrics) ──────────────
    panels.append(row(30, "Integration Transport Health", 24))
    panels.append(timeseries(
        31, "MQTT Ingest Outcomes",
        "MQTT bridge message disposition. Rejected and unmatched messages never become "
        "perception events, so they are invisible to the semantic guardrails above — "
        "this panel is where that loss shows up.",
        [target("rate(mqtt_messages_received_total[5m])", "received", "A"),
         target("rate(mqtt_messages_mapped_total[5m])", "mapped", "B"),
         target("rate(mqtt_messages_rejected_total[5m])", "rejected", "C"),
         target("rate(mqtt_messages_unmatched_total[5m])", "unmatched", "D"),
         target("rate(mqtt_pushes_triggered_total[5m])", "pushes triggered", "E")],
        {"h": 8, "w": 12, "x": 0, "y": 25}, unit="reqps",
    ))
    panels.append(timeseries(
        32, "PE Sources and Push Cadence",
        "Registered sources and engine step rate — the denominator for everything above.",
        [target("max(perception_engine_sources_total)", "sources", "A"),
         target("rate(perception_engine_global_step[5m])", "pushes/sec", "B")],
        {"h": 8, "w": 12, "x": 12, "y": 25},
    ))
    panels.append(stat(
        33, "MQTT Bridge",
        "MQTT bridge connection state.",
        [target("max(mqtt_bridge_connected)", "connected")],
        {"h": 4, "w": 8, "x": 0, "y": 33},
        mappings=[{"options": {"0": {"text": "DISCONNECTED"}, "1": {"text": "CONNECTED"}}, "type": "value"}],
        steps=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
    ))
    panels.append(stat(
        34, "Integrations Producing Events",
        "Distinct integrations that have produced at least one perception event.",
        [target("count(count by (integration) (semantic_perception_events_total))", "integrations")],
        {"h": 4, "w": 8, "x": 8, "y": 33},
    ))
    panels.append(stat(
        35, "Unattributed Writes",
        "Perception events with no originating integration recorded. These are auditable "
        "against the corpus but not against an upstream; a rising count means a new "
        "ingress path needs an origin tag.",
        [target('sum(semantic_perception_events_total{integration="unattributed"})', "events")],
        {"h": 4, "w": 8, "x": 16, "y": 33},
        steps=[{"color": "text", "value": None}, {"color": "yellow", "value": 1}],
    ))

    return {
        "annotations": {"list": []},
        "editable": True,
        "fiscalYearStartMonth": 0,
        "graphTooltip": 1,
        "id": None,
        "links": [],
        "liveNow": False,
        "panels": panels,
        "refresh": "30s",
        "schemaVersion": 39,
        "style": "dark",
        "tags": ["reality-engine", "semantics", "guardrails", "audit",
                 "healthkit", "mqtt", "localaistack", "openclaw"],
        "templating": {"list": []},
        "time": {"from": "now-6h", "to": "now"},
        "timepicker": {},
        "timezone": "",
        "title": "Semantic Guardrails",
        "uid": "semantic-guardrails",
        "version": 1,
        "weekStart": "",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="write the dashboard JSON")
    parser.add_argument("--check", action="store_true", help="fail if the checked-in file differs")
    args = parser.parse_args()

    rendered = json.dumps(build(), indent=2) + "\n"
    if args.check:
        if not OUTPUT.exists():
            print(f"DRIFT missing {OUTPUT.relative_to(REPO_ROOT)}", file=sys.stderr)
            return 1
        if OUTPUT.read_text() != rendered:
            print(f"DRIFT stale {OUTPUT.relative_to(REPO_ROOT)} — regenerate with --write",
                  file=sys.stderr)
            return 1
        print(f"semantic-guardrails dashboard: OK ({len(build()['panels'])} panels)")
        return 0
    if args.write:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(rendered)
        print(f"wrote {OUTPUT.relative_to(REPO_ROOT)} ({len(build()['panels'])} panels)")
        return 0
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
