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
    # The one pathway every runtime control is read or written through
    # (RealityEngine_CI#271). Internal surface — the external face is the
    # Manager's engine-qualified /api/engine/{id}/config, because a control
    # value belongs to the runtime that holds it.
    "GET:/api/engine/config":                                  "Every runtime control, with its scope and declared default",
    "GET:/api/engine/config/{control}":                        "Read one runtime control",
    "PUT:/api/engine/config/{control}":                        "Set one runtime control",
    "DELETE:/api/engine/config/{control}":                     "Restore a control to its declared default",
    # Manager (external) — engine-qualified. The engine is part of the address
    # because vector, sequence and control values are all scoped to the runtime
    # that holds them (RealityEngine_CI#397).
    "GET:/api/engines":                                        "List the registered engine instances",
    "GET:/api/engine/{id}/health":                             "Health of one engine, probed",
    "GET:/api/engine/{id}/vectors/{vectorId}":                 "Read a vector from the named engine",
    "GET:/api/engine/{id}/sequences/{sequenceId}":             "Read a sequence from the named engine",
    "GET:/api/engine/{id}/config":                             "Every control on the named engine",
    "GET:/api/engine/{id}/config/{control}":                   "Read one control on the named engine",
    "PUT:/api/engine/{id}/config/{control}":                   "Set one control on the named engine",
    "DELETE:/api/engine/{id}/config/{control}":                "Restore one control on the named engine to its declared default",
    # RE — Runtime Introspection
    "GET:/api/runtime/metrics":                                "Engine and worker-pool metrics",
    "GET:/api/runtime/vector-space":                           "Perceptual-space shape and mapping version",
    "GET:/api/runtime/storage-footprint":                      "Per-machine cell-storage footprint",
    "GET:/api/runtime/options":                                "Response-projection options",
    "PATCH:/api/runtime/options":                              "Update response-projection options",
    # RE — Vectors
    "POST:/api/vectors/search":                                "Search vectors by cosine similarity",
    "POST:/api/vectors":                                       "Store a vector",
    # Internal surface. Vector ids are engine-scoped, so the external read is
    # the Manager's engine-qualified GET /api/engine/{id}/vectors/{vectorId}
    # — an id is only meaningful in the context of the engine that minted it
    # (RealityEngine_CI#397).
    "GET:/api/vectors/{id}":                                   "Read a vector from THIS engine's store (internal; external callers use /api/engine/{id}/vectors/{vectorId})",
    "DELETE:/api/vectors/{id}":                                "Delete a vector",
    # RE — Sequences
    "GET:/api/sequences":                                      "List sequences",
    "POST:/api/sequences":                                     "Create sequence",
    # Internal surface, same reason as vectors: sequence ids are scoped to the
    # engine that holds them. External read is
    # GET /api/engine/{id}/sequences/{sequenceId}.
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
    # The Manager's engine-qualified routes. Without these the generated
    # documents templated `{vectorId}` and `{sequenceId}` into the path and
    # declared no parameter for them, which OpenAPI forbids — a path template
    # name must have a matching parameter. Nothing complained because no
    # validator ran over the output.
    "{vectorId}": [{"name": "vectorId", "in": "path", "required": True,
                     "schema": {"type": "string"},
                     "description": "Scoped to the engine named by {id}"}],
    "{sequenceId}": [{"name": "sequenceId", "in": "path", "required": True,
                       "schema": {"type": "string"},
                       "description": "Scoped to the engine named by {id}"}],
    "{control}": [{"name": "control", "in": "path", "required": True,
                    "schema": {"type": "string"},
                    "description": "Control name, as declared in SURFACE_SPEC"}],
}

