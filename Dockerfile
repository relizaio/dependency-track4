# Self-contained image build for the relizaio fork of Dependency-Track.
# Mirrors src/main/docker/Dockerfile from the OWASP upstream and prepends
# a Maven builder stage so the rearm-docker-action GitHub Actions workflow
# (see .github/workflows/github_actions.yml) can produce the image without
# a pre-build step. Keep src/main/docker/Dockerfile untouched so upstream
# rebases stay clean.
#
# Runtime base differs from upstream: we use distroless instead of
# debian:stable-slim. The dtrack project's own scan on 2026-05-22 (release
# 4.14.2-reliza.0) flagged 52 Critical/High/Medium CVEs in the upstream-shape
# image, 51 of which came from debian:stable-slim's apt-installed packages
# (glibc, curl, krb5, openssl, openldap, ncurses, sqlite3, systemd, util-linux,
# coreutils, mawk, libtasn1, nghttp2, pam, zlib). Switching to
# gcr.io/distroless/base-debian13:debug-nonroot drops the count to 5
# (0 Crit/High, 5 Medium — all glibc-level "no fix available" findings any
# glibc image faces). Trade-off: no apt/curl/tini in the image, so the
# Dockerfile HEALTHCHECK is dropped — K8s liveness/readiness probes (which
# is how this image is actually monitored on rearm-cd-managed clusters)
# replace it. The :debug-nonroot variant ships /busybox/sh so the existing
# ${JAVA_OPTIONS}/${EXTRA_JAVA_OPTIONS} env-var expansion in CMD still works
# without forcing every consumer over to JAVA_TOOL_OPTIONS.
#
# Arguments that can be passed at build time
# Directory names must end with / to avoid errors when COPYing
ARG COMMIT_SHA=unknown
ARG APP_VERSION=0.0.0
ARG APP_DIR=/opt/owasp/dependency-track/
ARG DATA_DIR=/data/
# UID 65532 / GID 0: distroless's built-in `nonroot` user; matches the
# image's default USER. No useradd needed.
ARG UID=65532
ARG GID=0
ARG WAR_FILENAME=dependency-track-apiserver.jar

FROM maven:3.9.15-eclipse-temurin-21@sha256:856fe78872c59d3b584a64d07693d5433cbf44e35b5ba1f2c911147f39f54266 AS build-cache-stage
WORKDIR /workdir
COPY pom.xml ./
# Warm the local Maven cache before pulling in the rest of the sources so a
# code-only change re-uses this layer (rearm-core/backend's Dockerfile pattern).
RUN mvn -B -T1C dependency:go-offline

FROM maven:3.9.15-eclipse-temurin-21@sha256:856fe78872c59d3b584a64d07693d5433cbf44e35b5ba1f2c911147f39f54266 AS build-stage
WORKDIR /workdir
COPY --from=build-cache-stage /root/.m2 /root/.m2
COPY . ./
# Maven invocation matching upstream _meta-build.yaml for the apiserver
# distribution (excludes the bundled UI; the frontend ships as a separate
# image). services.bom.merge.skip=true: that step invokes a `cyclonedx` CLI
# binary that isn't present in the base Maven image; it produces a release-
# level BOM that we don't bundle in the image anyway (ReARM generates its
# own SBOM via Dockerfile.sbom). Skipping keeps the builder dependency-free.
RUN mvn -B -P quick -P enhance -P embedded-jetty \
        -Dservices.bom.merge.skip=true \
        -Dlogback.configuration.file=src/main/docker/logback.xml \
        package

FROM eclipse-temurin:25.0.2_10-jre-jammy@sha256:d36843a6f1af5d0aca01ef3d926e2220444eb19fe38e1b23cef3d663ef29b306 AS jre-build

# Tiny shell-having stage just to create the runtime layout (the app dir +
# the data dir) with the right ownership; distroless can't `mkdir` so we
# bake the directory tree here and COPY it across.
FROM busybox:1.37.0@sha256:0d3f1e630be52ade0c06107515937607be2cab11a2ad2122099fc79e19bcc18b AS layout-stage
ARG APP_DIR
ARG DATA_DIR
ARG UID
ARG GID
RUN mkdir -p /layout${APP_DIR} /layout${DATA_DIR} \
 && chown -R ${UID}:${GID} /layout

FROM gcr.io/distroless/base-debian13:debug-nonroot@sha256:e66792ecce3d0044c797624461716e14df4aa88c57a3a00c3a41dfba3293d84e

ARG COMMIT_SHA
ARG APP_VERSION
ARG APP_DIR
ARG DATA_DIR
ARG UID
ARG GID
ARG WAR_FILENAME

