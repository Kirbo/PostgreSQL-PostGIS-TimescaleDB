#!/bin/sh
# smoke-test.sh IMAGE — start the image, assert it contains the versions it claims, and
# exercise both extensions for real (a hypertable + a spatial query), then clean up.
#
# Versions are read from build.env when present (written by resolve-versions.sh in CI),
# otherwise from versions.env — so this works identically on a laptop and in the pipeline.
#
# PLATFORM=linux/amd64 runs the container for that platform (QEMU / Rosetta emulation when it
# is not the host's own) — the pipeline does this for every published architecture.
set -eu

IMAGE="${1:?usage: smoke-test.sh IMAGE}"

# shellcheck disable=SC1091
if [ -f build.env ]; then . ./build.env; else . ./versions.env; fi

NAME="ppt-smoke-$$"
PASSWORD="smoke-test-only"
PLATFORM_ARGS="${PLATFORM:+--platform $PLATFORM}"

cleanup() {
  # Logs first: on a failed assertion they are the only record of what the server did.
  if [ "${KEEP_LOGS:-1}" = "1" ]; then
    echo "--- container logs ---"
    docker logs "$NAME" 2>&1 | tail -n 60 || true
    docker logs "$NAME-defaults" 2>&1 | tail -n 30 || true
  fi
  docker rm -f "$NAME" "$NAME-defaults" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> starting $IMAGE as $NAME${PLATFORM:+ ($PLATFORM)}"
# shellcheck disable=SC2086
docker run -d --name "$NAME" $PLATFORM_ARGS \
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
assert_eq "architecture" "${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}" \
  "$(docker inspect --format '{{.Os}}/{{.Architecture}}' "$IMAGE")"
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

# --- Home Assistant LTSS / ltss-turbo compatibility -----------------------------------------
#
# https://github.com/freol35241/ltss and https://github.com/velaar/ltss-turbo are the reason
# this image exists (PostGIS + TimescaleDB in one server), and the weekly auto-update means
# nobody reviews the version bump before it ships. So replay the exact DDL those integrations
# issue: the LEGACY positional create_hypertable() signature, the pre-hypercore
# `timescaledb.compress` table options, add_compression_policy/add_retention_policy, a GIST
# index on a PostGIS point, and an EWKT insert. If a future TimescaleDB drops any of it, this
# fails here instead of in someone's Home Assistant log.
echo "==> exercising Home Assistant LTSS compatibility (ltss / ltss-turbo DDL)"
docker exec -i "$NAME" psql -X -q -o /dev/null -v ON_ERROR_STOP=1 -U smoke -d smoke <<'SQL'
CREATE TABLE ltss (
    time TIMESTAMPTZ NOT NULL,
    entity_id VARCHAR(255) NOT NULL,
    state VARCHAR(255),
    attributes JSONB,
    domain VARCHAR(50) NOT NULL,
    state_numeric DOUBLE PRECISION,
    location geometry(Point, 4326),
    PRIMARY KEY (time, entity_id)
);
SET client_min_messages = warning;
SELECT create_hypertable('ltss', 'time',
    chunk_time_interval => INTERVAL '86400 seconds',
    if_not_exists => TRUE,
    migrate_data => FALSE);
ALTER TABLE ltss SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'entity_id',
    timescaledb.compress_orderby = 'time DESC'
);
SELECT add_compression_policy('ltss', INTERVAL '7 days', if_not_exists => TRUE);
SELECT add_retention_policy('ltss', INTERVAL '365 days', if_not_exists => TRUE);
CREATE INDEX ix_ltss_location_gist ON ltss USING GIST (location) WHERE location IS NOT NULL;
CREATE INDEX ix_ltss_attributes_gin ON ltss USING GIN (attributes);
INSERT INTO ltss (time, entity_id, state, attributes, domain, state_numeric, location)
VALUES (now(), 'device_tracker.phone', 'home', '{"battery": 97}'::jsonb, 'device_tracker', 1.0,
        'SRID=4326;POINT(24.94 60.17)');
INSERT INTO ltss (time, entity_id, state, domain, state_numeric)
SELECT now() - (s || ' hours')::interval, 'sensor.temp', (s % 30)::text, 'sensor', s % 30
FROM generate_series(1, 200) s;
SELECT compress_chunk(c) FROM show_chunks('ltss', older_than => INTERVAL '2 hours') c LIMIT 1;
SQL

assert_eq "ltss hypertable registered" "1"   "$(q "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_name = 'ltss';")"
assert_eq "ltss compression + retention policies" "2"   "$(q "SELECT count(*) FROM timescaledb_information.jobs WHERE hypertable_name = 'ltss' AND proc_name IN ('policy_compression', 'policy_retention');")"
assert_eq "ltss chunk compressed" "t"   "$(q "SELECT count(*) > 0 FROM timescaledb_information.chunks WHERE hypertable_name = 'ltss' AND is_compressed;")"
assert_eq "ltss location readable after compression" "POINT(24.94 60.17)"   "$(q "SELECT ST_AsText(location) FROM ltss WHERE location IS NOT NULL;")"
assert_eq "ltss time_bucket aggregation" "t"   "$(q "SELECT count(*) > 0 FROM (SELECT time_bucket('1 hour', time) b, avg(state_numeric) FROM ltss WHERE entity_id = 'sensor.temp' GROUP BY b) x;")"

# --- container plumbing ----------------------------------------------------------------------

echo "==> asserting the HEALTHCHECK reports healthy"
i=0
until [ "$(docker inspect --format '{{.State.Health.Status}}' "$NAME")" = healthy ]; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "ERROR: container did not become healthy within 60s (status: $(docker inspect --format '{{.State.Health.Status}}' "$NAME"))" >&2
    exit 1
  fi
  sleep 1
done
echo "ok: healthy after ${i}s"
assert_eq "data directory stamped for the upgrade check" \
  "postgresql=${PG_MAJOR} postgis=${POSTGIS_VERSION} timescaledb=${TIMESCALEDB_VERSION}" \
  "$(docker exec "$NAME" sh -c 'cat "$PGDATA/.ppt-versions"')"

echo "==> asserting a restart with the same image is a no-op for the upgrade logic"
docker restart "$NAME" >/dev/null
i=0
until docker exec "$NAME" pg_isready -h 127.0.0.1 -U smoke -d smoke >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -le 60 ] || { echo "ERROR: server did not come back within 60s" >&2; exit 1; }
  sleep 1
done
assert_eq "no upgrade activity on restart" "0" "$(docker logs "$NAME" 2>&1 | grep -c 'ppt: .*checking extensions' || true)"
assert_eq "hypertable rows survive a restart" "1000" "$(q "SELECT count(*) FROM readings;")"

echo "==> asserting the official image's defaults (no POSTGRES_USER / POSTGRES_DB) get both extensions"
# shellcheck disable=SC2086
docker run -d --name "$NAME-defaults" $PLATFORM_ARGS -e POSTGRES_PASSWORD="$PASSWORD" "$IMAGE" >/dev/null
i=0
until docker exec "$NAME-defaults" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -le 120 ] || { echo "ERROR: default-config server did not become ready within 120s" >&2; exit 1; }
  sleep 1
done
assert_eq "extensions in the default 'postgres' database" "postgis,postgis_topology,timescaledb" \
  "$(docker exec "$NAME-defaults" psql -X -A -t -U postgres -c "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname <> 'plpgsql';")"

KEEP_LOGS=0
echo "==> smoke test PASSED for $IMAGE${PLATFORM:+ ($PLATFORM)}"
