#!/usr/bin/env python3
"""
generate.py — build runtime-specific OpenAPI 3.1.0 YAML from SURFACE_SPEC.md
              plus a per-runtime overlay (title / version / servers).

Routes are sourced from SURFACE_SPEC.md (authoritative).
Operation bodies (summaries, schemas, parameters) are sourced from a rich
operations catalogue embedded below; unknown routes get a documented skeleton.

Usage:
  python3 scripts/openapi/generate.py \\
    --spec  path/to/SURFACE_SPEC.md \\
    --overlay scripts/openapi/overlays/cpp.yaml \\
    --out-re  docs/openapi/cpp-re.yaml \\
    --out-pe  docs/openapi/cpp-pe.yaml
"""

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("pip3 install pyyaml", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Route summaries — METHOD:openapi-path → summary string
# ---------------------------------------------------------------------------
SUMMARIES: dict[str, str] = {
    # RE — Info & Health
    "GET:/":                                                   "Service root",
    "GET:/api":                                                "API index",
    "GET:/api/health":                                         "Health check",
    "GET:/api/metrics":                                        "Prometheus text-format metrics",
    # RE — Configuration
    "GET:/api/config":                                         "Runtime configuration snapshot",
    "PUT:/api/config/dimension":                               "Set vector dimension",
    "PUT:/api/config/threshold":                               "Set match threshold",
    # RE — Runtime Introspection
    "GET:/api/runtime/metrics":                                "Engine and worker-pool metrics",
    "GET:/api/runtime/vector-space":                           "Perceptual-space shape and mapping version",
    "GET:/api/runtime/storage-footprint":                      "Per-machine cell-storage footprint",
    "GET:/api/runtime/options":                                "Response-projection options",
    "PATCH:/api/runtime/options":                              "Update response-projection options",
    # RE — Vectors
    "POST:/api/vectors/search":                                "Search vectors by cosine similarity",
    "POST:/api/vectors":                                       "Store a vector",
    "GET:/api/vectors/{id}":                                   "Read a vector",
    "DELETE:/api/vectors/{id}":                                "Delete a vector",
    # RE — Sequences
    "GET:/api/sequences":                                      "List sequences",
    "POST:/api/sequences":                                     "Create sequence",
    "GET:/api/sequences/{id}":                                 "Read a sequence",
    "DELETE:/api/sequences/{id}":                              "Delete a sequence",
    "POST:/api/sequences/{id}/reset":                          "Reset sequence state",
    "POST:/api/sequences/{id}/vectors":                        "Append vectors to sequence",
    "POST:/api/sequences/persist":                             "Persist sequences to Qdrant",
    # RE — Engine
    "GET:/api/engine/stats":                                   "Engine statistics",
    "GET:/api/engine/active":                                  "Active-vector compatibility endpoint",
    "GET:/api/engine/history":                                 "Audit trail of POST /api/engine/process calls",
    "GET:/api/engine/osre-history":                            "OSRE-History — output reality event vector per step",
    "GET:/api/engine/isre-history":                            "ISRE-History — input space reality event vector per step",
    "POST:/api/engine/process":                                "Process input vector across all machines",
    "POST:/api/engine/reset":                                  "Reset machine, engine, and perception state",
    # RE — Machines
    "GET:/api/machines":                                       "List loaded machines",
    "POST:/api/machines":                                      "Import a machine",
    "GET:/api/machines/{id}":                                  "Read a machine",
    "PUT:/api/machines/{id}":                                  "Replace a machine",
    "PATCH:/api/machines/{id}":                                "Patch machine metadata",
    "DELETE:/api/machines/{id}":                               "Remove a machine",
    "POST:/api/machines/{id}/process":                         "Process machine-local input vector",
    "POST:/api/machines/{id}/process-universal":               "Resolve universal input and process one machine",
    "POST:/api/machines/{id}/whatif":                          "What-if with machine-local input vector",
    "POST:/api/machines/{id}/whatif-universal":                "What-if with universal input space",
    "POST:/api/machines/process-universal/all":                "Resolve universal input and process all machines",
    "GET:/api/machines/json/list":                             "List machine JSON files on disk",
    "GET:/api/machines/json/{name}":                           "Load machine JSON file by filename",
    "POST:/api/machines/json/import":                          "Import machine JSON file by filename",
    "GET:/api/machines/{id}/export":                           "Export machine to JSON",
    "GET:/api/machines/{id}/checkpoints":                      "List machine checkpoints",
    "POST:/api/machines/{id}/checkpoints":                     "Create machine checkpoint",
    "POST:/api/machines/{machineId}/checkpoints/{cpId}/restore": "Restore machine from checkpoint",
    "DELETE:/api/machines/{machineId}/checkpoints/{cpId}":     "Delete machine checkpoint",
    # RE — Machine Graph
    "GET:/api/machine-graph":                                  "Machine graph — nodes and overlap edges",
    # RE — Perceptual Simulation
    "POST:/api/perceptual-simulation/configure/chunk":         "Append vectors and config to staging buffer",
    "POST:/api/perceptual-simulation/configure/commit":        "Commit staged simulation vectors",
    "POST:/api/perceptual-simulation/start":                   "Mark simulation running",
    "POST:/api/perceptual-simulation/stop":                    "Stop simulation",
    "POST:/api/perceptual-simulation/step":                    "Advance simulation by one step",
    "POST:/api/perceptual-simulation/reset":                   "Reset simulation state",
    "GET:/api/perceptual-simulation/state":                    "Current simulation state",
    "GET:/api/perceptual-simulation/history":                  "Bounded simulation step history",
    # RE — Sampler
    "POST:/api/sampler/start":                                 "Start sampler",
    "POST:/api/sampler/stop":                                  "Stop sampler",
    "POST:/api/sampler/sample":                                "Record a perceptual sample",
    "GET:/api/sampler/stats":                                  "Sampler statistics",
    # RE — Perception
    "POST:/api/perception/observe":                            "Observe raw sensor values",
    "POST:/api/perception/diagnostic":                         "Diagnose machine input mapping",
    "POST:/api/perceive":                                      "Process a perceptual-space vector through the reality engine",
    # RE — Governance
    "GET:/api/governance/route":                               "Resolve paging decision for a fired output",
    # RE — Demos
    "GET:/api/demo/multi-step":                                "Multi-step sequence demonstration",
    "GET:/api/demo/data-center":                               "Data-center scenario demonstration",
    "GET:/api/demo/kleene-star":                               "Kleene-star operator demonstration",
    # PE — Info & Health
    # GET:/ shared with RE above
    "GET:/api/state":                                          "Current PE state snapshot",
    # GET:/api/health shared with RE above
    # PE — Push Cycle
    "POST:/api/push":                                          "Push assembled perceptual vector to RE",
    "GET:/api/push/{id}":                                      "Read push result",
    "POST:/api/auto/start":                                    "Start automatic push cycle",
    "POST:/api/auto/stop":                                     "Stop automatic push cycle",
    # PE — Configuration & Reset
    "PATCH:/api/config":                                       "Update PE matching configuration",
    "POST:/api/reset":                                         "Reset PE state",
    # PE — Sources & Sensors
    "GET:/api/sources":                                        "List test sources",
    "POST:/api/sources":                                       "Create test source",
    "PATCH:/api/sources/{id}":                                 "Update test source",
    "DELETE:/api/sources/{id}":                                "Delete test source",
    "POST:/api/sources/bootstrap-from-machines":               "Bootstrap test sources from machine corpus",
    "POST:/api/sensors/{sensorId}":                            "Ingest a sensor reading",
    # PE — Signals
    "POST:/api/signals":                                       "Ingest a signal batch",
    # PE — Integrations
    "GET:/api/integrations/status":                            "All integration provider status",
    "POST:/api/integrations/completions":                      "Request AI completion from configured provider",
    "GET:/api/integrations/ollama/status":                     "Ollama integration status",
    "POST:/api/integrations/ollama/dispatch":                  "Dispatch prompt to Ollama",
    "GET:/api/integrations/openai/status":                     "OpenAI-compatible integration status",
    "POST:/api/integrations/openai/dispatch":                  "Dispatch prompt to OpenAI-compatible endpoint",
    "GET:/api/integrations/acp/status":                        "ACP / OpenClaw integration status",
    "POST:/api/integrations/acp/dispatch":                     "Dispatch request to ACP / OpenClaw gateway",
    "GET:/api/integrations/healthkit/status":                  "HealthKit bridge status",
    "POST:/api/integrations/healthkit/ingest":                 "Ingest HealthKit samples",
    "GET:/api/integrations/carekit/status":                    "CareKit bridge status",
    "POST:/api/integrations/carekit/ingest":                   "Ingest CareKit samples",
    "GET:/api/integrations/localai/status":                    "localAI integration status",
    "GET:/api/integrations/localai/catalog":                   "localAI model catalog",
    "POST:/api/integrations/localai/bootstrap":                "Bootstrap localAI models",
    "POST:/api/integrations/localai/invoke":                   "Invoke a localAI model",
    # PE — Dispatch & Triggers
    "GET:/api/dispatch/ledger":                                "Dispatch event ledger",
    "GET:/api/dispatch/records/{id}":                          "Read dispatch record",
    "PATCH:/api/dispatch/records/{id}":                        "Update dispatch record",
    "GET:/api/triggers/status":                                "Trigger evaluation status",
    # PE — MQTT Bridge
    "GET:/api/mqtt/status":                                    "MQTT bridge status",
    "GET:/api/mqtt/mappings":                                  "MQTT sensor mapping registry",
    "PUT:/api/mqtt/mappings":                                  "Replace MQTT sensor mapping registry",
    "POST:/api/mqtt/enable":                                   "Enable MQTT bridge",
    "POST:/api/mqtt/disable":                                  "Disable MQTT bridge",
}

# Paths that carry path parameters → parameter definitions
PATH_PARAMS: dict[str, list[dict]] = {
    "{id}": [{"name": "id", "in": "path", "required": True,
               "schema": {"type": "string"}}],
    "{name}": [{"name": "name", "in": "path", "required": True,
                 "schema": {"type": "string"}}],
    "{sensorId}": [{"name": "sensorId", "in": "path", "required": True,
                     "schema": {"type": "string"}}],
    "{machineId}": [{"name": "machineId", "in": "path", "required": True,
                      "schema": {"type": "string"}}],
    "{cpId}": [{"name": "cpId", "in": "path", "required": True,
                 "schema": {"type": "string"}}],
}

# ---------------------------------------------------------------------------
# Shared component schemas
# ---------------------------------------------------------------------------
def re_components() -> dict:
    return {
        "parameters": {
            "MachineId": {"name": "id", "in": "path", "required": True,
                          "schema": {"type": "string"}},
        },
        "responses": {
            "NotFound": {
                "description": "Resource not found",
                "content": {"application/json": {
                    "schema": {"$ref": "#/components/schemas/Error"}}},
            },
            "InternalError": {
                "description": "Internal server error",
                "content": {"application/json": {
                    "schema": {"$ref": "#/components/schemas/Error"}}},
            },
        },
        "schemas": {
            "Object": {"type": "object", "additionalProperties": True},
            "Vector": {"type": "array", "items": {"type": "number", "format": "double"}},
            "Success": {"type": "object", "properties": {
                "success": {"type": "boolean"}}},
            "Error": {"type": "object", "properties": {
                "error": {"type": "string"}}},
            "Health": {"type": "object", "properties": {
                "status":    {"type": "string", "example": "healthy"},
                "timestamp": {"type": "number"},
                "version":   {"type": "string"}}},
            "RealityConfig": {"type": "object", "properties": {
                "eventDimension": {"type": "integer", "example": 7680},
                "matchThreshold":  {"type": "number", "example": 0.5},
                "qdrantUrl":       {"type": "string"},
                "collectionName":  {"type": "string", "example": "reality-vectors"}}},
            "RuntimeOptions": {"type": "object", "properties": {
                "historyLimit":          {"type": "integer", "example": 256},
                "includeMachineResults": {"type": "boolean"},
                "includePerceptualSpace": {"type": "boolean"}}},
            "RuntimeOptionsPatch": {"type": "object", "properties": {
                "historyLimit":           {"type": "integer", "minimum": 0},
                "includeMachineResults":  {"type": "boolean"},
                "includePerceptualSpace": {"type": "boolean"}}},
            "Region": {"type": "object", "required": ["offset", "length"],
                       "properties": {
                           "offset": {"type": "integer"},
                           "length": {"type": "integer"}}},
            "Machine": {
                "type": "object", "additionalProperties": True,
                "description": "RealityEngine machine JSON.",
                "properties": {
                    "id":      {"type": "string"},
                    "name":    {"type": "string"},
                    "version": {"type": "string"},
                    "perceptualMapping": {"type": "object", "additionalProperties": True},
                    "sequences": {"type": "array",
                                  "items": {"type": "object", "additionalProperties": True}},
                }},
            "MachineMutationResponse": {"type": "object", "properties": {
                "success": {"type": "boolean"},
                "machine": {"$ref": "#/components/schemas/Machine"},
                "message": {"type": "string"}}},
            "MachineTransitionResult": {
                "type": "object", "additionalProperties": True,
                "properties": {
                    "inputEvent":    {"$ref": "#/components/schemas/Vector"},
                    "timestamp":      {"type": "number"},
                    "machineOutput":  {"type": "array",
                                       "items": {"type": "number", "format": "double"},
                                       "nullable": True},
                    "sequenceResults": {"type": "array",
                                        "items": {"type": "object",
                                                  "additionalProperties": True}}}},
            "SimulationStep": {"type": "object", "properties": {
                "stepNumber":    {"type": "integer"},
                "timestamp":     {"type": "number"},
                "perceptualSpace": {"$ref": "#/components/schemas/Vector"},
                "machineResults": {"type": "object", "additionalProperties": True}}},
            "SimulationConfigureChunk": {"type": "object", "properties": {
                "reset":   {"type": "boolean"},
                "vectors": {"type": "array", "items": {"$ref": "#/components/schemas/Vector"}},
                "config":  {"type": "object", "additionalProperties": True}}},
            "PerceiveRequest": {"type": "object", "required": ["vector"],
                                "properties": {
                                    "vector":  {"$ref": "#/components/schemas/Vector"},
                                    "compact": {"type": "boolean"},
                                    "includeMachineResults":  {"type": "boolean"},
                                    "includePerceptualSpace": {"type": "boolean"}}},
            "PagingDecision": {"type": "object", "properties": {
                "machineId":    {"type": "string"},
                "sequenceId":   {"type": "string"},
                "ragStatusCode": {"type": "string", "enum": ["GREEN", "AMBER", "RED"]},
                "ownerTeam":    {"type": "string"},
                "runbook":      {"type": "string"},
                "source":       {"type": "string",
                                  "enum": ["rule-with-override", "rule-only",
                                           "machine-fallback"]}}},
        },
    }


def pe_components() -> dict:
    return {
        "responses": {
            "NotFound": {
                "description": "Resource not found",
                "content": {"application/json": {
                    "schema": {"$ref": "#/components/schemas/Error"}}},
            },
        },
        "schemas": {
            "Object": {"type": "object", "additionalProperties": True},
            "Success": {"type": "object", "properties": {
                "success": {"type": "boolean"}}},
            "Error": {"type": "object", "properties": {
                "error": {"type": "string"}}},
            "Health": {"type": "object", "properties": {
                "status":    {"type": "string", "example": "healthy"},
                "timestamp": {"type": "number"},
                "version":   {"type": "string"}}},
            "Source": {"type": "object", "properties": {
                "id":          {"type": "string"},
                "machineId":   {"type": "string"},
                "sensorId":    {"type": "string"},
                "enabled":     {"type": "boolean"},
                "intervalMs":  {"type": "integer"}}},
            "HealthKitIngestRequest": {
                "type": "object",
                "description": "Single sample (flat) or batch.",
                "properties": {
                    "type":      {"type": "string",
                                  "example": "HKQuantityTypeIdentifierHeartRate"},
                    "value":     {"type": "number"},
                    "sourceName": {"type": "string"},
                    "bridgeId":  {"type": "string"},
                    "samples":   {"type": "array",
                                  "items": {"type": "object",
                                            "additionalProperties": True}}}},
            "HealthKitIngestResponse": {"type": "object", "properties": {
                "success":  {"type": "boolean"},
                "bridgeId": {"type": "string"},
                "resolved": {"type": "array",
                             "items": {"type": "object", "additionalProperties": True}},
                "unmapped": {"type": "array",
                             "items": {"type": "object", "additionalProperties": True}}}},
            "CareKitIngestRequest": {"type": "object", "properties": {
                "bridgeId":       {"type": "string"},
                "sampleType":     {"type": "string"},
                "sourceMappingId": {"type": "string"},
                "values":         {"type": "array",
                                   "items": {"type": "number"}}}},
            "CareKitIngestResponse": {"type": "object", "properties": {
                "success":  {"type": "boolean"},
                "bridgeId": {"type": "string"},
                "results":  {"type": "array",
                             "items": {"type": "object", "additionalProperties": True}}}},
            "MqttBridgeStatus": {"type": "object", "properties": {
                "enabled":       {"type": "boolean"},
                "connected":     {"type": "boolean"},
                "brokerUrl":     {"type": "string"},
                "clientId":      {"type": "string"},
                "mappingCount":  {"type": "integer"}}},
            "MqttMappingRule": {"type": "object", "required": ["topic", "sensorId"],
                                "properties": {
                                    "topic":    {"type": "string"},
                                    "sensorId": {"type": "string"},
                                    "field":    {"type": "string"},
                                    "scale":    {"type": "number"},
                                    "offset":   {"type": "number"}}},
            "MqttMappingsResponse": {"type": "object", "properties": {
                "mappings": {"type": "array",
                             "items": {"$ref": "#/components/schemas/MqttMappingRule"}}}},
            "DispatchRecord": {"type": "object", "properties": {
                "id":         {"type": "string"},
                "machineId":  {"type": "string"},
                "sequenceId": {"type": "string"},
                "timestamp":  {"type": "number"},
                "status":     {"type": "string"}}},
        },
    }


# ---------------------------------------------------------------------------
# Request-body hints for known POST/PUT/PATCH routes
# ---------------------------------------------------------------------------
def request_body(method: str, path: str) -> dict | None:
    if method not in ("POST", "PUT", "PATCH"):
        return None

    schema_ref: dict | None = None

    if path == "/api/machines" and method == "POST":
        schema_ref = {"$ref": "#/components/schemas/Machine"}
    elif path in ("/api/machines/{id}", ) and method in ("PUT",):
        schema_ref = {"$ref": "#/components/schemas/Machine"}
    elif path == "/api/machines/{id}" and method == "PATCH":
        schema_ref = {"type": "object", "additionalProperties": True}
    elif path == "/api/engine/process":
        schema_ref = {"type": "object", "required": ["vector"],
                      "properties": {"vector": {"$ref": "#/components/schemas/Vector"}}}
    elif path in ("/api/machines/{id}/process", "/api/machines/{id}/whatif"):
        schema_ref = {"type": "object", "required": ["inputEvent"],
                      "properties": {"inputEvent": {"$ref": "#/components/schemas/Vector"}}}
    elif path in ("/api/machines/{id}/process-universal",
                  "/api/machines/{id}/whatif-universal",
                  "/api/machines/process-universal/all"):
        schema_ref = {"type": "object", "required": ["universalInputSpace"],
                      "properties": {"universalInputSpace": {"$ref": "#/components/schemas/Vector"}}}
    elif path == "/api/perceive":
        schema_ref = {"$ref": "#/components/schemas/PerceiveRequest"}
    elif path == "/api/perceptual-simulation/configure/chunk":
        schema_ref = {"$ref": "#/components/schemas/SimulationConfigureChunk"}
    elif path == "/api/runtime/options" and method == "PATCH":
        schema_ref = {"$ref": "#/components/schemas/RuntimeOptionsPatch"}
    elif path == "/api/integrations/healthkit/ingest":
        schema_ref = {"$ref": "#/components/schemas/HealthKitIngestRequest"}
    elif path == "/api/integrations/carekit/ingest":
        schema_ref = {"$ref": "#/components/schemas/CareKitIngestRequest"}
    elif path == "/api/mqtt/mappings" and method == "PUT":
        schema_ref = {"$ref": "#/components/schemas/MqttMappingsResponse"}

    if schema_ref is None:
        schema_ref = {"type": "object", "additionalProperties": True}

    return {"required": method in ("POST", "PUT"),
            "content": {"application/json": {"schema": schema_ref}}}


# ---------------------------------------------------------------------------
# Response schema hints for known routes
# ---------------------------------------------------------------------------
def response_schema(method: str, path: str) -> dict:
    for suffix in ("/health",):
        if path.endswith(suffix):
            return {"$ref": "#/components/schemas/Health"}
    if path == "/api/machines" and method == "GET":
        return {"type": "object",
                "properties": {
                    "machines": {"type": "array",
                                 "items": {"$ref": "#/components/schemas/Machine"}}}}
    if path in ("/api/machines/{id}", ) and method == "GET":
        return {"type": "object",
                "properties": {"machine": {"$ref": "#/components/schemas/Machine"}}}
    if path in ("/api/machines",) and method == "POST":
        return {"$ref": "#/components/schemas/MachineMutationResponse"}
    if "/machines/{id}" in path and method in ("PUT", "GET"):
        if path.endswith("/{id}") or path.endswith("/export"):
            return {"$ref": "#/components/schemas/MachineMutationResponse"}
    if path in ("/api/machines/{id}/process",
                "/api/machines/{id}/process-universal",
                "/api/machines/{id}/whatif",
                "/api/machines/{id}/whatif-universal"):
        return {"$ref": "#/components/schemas/MachineTransitionResult"}
    if path == "/api/perceive":
        return {"$ref": "#/components/schemas/SimulationStep"}
    if path == "/api/governance/route":
        return {"$ref": "#/components/schemas/PagingDecision"}
    if path == "/api/config" and method == "GET":
        return {"$ref": "#/components/schemas/RealityConfig"}
    if path in ("/api/runtime/options",) and method in ("GET", "PATCH"):
        return {"$ref": "#/components/schemas/RuntimeOptions"}
    if path == "/api/mqtt/status":
        return {"$ref": "#/components/schemas/MqttBridgeStatus"}
    if path == "/api/mqtt/mappings":
        return {"$ref": "#/components/schemas/MqttMappingsResponse"}
    if path == "/api/integrations/healthkit/ingest":
        return {"$ref": "#/components/schemas/HealthKitIngestResponse"}
    if path == "/api/integrations/carekit/ingest":
        return {"$ref": "#/components/schemas/CareKitIngestResponse"}
    if path.startswith("/api/dispatch/records/"):
        return {"$ref": "#/components/schemas/DispatchRecord"}
    if method in ("DELETE", "POST") and not path.endswith("/search"):
        return {"$ref": "#/components/schemas/Success"}
    return {"$ref": "#/components/schemas/Object"}


# ---------------------------------------------------------------------------
# SURFACE_SPEC.md parser
# ---------------------------------------------------------------------------
def parse_surface_spec(spec_path: str) -> dict[str, list[tuple[str, str, str]]]:
    """
    Returns {'re': [(tag, method, openapi_path), ...],
             'pe': [(tag, method, openapi_path), ...]}
    """
    text = Path(spec_path).read_text()
    # Split at horizontal rules to isolate RE and PE sections
    parts = re.split(r'\n---\n', text)
    # Structure: intro | RE | PE | Gap Register | ...
    re_text = parts[1] if len(parts) > 1 else ""
    pe_text = parts[2] if len(parts) > 2 else ""

    protocol_to_method = {"SSE": "GET", "WebSocket": "GET"}

    def extract(section: str) -> list[tuple[str, str, str]]:
        routes: list[tuple[str, str, str]] = []
        tag = "General"
        for line in section.splitlines():
            m = re.match(r'^#{2,4}\s+(.+)', line)
            if m:
                tag = m.group(1).strip()
                continue
            # table row: | METHOD_OR_PROTOCOL | `/path` | ...
            m = re.match(r'\|\s*(\w+)\s*\|\s*`([^`]+)`\s*\|', line)
            if m:
                raw_method = m.group(1).upper()
                path_raw   = m.group(2)
                if raw_method in ("METHOD", "PROTOCOL"):   # header row
                    continue
                method = protocol_to_method.get(raw_method, raw_method)
                openapi_path = re.sub(r':(\w+)', r'{\1}', path_raw)
                routes.append((tag, method, openapi_path))
        return routes

    return {"re": extract(re_text), "pe": extract(pe_text)}


# ---------------------------------------------------------------------------
# OpenAPI path-item builder
# ---------------------------------------------------------------------------
def build_paths(routes: list[tuple[str, str, str]],
                is_sse_path: set[str]) -> dict:
    """Build the OpenAPI `paths` dict from a list of (tag, method, path) tuples."""
    paths: dict = {}
    for tag, method, path in routes:
        if path not in paths:
            paths[path] = {}

        key = f"{method}:{path}"
        summary = SUMMARIES.get(key, f"{method.title()} {path}")
        op: dict = {
            "tags": [tag],
            "summary": summary,
        }

        # Path parameters
        params: list[dict] = []
        for placeholder, param_defs in PATH_PARAMS.items():
            if placeholder in path:
                params.extend(param_defs)
        if params:
            op["parameters"] = params

        # Special: /api/governance/route uses query params
        if path == "/api/governance/route":
            op["parameters"] = [
                {"name": "machineId",  "in": "query", "required": True,
                 "schema": {"type": "string"}},
                {"name": "sequenceId", "in": "query", "required": True,
                 "schema": {"type": "string"}},
                {"name": "values",     "in": "query", "required": True,
                 "description": "Comma-separated numeric values.",
                 "schema": {"type": "string"}},
            ]

        # Request body
        rb = request_body(method, path)
        if rb is not None:
            op["requestBody"] = rb

        # SSE response
        if path in is_sse_path and method == "GET":
            op["description"] = (
                "Server-Sent Events stream. "
                "Frames: `data: <json>\\n\\n`; keepalive: `: keepalive\\n\\n` every 15 s."
            )
            op["responses"] = {
                "200": {
                    "description": "Event stream",
                    "content": {"text/event-stream": {"schema": {"type": "string"}}},
                }
            }
        elif path == "/ws":
            op["description"] = (
                "WebSocket endpoint. RFC 6455 text frames; "
                "ping every 15 s on idle. Each frame is a JSON event object."
            )
            op["responses"] = {
                "101": {"description": "Switching Protocols — WebSocket handshake"},
            }
        else:
            schema = response_schema(method, path)
            op["responses"] = {
                "200": {
                    "description": "Success",
                    "content": {"application/json": {"schema": schema}},
                },
                "500": {"$ref": "#/components/responses/InternalError"},
            }
            # Add 404 for paths with id params
            if "{id}" in path or "{machineId}" in path or "{name}" in path:
                op["responses"]["404"] = {"$ref": "#/components/responses/NotFound"}

        method_key = method.lower()
        paths[path][method_key] = op

    return paths


# ---------------------------------------------------------------------------
# Full spec assembler
# ---------------------------------------------------------------------------
def assemble(surface: str, routes: list[tuple[str, str, str]],
             overlay: dict, spec_path: str) -> dict:
    is_re = (surface == "re")
    sse_paths = {"/api/engine/stream"} if is_re else {"/api/events"}

    tags = sorted({tag for tag, _, _ in routes})
    paths = build_paths(routes, sse_paths)
    components = re_components() if is_re else pe_components()

    # Derive operationIds (must be unique)
    for path, methods in paths.items():
        for method, op in methods.items():
            slug = re.sub(r'[^a-zA-Z0-9]', '_', path)
            slug = re.sub(r'_+', '_', slug).strip('_')
            op["operationId"] = f"{method}_{slug}"

    spec: dict = {
        "openapi": "3.1.0",
        "info": {
            "title": overlay.get("info", {}).get("title", f"RealityEngine {surface.upper()} API"),
            "version": overlay.get("info", {}).get("version", "1.1.0"),
            "description": overlay.get("info", {}).get(
                "description",
                f"Generated from {Path(spec_path).name} — do not edit by hand."),
            "x-generated-from": str(Path(spec_path).resolve()),
        },
        "servers": overlay.get("servers", []),
        "tags": [{"name": t} for t in tags],
        "paths": paths,
        "components": components,
    }
    return spec


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--spec",    required=True, help="Path to SURFACE_SPEC.md")
    ap.add_argument("--overlay", required=True, help="Runtime overlay YAML")
    ap.add_argument("--out-re",  required=True, help="Output path for RE spec")
    ap.add_argument("--out-pe",  required=True, help="Output path for PE spec")
    args = ap.parse_args()

    routes = parse_surface_spec(args.spec)
    with open(args.overlay) as f:
        overlay_root = yaml.safe_load(f) or {}

    for surface in ("re", "pe"):
        out_path = args.out_re if surface == "re" else args.out_pe
        overlay = overlay_root.get(surface, {})
        spec = assemble(surface, routes[surface], overlay, args.spec)
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        with open(out_path, "w") as f:
            yaml.dump(spec, f, allow_unicode=True, sort_keys=False,
                      default_flow_style=False, width=120)
        print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
