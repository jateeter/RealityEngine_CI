# RealityEngine Deployment Contract

This file is the authoritative service and port contract for the integrated RealityEngine system.
All deployment scripts, compose files, runtime presets, and local `.env.example` files should converge on this document.

## Port Ranges

| Range | Owner | Rule |
|---|---|---|
| `3000-3199` | CI Docker public RealityEngine stack | TLS/public endpoints exposed by `RealityEngine_CI` |
| `4000-4499` | `localAIStack` | local AI API, Qdrant, Redis, and local observability |
| `5000-5899` | Native RealityEngine runtimes | Deterministic RE/PE runtime pairs |
| `5900-5999` | Runtime registry/control plane | Multi-engine registry and control endpoints |
| `8000-8099` | External/local UI tools | OpenClaw WebUI default |
| `11434` | Ollama native | Ollama API |
| `18780-18799` | OpenClaw/xACP | OpenClaw gateway |
| `1883` | MQTT broker | Only when a broker is started locally |

## Canonical Native Runtime Pairs

| Runtime | PE | RE | Additional instances |
|---|---:|---:|---|
| Scala | `5000` | `5001` | add `+100` per instance |
| CPP | `5300` | `5301` | add `+100` per instance |
| LSP | `5600` | `5601` | add `+100` per instance |

Examples:

| Instance | PE | RE |
|---|---:|---:|
| `scala-1` | `5000` | `5001` |
| `scala-2` | `5100` | `5101` |
| `cpp-1` | `5300` | `5301` |
| `cpp-2` | `5400` | `5401` |
| `lsp-1` | `5600` | `5601` |
| `lsp-2` | `5700` | `5701` |

### Per-Runtime Instance Limits

Because each runtime's port band starts `+300` above the previous one, the maximum safe instance count per runtime **when all three runtimes are also running** is **3**.

| Runtime | Band start (PE/RE) | Safe instances when all runtimes active | Reason |
|---|---|---|---|
| Scala | 5000/5001 | ≤ 3 | scala-4 would claim 5300/5301, colliding with cpp-1 |
| CPP | 5300/5301 | ≤ 3 | cpp-4 would claim 5600/5601, colliding with lsp-1 |
| LSP | 5600/5601 | ≤ 3 | lsp-4 would claim 5900/5901, exceeding the 5000–5899 range |

If only one runtime type is in use the limit is the number of `+100` steps before reaching 5900 (i.e. Scala alone: max 9 instances).

`startUniverse.sh` enforces these limits at pre-flight: the `--engines` spec is checked for cross-runtime collisions before any process is spawned.

`3299/3300` are deprecated compatibility ports and must not be used as canonical defaults.
`3000/3004` are reserved for the CI Docker public stack and must not be native runtime defaults.

## CI Docker Public Services

| Service | URL | Notes |
|---|---|---|
| Reality Engine API | `https://localhost:3000` | Public TLS endpoint through nginx |
| Manager / Visualizer backend | `https://localhost:3001` | Proxies selected RE/PE runtime |
| RealityEngine Grafana | `https://localhost:3002` | CI observability |
| Perception Engine API | `https://localhost:3004` | Public TLS endpoint |
| Perception frontend | `https://localhost:3005` | PE UI |
| Manager frontend | `https://localhost:5173` | Vite/React UI |
| CI Loki | `https://localhost:3100` | Host-bound for Docker log driver |
| Prometheus | internal `9090` | No public host binding by default |

## localAIStack Services

| Service | URL | Notes |
|---|---|---|
| localAI API | `http://localhost:4000` | FastAPI orchestration |
| localAI Grafana | `http://localhost:4002` | localAI dashboard |
| Open WebUI | `http://localhost:4080` | Ollama UI |
| localAI Loki | `http://localhost:4100` | localAI logging |
| Qdrant REST | `http://localhost:4333` | Shared vector store |
| Qdrant gRPC | `localhost:4334` | Shared vector store |
| Redis | `localhost:4379` | Host-mapped Redis |
| Ollama | `http://localhost:11434` | Native macOS service |

## OpenClaw Services

| Service | URL | Notes |
|---|---|---|
| OpenClaw gateway | `http://localhost:18789` | xACP/OpenAI-compatible gateway |
| OpenClaw WebUI | `http://localhost:8080` | Configurable with `OPEN_WEBUI_PORT` |

## Required Environment Names

| Variable | Meaning |
|---|---|
| `REALITY_ENGINE_PORT` | Native RE bind port |
| `PERCEPTION_ENGINE_PORT` | Native PE bind port |
| `REALITY_ENGINE_URL` | PE or tool target for RE |
| `PERCEPTION_ENGINE_URL` / `PE_URL` | Tool target for PE |
| `RE_REGISTRY_URL` | Multi-engine registry URL |
| `VECTOR_DIMENSION` | RE/PE perceptual vector floor |
| `MACHINES_DIR` | Machine corpus path, normally `../RealityEngine_Machines/machines` |
| `QDRANT_URL` | Qdrant REST URL |
| `LOCAL_AI_API_URL` / `LOCAL_AI_BASE_URL` | localAIStack API URL |
| `INTEGRATIONS_CONFIG` | Provider/source mapping registry |
| `MQTT_BROKER_URL` | Preferred MQTT broker config |
| `MQTT_MAPPINGS_FILE` / `MQTT_MAPPINGS_JSON` | MQTT mapping registry |
| `OPENCLAW_GATEWAY_URL` / `ACP_GATEWAY_URL` | OpenClaw gateway |
| `ACP_SESSION_KEY` / `OPENCLAW_ACP_SESSION` | xACP session key |
| `HEALTHKIT_BRIDGE_ID`, `HEALTHKIT_BRIDGE_TOKEN` | HealthKit bridge identity/auth |

## Normative Rules

- Manager must prefer `RE_REGISTRY_URL` when present; static runtime presets are fallback only.
- CI Docker mode owns public `3000/3004`; native runtimes must not default there.
- Native multi-engine allocation must use the `5000/5300/5600` bands.
- Orchestration owns `VECTOR_DIMENSION` and must propagate it to RE, PE, and tests.
- Integrated runs use `RealityEngine_Machines/machines` as the canonical machine corpus.
- localAIStack must accept `RE_URL` and `PE_URL` from orchestration instead of assuming a fixed engine mode.
- OpenClaw startup is separate from ACP integration; PE must receive ACP registry/env before dispatch is considered configured.
