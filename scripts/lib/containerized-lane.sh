#!/usr/bin/env bash
# The local-containerized lane (RealityEngine_CI#165; ReleaseRoadmap E1).
#
# Sourced by scripts/regression-test.sh under --profile local-containerized.
# The lane runs the local lane's live stages against the RELEASE IMAGES
# instead of native processes: the same corpus, the same instance registry
# contract, the same stages, on the same hardware, so a difference between the
# two lanes is a difference between the deployments and nothing else.
#
#   --images FILE   install that images file (a published candidate, by digest)
#                   — the certifying form;
#   (no --images)   build the images from the run's worktrees with
#                   release/build-images.py and install them locally — the
#                   development form, which certifies the source, not a
#                   published artifact.
#
# The install lives in <run>/install under the fixed compose project
# re-regression; a previous run's install of that project is removed first.
# Like the native lane, the universe is left running at the end for
# inspection; `RE_REGRESSION_KEEP=0` removes it.

CONTAINERIZED_PROJECT="${CONTAINERIZED_PROJECT:-re-regression}"

containerized_cli() {
  # The installer, from the run's own CI worktree, against the run's install.
  REALITYENGINE_DIR="$RUN_DIR/install" REALITYENGINE_PROJECT="$CONTAINERIZED_PROJECT" \
    bash "$(repo_root RealityEngine_CI)/release/realityengine" "$@"
}

containerized_image_tag() {
  # dev-<run id>, lower-cased to the image tag alphabet.
  printf 'dev-%s' "$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-')"
}

# Build every release image from the run's worktrees (no --images), or take the
# given images file; either way leave <run>/reports/images.json naming exactly
# what will be installed, and check each image's revision label against the
# commit its repo was checked out at. A mismatch is a different source than
# the run certifies, and fails the build phase.
containerized_build_images() {
  local ci images
  ci="$(repo_root RealityEngine_CI)"
  images="$REPORT_DIR/images.json"
  mkdir -p "$REPORT_DIR"
  if [ -n "$RELEASE_IMAGES_FILE" ]; then
    step "Release images: the published candidate"
    cp "$RELEASE_IMAGES_FILE" "$images"
  else
    step "Release images: build from the run's worktrees"
    run_cmd "build-release-images" python3 "$ci/release/build-images.py" \
      --workspace "$(dirname "$ci")" --tag "$(containerized_image_tag)" --out "$images" || return 1
  fi
  run_cmd "release-images-provenance" python3 - "$images" "$RUN_DIR/manifest.json" <<'PYEOF'
import json, sys
images = json.load(open(sys.argv[1]))["images"]
repos = {r["name"]: r.get("worktreeSha") for r in json.load(open(sys.argv[2])).get("repos", [])}
bad = [f"{i['name']}: built from {i['repo']} {i.get('revision','')[:12]}, run pins {str(repos.get(i['repo']))[:12]}"
       for i in images if repos.get(i["repo"]) and i.get("revision") != repos[i["repo"]]]
print(f"{len(images)} image(s); revision labels checked against the run's pins")
if bad:
    print("\n".join("  " + b for b in bad))
    sys.exit(1)
PYEOF
}

containerized_start() {
  local tag args=()
  step "Install the release images"
  # A previous run of this lane leaves its install up; remove it, data too.
  local old
  for old in "$RUN_DIR"/../*/install; do
    [ -f "$old/.env" ] || continue
    grep -q "^COMPOSE_PROJECT_NAME=$CONTAINERIZED_PROJECT$" "$old/.env" || continue
    (cd "$old" && docker compose down -v --remove-orphans) >/dev/null 2>&1 || true
  done
  if [ -n "$RELEASE_IMAGES_FILE" ]; then
    tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$REPORT_DIR/images.json")"
    args=(--images "$REPORT_DIR/images.json")
  else
    tag="$(containerized_image_tag)"
    args=(--local)
  fi
  # The boot corpus, materialized here from the run's own worktrees by the same
  # script and manifest that built re-corpus: the stages that read machine
  # files (universal-vectors) read exactly what the engines booted.
  MACHINE_CORPUS_WORK_DIR="$RUN_DIR/corpus"
  run_cmd "materialize-boot-corpus" bash "$(repo_root RealityEngine_CI)/scripts/materialize-machine-corpus.sh" \
    "$(repo_root RealityEngine_Machines)" "$MACHINE_CORPUS_MANIFEST" "$MACHINE_CORPUS_WORK_DIR" \
    "$(repo_root localAIStack)/data/machines" || return 1
  run_cmd "install-release" containerized_cli install --version "$tag" --engines "$ENGINES_SPEC" "${args[@]}" || return 1
  REGISTRY_FILE="$RUN_DIR/install/registry/re-registry.json"
  RE_REGISTRY_URL="http://localhost:${RE_PORT_REGISTRY:-5999}/re-registry.json"
  export RE_REGISTRY_URL
  log "instance registry: $REGISTRY_FILE"
}

containerized_finish() {
  if [ "${RE_REGRESSION_KEEP:-1}" = "0" ]; then
    containerized_cli uninstall --purge >/dev/null 2>&1 || true
    log "Removed the install (RE_REGRESSION_KEEP=0)."
  else
    log "The install is left running: $RUN_DIR/install (project $CONTAINERIZED_PROJECT)."
  fi
}
