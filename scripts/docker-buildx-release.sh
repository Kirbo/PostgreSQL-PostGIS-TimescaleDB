#!/bin/sh
# docker-buildx-release.sh local|build|publish — the buildx / registry side of the pipeline.
#
#   local    single-arch (this machine's), --load into the local docker: what a laptop and
#            `make`-style usage want. Tag: LOCAL_TAG.
#   build    every arch in PLATFORMS, pushed ONCE to the staging registry (STAGING_IMAGE, the
#            project's GitLab container registry in CI) as :ci-<pipeline>, with provenance +
#            SBOM attestations. Writes the manifest-list digest to staging.env
#            (STAGING_REF=<image>@sha256:...), which is what gets tested and, unchanged, what
#            gets published — the bits that were tested are the bits that ship.
#   publish  re-tags STAGING_REF onto the Docker Hub tags (no rebuild: `imagetools create`
#            copies the manifest list + blobs), then verifies every tag resolves to the same
#            digest and carries every platform.
#
# Tags published:
#   :<PG_VERSION>-postgis<X>-timescaledb<Y>                  the fully-qualified combo
#   :<PG_VERSION>                                            e.g. 18.6
#   :<PG_MAJOR>                                              e.g. 18 — track a major
#   :latest                                                  moving, newest build
#
# They are pushed in that order ON PURPOSE. Docker Hub's tag page sorts by last-pushed, so
# pushing :latest LAST puts it at the top of
# https://hub.docker.com/r/kirbownz/postgresql-postgis-timescaledb/tags — and the rest fall in
# most-specific-last order beneath it.
#
# Inputs (env): DOCKER_REGISTRY, DOCKERHUB_REPOSITORY, STAGING_IMAGE, BUILDER_NAME, LOCAL_TAG,
#   CI_COMMIT_SHORT_SHA, CI_PIPELINE_ID; versions from build.env (resolve-versions.sh) or
#   versions.env.
set -eu

MODE="${1:?usage: docker-buildx-release.sh local|build|publish}"

# shellcheck disable=SC1091
if [ -f build.env ]; then . ./build.env; else . ./versions.env; fi

REGISTRY="${DOCKER_REGISTRY:-docker.io}"
REPOSITORY="${DOCKERHUB_REPOSITORY:?DOCKERHUB_REPOSITORY is not set}"
IMAGE="${REGISTRY}/${REPOSITORY}"
COMBO="${PG_VERSION}-postgis${POSTGIS_VERSION}-timescaledb${TIMESCALEDB_VERSION}"
STAGING_TAG="${STAGING_IMAGE:-}:ci-${CI_PIPELINE_ID:-local}"

build() { # build [buildx args...]
  echo "==> ${MODE}: PostgreSQL ${PG_VERSION} + PostGIS ${POSTGIS_VERSION} + TimescaleDB ${TIMESCALEDB_VERSION} (${DEBIAN_SUITE})"
  docker buildx build \
    ${BUILDER_NAME:+--builder "${BUILDER_NAME}"} \
    --build-arg PG_VERSION="${PG_VERSION}" \
    --build-arg DEBIAN_SUITE="${DEBIAN_SUITE}" \
    --build-arg POSTGIS_VERSION="${POSTGIS_VERSION}" \
    --build-arg TIMESCALEDB_VERSION="${TIMESCALEDB_VERSION}" \
    --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --build-arg VCS_REF="${CI_COMMIT_SHORT_SHA:-local}" \
    "$@" \
    -f Dockerfile .
}

case "$MODE" in
  local)
    build --load -t "${LOCAL_TAG:-postgresql-postgis-timescaledb:local}"
    ;;

  build)
    [ -n "${STAGING_IMAGE:-}" ] || { echo "ERROR: STAGING_IMAGE is not set" >&2; exit 1; }
    # provenance + sbom: the pushed manifest records how and from what it was built.
    build --platform "${PLATFORMS}" --push --provenance=true --sbom=true \
      --metadata-file staging-metadata.json -t "${STAGING_TAG}"
    DIGEST="$(sed -n 's/.*"containerimage.digest": *"\([^"]*\)".*/\1/p' staging-metadata.json | head -n 1)"
    [ -n "$DIGEST" ] || { echo "ERROR: no digest in staging-metadata.json" >&2; cat staging-metadata.json; exit 1; }
    {
      echo "STAGING_TAG=${STAGING_TAG}"
      echo "STAGING_REF=${STAGING_IMAGE}@${DIGEST}"
      echo "STAGING_DIGEST=${DIGEST}"
    } > staging.env
    echo "==> pushed ${STAGING_TAG} = ${DIGEST}"
    docker buildx imagetools inspect "${STAGING_TAG}"
    ;;

  publish)
    # shellcheck disable=SC1091
    [ -f staging.env ] && . ./staging.env
    [ -n "${STAGING_REF:-}" ] || { echo "ERROR: STAGING_REF is not set (no staging.env from the build job?)" >&2; exit 1; }
    echo "==> publishing ${STAGING_REF} as ${IMAGE}:{${COMBO},${PG_VERSION},${PG_MAJOR},latest}"
    for tag in "${COMBO}" "${PG_VERSION}" "${PG_MAJOR}" latest; do
      docker buildx imagetools create -t "${IMAGE}:${tag}" "${STAGING_REF}"
    done

    echo "==> verifying what Docker Hub now serves"
    want="${STAGING_DIGEST:-${STAGING_REF##*@}}"
    for tag in "${COMBO}" "${PG_VERSION}" "${PG_MAJOR}" latest; do
      got="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "${IMAGE}:${tag}")"
      if [ "$got" != "$want" ]; then
        echo "ERROR: ${IMAGE}:${tag} is ${got}, expected ${want}" >&2
        exit 1
      fi
      echo "ok: ${IMAGE}:${tag} = ${got}"
    done
    platforms="$(docker buildx imagetools inspect --format '{{range .Manifest.Manifests}}{{if ne .Platform.OS "unknown"}}{{.Platform.OS}}/{{.Platform.Architecture}} {{end}}{{end}}' "${IMAGE}:latest")"
    for p in $(echo "${PLATFORMS}" | tr ',' ' '); do
      case " ${platforms} " in
        *" ${p} "*) echo "ok: ${IMAGE}:latest has ${p}" ;;
        *) echo "ERROR: ${IMAGE}:latest lacks ${p} (has: ${platforms})" >&2; exit 1 ;;
      esac
    done
    ;;

  *)
    echo "ERROR: unknown mode '${MODE}' (expected local|build|publish)" >&2
    exit 1
    ;;
esac
