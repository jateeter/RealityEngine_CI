# RealityEngine_CI Guidance

Last reviewed: 2026-09-25

See `/Users/johnt/workspace/GitHub/CLAUDE.md` for the integrated application map. Update both this file and the root map when orchestration, instance registry, environment, or e2e responsibilities change.

## Role

This repo is the integration and operations control plane for the RealityEngine universe. It owns native/Docker stack lifecycle, instance registry generation, CI integration config, and full-stack e2e entrypoints.

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
# See scripts/CLAUDE.md for what it measures and what a sweep costs.
./scripts/test-corpus-parity-loop.sh --stop-on-fail
```

## Runtime Contract

- Prefer `RE_REGISTRY_URL` for Manager, Machines, and CI e2e tests.
- Pass CI-generated `config/integrations.json` to PE services with `INTEGRATIONS_CONFIG`.
- Keep OpenClaw defaults aligned with `ACP_ENABLED=true`, `ACP_GATEWAY_URL` or `OPENCLAW_GATEWAY_URL`, `ACP_SESSION_KEY`, `ACP_TARGET_AGENT`, and `ACP_COMPLETION_SOURCE_MAPPING_ID=acp-openclaw-completion`.
- **Instance identity (#296).** A UUID belongs to an instance, never an engine
  type or image, and no two instances of any engine type may share one.
  - `scripts/lib/instance_uuids.py` allocates a v7 UUID per `<lane>/<id>`
    (`native/cpp-1`, `docker/cpp-1` — the lanes are different instance sets) in
    `$RE_INSTANCE_STATE_DIR/instance-uuids.json` (default `~/.reality-engine/`),
    durably, so an instance keeps its UUID and its Lamport clock across
    universes. A table holding a duplicate is refused, never repaired.
  - Native spawns pass `INSTANCE_UUID` and `INSTANCE_CLOCK_DIR`
    (`<state>/clock`); the Docker REs load `<state>/docker/<id>.env` through
    `env_file`, so a container recreated by any tool keeps its UUID, and keep
    their clocks on the `<state>/clock-docker` bind mount.
  - `registry_add` records `instance_uuid` and refuses a UUID another instance
    holds; `instance_uuids.py check-registry` checks a whole instance registry.
  - The engine enforces it too: an instance holding an allocated UUID takes an
    exclusive lock for its life, so a second live process with the same UUID
    refuses to boot.
- The Docker path (no `--engines`) runs the same engine set as
  `--engines=cpp:1,lsp:1,scala:1`: compose services `engine-{scala,cpp,lsp}-{re,pe}`
  (images in `docker/scala`, `docker/scala-perception-engine`, `docker/cpp`,
  `docker/lsp`), plain HTTP on 6100/6101, 6300/6301, 6600/6601 (PE/RE),
  registered as `scala-1`, `cpp-1`, `lsp-1`. The TLS-proxied `reality-engine` +
  TypeScript PE pair stays Manager's and is not an engine instance (#363).
- `startUniverse.sh --openclaw` delegates to `localOpenClawStack/scripts/start.sh`; keep hardening, immutable image pins, WebUI bootstrap, and live verification authoritative in that native stack entrypoint.
- Keep e2e results separated by availability, instance registry alignment, contract parity, byte equivalence, and integration success.
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
    stale this way. LSP's `bin/reality-engine-lsp` is an optional artifact: a
    source-mode run has none, but a stale image is refused, because
    `LSP_LAUNCH_MODE=auto` prefers it (RealityEngine_LSP#62).
  - Why it exists: on 2026-08-22 both Scala jars predated that morning's merge
    (`perception-engine.jar` by 5h39m). `startUniverse.sh` launches each repo's
    checked-in artifact while the harness rebuilds only inside throwaway
    worktrees, so a stale main-repo artifact survives a "rebuilt everything"
    run. The resulting three-engine divergence was investigated and filed as an
    engine defect before the build skew was found.

## Editing Rules

- Do not stage generated `e2e-report`, `test-results`, local runtime manifests, or logs unless explicitly requested.
- Keep `startUniverse.sh` compatible with native multi-engine and legacy Docker paths.
- When adding a live-stack test, make it resolve endpoints from the instance registry (`RE_REGISTRY_URL`) instead of hard-coding legacy single-engine ports.

## Standing rules — authoritative in `docs/ENGINEERING_CONTRACT.md`

These apply here and are **not** restated in this file. The table is an index
to the contract, not a copy of it: it names every rule so you know what to look
up, and the contract's wording governs wherever the two differ.

| Rule | In short |
| --- | --- |
| Qualify every "registry" | Never the bare word — instance / machine / cesgen / arbitration / domain / semantic-bus / tag. |
| Regenerate a stale `<name>` registry, don't fail it | Each `<name>` registry is a view of the running system. A gate regenerates it and fails only on a disagreement that survives regeneration. |
| Verify a merge beyond the hosted checks | A green PR is not a verified PR; the hosted path cannot reach the integration points. Name what you could not exercise, and record what you noticed but did not chase. |
| _CI is the authority | Peripheral repos keep minimal CI that forces local validation; RealityEngine_CI verifies fixes against a live universe. Check its `docs/` before adding CI anywhere else. |
| Name it `CLAUDE.md` | Uppercase, always. On a case-insensitive filesystem `claude.md` is the same inode; dedupe on `st_ino`, never on a resolved path. |
| Never commit to main | Branch from `origin/main`, PR, verify, squash-merge, clean up. |
| Use bash, not zsh | Shell work runs in `/opt/homebrew/bin/bash` (5.x), not zsh or macOS `/bin/bash` 3.2: any loop, unquoted variable, glob or `set --` goes through it with `set -euo pipefail`, and you check the command's exit status, not the pipeline tail. |

Read the contract for the full text, the qualifier table, and the cleanup steps.
