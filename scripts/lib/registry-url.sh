#!/bin/bash
# Where is the instance registry? — one answer for every consumer.
#
# Usage (sourced):  url="$(registry_url)"
#
# Order:
#   1. RE_REGISTRY_URL, when set: the caller (or startUniverse.sh) said so.
#   2. $CI_DIR/.universe-registry-url: startUniverse.sh writes the address the
#      running universe serves there on every start; stopUniverse.sh removes it
#      when the registry shim stops.
#   3. http://127.0.0.1:${RE_REGISTRY_PORT:-5999}/re-registry.json — the
#      fixed-port default (scripts/registry.sh).
#
# Consumers used to jump straight from 1 to a literal :5999. Under
# --free-ports the shim takes an OS-assigned port, so every script run without
# an exported RE_REGISTRY_URL looked for the registry where nothing listened.

registry_url() {
    if [ -n "${RE_REGISTRY_URL:-}" ]; then
        printf '%s\n' "$RE_REGISTRY_URL"
        return 0
    fi
    local ci_dir file url
    ci_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    file="${RE_UNIVERSE_REGISTRY_URL_FILE:-$ci_dir/.universe-registry-url}"
    if [ -s "$file" ]; then
        url="$(head -n 1 "$file" | tr -d '[:space:]')"
        if [ -n "$url" ]; then
            printf '%s\n' "$url"
            return 0
        fi
    fi
    printf 'http://127.0.0.1:%s/re-registry.json\n' "${RE_REGISTRY_PORT:-5999}"
}
