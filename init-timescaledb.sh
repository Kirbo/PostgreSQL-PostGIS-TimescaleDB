#!/bin/sh
# Runs once, on an empty $PGDATA, via the base image's /docker-entrypoint-initdb.d hook.
set -e

# NOTE: no template_timescaledb here, unlike the PostGIS script above. Timescale does not
# support using a database that has TimescaleDB installed as a TEMPLATE — the copy carries
# the source database's internal catalog/job state. For a new database, create the extension
# in it directly instead:
#   CREATE DATABASE metrics;
#   \c metrics
#   CREATE EXTENSION timescaledb;
echo "Loading TimescaleDB extension into $POSTGRES_DB"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE EXTENSION IF NOT EXISTS timescaledb;
EOSQL
