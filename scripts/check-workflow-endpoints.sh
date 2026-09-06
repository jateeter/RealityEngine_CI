#!/usr/bin/env bash
# No workflow may LOCATE a service with a literal — RealityEngine_CI#278 step 5.
#
# The issue's original acceptance was "grep finds no host:port in the workflows".
# That is the wrong test, and enforcing it would make the workflows worse. Three
# kinds of literal appear there and only one is a defect:
#
#   LOOKUP       "where is the Manager" — must come from the registry, because
#                under --free-ports the answer is not knowable in advance.
#   BOOTSTRAP    the registry's own address. A registry cannot publish where it
#                is to a reader that has not found it yet, so exactly one
#                literal has to survive and everything else derives from it.
#   DECLARATION  "start the broker here", "serve MCP on this port". These
#                configure a service rather than finding one; there is nothing
#                to resolve them from, since they are what creates the thing.
#
# So this gate allows an annotated exception and fails anything else. The
# annotation is the point: a literal with a stated reason is a decision, and a
# literal without one is an oversight.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CI_DIR"

# Bootstrap and declarations, each with why it cannot be resolved.
ALLOWED=(
  "RE_REGISTRY_URL"                 # bootstrap: the registry's own address
  "default: 'http://127.0.0.1:7331" # declaration: where MCP is served
  "default: 'http://127.0.0.1:8088" # declaration: where Swagger is served
  "mcp_url="                        # declaration fallback for the above
  "swagger_url="                    # declaration fallback for the above
  "SCHEDULE_MCP_URL"                # declaration fallback, scheduled runs
  "SCHEDULE_SWAGGER_URL"            # declaration fallback, scheduled runs
  "HOSTED_MQTT_BROKER_URL"          # declaration: the broker this run starts
  "service_endpoint "               # the resolver's own fallback argument
  "PLAYWRIGHT_BASE_URL: 'https://"  # TLS-fronted Docker deployment; the registry
                                    # publishes native endpoints only, so this
                                    # cannot resolve until the deployments
                                    # converge (RealityEngine_CI#165)
)

fail=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  case "$hit" in
    *"#"*"://"*) continue ;;   # prose in a comment
  esac
  allowed=false
  for pattern in "${ALLOWED[@]}"; do
    case "$hit" in *"$pattern"*) allowed=true; break ;; esac
  done
  if [ "$allowed" = false ]; then
    echo "FAIL literal endpoint used to locate a service:"
    echo "     $hit"
    echo "     Resolve it with scripts/lib/resolve-endpoint.sh, or add it to"
    echo "     ALLOWED here with the reason it cannot be resolved."
    fail=1
  fi
done < <(grep -nE "(localhost|127\.0\.0\.1):[0-9]{4}" .github/workflows/*.yml || true)

if [ "$fail" -eq 0 ]; then
  echo "workflow endpoints: no literal is used to locate a service"
fi
exit "$fail"
