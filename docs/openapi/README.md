# OpenAPI Contracts — RealityEngine

Six OpenAPI 3.1.0 documents describe the RE and PE HTTP surfaces for each runtime.
All six are **generated** — do not edit them by hand. Edit the source files and regenerate.

## Generated files

| File | Runtime | Service | Default port |
|---|---|---|---|
| [`cpp-re.yaml`](cpp-re.yaml) | CPP (C++ / Boost.Beast) | Reality Engine  | `5301` |
| [`cpp-pe.yaml`](cpp-pe.yaml) | CPP (C++ / Boost.Beast) | Perception Engine | `5300` |
| [`lsp-re.yaml`](lsp-re.yaml) | LSP (SBCL / Hunchentoot) | Reality Engine  | `5601` |
| [`lsp-pe.yaml`](lsp-pe.yaml) | LSP (SBCL / Hunchentoot) | Perception Engine | `5600` |
| [`scala-re.yaml`](scala-re.yaml) | Scala (Akka-HTTP) | Reality Engine  | `5001` |
| [`scala-pe.yaml`](scala-pe.yaml) | Scala (Akka-HTTP) | Perception Engine | `5000` |

## Source files

| Source | Role |
|---|---|
| `RealityEngine_CPP/SURFACE_SPEC.md` | Canonical route authority — every path and method |
| `scripts/openapi/overlays/{cpp,lsp,scala}.yaml` | Runtime overlays — `info.title`, `info.version`, `servers` |
| `scripts/openapi/generate.py` | Generator — parses SURFACE_SPEC.md, applies overlay, writes YAML |

## Regenerate

```bash
# From RealityEngine_CI root:
bash scripts/generate-openapi.sh

# Also copy into each runtime's docs/openapi/:
bash scripts/generate-openapi.sh --propagate
```

Requires Python 3 with `pyyaml` (`pip3 install pyyaml`).

## Quick view

```bash
# Redocly CLI
npx @redocly/cli preview-docs docs/openapi/cpp-re.yaml

# Swagger UI (Docker)
docker run -p 8081:8080 \
  -e SWAGGER_JSON=/spec/cpp-re.yaml \
  -v $PWD/docs/openapi:/spec \
  swaggerapi/swagger-ui
# open http://localhost:8081
```

## Code generation

```bash
npx @openapitools/openapi-generator-cli generate \
  -i docs/openapi/cpp-re.yaml \
  -g typescript-axios \
  -o generated/cpp-re-client
```

## Path coverage

The generator reads every route table in `SURFACE_SPEC.md` and emits one
operation per `METHOD + path` combination. Route counts as of last generation:

- RE surface: **59 paths**
- PE surface: **40 paths**

Operation summaries, request-body schemas, and response schemas are sourced
from a catalogue in `generate.py`. Paths not in the catalogue receive a
documented skeleton with `additionalProperties: true` schemas.
