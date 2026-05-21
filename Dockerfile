# Self-contained image build for the relizaio fork of Dependency-Track.
# Mirrors src/main/docker/Dockerfile from the OWASP upstream and prepends
# a Maven builder stage so the rearm-docker-action GitHub Actions workflow
# (see .github/workflows/github_actions.yml) can produce the image without
# a pre-build step. Keep src/main/docker/Dockerfile untouched so upstream
# rebases stay clean.
#
# Arguments that can be passed at build time
# Directory names must end with / to avoid errors when COPYing
ARG COMMIT_SHA=unknown
ARG APP_VERSION=0.0.0
ARG APP_DIR=/opt/owasp/dependency-track/
ARG DATA_DIR=/data/
ARG UID=1000
ARG GID=1000
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

FROM debian:stable-slim@sha256:8f0c555de6a2f9c2bda1b170b67479d11f7f5e3b66bb4a7a1d8843361c9dd3ff

ARG COMMIT_SHA
ARG APP_VERSION
ARG APP_DIR
ARG DATA_DIR
ARG UID
ARG GID
ARG WAR_FILENAME

ENV TZ=Etc/UTC \
    LOGGING_LEVEL=INFO \
    JAVA_OPTIONS="-XX:+UseG1GC -XX:+UseStringDeduplication -XX:+UseCompactObjectHeaders -XX:MaxRAMPercentage=80.0 -XX:MaxGCPauseMillis=250" \
    EXTRA_JAVA_OPTIONS="" \
    CONTEXT="/" \
    WAR_FILENAME=${WAR_FILENAME} \
    JAVA_HOME=/opt/java/openjdk \
    PATH="/opt/java/openjdk/bin:${PATH}" \
    LANG=C.UTF-8 \
    HOME=${DATA_DIR} \
    DEFAULT_TEMPLATES_OVERRIDE_ENABLED=false \
    DEFAULT_TEMPLATES_OVERRIDE_BASE_DIRECTORY=${DATA_DIR} \
    LOGGING_CONFIG_PATH="logback.xml"

# Create the directories where the WAR will be deployed to (${APP_DIR}) and
# where Dependency-Track will store its data (${DATA_DIR}); create the dtrack
# user; install curl (used by HEALTHCHECK) and tini.
RUN mkdir -p ${APP_DIR} ${DATA_DIR} \
    && groupadd --system --gid ${GID} dtrack \
    && useradd --system --no-user-group --gid dtrack --no-create-home --home-dir ${DATA_DIR} --comment "dtrack user" --shell /bin/false --uid ${UID} dtrack \
    && chown -R dtrack:0 ${DATA_DIR} ${APP_DIR} \
    && chmod -R g=u ${DATA_DIR} ${APP_DIR} \
    && apt-get -yqq update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -yqq --no-install-recommends curl tini \
    && rm -rf /var/lib/apt/lists/*

USER ${UID}
WORKDIR ${APP_DIR}

COPY --from=jre-build --chown=${UID}:0 /opt/java/openjdk $JAVA_HOME
COPY --from=build-stage --chown=${UID}:0 /workdir/target/${WAR_FILENAME} /workdir/src/main/docker/logback-json.xml ./

ENTRYPOINT ["/usr/bin/tini", "--"]

# Launch Dependency-Track
CMD [ \
    "/bin/sh", "-c", \
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

HEALTHCHECK --interval=30s --start-period=60s --timeout=5s CMD [ \
    "/bin/sh", "-c", \
    "curl -f -s --max-time 3 --noproxy '*' -o /dev/null http://127.0.0.1:8080${CONTEXT}health" \
]

LABEL \
    org.opencontainers.image.vendor="Reliza Inc." \
    org.opencontainers.image.title="Dependency-Track API Server (relizaio fork)" \
    org.opencontainers.image.description="Dependency-Track API server, built from the relizaio fork tracking https://github.com/DependencyTrack/dependency-track" \
    org.opencontainers.image.version="${APP_VERSION}" \
    org.opencontainers.image.url="https://reliza.rearmhq.com/" \
    org.opencontainers.image.source="https://github.com/relizaio/dependency-track" \
    org.opencontainers.image.revision="${COMMIT_SHA}" \
    org.opencontainers.image.licenses="Apache-2.0"
