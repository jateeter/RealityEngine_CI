#!/usr/bin/env bash
# node-env.sh — establish the Node version every Node-based operation runs on.
#
# Never inherit it from the terminal. An interactive deploy-validate run used
# the shell's nvm default (25.5.0), and the gate skipped the Manager build as
# "Node 25.5.0 too old (need >=26.0.0)" — a failure caused by whoever started
# the run, not by the code (RealityEngine_Machines#126). Scheduled runs only
# worked because #477 fixed launchd's PATH. Every script that runs node, npm,
# npx or Playwright calls establish_node first.
#
#   source scripts/lib/node-env.sh
#   establish_node        # nvm use $RE_NODE_VERSION (default 26.8); install if absent
#
# One minor everywhere: the workflows (node-version 26.8), the Docker images
# (node:26.8-alpine, node:26.8-bookworm-slim), every .nvmrc and this. A bare
# major let nvm pick the newest 26.x installed, so a machine with 26.10 ran a
# different Node from the hosted lane without anything saying so.
#
# RE_NODE_VERSION overrides it; RE_NODE_MAJOR, its earlier name, still does.
# Fails (return 1) with a stated reason when nvm is unavailable or the version
# cannot be selected, rather than continuing on whatever node is on PATH.

: "${RE_NODE_VERSION:=${RE_NODE_MAJOR:-26.8}}"

establish_node() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    echo "node-env: nvm not found at $NVM_DIR/nvm.sh — cannot establish Node $RE_NODE_VERSION" >&2
    return 1
  fi
  # nvm.sh is not safe under `set -u`; restore the caller's setting after.
  local had_u=false
  case $- in *u*) had_u=true; set +u ;; esac
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh" --no-use
  if ! nvm use "$RE_NODE_VERSION" >/dev/null 2>&1; then
    nvm install "$RE_NODE_VERSION" >/dev/null 2>&1 && nvm use "$RE_NODE_VERSION" >/dev/null 2>&1 || {
      [ "$had_u" = true ] && set -u
      echo "node-env: could not select Node $RE_NODE_VERSION via nvm" >&2
      return 1
    }
  fi
  [ "$had_u" = true ] && set -u
  return 0
}
