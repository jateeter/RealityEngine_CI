# The universe stamp (.universe-engine-selection): what startUniverse.sh
# started, read back by stopUniverse.sh to decide what to stop.
#
# startUniverse.sh writes the stamp early, before the preflight that can still
# refuse the start (ports in use, an instance registry that lists running
# engines, a stack running from another checkout). A refused start used to
# leave its own stamp over the running universe's: a refused `--no-openclaw`
# start stamped OPENCLAW=no over a universe that had started OpenClaw, and
# stopUniverse.sh then skipped the OpenClaw stack and left Open WebUI and the
# browser sidecar running on :8080 and :9222 (e1-dev-20261126b, 2026-11-26).
#
#   universe_stamp_stage STAMP       before writing STAMP: keep the one there
#   universe_stamp_commit STAMP      the preflight passed: the new STAMP stands
#   universe_stamp_abandon STAMP     the start died before committing: put the
#                                    kept stamp back (or remove the new one)
#   universe_openclaw_stamp STAMPED MANIFEST
#                                    the OpenClaw value stopUniverse.sh acts on:
#                                    STAMPED, unless it is "no" and MANIFEST
#                                    (startUniverse.sh's universe manifest)
#                                    records openclaw_started true

universe_stamp_stage() {
  local stamp="$1"
  UNIVERSE_STAMP_PENDING=true
  rm -f "$stamp.prev"
  if [ -f "$stamp" ]; then cp -p "$stamp" "$stamp.prev"; fi
}

universe_stamp_commit() {
  UNIVERSE_STAMP_PENDING=false
  rm -f "$1.prev"
}

universe_stamp_abandon() {
  local stamp="$1"
  [ "${UNIVERSE_STAMP_PENDING:-false}" = true ] || return 0
  UNIVERSE_STAMP_PENDING=false
  if [ -f "$stamp.prev" ]; then
    mv -f "$stamp.prev" "$stamp"
  else
    rm -f "$stamp"
  fi
}

universe_openclaw_stamp() {
  local stamped="${1:-auto}" manifest="$2" started
  if [ "$stamped" = no ] && [ -f "$manifest" ]; then
    started=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("openclaw_started", False))' \
      "$manifest" 2>/dev/null || echo False)
    [ "$started" = True ] && { echo yes; return 0; }
  fi
  echo "$stamped"
}
