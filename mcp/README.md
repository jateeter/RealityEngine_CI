# RealityEngine MCP Gateway

Packages the RealityEngine **Reality Engine (RE)** and **Perception Engine (PE)**
HTTP surfaces — the CPP, LSP, and Scala runtimes — as [Model Context
Protocol](https://modelcontextprotocol.io) tools and resources, for integration
into a larger agent/tool ecosystem.

It implements the **MCP Gateway** described in
[`../docs/INTEGRATION_ARCHITECTURE.md`](../docs/INTEGRATION_ARCHITECTURE.md):
CLI, HTTPS, WS, and provider adapters all call the same internal operations, and
none bypass PE policy. The same routes are documented as OpenAPI under
[`../docs/openapi`](../docs/openapi) (with a Swagger portal); this gateway is the
MCP-native projection of those contracts.

## What it exposes

| Tool | Service | Mutating | Route |
|---|---|---|---|
| `re.read_state` | RE | – | `GET /api/state` |
| `re.list_machines` | RE | – | `GET /api/machines` |
| `re.read_machine` | RE | – | `GET /api/machines/:id` |
| `re.machine_graph` | RE | – | `GET /api/machine-graph` |
| `re.list_sequences` | RE | – | `GET /api/sequences` |
| `re.perceive` | RE | ✓ | `POST /api/perceive` |
| `pe.read_state` | PE | – | `GET /api/state` |
| `pe.list_sources` | PE | – | `GET /api/sources` |
| `pe.triggers_status` | PE | – | `GET /api/triggers/status` |
| `pe.integrations_status` | PE | – | `GET /api/integrations/status` |
| `dispatch.read_ledger` | PE | – | `GET /api/dispatch/ledger` |
| `dispatch.read_record` | PE | – | `GET /api/dispatch/records/:id` |
| `pe.push_signal` | PE | ✓ | `POST /api/signals` |
| `pe.enqueue_push` | PE | ✓ | `POST /api/push` |
| `pe.sensor_push` | PE | ✓ | `POST /api/sensors/:sensorId` |
| `trigger.replay` | PE | ✓ | `POST /api/triggers/replay/:dispatchId` |
| `dispatch.update_record` | PE | ✓ | `PATCH /api/dispatch/records/:id` |
| `integrations.completion` | PE | ✓ | `POST /api/integrations/completions` |

**Resources**

- `realityengine://instances` — live RE/PE instances (registry or env).
- `realityengine://openapi/{file}` — the generated OpenAPI 3.1 specs
  (`cpp|lsp|scala` × `re|pe`), when run from a full checkout.

## Install & run

```bash
cd mcp
npm install

# stdio transport (local MCP clients)
node bin/realityengine-mcp.js
# or from the CI repo root:  npm run mcp

# Streamable HTTP transport (ecosystem / remote)
node src/http-server.js          # -> http://127.0.0.1:7331/mcp
# or:  npm run mcp:http

# Inspect the tool catalogue without starting a transport
node bin/realityengine-mcp.js --list-tools   # npm run mcp:tools
```

## Configuration (env)

| Variable | Default | Purpose |
|---|---|---|
| `RE_REGISTRY_URL` | – | Instance registry (CI `scripts/registry.sh`, `:5999`). Preferred. |
| `RE_URL` / `PE_URL` | – | Single-instance fallback when no registry. |
| `RE_MCP_ALLOW_MUTATION` | `false` | Allow all mutating tools. |
| `RE_MCP_ALLOWED_TOOLS` | – | Comma-list allowlist (overrides the above; read or write). |
| `RE_MCP_INSECURE_TLS` | – | `1` to accept the self-signed Docker TLS proxy certs. |
| `RE_MCP_HTTP_HOST` / `RE_MCP_HTTP_PORT` | `127.0.0.1` / `7331` | HTTP transport bind. |
| `RE_MCP_TIMEOUT_MS` | `15000` | Per-request timeout. |
| `RE_MCP_SERVER_NAME` | `realityengine` | MCP server name. |

### Discovery & multi-runtime

With `RE_REGISTRY_URL` set, the gateway lists all live instances. When more than
one runtime is up (e.g. `cpp`, `lsp`, `scala`), pass an `instance` argument to any
tool — an instance **id** or a **runtime** name — to target a specific engine:

```jsonc
// tool call args
{ "instance": "scala" }            // by runtime
{ "instance": "cpp-1", "id": "m_42" }  // by registry id
```

Omitting `instance` selects the first live instance.

### Mutation policy

Read-only tools always run. Mutating tools (✓ above) are **disabled by default**
so a gateway can be exposed broadly without risk. Enable explicitly:

```bash
RE_MCP_ALLOW_MUTATION=true node src/http-server.js
# or scope to specific tools:
RE_MCP_ALLOWED_TOOLS="re.read_state,pe.list_sources,integrations.completion" node bin/realityengine-mcp.js
```

This mirrors the architecture rule that mutating MCP tools must be policy-gated,
and that external completion always flows back through PE source mappings.

## Client config

See [`.mcp.json.example`](.mcp.json.example) for Claude Code / Claude Desktop
blocks (stdio, single-endpoint, and HTTP).

## Manifest

[`manifest.json`](manifest.json) is **generated** from the tool catalogue
(`src/tools.js`) so it can never drift from what the server registers:

```bash
npm run manifest:gen      # regenerate after editing tools
npm run manifest:check    # CI guard — fails if manifest.json is stale
```

## Docker

```bash
docker build -t realityengine-mcp -f Dockerfile .
docker run --rm -p 7331:7331 \
  -e RE_REGISTRY_URL=http://host.docker.internal:5999 \
  -e RE_MCP_HTTP_HOST=0.0.0.0 \
  realityengine-mcp
```

## Design notes

- The gateway is a **projection**, not a second source of truth. Every tool maps
  1:1 onto a route in `RealityEngine_CPP/SURFACE_SPEC.md`; behaviour, validation,
  and governance stay in the engines.
- It never runs an agent or calls a provider inside a PE cycle. `trigger.replay`
  and `dispatch.update_record` only annotate the audit/outbox ledger; results
  return through `integrations.completion` → PE source mappings.
- Wire-compatible across runtimes: the same tool set works against CPP, LSP, and
  Scala because they implement the same canonical surface.