# ---------------------------------------------------------------------------
# Shared component schemas
# ---------------------------------------------------------------------------
# The corpus machine document. Both surfaces accept one — the RE on
# `POST /api/machines`, and the PE on the same route, which is its machine
# ingestion path — so it is defined once and referenced by both component sets.
# It used to live only in `re_components`, which left
# `$ref: '#/components/schemas/Machine'` dangling in every generated PE
# document. Invisible until #250, because before that fix the PE document was
# being generated from the RE surface entirely.
# The corpus file's own top level — the shape of every machines/**/*.json.
# Accepted by POST /api/machines and PUT /api/machines/{id} alongside the bare
# Machine object, so a caller holding a corpus file can post it unmodified.
MACHINE_ENVELOPE_SCHEMA = {
    "type": "object",
    "required": ["version", "machine"],
    "properties": {
        "version": {"type": "string", "description":
                    "Corpus file format version. Required in this shape and "
                    "validated on its major component; the bare Machine schema "
                    "does not declare it."},
        "machine": {"$ref": "#/components/schemas/Machine"},
    },
}

MACHINE_SCHEMA = {
    "type": "object", "additionalProperties": True,
    "description": "RealityEngine machine JSON.",
    "properties": {
        "id":      {"type": "string"},
        "name":    {"type": "string"},
        "version": {"type": "string"},
        "perceptualMapping": {"type": "object", "additionalProperties": True},
        "sequences": {"type": "array",
                      "items": {"type": "object", "additionalProperties": True}},
    },
}


# Responses both surfaces attach to their operations. `build_paths` puts
# `InternalError` on every non-streaming operation and `NotFound` on every
# operation with an id parameter, regardless of surface, so the definitions
# cannot live in one component set and not the other.
#
# `InternalError` did exactly that: defined in `re_components`, absent from
# `pe_components`, referenced 43 times in each generated PE document and
# resolvable in none of them (RealityEngine_CI#403). Nothing complained,
# because the audit regenerated the documents and diffed them against
# themselves — a generator that consistently emits a dangling reference
# compares equal to itself.
SHARED_RESPONSES: dict = {
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
}

