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

## MUST: every use of the word "registry" carries a qualifier

**The word "registry" MUST NEVER appear unqualified. Every single use of the
word takes a qualifier naming which registry is meant.**

This is a hard requirement, not a style preference. It applies to every
occurrence in every context, with no exceptions: prose, end-of-task summaries,
commit messages, PR bodies, issue titles and bodies, code comments, docstrings,
variable and function names, log lines, and documentation.

Wrong, in every case — these are all violations:

- "the registry"
- "a versioned registry"
- "the registry file" / "update the registry" / "registry-backed"
- "check the registry first"
- "registry drift"

Right — a qualifier every time:

- "the **instance** registry"
- "a versioned **cesgen** registry"
- "the **arbitration** registry"
- "**machine** registry drift"

If you type the word "registry" and the word immediately before it is not a
qualifier, stop and add one. Re-read every summary and every message for the
bare word before sending it — that is where this rule is actually broken, because
the surrounding context makes the referent feel obvious in the moment. That
feeling is exactly the assumption the rule exists to block.

Qualifiers currently in use. **This list is open, not exhaustive** — a registry
added later gets a qualifier too; nothing is ever promoted to being "the
registry" by virtue of being the one under discussion:

- **instance** registry — `/tmp/re-registry/re-registry.json`, served at
  `:5999/re-registry.json`. Running RE/PE instances with `re_url`/`pe_url`/ports,
  plus `services` and `allocation`. What `RE_REGISTRY_URL` points at.
- **machine** registry — the machines a runtime holds in memory, reported by
  `GET /api/machines`. Distinct from `GET /api/machines/json/list`, the on-disk
  corpus catalog.
- **cesgen** registry — `RealityEngine_Machines/domains/ces-contract-registry.json`.
  Which CES output-stream contract shards exist, what corpus each was recorded
  against, whether each is current.
- **arbitration** registry — `machines/domains/arbitration-registry.json`.
- **domain** registry — `machines/domains/domain-registry.json`.
- **semantic-bus** registry — `machines/domains/semantic-bus-registry.json`.
- **tag** registry — `RealityEngine_CI/docs/TAG_REGISTRY.md`.

## MUST: verify a merge beyond the hosted checks

**A green PR is not a verified PR. Never merge on the hosted checks alone.**

The hosted path does not exercise this system's integration points. A PR can show
every check green and still be unverified, because the checks that ran were a
security scan and — at most — a corpus gate. `localAIStack`, `localOpenClawStack`,
Ollama, Qdrant, MQTT, the OpenClaw ACP gateway and the multi-engine universe are
**not** reachable from the hosted runners, so nothing on that path can tell you
whether the change works where it has to work.

Observed repeatedly: RealityEngine_Machines PRs report exactly one check
(GitGuardian). That is not evidence about the corpus, the registries, the
engines, or any bridge.

Before merging, verify **locally**, and say in the PR which of these you ran and
what they returned:

- The repo's own gates — `validate-corpus.sh`, the contract suite,
  `npm test`, `make test`, `sbt test` — whichever the change touches.
- The integration points the change can reach: a live 3-of-3 universe, the
  local AI stack, the OpenClaw gateway, MQTT — whichever the change can affect.
- The specific behaviour the change claims, with the numbers it produced.

If an integration point cannot be exercised, **say so in the PR** and name it.
An unverified area that is named is a known gap; an unverified area that is
silent reads as tested.

A hosted green tells you the change did not break the hosted path. That is worth
having and is not the question being asked at merge time.

## MUST: never commit to main — branch, PR, verify, merge, clean up

**No change reaches `main` in any repo except through a branch and a pull
request.** Not documentation, not a one-line fix, not a "trivial" follow-up, and
not a hotfix for a gate that is currently red. There is no size or urgency
threshold below which this stops applying.

The full workflow, every time:

1. **Branch from `origin/main`** — `git fetch origin main && git checkout -B <branch> origin/main`.
   Branch from the remote, not from whatever the local `main` happens to be:
   a stale local ref is how a change gets built on a tree that no longer exists.
2. **Commit** with a message that says what changed and *why*, including the
   evidence that motivated it.
3. **Push** and **open a PR**.
4. **Verify** — see "MUST: verify a merge beyond the hosted checks". State in the
   PR which gates ran, what they returned, and what could not be exercised.
5. **Merge** — squash, and delete the remote branch.
6. **Clean up** — delete the local branch, `git worktree prune`, and remove any
   run directories the work created.

Two things about cleanup that are easy to get wrong:

- **Squash-merged branches are not ancestors of `main`.** `git merge-base
  --is-ancestor` and "empty diff against origin/main" both report *nothing to
  delete*, and a branch that is merely behind `main` shows a diff full of
  reversions. Ask the forge which PRs merged — `gh pr list --state merged
  --json headRefName` — and delete those heads.
- **Never delete a branch with an open PR.** Check state before pruning.

Why this is absolute: a direct commit to `main` has no diff anyone reviewed, no
place to record the verification, and nothing to revert cleanly if it is wrong.
It also breaks the only reliable cleanup signal — a merged PR — so the branch
inventory stops meaning anything.
