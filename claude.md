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

# Incremental corpus parity: boot with one machine, then add one corpus machine
# per iteration over the RE/PE APIs and re-check trajectory parity after each.
# Iteration n drives the engines with machines 1..n interned sequences merged.
# See scripts/claude.md — currently blocked by cpp freezing interned sequences
# at their first vector and lsp discarding sources on POST /api/reset.
./scripts/test-corpus-parity-loop.sh --stop-on-fail
```

## Runtime Contract

- Prefer `RE_REGISTRY_URL` for Manager, Machines, and CI e2e tests.
- Pass CI-generated `config/integrations.json` to PE services with `INTEGRATIONS_CONFIG`.
- Keep OpenClaw defaults aligned with `ACP_ENABLED=true`, `ACP_GATEWAY_URL` or `OPENCLAW_GATEWAY_URL`, `ACP_SESSION_KEY`, `ACP_TARGET_AGENT`, and `ACP_COMPLETION_SOURCE_MAPPING_ID=acp-openclaw-completion`.
- `startUniverse.sh --openclaw` delegates to `localOpenClawStack/scripts/start.sh`; keep hardening, immutable image pins, WebUI bootstrap, and live verification authoritative in that native stack entrypoint.
- Keep e2e results separated by availability, registry alignment, contract parity, byte equivalence, and integration success.
- **No parity or proof run against engines that are not built from current source.**
  `scripts/verify-build-provenance.py` gates this, and both `startUniverse.sh`
  (before the multi-engine spawn) and `scripts/regression-test.sh` (before the
  start phase) call it. It checks each engine repo is on `main`, clean of
  uncommitted source, not behind origin, and that every launched artifact is
  newer than both its newest source file and the HEAD commit.
  - The override is `RE_SKIP_PROVENANCE=1`, deliberately **not** `--warn-only` —
    the regression harness passes `--warn-only` on every run, so reusing it
    would disable the check on the lane that needs it most.
  - Engines only. The corpus and service repos run from source and cannot go
    stale this way; LSP has no compiled artifact, so its git state is the check.
  - Why it exists: on 2026-08-22 both Scala jars predated that morning's merge
    (`perception-engine.jar` by 5h39m). `startUniverse.sh` launches each repo's
    checked-in artifact while the harness rebuilds only inside throwaway
    worktrees, so a stale main-repo artifact survives a "rebuilt everything"
    run. The resulting three-engine divergence was investigated and filed as an
    engine defect before the build skew was found.

## LSP Support

- TypeScript: `typescript-language-server` for Playwright specs and Node scripts.
- Bash: `bash-language-server` for launcher scripts.
- Docker/YAML/JSON: Docker, Compose, YAML, and JSON schema language servers.
- Markdown: markdown LSP for docs and this file.

## Editing Rules

- Do not stage generated `e2e-report`, `test-results`, local runtime manifests, or logs unless explicitly requested.
- Keep `startUniverse.sh` compatible with native multi-engine and legacy Docker paths.
- When adding a live-stack test, make it registry-aware instead of hard-coding legacy single-engine ports.