def re_components() -> dict:
    return {
        "parameters": {
            "MachineId": {"name": "id", "in": "path", "required": True,
                          "schema": {"type": "string"}},
        },
        "responses": dict(SHARED_RESPONSES),
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
                "collectionName":  {"type": "string", "example": "reality-events"}}},
            # The five fields SURFACE_SPEC declares a control to have. `value`
            # is untyped because it follows `scope`: a scalar for `engine`, an
            # object keyed by machine id for `machine`.
            "EngineControl": {"type": "object",
                "required": ["name", "scope", "value", "default", "mutable"],
                "properties": {
                    "name":    {"type": "string", "example": "transitionsInhibited"},
                    "scope":   {"type": "string", "enum": ["engine", "machine"]},
                    "value":   {"description": "Scalar when scope is engine; "
                                               "an object keyed by machine id when scope is machine"},
                    "default": {"description": "The default this document declares"},
                    "mutable": {"type": "boolean",
                                "description": "Whether PUT is accepted; a derived reading is reported, not set"}}},
            "EngineConfig": {"type": "object", "properties": {
                "controls": {"type": "array", "items":
                             {"$ref": "#/components/schemas/EngineControl"},
                             "description": "Emitted sorted by name"}}},
            "EngineControlWrite": {"type": "object", "required": ["value"],
                "properties": {
                    "machine": {"type": "string",
                                "description": "Required when the control's scope is machine"},
                    "value":   {"description": "The value to set"}}},
            # The flat view of the engine-scoped controls. `projectionControls`
            # was removed from this response in #271 Phase 2: prose describing
            # request fields, emitted by two runtimes with different key sets
            # and read by nothing.
            "RuntimeOptions": {"type": "object", "properties": {
                "historyLimit":          {"type": "integer", "example": 250},
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
            "Machine": MACHINE_SCHEMA,
            "MachineEnvelope": MACHINE_ENVELOPE_SCHEMA,
            "MachineMutationResponse": {"type": "object", "properties": {
                "success": {"type": "boolean"},
                "machine": {"$ref": "#/components/schemas/Machine"},
                "message": {"type": "string"}}},
            "MachineTransitionResult": {
                "type": "object", "additionalProperties": True,
                "properties": {
                    "inputEvent":    {"$ref": "#/components/schemas/Vector"},
                    "timestamp":      {"type": "number"},
                    # `nullable: true` here was 3.0 syntax inside a document
                    # declaring 3.1.0, where the keyword no longer exists. 3.1
                    # spells an optional value as a union with the null type.
                    "machineOutput":  {"type": ["array", "null"],
                                       "items": {"type": "number", "format": "double"}},
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
        "responses": dict(SHARED_RESPONSES),
        "schemas": {
            "Machine": MACHINE_SCHEMA,
            "MachineEnvelope": MACHINE_ENVELOPE_SCHEMA,
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

    # Two accepted shapes, not one. The document declared only the bare Machine
    # object while two of three runtimes required the corpus file's
    # `{version, machine}` envelope — cpp answering 200 and discarding the body,
    # scala refusing it outright. A client generated from these documents could
    # not add a machine to either (RealityEngine_CI#419).
    #
    # All three now accept both, disambiguating on an object-valued `machine`
    # key, so the document describes both. oneOf rather than a merged schema:
    # they are genuinely alternative bodies, and a caller should be told it may
    # post the corpus file it already holds without unwrapping it.
    if path == "/api/machines" and method == "POST" or (
            path == "/api/machines/{id}" and method == "PUT"):
        schema_ref = {"oneOf": [
            {"$ref": "#/components/schemas/Machine"},
            {"$ref": "#/components/schemas/MachineEnvelope"},
        ]}
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
    elif path in ("/api/engine/config/{control}",
                  "/api/engine/{id}/config/{control}") and method == "PUT":
        schema_ref = {"$ref": "#/components/schemas/EngineControlWrite"}
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
    if path in ("/api/engine/config", "/api/engine/{id}/config"):
        return {"$ref": "#/components/schemas/EngineConfig"}
    if path in ("/api/engine/config/{control}", "/api/engine/{id}/config/{control}"):
        return {"type": "object", "properties": {
            "control": {"$ref": "#/components/schemas/EngineControl"}}}
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
# The `##` headings that open each surface's route tables. Matched on the
# heading, not on a position in the document.
SURFACE_HEADINGS = {
    "re": "Reality Engine (RE) Surface",
    "pe": "Perception Engine (PE) Surface",
    # The external surface, served by the Manager rather than by a runtime, so
    # it is generated once instead of per runtime (RealityEngine_CI#399).
    "manager": "Manager (Visualizer) Surface",
}


def _section(text: str, heading: str) -> str:
    """The body of one `## <heading>` section, up to the next `##` heading.

    This used to be `re.split(r'\\n---\\n', text)` indexed at `parts[1]` and
    `parts[2]`, with a comment asserting the layout was `intro | RE | PE | Gap
    Register`. That was true when written and silently stopped being true: #212
    added "The observable boundary" with a horizontal rule before it, the
    document went to ten parts with the tables at 2 and 3, and every index shifted
    by one. The RE document then generated from prose (0 routes) and the PE
    document generated from the RE table — 63 RE routes published under a
    Perception Engine title, with the real PE section reaching no document at all.

    Nothing caught it for two reasons worth remembering. The audit's staleness
    check compared generated output against generated output, so a parser
    consistently misreading its input compares equal to itself. And an empty
    `paths` map is valid OpenAPI, so nothing downstream objected.

    A heading cannot be shifted by an unrelated edit elsewhere in the document.
    """
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r'^##\s+' + re.escape(heading) + r'\s*$', line):
            start = i + 1
            break
    if start is None:
        return ""
    end = len(lines)
    for j in range(start, len(lines)):
        if re.match(r'^##\s+\S', lines[j]):
            end = j
            break
    return "\n".join(lines[start:end])


def parse_surface_spec(spec_path: str) -> dict[str, list[tuple[str, str, str]]]:
    """
    Returns {'re': [(tag, method, openapi_path), ...],
             'pe': [(tag, method, openapi_path), ...]}
    """
    text = Path(spec_path).read_text()
    re_text = _section(text, SURFACE_HEADINGS["re"])
    pe_text = _section(text, SURFACE_HEADINGS["pe"])
    mgr_text = _section(text, SURFACE_HEADINGS["manager"])

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

    parsed = {"re": extract(re_text), "pe": extract(pe_text),
              "manager": extract(mgr_text)}

    # A surface that parses to nothing is a parser failure, not a spec with no
    # routes. Both of these documents describe dozens; neither will ever
    # legitimately be empty, and writing an empty one is exactly how this went
    # unnoticed for two months. Fail here rather than emit it.
    empty = [name for name, routes in parsed.items() if not routes]
    if empty:
        raise SystemExit(
            "generate.py: no routes parsed for surface(s): " + ", ".join(sorted(empty)) + "\n"
            f"  spec: {spec_path}\n"
            "  Sections are located by heading. Expected to find:\n"
            + "".join(f"    ## {SURFACE_HEADINGS[n]}\n" for n in sorted(empty))
            + "  If a heading was renamed, update SURFACE_HEADINGS to match."
        )
    return parsed


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
    is_re  = (surface == "re")
    is_mgr = (surface == "manager")

    # The Manager surface streams nothing and is not a runtime, so it takes
    # neither SSE path. Spelled out rather than left to fall through the
    # is_re/else split, which would have silently given it the PE stream path
    # and the PE component set (RealityEngine_CI#399).
    if is_mgr:
        sse_paths = set()
        components = re_components()   # the vector and sequence schemas it reads
    else:
        sse_paths = {"/api/engine/stream"} if is_re else {"/api/events"}
        components = re_components() if is_re else pe_components()

    tags = sorted({tag for tag, _, _ in routes})
    paths = build_paths(routes, sse_paths)

    # Derive operationIds (must be unique)
    for path, methods in paths.items():
        for method, op in methods.items():
            slug = re.sub(r'[^a-zA-Z0-9]', '_', path)
            slug = re.sub(r'_+', '_', slug).strip('_')
            op["operationId"] = f"{method}_{slug}"

    spec: dict = {
        "openapi": "3.1.0",
        "info": {
            "title": overlay.get("info", {}).get(
                "title",
                "RealityEngine Manager API (external)" if is_mgr
                else f"RealityEngine {surface.upper()} API"),
            "version": overlay.get("info", {}).get("version", "1.1.0"),
            "description": overlay.get("info", {}).get(
                "description",
                f"Generated from {Path(spec_path).name} — do not edit by hand."),
            # Repo-qualified, never absolute. An absolute path made the output
            # a function of the checkout location: every regeneration from a
            # worktree or a CI runner rewrote this line in all fifteen
            # documents, and committed a developer's home directory into them.
            "x-generated-from": "/".join(Path(spec_path).resolve().parts[-2:]),
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
    ap.add_argument("--out-manager", help="Output path for the Manager (external) spec")
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

    # The Manager surface is not runtime-specific: one document, no overlay.
    # Written only when asked for, so the per-runtime invocations above are
    # unchanged and do not each rewrite the same file.
    if args.out_manager:
        spec = assemble("manager", routes["manager"], {}, args.spec)
        Path(args.out_manager).parent.mkdir(parents=True, exist_ok=True)
        with open(args.out_manager, "w") as f:
            yaml.dump(spec, f, allow_unicode=True, sort_keys=False,
                      default_flow_style=False, width=120)
        print(f"wrote {args.out_manager}")


if __name__ == "__main__":
    main()
