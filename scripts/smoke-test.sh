#!/bin/sh
# smoke-test.sh IMAGE — start the image, assert it contains the versions it claims, and
# exercise both extensions for real (a hypertable + a spatial query), then clean up.
#
# Versions are read from build.env when present (written by resolve-versions.sh in CI),
# otherwise from versions.env — so this works identically on a laptop and in the pipeline.
set -eu

IMAGE="${1:?usage: smoke-test.sh IMAGE}"

if [ -f build.env ]; then . ./build.env; else . ./versions.env; fi

NAME="ppt-smoke-$$"
PASSWORD="smoke-test-only"

cleanup() {
  # Logs first: on a failed assertion they are the only record of what the server did.
  if [ "${KEEP_LOGS:-1}" = "1" ]; then
    echo "--- container logs ---"
    docker logs "$NAME" 2>&1 | tail -n 60 || true
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> starting $IMAGE as $NAME"
docker run -d --name "$NAME" \
  -e POSTGRES_PASSWORD="$PASSWORD" \
  -e POSTGRES_USER=smoke \
  -e POSTGRES_DB=smoke \
  "$IMAGE" >/dev/null

echo "==> waiting for the server to accept connections"
i=0
until docker exec "$NAME" pg_isready -U smoke -d smoke >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then
    echo "ERROR: server did not become ready within 120s" >&2
    exit 1
  fi
  sleep 1
done
# pg_isready goes green during the entrypoint's temporary local-only startup, i.e. possibly
# BEFORE the initdb.d scripts have created the extensions. Wait for the real listener too.
i=0
until docker exec "$NAME" pg_isready -h 127.0.0.1 -U smoke -d smoke >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then
    echo "ERROR: init scripts did not finish within 120s" >&2
    exit 1
  fi
  sleep 1
done

q() { docker exec "$NAME" psql -X -A -t -q -v ON_ERROR_STOP=1 -U smoke -d smoke -c "$1"; }

assert_eq() { # assert_eq LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then
    echo "ok: $1 = $3"
  else
    echo "FAIL: $1 — expected '$2', got '$3'" >&2
    exit 1
  fi
}

echo "==> asserting versions"
assert_eq "postgresql"  "$PG_VERSION"          "$(q "SHOW server_version;" | cut -d' ' -f1)"
assert_eq "postgis"     "$POSTGIS_VERSION"     "$(q "SELECT extversion FROM pg_extension WHERE extname = 'postgis';")"
assert_eq "timescaledb" "$TIMESCALEDB_VERSION" "$(q "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';")"
assert_eq "postgis_topology present" "1" "$(q "SELECT count(*) FROM pg_extension WHERE extname = 'postgis_topology';")"
assert_eq "template_postgis is a template" "t" "$(q "SELECT datistemplate FROM pg_database WHERE datname = 'template_postgis';")"

echo "==> exercising TimescaleDB (hypertable + chunks)"
q "CREATE TABLE readings (ts timestamptz NOT NULL, sensor int, value double precision);" >/dev/null
q "SELECT create_hypertable('readings', 'ts');" >/dev/null
q "INSERT INTO readings SELECT now() - (s || ' minutes')::interval, s % 5, random() FROM generate_series(1, 1000) s;" >/dev/null
assert_eq "hypertable rows" "1000" "$(q "SELECT count(*) FROM readings;")"
assert_eq "chunks created"  "t"    "$(q "SELECT count(*) > 0 FROM timescaledb_information.chunks WHERE hypertable_name = 'readings';")"

echo "==> exercising PostGIS (geometry + spatial index + distance query)"
q "CREATE TABLE places (id serial PRIMARY KEY, geom geometry(Point, 4326));" >/dev/null
q "CREATE INDEX places_geom_idx ON places USING gist (geom);" >/dev/null
q "INSERT INTO places (geom) VALUES (ST_SetSRID(ST_MakePoint(24.94, 60.17), 4326)), (ST_SetSRID(ST_MakePoint(23.76, 61.50), 4326));" >/dev/null
assert_eq "places within 200km of Helsinki" "1" \
  "$(q "SELECT count(*) FROM places WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(24.94, 60.17), 4326)::geography, 200000) AND ST_Distance(geom::geography, ST_SetSRID(ST_MakePoint(24.94, 60.17), 4326)::geography) < 1;")"

echo "==> exercising both together (geometry column on a hypertable)"
q "ALTER TABLE readings ADD COLUMN location geometry(Point, 4326);" >/dev/null
q "UPDATE readings SET location = ST_SetSRID(ST_MakePoint(24.94, 60.17), 4326) WHERE sensor = 1;" >/dev/null
assert_eq "geo-tagged readings" "t" "$(q "SELECT count(*) > 0 FROM readings WHERE ST_X(location) IS NOT NULL;")"

KEEP_LOGS=0
echo "==> smoke test PASSED for $IMAGE"
