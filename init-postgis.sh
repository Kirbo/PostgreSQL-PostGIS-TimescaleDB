#!/bin/sh
# Runs once, on an empty $PGDATA, via the base image's /docker-entrypoint-initdb.d hook.
set -e

# template_postgis is the conventional way to get PostGIS into databases created LATER:
#   CREATE DATABASE gis TEMPLATE template_postgis;
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
	CREATE DATABASE template_postgis;
	UPDATE pg_database SET datistemplate = TRUE WHERE datname = 'template_postgis';
EOSQL

for DB in template_postgis "$POSTGRES_DB"; do
	echo "Loading PostGIS extensions into $DB"
	psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB" <<-EOSQL
		CREATE EXTENSION IF NOT EXISTS postgis;
		CREATE EXTENSION IF NOT EXISTS postgis_topology;
	EOSQL
done
