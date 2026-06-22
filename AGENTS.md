# Codex Guidance: RealityEngine_CI

Read `claude.md` for the current codebase map and integration context.

## Role

This repo is the operational control plane. It owns universe startup/teardown, registry generation, integration config, and full-stack e2e verification.

## Development Rules

- Treat `startUniverse.sh`, `stopUniverse.sh`, registry shape, and generated integration config as cross-repo contracts.
- Preserve both native multi-engine and legacy Docker paths unless the user explicitly narrows the scope.
- Pass CI-generated `config/integrations.json` through `INTEGRATIONS_CONFIG` when PE services need adapters.
- Prefer `RE_REGISTRY_URL` for multi-engine tests; use `RE_BASE_URL` and `PE_BASE_URL` only for single-engine fallback.

## Bug Triage

- Start with the launched universe manifest and live registry.
- Verify health endpoints before debugging payload behavior.
- Keep OpenClaw/localAI failures separate from engine parity failures.
- For byte-equivalence failures, capture identity-key differences before comparing serialized bodies.

## Verification

Common commands:

```bash
npm run test
npm run test:e2e
npm run test:deployment
./startUniverse.sh --engines=cpp:1,lsp:1,scala:1 --openclaw --machine-load=runtime --pe-source-bootstrap=auto --warn-only
./stopUniverse.sh
```

## Artifact Hygiene

Do not commit generated `e2e-report`, `test-results`, runtime manifests, local logs, or credentials unless explicitly requested.

