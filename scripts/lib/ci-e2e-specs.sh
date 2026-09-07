#!/usr/bin/env bash
# CI e2e spec selection — which Playwright specs are safe for which universe shape.
#
# Sourceable and side-effect free, so scripts/tests/test-ci-e2e-specs.sh can
# exercise the selection without a live stack.
#
# e2e/tests/ is the canonical home of the app-level Playwright specs. They were
# deduped here deliberately (see RealityEngine_Machines README) — do not re-add
# copies to that repo.
#
# Only registry-aware specs can run against a native multi-engine universe. The
# rest hardcode the Docker endpoints (https://localhost:5001 RE,
# https://localhost:3004 PE), which do not exist when engines are spawned
# natively at registry-assigned ports (scala 5000/5001, cpp 5300/5301,
# lsp 5600/5601 — all HTTP). Running them multi-engine fails on connection
# rather than on behavior, so they are skipped and reported, not silently
# dropped.
#
# To promote a spec: make it resolve endpoints from RE_REGISTRY_URL, then add
# it to CI_E2E_MULTI_ENGINE_SPECS.

CI_E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Space-separated, repo-relative. Specs proven safe against a multi-engine
# universe.
# Promotions are earned by a measured run against a real multi-engine universe,
# not by inspection. Each entry below names what was observed.
#
#   tree-to-pe-manager-equivalence  registry-aware from the start
#   visualizer-ui                   4 passed against cpp:2,lsp:1,scala:1 on
#                                   2026-09-07, after #301 made global-setup and
#                                   the spec resolve endpoints from the instance
#                                   registry rather than hardcoding the Docker
#                                   TLS proxy (RealityEngine_CI#278)
: "${CI_E2E_MULTI_ENGINE_SPECS:=e2e/tests/tree-to-pe-manager-equivalence.spec.ts e2e/tests/visualizer-ui.spec.ts}"

# Reason surfaced for each spec excluded from a multi-engine run.
# The blanket reason no longer fits every excluded spec: #301 made them all
# registry-aware, so what keeps the remaining four out is specific and per-spec.
#
#   api                  resolves correctly; 14 passed / 1 failed multi-engine.
#                        The failure is `should get engine statistics` — the
#                        three runtimes return three different shapes from
#                        GET /api/engine/stats, which /api/engine/stats-next
#                        exists to fix. Promote when that lands, not before:
#                        promoting now would make the multi-engine job red for
#                        a contract defect it did not cause.
#   full-integration     resolves correctly; 6 passed / 1 failed multi-engine.
#                        The failing test is the UI leg of
#                        "create sequence, process vector, and see results in
#                        UI". Undiagnosed — creation succeeds on all three
#                        runtimes, so the failure is later in the flow.
#   multi-step-output-workflow        skips on this corpus (4 skipped)
#   perceptual-space-interconnection  skips on this corpus (2 skipped)
#
# The last two skip for the same reason the already-promoted
# tree-to-pe-manager-equivalence skips here, so skipping is not evidence
# against them — they need a corpus that exercises them before promotion means
# anything.
: "${CI_E2E_SINGLE_ENGINE_REASON:=not yet promoted - see per-spec notes in this file}"

# ci_e2e_all_specs [root]
#   Repo-relative paths of every CI e2e spec, sorted. `root` defaults to the
#   RealityEngine_CI checkout containing this library.
ci_e2e_all_specs() {
    local root="${1:-$CI_E2E_LIB_DIR}"
    ( cd "$root" 2>/dev/null && ls e2e/tests/*.spec.ts 2>/dev/null | sort )
}

# ci_e2e_single_engine_specs [root]
#   Specs excluded from a multi-engine run — every spec not in the allowlist.
ci_e2e_single_engine_specs() {
    local root="${1:-$CI_E2E_LIB_DIR}"
    local spec
    ci_e2e_all_specs "$root" | while IFS= read -r spec; do
        case " $CI_E2E_MULTI_ENGINE_SPECS " in
            *" $spec "*) ;;
            *) printf '%s\n' "$spec" ;;
        esac
    done
}

# ci_e2e_specs_for_mode MODE [root]
#   MODE is `multi-engine` or `single-engine`. Emits the specs that mode runs.
ci_e2e_specs_for_mode() {
    local mode="${1:?mode required}" root="${2:-$CI_E2E_LIB_DIR}"
    case "$mode" in
        multi-engine)
            local spec
            for spec in $CI_E2E_MULTI_ENGINE_SPECS; do printf '%s\n' "$spec"; done
            ;;
        single-engine)
            ci_e2e_all_specs "$root"
            ;;
        *)
            echo "ci_e2e_specs_for_mode: unknown mode '$mode'" >&2
            return 2
            ;;
    esac
}
