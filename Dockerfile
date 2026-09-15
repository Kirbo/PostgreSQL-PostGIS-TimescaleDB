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
# Manifest-list digest of that tag (versions.env's PG_IMAGE_DIGEST). Empty = whatever the tag
# points at today; set = reproducible, and what CI always does.
ARG PG_IMAGE_DIGEST=

FROM postgres:${PG_VERSION}-${DEBIAN_SUITE}${PG_IMAGE_DIGEST:+@${PG_IMAGE_DIGEST}}

# Re-declare after FROM: ARGs above FROM are not visible inside the build stage.
# PG_MAJOR is already an ENV in the base image, so it is deliberately NOT an ARG here — the
# base image is the authority on which major it contains.
ARG DEBIAN_SUITE=trixie
ARG POSTGIS_VERSION=3.6.4
ARG TIMESCALEDB_VERSION=2.30.0
# Oldest PostgreSQL major whose server binaries (plus PostGIS + TimescaleDB at the versions
# above) are bundled so that a data directory of that major is pg_upgrade'd automatically on
# start. Majors for which upstream has no TimescaleDB package at TIMESCALEDB_VERSION are
# skipped (Timescale requires the same extension version on both sides of pg_upgrade), which
# is what bounds the list in practice. Set to PG_MAJOR to bundle nothing.
ARG MIN_UPGRADE_FROM_MAJOR=15
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

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
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

# Install the extensions for the image's own major, then server + extensions for every older
# major that the auto-upgrade can start from. The current major is mandatory; an older major
# is bundled only when BOTH extensions exist for it at exactly these versions.
UPGRADE_FROM=""
major="${MIN_UPGRADE_FROM_MAJOR}"
while [ "$major" -le "$PG_MAJOR" ]; do
  POSTGIS_PKG="$(resolve_pkg "postgresql-${major}-postgis-3" "${POSTGIS_VERSION}")"
  POSTGIS_SCRIPTS_PKG="$(resolve_pkg "postgresql-${major}-postgis-3-scripts" "${POSTGIS_VERSION}")"
  TIMESCALEDB_PKG="$(resolve_pkg "timescaledb-2-postgresql-${major}" "${TIMESCALEDB_VERSION}")"
  TIMESCALEDB_LOADER_PKG="$(resolve_pkg "timescaledb-2-loader-postgresql-${major}" "${TIMESCALEDB_VERSION}")"

  if [ "$major" = "$PG_MAJOR" ]; then
    require "postgresql-${major}-postgis-3 ${POSTGIS_VERSION}" "${POSTGIS_PKG}"
    require "postgresql-${major}-postgis-3-scripts ${POSTGIS_VERSION}" "${POSTGIS_SCRIPTS_PKG}"
    require "timescaledb-2-postgresql-${major} ${TIMESCALEDB_VERSION}" "${TIMESCALEDB_PKG}"
    require "timescaledb-2-loader-postgresql-${major} ${TIMESCALEDB_VERSION}" "${TIMESCALEDB_LOADER_PKG}"
    SERVER_PKGS=""
  elif [ -z "${POSTGIS_PKG}" ] || [ -z "${POSTGIS_SCRIPTS_PKG}" ] || [ -z "${TIMESCALEDB_PKG}" ] || [ -z "${TIMESCALEDB_LOADER_PKG}" ]; then
    echo "upgrade-from PostgreSQL ${major}: skipped (postgis=${POSTGIS_PKG:-none} timescaledb=${TIMESCALEDB_PKG:-none})"
    major=$((major + 1))
    continue
  else
    SERVER_PKGS="postgresql-${major}"
    UPGRADE_FROM="${UPGRADE_FROM:+${UPGRADE_FROM} }${major}"
  fi

  echo "resolved for PostgreSQL ${major}: postgis=${POSTGIS_PKG} postgis-scripts=${POSTGIS_SCRIPTS_PKG} timescaledb=${TIMESCALEDB_PKG} loader=${TIMESCALEDB_LOADER_PKG}"
  # shellcheck disable=SC2086
  apt-get install -y --no-install-recommends ${SERVER_PKGS} \
    "postgresql-${major}-postgis-3=${POSTGIS_PKG}" \
    "postgresql-${major}-postgis-3-scripts=${POSTGIS_SCRIPTS_PKG}" \
    "timescaledb-2-loader-postgresql-${major}=${TIMESCALEDB_LOADER_PKG}" \
    "timescaledb-2-postgresql-${major}=${TIMESCALEDB_PKG}"
  major=$((major + 1))
done
# Read by docker-entrypoint-ppt.sh to decide whether a data directory can be upgraded.
echo "PPT_UPGRADE_FROM_MAJORS=\"${UPGRADE_FROM}\"" > /etc/ppt-upgrade-from.env
echo "bundled upgrade sources: PostgreSQL ${UPGRADE_FROM:-<none>}"

# The bundled old majors exist only to run pg_upgrade. Their extensions are brought to
# TIMESCALEDB_VERSION before that happens, so the ~350 MB of previous TimescaleDB shared
# libraries each package carries (for in-place updates FROM those versions) are dead weight
# there, as is the LLVM JIT bitcode. The image's own major keeps everything.
for major in ${UPGRADE_FROM}; do
  find "/usr/lib/postgresql/${major}/lib" -name 'timescaledb-*.so' \
    ! -name "timescaledb-${TIMESCALEDB_VERSION}.so" ! -name "timescaledb-tsl-${TIMESCALEDB_VERSION}.so" -delete
  rm -rf "/usr/lib/postgresql/${major}/lib/bitcode" "/usr/share/postgresql/${major}/man"
done

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
# what ended up installed, and the stamp that marks the directory as matching this image last.
COPY ./init-postgis.sh /docker-entrypoint-initdb.d/1.postgis.sh
COPY ./init-timescaledb.sh /docker-entrypoint-initdb.d/2.timescaledb.sh
COPY ./init-postgres.sh /docker-entrypoint-initdb.d/3.postgres.sh
COPY ./init-stamp.sh /docker-entrypoint-initdb.d/9.ppt-stamp.sh

# Existing data directories are brought up to date (extension updates, pg_upgrade from an
# older bundled major) before the official entrypoint starts the server. See the script.
COPY --chmod=755 ./docker-entrypoint-ppt.sh /usr/local/bin/docker-entrypoint-ppt.sh
ENTRYPOINT ["docker-entrypoint-ppt.sh"]
CMD ["postgres"]

# The base image ships no healthcheck; docker-compose depends_on: service_healthy needs one.
# TCP on purpose: the entrypoint's temporary init/upgrade server listens on the socket only,
# so a socket check would report healthy while the extensions are still being set up.
# hadolint ignore=DL3025
HEALTHCHECK --interval=10s --timeout=5s --start-period=5m --retries=5 \
  CMD pg_isready -h localhost -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" || exit 1
