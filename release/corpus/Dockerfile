# re-corpus: the machine corpus a release ships (decision A8, ReleaseRoadmap B2).
#
#   /corpus/boot             the regression corpus the engines boot with,
#                            materialized by scripts/materialize-machine-corpus.sh
#                            from config/regression-corpus.txt (machines/,
#                            semantics/abox-manifest.json, machine-count.txt)
#   /corpus/catalog          RealityEngine_Machines at the release commit: what
#                            Manager's Load Machines modal offers (Manager#257),
#                            until `realityengine machines sync` replaces it
#   /corpus/localai-machines localAIStack's own machine definitions
#
# Built by release/build-images.py, which runs the materializer first and passes
# its output as the `boot` build context, with `machines` and `localai` the two
# source repos. The image only carries data: the release compose runs it once
# per start to copy the corpus into the volumes the engines and Manager mount.
FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

# boot, machines and localai below are named build contexts (release/images.json), not stages.

# hadolint ignore=DL3022
COPY --from=boot / /corpus/boot/
# hadolint ignore=DL3022
COPY --from=machines machines/ /corpus/catalog/machines/
# hadolint ignore=DL3022
COPY --from=machines semantics/abox-manifest.json /corpus/catalog/semantics/abox-manifest.json
# hadolint ignore=DL3022
COPY --from=localai / /corpus/localai-machines/

# Copy the shipped corpus into the mounted volumes. The script is written with
# single quotes on purpose: it expands when it runs, not at build time. boot and localai-machines are
# replaced on every start, so an upgrade boots the release's own corpus. The
# catalog is seeded only when empty: after `realityengine machines sync` it holds
# a newer RealityEngine_Machines, and a restart must not take that back.
# hadolint ignore=SC2016
RUN printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'for d in boot localai-machines; do' \
  '  mkdir -p "/volumes/$d"' \
  '  find "/volumes/$d" -mindepth 1 -delete' \
  '  cp -a "/corpus/$d/." "/volumes/$d/"' \
  'done' \
  'if [ -z "$(ls -A /volumes/catalog 2>/dev/null)" ]; then' \
  '  mkdir -p /volumes/catalog && cp -a /corpus/catalog/. /volumes/catalog/' \
  '  echo "catalog seeded from the release corpus"' \
  'fi' \
  'echo "corpus: $(cat /corpus/boot/machine-count.txt) boot machine(s)"' \
  > /usr/local/bin/seed-corpus && chmod 755 /usr/local/bin/seed-corpus

# Data only; the seed step needs to write the volumes as whoever owns them.
# hadolint ignore=DL3002
USER 0
CMD ["/usr/local/bin/seed-corpus"]
