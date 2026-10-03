# Build context: ../RealityEngine_CPP (set by docker-compose.yml)
# Dockerfile referenced from: ../RealityEngine_CI/docker/cpp/Dockerfile
#
# One image, two services: the compose file runs it once as the RE
# (`reality_engine_server`) and once as the PE (`perception_engine_server`),
# with the same arguments RealityEngine_CPP/start.sh passes natively. Only the
# two runtime servers are built — the Makefile's `all` also builds ~18 test and
# cesgen binaries the container never runs (RealityEngine_CPP#43).
#
# Ubuntu 24.04, the hosted lane's runner image, not Debian bookworm: bookworm's
# Boost 1.74 does not compile under C++20 (boost/asio/awaitable.hpp uses
# std::exchange without including <utility>); noble ships 1.83.
#
# ── Stage 1: Build ─────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS build

# The same two libraries the hosted lane installs (regression-tests.yml):
# Boost is header-only here (asio + beast), OpenSSL is linked.
RUN apt-get update && \
    apt-get install -y --no-install-recommends g++ make libboost-dev libssl-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Makefile ./
COPY include/ include/
COPY src/ src/

# BOOST_PREFIX/OPENSSL_PREFIX default to `brew --prefix`; on Ubuntu the system
# include and lib paths are already on the compiler's search path.
RUN make -j"$(nproc)" BOOST_PREFIX= OPENSSL_PREFIX= \
        bin/reality_engine_server bin/perception_engine_server

# ── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM ubuntu:24.04

# libssl3t64 (noble's name for libssl3) for the linked servers; wget for the
# compose healthcheck.
RUN apt-get update && \
    apt-get install -y --no-install-recommends libssl3t64 ca-certificates wget && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /app/bin /app/machines /app/semantics && \
    groupadd -r -g 1001 appuser && \
    useradd -r -u 1001 -g appuser appuser && \
    chown -R appuser:appuser /app

WORKDIR /app
COPY --from=build /build/bin/reality_engine_server /build/bin/perception_engine_server /app/bin/

ENV VECTOR_DIMENSION=7680 \
    MACHINES_DIR=/app/machines

USER appuser

# The compose service supplies the command (RE or PE, with its port arguments).
CMD ["/app/bin/reality_engine_server", "3000", "/app/machines", "7680"]
