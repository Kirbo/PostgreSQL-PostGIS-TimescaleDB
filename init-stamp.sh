#!/bin/sh
# Runs last on a fresh $PGDATA: records which image versions this data directory matches, so
# docker-entrypoint-ppt.sh can skip its extension check on every later start with one stat.
set -e
echo "postgresql=${PG_MAJOR} postgis=${POSTGIS_VERSION} timescaledb=${TIMESCALEDB_VERSION}" > "$PGDATA/.ppt-versions"
