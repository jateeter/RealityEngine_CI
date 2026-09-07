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
# not by inspection. Each entry names what was observed on
# cpp:2,lsp:1,scala:1 with the regression corpus, 2026-09-07:
#
#   tree-to-pe-manager-equivalence  registry-aware from the start
#   visualizer-ui                   4 passed
#   api                             14 passed, 1 skipped (#311)
#   full-integration                7 passed
#
# All four became answerable only after RealityEngine_CI#301 made global-setup
# and the specs resolve endpoints from the instance registry instead of
# hardcoding the Docker stack's TLS proxy. Before that the suite died in
# global-setup before a single test ran.
: "${CI_E2E_MULTI_ENGINE_SPECS:=e2e/tests/tree-to-pe-manager-equivalence.spec.ts e2e/tests/visualizer-ui.spec.ts e2e/tests/api.spec.ts e2e/tests/full-integration.spec.ts}"

# Reason surfaced for each spec excluded from a multi-engine run.
# The old blanket reason — "hardcodes Docker RE/PE endpoints, not
# registry-aware" — stopped being true when #301 converted them. What keeps the
# last two out is that they skip on this corpus, exactly as the
# already-promoted tree-to-pe-manager-equivalence does here. Skipping is
# therefore not evidence against them: they need a corpus that exercises them
# before promotion means anything.
: "${CI_E2E_SINGLE_ENGINE_REASON:=skips on this corpus - needs a corpus that exercises it before promotion is meaningful}"

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
