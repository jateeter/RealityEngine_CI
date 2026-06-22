# RealityEngine_CI Guidance

Last reviewed: 2026-06-22

See `/Users/johnt/workspace/GitHub/claude.md` for the integrated application map. Update both this file and the root map when orchestration, registry, environment, or e2e responsibilities change.

## Role

This repo is the integration and operations control plane for the RealityEngine universe. It owns native/Docker stack lifecycle, runtime registry generation, CI integration config, and full-stack e2e entrypoints.

## Codebase Map

- `startUniverse.sh`: canonical multi-engine launcher for C++, LSP, Scala, Manager, localAIStack, and OpenClaw options.
- `stopUniverse.sh`: canonical teardown path.
- `config/`: generated/shared config, dashboards, registry, and `integrations.json`.
- `docker/`: image contexts for Manager, Scala RE/PE, and related services.
- `e2e/`: Playwright and shell e2e suites, including OpenClaw and Manager parity coverage.
- `scripts/`: universe helpers, OpenAPI generation, tests, and visualizer utilities.
- `docs/`: integration architecture and operational docs.
- `nginx/`: reverse proxy configuration for composed deployments.

## Key Commands

```bash
npm run test
npm run test:e2e
npm run test:all
npm run test:deployment
./startUniverse.sh --engines=cpp:1,lsp:1,scala:1 --openclaw --machine-load=runtime --pe-source-bootstrap=auto --warn-only
./stopUniverse.sh
```

## Runtime Contract

- Prefer `RE_REGISTRY_URL` for Manager, Machines, and CI e2e tests.
- Pass CI-generated `config/integrations.json` to PE services with `INTEGRATIONS_CONFIG`.
- Keep OpenClaw defaults aligned with `ACP_ENABLED=true`, `ACP_GATEWAY_URL` or `OPENCLAW_GATEWAY_URL`, `ACP_SESSION_KEY`, `ACP_TARGET_AGENT`, and `ACP_COMPLETION_SOURCE_MAPPING_ID=acp-openclaw-completion`.
- Keep e2e results separated by availability, registry alignment, contract parity, byte equivalence, and integration success.

## LSP Support

- TypeScript: `typescript-language-server` for Playwright specs and Node scripts.
- Bash: `bash-language-server` for launcher scripts.
- Docker/YAML/JSON: Docker, Compose, YAML, and JSON schema language servers.
- Markdown: markdown LSP for docs and this file.

## Editing Rules

- Do not stage generated `e2e-report`, `test-results`, local runtime manifests, or logs unless explicitly requested.
- Keep `startUniverse.sh` compatible with native multi-engine and legacy Docker paths.
- When adding a live-stack test, make it registry-aware instead of hard-coding legacy single-engine ports.
