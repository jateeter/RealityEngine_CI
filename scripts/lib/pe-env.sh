# shellcheck shell=bash
# The Perception Engine environment a universe gives every PE it starts, held
# once so startUniverse.sh and the follower lane (rust-conformance.sh) cannot
# drift apart. A value already in the environment wins.

# pe_env_defaults <integrations-config>
# ACP/OpenClaw, trigger dispatch, and the integrations configuration.
pe_env_defaults() {
    export ACP_ENABLED="${ACP_ENABLED:-true}"
    export ACP_PLATFORM="${ACP_PLATFORM:-OpenClaw}"
    export ACP_SURFACE="${ACP_SURFACE:-xACP}"
    export ACP_GATEWAY_URL="${ACP_GATEWAY_URL:-${OPENCLAW_GATEWAY_URL:-ws://127.0.0.1:18789}}"
    export OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-$ACP_GATEWAY_URL}"
    export ACP_SESSION_KEY="${ACP_SESSION_KEY:-${OPENCLAW_ACP_SESSION:-agent:main:main}}"
    export OPENCLAW_ACP_SESSION="${OPENCLAW_ACP_SESSION:-$ACP_SESSION_KEY}"
    export ACP_TARGET_AGENT="${ACP_TARGET_AGENT:-openclaw}"
    export ACP_COMPLETION_SOURCE_MAPPING_ID="${ACP_COMPLETION_SOURCE_MAPPING_ID:-acp-openclaw-completion}"
    export TRIGGERS_ENABLED="${TRIGGERS_ENABLED:-true}"
    export TRIGGER_DISPATCH_MODE="${TRIGGER_DISPATCH_MODE:-dry-run}"
    export INTEGRATIONS_CONFIG="$1"
}

# mqtt_client_id <instance-id> <instance-uuid>
# A PE's MQTT client id: unique per instance, so no two PEs on one broker
# share one. A broker drops an existing session when another connects with
# its id, so two bridges sharing one evict each other in turn (81 reconnects
# on cpp-1 in the 2026-11-01 R2 run). The UUID's last 8 hex digits are its
# random tail (v7 leads with the clock, which instances allocated together
# share). At most 23 bytes for a short id, the v3.1.1 guaranteed length.
mqtt_client_id() {
    local uuid="${2//-/}"
    printf 're-pe-%s-%s' "$1" "${uuid: -8}"
}
