# syntax=docker/dockerfile:1

# PostgreSQL + PostGIS + TimescaleDB, on top of the official Debian postgres image.
#
# Both extensions are installed as PACKAGES rather than compiled from source:
#   PostGIS     -> apt.postgresql.org (PGDG); the repo is already configured in the base image
#   TimescaleDB -> packagecloud.io/timescale/timescaledb (added below)
# Both publish amd64 AND arm64 for Debian bookworm/trixie, which is what makes
# `docker buildx --platform linux/amd64,linux/arm64` cheap: a package install per arch instead
# of a ~20 min PostGIS+TimescaleDB compile under QEMU emulation on the arm64 runner.
#
# Versions come from versions.env via --build-arg (scripts/docker-buildx-release.sh does this).
# The defaults below are only for a bare `docker build .`.

ARG PG_VERSION=18.6
ARG DEBIAN_SUITE=trixie

FROM postgres:${PG_VERSION}-${DEBIAN_SUITE}

# Re-declare after FROM: ARGs above FROM are not visible inside the build stage.
# PG_MAJOR is already an ENV in the base image, so it is deliberately NOT an ARG here — the
# base image is the authority on which major it contains.
ARG DEBIAN_SUITE=trixie
ARG POSTGIS_VERSION=3.6.4
ARG TIMESCALEDB_VERSION=2.29.2
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="PostgreSQL + PostGIS + TimescaleDB" \
      org.opencontainers.image.description="PostgreSQL ${PG_VERSION} with PostGIS ${POSTGIS_VERSION} and TimescaleDB ${TIMESCALEDB_VERSION}" \
      org.opencontainers.image.source="https://gitlab.com/KirboDev/agentic-coding/postgresql-postgis-timescaledb" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV POSTGIS_VERSION=${POSTGIS_VERSION} \
    TIMESCALEDB_VERSION=${TIMESCALEDB_VERSION}

RUN <<'EOF'
set -eux

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg

# TimescaleDB apt repo. PGDG is already wired up by the base image
# (/etc/apt/sources.list.d/pgdg.list, components "main ${PG_MAJOR}").
curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/timescaledb.gpg
echo "deb [signed-by=/usr/share/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/debian/ ${DEBIAN_SUITE} main" \
  > /etc/apt/sources.list.d/timescaledb.list
apt-get update

# Map an UPSTREAM version (3.6.4) to the exact Debian revision in the repo
# (3.6.4+dfsg-2.pgdg13+1), highest first — apt-cache madison lists in preference order.
# Matching on "<want>" or "<want>" followed by a separator stops 3.6.4 from matching 3.6.41.
# An empty result aborts the build: better a red pipeline than an image that silently
# contains a different version than the one it is tagged with.
resolve_pkg() {
  apt-cache madison "$1" | awk -F'|' '{ gsub(/ /, "", $2); print $2 }' \
    | while read -r ver; do
        case "$ver" in
          "$2" | "$2"[+~-]*) echo "$ver"; break ;;
        esac
      done
}

require() {
  [ -n "$2" ] || { echo "ERROR: no package '$1' matching the requested version in the apt repos" >&2; exit 1; }
}

POSTGIS_PKG="$(resolve_pkg "postgresql-${PG_MAJOR}-postgis-3" "${POSTGIS_VERSION}")"
POSTGIS_SCRIPTS_PKG="$(resolve_pkg "postgresql-${PG_MAJOR}-postgis-3-scripts" "${POSTGIS_VERSION}")"
TIMESCALEDB_PKG="$(resolve_pkg "timescaledb-2-postgresql-${PG_MAJOR}" "${TIMESCALEDB_VERSION}")"
TIMESCALEDB_LOADER_PKG="$(resolve_pkg "timescaledb-2-loader-postgresql-${PG_MAJOR}" "${TIMESCALEDB_VERSION}")"

require "postgresql-${PG_MAJOR}-postgis-3 ${POSTGIS_VERSION}" "${POSTGIS_PKG}"
require "postgresql-${PG_MAJOR}-postgis-3-scripts ${POSTGIS_VERSION}" "${POSTGIS_SCRIPTS_PKG}"
require "timescaledb-2-postgresql-${PG_MAJOR} ${TIMESCALEDB_VERSION}" "${TIMESCALEDB_PKG}"
require "timescaledb-2-loader-postgresql-${PG_MAJOR} ${TIMESCALEDB_VERSION}" "${TIMESCALEDB_LOADER_PKG}"

echo "resolved: postgis=${POSTGIS_PKG} postgis-scripts=${POSTGIS_SCRIPTS_PKG} timescaledb=${TIMESCALEDB_PKG} loader=${TIMESCALEDB_LOADER_PKG}"

apt-get install -y --no-install-recommends \
  "postgresql-${PG_MAJOR}-postgis-3=${POSTGIS_PKG}" \
  "postgresql-${PG_MAJOR}-postgis-3-scripts=${POSTGIS_SCRIPTS_PKG}" \
  "timescaledb-2-loader-postgresql-${PG_MAJOR}=${TIMESCALEDB_LOADER_PKG}" \
  "timescaledb-2-postgresql-${PG_MAJOR}=${TIMESCALEDB_PKG}"

# TimescaleDB is a loadable module: without it in shared_preload_libraries, CREATE EXTENSION
# timescaledb fails. The base image copies this sample into $PGDATA at initdb time, so patching
# it here is what makes a fresh volume come up TimescaleDB-ready.
# ($PG_MAJOR/postgresql.conf.sample is a symlink to this file.)
sed -ri "s!^#?\s*(shared_preload_libraries)\s*=\s*'([^']*)'.*!\1 = 'timescaledb,\2'!; s!,'!'!" \
  /usr/share/postgresql/postgresql.conf.sample
grep -q "^shared_preload_libraries = 'timescaledb" /usr/share/postgresql/postgresql.conf.sample

apt-get purge -y --auto-remove curl gnupg
rm -rf /var/lib/apt/lists/*
EOF

# Order matters: PostGIS and TimescaleDB extensions are created before the summary that prints
# what ended up installed.
COPY ./init-postgis.sh /docker-entrypoint-initdb.d/1.postgis.sh
COPY ./init-timescaledb.sh /docker-entrypoint-initdb.d/2.timescaledb.sh
COPY ./init-postgres.sh /docker-entrypoint-initdb.d/3.postgres.sh

# The base image ships no healthcheck; docker-compose depends_on: service_healthy needs one.
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=5 \
  CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" || exit 1
