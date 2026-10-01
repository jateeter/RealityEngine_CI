#!/usr/bin/env bash
# stack-owner.sh — is a support stack running from a different checkout?
#
# Docker Compose names a project after its directory (or the file's `name:`),
# so a worktree of localAIStack or localOpenClawStack is the *same project* as
# the main checkout. startUniverse.sh's pre-start cleanup ran `compose down` and
# `docker rm -f` on those stacks unconditionally, so a universe started from
# worktrees removed the operator's running stacks and recreated localAI with
# its bind mounts pointing into the worktree (RealityEngine_CI#479).
#
# The same project name does not mean the same checkout. Compose records the
# directory it was run from on every container, in the
# com.docker.compose.project.working_dir label; that is what this compares.
#
#   source scripts/lib/stack-owner.sh
#   stack_foreign_owner <checkout-dir> <container-name-regex>
#     prints the working_dir of the first running container whose name matches
#     and whose compose working_dir resolves somewhere other than <checkout-dir>.
#     Prints nothing when every match belongs to <checkout-dir>, or none runs.
#     A container with no compose label is not attributed to anyone.

_stack_owner_resolve() {
  # Physical path, so a symlinked workspace is not mistaken for another checkout.
  # A directory that no longer exists (a removed worktree) is returned as given.
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

stack_foreign_owner() {
  local dir="$1" pattern="$2" mine name wd
  mine=$(_stack_owner_resolve "$dir")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [[ "$name" =~ $pattern ]] || continue
    wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2>/dev/null || true)
    [ -n "$wd" ] || continue
    wd=$(_stack_owner_resolve "$wd")
    if [ "$wd" != "$mine" ]; then
      printf '%s\n' "$wd"
      return 0
    fi
  done < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
  return 0
}

# The container names each stack runs under, as startUniverse.sh removes them.
# Read by the scripts that source this file.
# shellcheck disable=SC2034
STACK_OWNER_LOCALAI_PATTERN='^localai_'
STACK_OWNER_OPENCLAW_PATTERN='^(openclaw-gateway|open-webui|browser)$'
