#!/bin/sh
# docker-buildx-release.sh test|publish — the single buildx invocation used by CI.
#
#   test     single-arch (the runner's own arch), --load into the local docker so
#            scripts/smoke-test.sh can actually run the image. Never pushed.
#   publish  every arch in PLATFORMS, --push, with the full tag set.
#
# Tags pushed by `publish`:
#   :latest                                                  moving, newest build
#   :<PG_MAJOR>                                              e.g. 18 — track a major
#   :<PG_VERSION>                                            e.g. 18.6
#   :<PG_VERSION>-postgis<X>-timescaledb<Y>                  the immutable, fully-qualified combo
#
# Inputs (env): DOCKER_REGISTRY, DOCKERHUB_REPOSITORY, BUILDER_NAME, LOCAL_TAG,
#   CI_COMMIT_SHORT_SHA; versions from build.env (resolve-versions.sh) or versions.env.
set -eu

MODE="${1:?usage: docker-buildx-release.sh test|publish}"

if [ -f build.env ]; then . ./build.env; else . ./versions.env; fi

REGISTRY="${DOCKER_REGISTRY:-docker.io}"
REPOSITORY="${DOCKERHUB_REPOSITORY:?DOCKERHUB_REPOSITORY is not set}"
IMAGE="${REGISTRY}/${REPOSITORY}"
COMBO="${PG_VERSION}-postgis${POSTGIS_VERSION}-timescaledb${TIMESCALEDB_VERSION}"

case "$MODE" in
  test)
    PLATFORM_ARGS="--load"
    OUTPUT_ARGS=""
    TAGS="-t ${LOCAL_TAG:-postgresql-postgis-timescaledb:ci-test}"
    ;;
  publish)
    PLATFORM_ARGS="--platform ${PLATFORMS}"
    # provenance + sbom: the pushed manifest records how and from what it was built.
    OUTPUT_ARGS="--push --provenance=true --sbom=true"
    TAGS="-t ${IMAGE}:latest -t ${IMAGE}:${PG_MAJOR} -t ${IMAGE}:${PG_VERSION} -t ${IMAGE}:${COMBO}"
    ;;
  *)
    echo "ERROR: unknown mode '${MODE}' (expected test|publish)" >&2
    exit 1
    ;;
esac

echo "==> ${MODE}: PostgreSQL ${PG_VERSION} + PostGIS ${POSTGIS_VERSION} + TimescaleDB ${TIMESCALEDB_VERSION} (${DEBIAN_SUITE})"

# ${PLATFORM_ARGS} / ${OUTPUT_ARGS} / ${TAGS} are deliberately unquoted — each is a list of
# flags, and some are empty depending on the mode.
# shellcheck disable=SC2086
docker buildx build \
  ${BUILDER_NAME:+--builder "${BUILDER_NAME}"} \
  --build-arg PG_VERSION="${PG_VERSION}" \
  --build-arg DEBIAN_SUITE="${DEBIAN_SUITE}" \
  --build-arg POSTGIS_VERSION="${POSTGIS_VERSION}" \
  --build-arg TIMESCALEDB_VERSION="${TIMESCALEDB_VERSION}" \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VCS_REF="${CI_COMMIT_SHORT_SHA:-local}" \
  ${PLATFORM_ARGS} \
  ${OUTPUT_ARGS} \
  ${TAGS} \
  -f Dockerfile .
