#!/usr/bin/env bash
# tests/smoke.sh main|defaults — the smoke test, run inside the `smoke` stage of tests/Dockerfile
# (FROM the image under test, once per platform; amd64 runs under emulation on the arm64 Mac).
#
#   main      starts the image, asserts it contains the versions it claims, exercises both
#             extensions for real (a hypertable + a spatial query), replays the Home Assistant
#             LTSS DDL, checks the HEALTHCHECK, the upgrade stamp, and that a restart with the
#             same image does no upgrade work
#   defaults  a second, fresh volume without POSTGRES_USER / POSTGRES_DB: the official image's
#             defaults get both extensions too
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. /ppt/tests/lib.sh

PASSWORD="smoke-test-only"

main() {
  test_begin smoke-main
  local c=smoke

  section "starting the image (${TARGETPLATFORM:-native})"
  ctr_start "$c" -e POSTGRES_PASSWORD="$PASSWORD" -e POSTGRES_USER=smoke -e POSTGRES_DB=smoke

  section "waiting for the server to accept connections"
  ctr_wait_socket "$c" smoke smoke 120
  # The socket answers during the entrypoint's temporary local-only startup, i.e. possibly BEFORE
  # the initdb.d scripts have created the extensions. Wait for the real listener too.
  ctr_wait_ready "$c" smoke 120

  q() { ctr_exec "$c" psql -X -A -t -q -v ON_ERROR_STOP=1 -U smoke -d smoke -c "$1"; }

  section "asserting versions"
  local want_arch=''
  case "${TARGETPLATFORM:-}" in
    linux/amd64) want_arch=x86_64 ;;
    linux/arm64) want_arch=aarch64 ;;
  esac
  [ -z "$want_arch" ] || assert_eq "architecture" "$want_arch" "$(ctr_exec "$c" uname -m)"
  assert_eq "postgresql"  "$WANT_PG_VERSION"          "$(q "SHOW server_version;" | cut -d' ' -f1)"
  assert_eq "postgis"     "$WANT_POSTGIS_VERSION"     "$(q "SELECT extversion FROM pg_extension WHERE extname = 'postgis';")"
  assert_eq "timescaledb" "$WANT_TIMESCALEDB_VERSION" "$(q "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';")"
  assert_eq "postgis_topology present" "1" "$(q "SELECT count(*) FROM pg_extension WHERE extname = 'postgis_topology';")"
  assert_eq "template_postgis is a template" "t" "$(q "SELECT datistemplate FROM pg_database WHERE datname = 'template_postgis';")"
  # Everyone on the previous major (the :latest of last week, the day a new major is adopted)
  # must be upgradable by this image, on every platform: the Dockerfile only SKIPS an older major
  # it cannot bundle, so this is the check that stops such an image from being published.
  local bundled
  bundled="$(ctr_exec "$c" sh -c '. /etc/ppt-upgrade-from.env && echo "$PPT_UPGRADE_FROM_MAJORS"')"
  case " ${bundled} " in
    *" $((WANT_PG_MAJOR - 1)) "*) echo "${C_OK}ok:${C_OFF} PostgreSQL $((WANT_PG_MAJOR - 1)) is upgradable (bundled: ${bundled})" ;;
    *) assert_eq "previous major bundled for the automatic upgrade" "$((WANT_PG_MAJOR - 1))" "${bundled:-<none>}" ;;
  esac

  section "exercising TimescaleDB (hypertable + chunks)"
  q "CREATE TABLE readings (ts timestamptz NOT NULL, sensor int, value double precision);" >/dev/null
  q "SELECT create_hypertable('readings', 'ts');" >/dev/null
  q "INSERT INTO readings SELECT now() - (s || ' minutes')::interval, s % 5, random() FROM generate_series(1, 1000) s;" >/dev/null
  assert_eq "hypertable rows" "1000" "$(q "SELECT count(*) FROM readings;")"
  assert_eq "chunks created"  "t"    "$(q "SELECT count(*) > 0 FROM timescaledb_information.chunks WHERE hypertable_name = 'readings';")"

  section "exercising PostGIS (geometry + spatial index + distance query)"
  q "CREATE TABLE places (id serial PRIMARY KEY, geom geometry(Point, 4326));" >/dev/null
  q "CREATE INDEX places_geom_idx ON places USING gist (geom);" >/dev/null
  q "INSERT INTO places (geom) VALUES (ST_SetSRID(ST_MakePoint(24.94, 60.17), 4326)), (ST_SetSRID(ST_MakePoint(23.76, 61.50), 4326));" >/dev/null
  assert_eq "places within 200km of Helsinki" "1" \
    "$(q "SELECT count(*) FROM places WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(24.94, 60.17), 4326)::geography, 200000) AND ST_Distance(geom::geography, ST_SetSRID(ST_MakePoint(24.94, 60.17), 4326)::geography) < 1;")"

  section "exercising both together (geometry column on a hypertable)"
  q "ALTER TABLE readings ADD COLUMN location geometry(Point, 4326);" >/dev/null
  q "UPDATE readings SET location = ST_SetSRID(ST_MakePoint(24.94, 60.17), 4326) WHERE sensor = 1;" >/dev/null
  assert_eq "geo-tagged readings" "t" "$(q "SELECT count(*) > 0 FROM readings WHERE ST_X(location) IS NOT NULL;")"

  # --- Home Assistant LTSS / ltss-turbo compatibility ---------------------------------------
  #
  # https://github.com/freol35241/ltss and https://github.com/velaar/ltss-turbo are the reason
  # this image exists (PostGIS + TimescaleDB in one server), and the weekly auto-update means
  # nobody reviews the version bump before it ships. So replay the exact DDL those integrations
  # issue: the LEGACY positional create_hypertable() signature, the pre-hypercore
  # `timescaledb.compress` table options, add_compression_policy/add_retention_policy, a GIST
  # index on a PostGIS point, and an EWKT insert. If a future TimescaleDB drops any of it, this
  # fails here instead of in someone's Home Assistant log.
  section "exercising Home Assistant LTSS compatibility (ltss / ltss-turbo DDL)"
  ctr_exec "$c" psql -X -q -o /dev/null -v ON_ERROR_STOP=1 -U smoke -d smoke <<'SQL'
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

  assert_eq "ltss hypertable registered" "1" "$(q "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_name = 'ltss';")"
  assert_eq "ltss compression + retention policies" "2" "$(q "SELECT count(*) FROM timescaledb_information.jobs WHERE hypertable_name = 'ltss' AND proc_name IN ('policy_compression', 'policy_retention');")"
  assert_eq "ltss chunk compressed" "t" "$(q "SELECT count(*) > 0 FROM timescaledb_information.chunks WHERE hypertable_name = 'ltss' AND is_compressed;")"
  assert_eq "ltss location readable after compression" "POINT(24.94 60.17)" "$(q "SELECT ST_AsText(location) FROM ltss WHERE location IS NOT NULL;")"
  assert_eq "ltss time_bucket aggregation" "t" "$(q "SELECT count(*) > 0 FROM (SELECT time_bucket('1 hour', time) b, avg(state_numeric) FROM ltss WHERE entity_id = 'sensor.temp' GROUP BY b) x;")"

  # --- container plumbing --------------------------------------------------------------------

  section "asserting the HEALTHCHECK command reports healthy"
  ctr_wait_healthy "$c" 60
  echo "${C_OK}ok:${C_OFF} healthy after ${HEALTHY_AFTER}s: $(healthcheck_cmd)"
  assert_eq "data directory stamped for the upgrade check" \
    "postgresql=${WANT_PG_MAJOR} postgis=${WANT_POSTGIS_VERSION} timescaledb=${WANT_TIMESCALEDB_VERSION}" \
    "$(ctr_exec "$c" sh -c 'cat "$PGDATA/.ppt-versions"')"

  section "asserting a restart with the same image is a no-op for the upgrade logic"
  ctr_restart "$c"
  ctr_wait_ready "$c" smoke 60
  assert_eq "no upgrade activity on restart" "0" "$(ctr_logs "$c" | grep -c 'ppt: .*checking extensions' || true)"
  assert_eq "hypertable rows survive a restart" "1000" "$(q "SELECT count(*) FROM readings;")"
  ctr_stop "$c"

  test_pass "${TARGETPLATFORM:-native}"
}

defaults() {
  test_begin smoke-defaults
  local c=defaults
  section "asserting the official image's defaults (no POSTGRES_USER / POSTGRES_DB) get both extensions"
  ctr_start "$c" -e POSTGRES_PASSWORD="$PASSWORD"
  ctr_wait_ready "$c" postgres 120
  assert_eq "extensions in the default 'postgres' database" "postgis,postgis_topology,timescaledb" \
    "$(ctr_exec "$c" psql -X -A -t -U postgres -c "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname <> 'plpgsql';")"
  ctr_stop "$c"
  test_pass "${TARGETPLATFORM:-native}"
}

case "${1:-}" in
  main) main ;;
  defaults) defaults ;;
  *) echo "usage: smoke.sh main|defaults" >&2; exit 2 ;;
esac
