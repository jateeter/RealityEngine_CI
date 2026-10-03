# Build context: ../RealityEngine_LSP (set by docker-compose.yml)
# Dockerfile referenced from: ../RealityEngine_CI/docker/lsp/Dockerfile
#
# One image, two services: `main` in the saved executable dispatches on its
# first argument, so the compose file runs it once as `reality` and once as
# `perception` — the same image start.sh launches natively in
# LSP_LAUNCH_MODE=binary. Building the executable here means container start is
# never a Quicklisp load.
#
# ── Stage 1: Build ─────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS build

# libssl-dev: drakma pulls in cl+ssl, which loads libssl through CFFI while the
# system is being built, not only at run time.
RUN apt-get update && \
    apt-get install -y --no-install-recommends sbcl make curl ca-certificates libssl-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Quicklisp and the dependency tree first, keyed on the .asd only, so a source
# edit does not re-download every library.
COPY reality-engine-lsp.asd ./
COPY scripts/bootstrap-quicklisp.sh scripts/
RUN bash scripts/bootstrap-quicklisp.sh --home --no-warm && \
    sbcl --noinform --disable-debugger --load /root/quicklisp/setup.lisp \
      --eval '(pushnew (truename ".") ql:*local-project-directories*)' \
      --eval '(ql:register-local-projects)' \
      --eval '(ql:quickload (remove-if-not (lambda (d) (and (or (symbolp d) (stringp d)) (not (search "reality-engine" (string-downcase (string d)))))) (asdf:system-depends-on (asdf:find-system :reality-engine-lsp))))' \
      --quit

COPY src/ src/
COPY Makefile ./
RUN make build QUICKLISP=/root/quicklisp/setup.lisp

# ── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM debian:bookworm-slim

# The saved image re-opens libssl through CFFI at start-up (cl+ssl), and its
# loader looks for the unversioned libssl.so that only the -dev package ships.
RUN apt-get update && \
    apt-get install -y --no-install-recommends libssl-dev ca-certificates wget && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /app/bin /app/machines /app/semantics /app/logs /app/run && \
    groupadd -r -g 1001 appuser && \
    useradd -r -u 1001 -g appuser appuser && \
    chown -R appuser:appuser /app

WORKDIR /app
COPY --from=build /build/bin/reality-engine-lsp /app/bin/reality-engine-lsp

ENV VECTOR_DIMENSION=7680 \
    MACHINES_DIR=/app/machines \
    SBCL_DYNAMIC_SPACE_SIZE=4096

USER appuser

# The compose service supplies the mode (reality | perception).
ENTRYPOINT ["/bin/sh", "-c", "exec /app/bin/reality-engine-lsp --dynamic-space-size \"$SBCL_DYNAMIC_SPACE_SIZE\" \"$@\"", "--"]
CMD ["reality"]
