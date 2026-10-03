# Build context: ../RealityEngine_Scala/perception-engine (set by docker-compose.yml)
# Dockerfile referenced from: ../RealityEngine_CI/docker/scala-perception-engine/Dockerfile
#
# The standalone Scala PE is its own sbt build (RealityEngine_Scala/perception-engine),
# so its directory is the whole context. This file used to COPY from
# scala/perception-engine/ — a monorepo layout that no longer exists — and
# nothing built it, so the breakage went unnoticed until the Docker lane needed
# a Scala PE beside the C++ and LSP ones.
#
# ── Stage 1: Build ──────────────────────────────────────────────────────────
FROM sbtscala/scala-sbt:eclipse-temurin-17.0.15_6_1.12.8_2.13.18 AS build

WORKDIR /build

# Cache dependency downloads by copying build files first
COPY project/build.properties project/plugins.sbt project/
COPY build.sbt build.sbt

RUN --mount=type=cache,target=/root/.sbt,sharing=locked \
    --mount=type=cache,target=/root/.ivy2,sharing=locked \
    --mount=type=cache,target=/root/.cache/coursier,sharing=locked \
    sbt update

# Compile and assemble fat JAR
COPY src/ src/
RUN --mount=type=cache,target=/root/.sbt,sharing=locked \
    --mount=type=cache,target=/root/.ivy2,sharing=locked \
    --mount=type=cache,target=/root/.cache/coursier,sharing=locked \
    sbt assembly

# ── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM eclipse-temurin:25-jre-jammy

WORKDIR /app

COPY --from=build /build/target/scala-2.13/perception-engine.jar ./perception-engine.jar

# wget for the compose healthcheck; the 25 JRE image does not ship it (#334).
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /app/data /app/machines /app/semantics && \
    groupadd -r -g 1001 appuser && \
    useradd -r -u 1001 -g appuser appuser && \
    chown -R appuser:appuser /app

EXPOSE 3004

ENV PORT=3004 \
    DATA_PATH=/app/data

USER appuser

CMD ["java", "-jar", "/app/perception-engine.jar"]
