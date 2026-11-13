# Build context: ../RealityEngine_Rust (release/images.json re-rust; docker-compose.yml)
# Dockerfile referenced from: RealityEngine_CI/docker/rust/Dockerfile
#
# The Rust engine, a non-voting conformance follower (RealityEngine_CI#607),
# in the release and the docker lane (owner, 2026-11-12). One image, two
# services, as re-cpp: `reality-engine` (the RE) and `perception-engine` (the
# PE), both from the repo's Cargo.lock (--locked). The toolchain is the one
# rust-toolchain.toml names.
#
# ── Stage 1: Build ─────────────────────────────────────────────────────────
FROM rust:1.99.1-slim-bookworm AS build
WORKDIR /build
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY src/ src/
COPY conformance/surface/ conformance/surface/
RUN cargo build --release --locked --bins

# ── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM debian:bookworm-slim
# ca-certificates: the system roots for external parties (rustls-native-certs);
# curl for the compose healthcheck.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /app/bin /app/machines && \
    groupadd -r -g 1001 appuser && \
    useradd -r -u 1001 -g appuser appuser && \
    chown -R appuser:appuser /app
WORKDIR /app
COPY --from=build /build/target/release/reality-engine /build/target/release/perception-engine /app/bin/
ENV VECTOR_DIMENSION=7680 \
    MACHINES_DIR=/app/machines \
    REALITY_ENGINE_PORT=3000 \
    PERCEPTION_ENGINE_PORT=3004
USER appuser
# The compose service supplies the command (RE or PE).
CMD ["/app/bin/reality-engine"]
