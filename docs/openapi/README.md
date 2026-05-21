# OpenAPI Contracts — RealityEngine_AI

Two OpenAPI 3.0.3 documents describe the AI runtime's HTTP surface.

| File | Service | Default URL |
|---|---|---|
| [`reality-engine.yaml`](reality-engine.yaml)     | Reality Engine     | `http://localhost:3000` (direct) / `https://localhost:3000` (TLS proxy) |
| [`perception-engine.yaml`](perception-engine.yaml) | Perception Engine | `http://localhost:3004` (direct) / `https://localhost:3004` (TLS proxy) |

Wire-compatible with [`RealityEngine_CPP`](../../../RealityEngine_CPP/docs/openapi/)
and [`RealityEngine_LSP`](../../../RealityEngine_LSP/docs/openapi/) — the same
JSON corpus drives byte-identical merge ordering and identical Prometheus
metrics shape across all three runtimes; only the `runtime` label differs.

## Quick view (Redocly CLI)

```bash
npx @redocly/cli preview-docs docs/openapi/reality-engine.yaml
npx @redocly/cli preview-docs docs/openapi/perception-engine.yaml
```

## Quick view (Swagger UI)

```bash
docker run -p 8081:8080 \
  -e SWAGGER_JSON=/spec/reality-engine.yaml \
  -v $PWD/docs/openapi:/spec \
  swaggerapi/swagger-ui
# open http://localhost:8081
```

## Code generation

```bash
npx @openapitools/openapi-generator-cli generate \
  -i docs/openapi/reality-engine.yaml \
  -g typescript-axios \
  -o generated/reality-engine-client
```

## What's new in 1.1

- `/api/metrics` (Prometheus text exposition) on the RE
- `/api/governance/route` paging-decision resolver on the RE
- `/api/runtime/vector-space` and `/api/runtime/storage-footprint` on the RE
- `/api/mqtt/status` and `/api/mqtt/mappings` on the PE
- `PagingDecision`, `MqttBridgeStatus`, `MqttMappingRule`, `MqttMappingsResponse` schemas
- Cross-runtime parity statement added to both `info.description` blocks
