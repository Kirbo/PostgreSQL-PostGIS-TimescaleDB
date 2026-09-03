#!/bin/sh
# Prints what actually ended up in the database — shows up in `docker logs` on first start.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	SELECT version();
	SELECT extname, extversion FROM pg_extension ORDER BY extname;
EOSQL