ENV TZ=Etc/UTC \
    LOGGING_LEVEL=INFO \
    # -Duser.home: the distroless `nonroot` user's /etc/passwd entry has
    # `/home/nonroot` as its home dir, which is in the image layer (not on
    # the PV) and not what dtrack should write to. The Alpine framework
    # writes ~/.dependency-track/id.system on first start, and the JVM
    # reads `user.home` from getpwuid(), not from $HOME. Without this flag
    # the apiserver crashes with NoSuchFileException on /home/nonroot/...
    # Pin to ${DATA_DIR} (which is on the PV and chowned to UID 65532).
    JAVA_OPTIONS="-XX:+UseG1GC -XX:+UseStringDeduplication -XX:+UseCompactObjectHeaders -XX:MaxRAMPercentage=80.0 -XX:MaxGCPauseMillis=250 -Duser.home=/data" \
    EXTRA_JAVA_OPTIONS="" \
    CONTEXT="/" \
    WAR_FILENAME=${WAR_FILENAME} \
    JAVA_HOME=/opt/java/openjdk \
    PATH="/opt/java/openjdk/bin:/busybox:${PATH}" \
    LANG=C.UTF-8 \
    HOME=${DATA_DIR} \
    DEFAULT_TEMPLATES_OVERRIDE_ENABLED=false \
    DEFAULT_TEMPLATES_OVERRIDE_BASE_DIRECTORY=${DATA_DIR} \
    LOGGING_CONFIG_PATH="logback.xml"

# Pre-created directories with correct ownership (distroless has no mkdir).
# Copy only the subtrees we own — `COPY --from=layout-stage / /` would also
# drag busybox's `/bin → /busybox` symlink, which collides with distroless's
# real `/bin` directory and fails the build.
COPY --from=layout-stage --chown=${UID}:${GID} /layout${APP_DIR}  ${APP_DIR}
COPY --from=layout-stage --chown=${UID}:${GID} /layout${DATA_DIR} ${DATA_DIR}

# JRE 25 (same image upstream uses as jre-build) and the apiserver JAR.
COPY --from=jre-build  --chown=${UID}:${GID} /opt/java/openjdk $JAVA_HOME
COPY --from=build-stage --chown=${UID}:${GID} /workdir/target/${WAR_FILENAME} /workdir/src/main/docker/logback-json.xml ${APP_DIR}

USER ${UID}
WORKDIR ${APP_DIR}

# Launch Dependency-Track. /busybox/sh is provided by the `:debug-nonroot`
# variant of the distroless base; the rest of the command is unchanged from
# upstream's CMD so EXTRA_JAVA_OPTIONS/JAVA_OPTIONS env-var expansion at run
# time still works (no migration to JAVA_TOOL_OPTIONS needed).
ENTRYPOINT [ \
    "/busybox/sh", "-c", \
    "exec java \
        ${JAVA_OPTIONS} ${EXTRA_JAVA_OPTIONS} \
        --add-opens java.base/java.util.concurrent=ALL-UNNAMED \
        --sun-misc-unsafe-memory-access=allow \
        -Dlogback.configurationFile=${LOGGING_CONFIG_PATH} \
        -DdependencyTrack.logging.level=${LOGGING_LEVEL} \
        -jar ${WAR_FILENAME} \
        -context ${CONTEXT}" \
]

EXPOSE 8080

# HEALTHCHECK omitted: distroless ships no curl. The image is consumed by
# rearm-cd-managed K8s deployments where the helm chart wires up an HTTP
# liveness/readiness probe against ${CONTEXT}health on port 8080, which is
# the canonical health signal anyway — the Dockerfile HEALTHCHECK was never
# read by the runtime. Add a probe block to the helm chart (which already
# does for the deploy/dependency-track-helm chart in rearm-core) if you
# deploy this image outside K8s and need an equivalent.

LABEL \
    org.opencontainers.image.vendor="Reliza Inc." \
    org.opencontainers.image.title="Dependency-Track API Server (relizaio fork)" \
    org.opencontainers.image.description="Dependency-Track API server, built from the relizaio fork tracking https://github.com/DependencyTrack/dependency-track" \
    org.opencontainers.image.version="${APP_VERSION}" \
    org.opencontainers.image.url="https://reliza.rearmhq.com/" \
    org.opencontainers.image.source="https://github.com/relizaio/dependency-track" \
    org.opencontainers.image.revision="${COMMIT_SHA}" \
    org.opencontainers.image.licenses="Apache-2.0"
