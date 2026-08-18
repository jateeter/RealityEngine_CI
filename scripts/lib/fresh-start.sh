#!/usr/bin/env bash
# Fresh-universe state clearing for startUniverse.sh (RealityEngine_CI#144).
#
# Sourced, not executed. Expects SCALA_DIR, MGR_DIR, CPP_DIR, LSP_DIR, LAS_DIR,
# CI_DIR, FRESH_PROVIDER_CONTENT, and the info/ok/add_warn helpers from the
# caller. Lives here rather than inline so scripts/tests/test-fresh-start.sh can
# exercise it against a temporary tree.

# --- Fresh universe -----------------------------------------------------------
# A --fresh universe must carry no perception state from the one before it.
# Anything a previous run left behind — a persisted source, a latched machine
# output — is indistinguishable from something this run produced, and it is
# what made scala report 20 nonzero perceptual cells against cpp's and lsp's 6
# on a run that had just been started with --fresh (#144).
#
# The stores are removed directly rather than by asking each engine to honour
# FRESH_START. Two reasons: an engine that is not in this run's --engines spec
# never gets asked at all, and a guarantee that depends on every runtime
# implementing an env var the same way is the weaker of the two. FRESH_START is
# still propagated (see the native launch blocks) so an engine that reads it
# also skips its own load.
#
# Ingested provider *content* is deliberately out of scope: Qdrant vectors and
# the Open WebUI volume are expensive to rebuild and are a step removed from
# perception — they change what localAI retrieves, not what the PE assembles.
# --fresh-provider-content clears those, and only when asked.

# Perception state written by a previous universe, by engine.
_perception_state_paths() {
    local p
    # Scala PE — per-instance store (data-<instance>/) and the pre-instance
    # default store, which is still written when DATA_PATH is unset.
    for p in "$SCALA_DIR"/data/perception-sources.json \
             "$SCALA_DIR"/data-*/perception-sources.json; do
        [ -f "$p" ] && printf '%s\n' "$p"
    done
    # TypeScript PE (Manager).
    for p in "$MGR_DIR"/perception-engine/backend/data/perception-sources.json \
             "$MGR_DIR"/perception-engine/backend/data-*/perception-sources.json; do
        [ -f "$p" ] && printf '%s\n' "$p"
    done
    # C++ and LSP hold sources in memory only, so a restart is already fresh for
    # them. Globbed anyway: if either gains a store, this keeps working rather
    # than silently leaving it behind.
    for p in "$CPP_DIR"/data*/perception-sources.json \
             "$LSP_DIR"/data*/perception-sources.json; do
        [ -f "$p" ] && printf '%s\n' "$p"
    done
    return 0
}

clear_perception_state() {
    local path cleared=0
    info "Fresh universe — clearing persisted perception state"

    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if rm -f "$path" 2>/dev/null; then
            info "  removed ${path#$CI_DIR/../}"
            cleared=$((cleared + 1))
        else
            add_warn "--fresh could not remove $path"
        fi
    done < <(_perception_state_paths)

    # Redis is session/cache state — ephemeral by construction, and cheap to
    # rebuild, unlike the vector store next to it.
    if [ -d "$LAS_DIR/volumes/redis" ]; then
        if find "$LAS_DIR/volumes/redis" -mindepth 1 -delete 2>/dev/null; then
            info "  cleared localAIStack Redis state"
            cleared=$((cleared + 1))
        else
            add_warn "--fresh could not clear $LAS_DIR/volumes/redis"
        fi
    fi

    if [ "$FRESH_PROVIDER_CONTENT" = true ]; then
        if [ -d "$LAS_DIR/volumes/qdrant" ]; then
            if find "$LAS_DIR/volumes/qdrant" -mindepth 1 -delete 2>/dev/null; then
                info "  cleared localAIStack Qdrant vector store (--fresh-provider-content)"
                cleared=$((cleared + 1))
            else
                add_warn "--fresh-provider-content could not clear $LAS_DIR/volumes/qdrant"
            fi
        fi
    fi

    # Report the count rather than assert a wipe. The block this replaced
    # removed a Docker volume that no longer exists on any host — `docker volume
    # ls | grep -c _perception_sources_data` is 0 — and printed "Perception
    # volume cleared" regardless, so --fresh reported success having done
    # nothing at all (#144).
    if [ "$cleared" -eq 0 ]; then
        ok "No persisted perception state to clear"
    else
        ok "Cleared $cleared perception state location(s)"
    fi
}
