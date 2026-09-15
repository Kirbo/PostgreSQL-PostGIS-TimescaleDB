#!/bin/sh
# upgrade-test.sh IMAGE — prove that IMAGE can take over the data directory of every image a
# user may currently be running, without losing data or needing manual steps:
#
#   1. the previously published image (PREVIOUS_IMAGE, default: the Docker Hub :latest), same
#      PostgreSQL major, possibly older PostGIS / TimescaleDB -> extensions updated in place,
#      then the whole thing again after an unclean shutdown (docker kill)
#   2. every older PostgreSQL major the image bundles binaries for (its
#      PPT_UPGRADE_FROM_MAJORS), in both layouts users have:
#        a. the volume mounted at /var/lib/postgresql/data (the <= 17 official layout)
#           -> upgraded in place, inside the mount
#        b. the volume mounted at /var/lib/postgresql (the 18+ layout)
#           -> upgraded into /var/lib/postgresql/<major>/docker
#      with a custom superuser, several databases, postgresql.conf / ALTER SYSTEM settings,
#      compressed TimescaleDB chunks and PostGIS geometries that all have to come through
#   3. PPT_AUTO_UPGRADE=off leaves a foreign data directory alone
#   4. an interrupted upgrade is resumed on the next start
#
# The old-major fixtures are built from this repository's own Dockerfile (postgres:<major>
# base, same extension versions), so the test needs the build context and versions; the
# previous published image is pulled. Runs on the host's architecture only.
#
# Env: PREVIOUS_IMAGES — space-separated images to start from in scenario 1. Default: the
#        published :latest AND the oldest published tag of the same PostgreSQL major (so the
#        extension-update path is exercised even when :latest is already current). "" skips.
#      UPGRADE_FROM_MAJORS (default: what the image reports), FIXTURE_PREFIX.
set -eu

IMAGE="${1:?usage: upgrade-test.sh IMAGE}"
# shellcheck disable=SC1091
if [ -f build.env ]; then . ./build.env; else . ./versions.env; fi

HUB_REPO="${DOCKERHUB_REPOSITORY:-kirbownz/postgresql-postgis-timescaledb}"

# oldest_published_tag MAJOR — the oldest "<major>.x-postgis*-timescaledb*" tag on Docker Hub
oldest_published_tag() {
  url="https://hub.docker.com/v2/repositories/${HUB_REPO}/tags?page_size=100&name=$1."
  { curl -fsSL "$url" 2>/dev/null || wget -qO- "$url" 2>/dev/null || true; } \
    | tr ',{' '\n' | sed -n 's/.*"name": *"\([0-9][0-9.]*-postgis[0-9.]*-timescaledb[0-9.]*\)".*/\1/p' \
    | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1
}

if [ "${PREVIOUS_IMAGES+set}" != set ]; then
  PREVIOUS_IMAGES="docker.io/${HUB_REPO}:latest"
  oldest="$(oldest_published_tag "$PG_MAJOR")"
  [ -z "$oldest" ] || PREVIOUS_IMAGES="${PREVIOUS_IMAGES} docker.io/${HUB_REPO}:${oldest}"
fi
FIXTURE_PREFIX="${FIXTURE_PREFIX:-ppt-upgrade-fixture}"
RUN_ID="$$"
PW="upgrade-test-only"

# --- helpers ----------------------------------------------------------------------------------

log()  { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

assert_eq() { # assert_eq LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then echo "ok: $1 = $3"; else fail "$1 — expected '$2', got '$3'"; fi
}

CONTAINERS=""
VOLUMES=""
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    for c in $CONTAINERS; do
      echo "--- logs of $c ---"; docker logs "$c" 2>&1 | tail -n 80 || true
    done
  fi
  # shellcheck disable=SC2086
  [ -z "$CONTAINERS" ] || docker rm -f $CONTAINERS >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  [ -z "$VOLUMES" ] || docker volume rm -f $VOLUMES >/dev/null 2>&1 || true
}
trap cleanup EXIT

# POSIX sh, no `local`: these helpers set the globals V (volume) and C (container) instead of
# printing, so the cleanup lists are updated in this shell rather than in a $(...) subshell.

new_volume() { # new_volume NAME -> V
  V="ppt-ut-${RUN_ID}-$1"
  docker volume rm -f "$V" >/dev/null 2>&1 || true
  docker volume create "$V" >/dev/null
  VOLUMES="$VOLUMES $V"
}

# start NAME IMAGE [docker run args...] -> C — background container, registered for cleanup
start() {
  C="ppt-ut-${RUN_ID}-$1"; _image="$2"; shift 2
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker run -d --name "$C" "$@" "$_image" >/dev/null
  CONTAINERS="$CONTAINERS $C"
}

# wait_ready CONTAINER USER [SECS] — until the real (TCP) listener answers; fails if it exits
wait_ready() {
  _limit="${3:-300}"; _i=0
  while :; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" != true ]; then
      fail "container $1 exited (exit code $(docker inspect -f '{{.State.ExitCode}}' "$1"))"
    fi
    docker exec "$1" pg_isready -h 127.0.0.1 -U "$2" >/dev/null 2>&1 && return 0
    _i=$((_i + 1)); [ "$_i" -le "$_limit" ] || fail "$1 not ready after ${_limit}s"
    sleep 1
  done
}

# wait_exit CONTAINER [SECS] — until it stops; prints its exit code
wait_exit() {
  _limit="${2:-120}"; _i=0
  while [ "$(docker inspect -f '{{.State.Running}}' "$1")" = true ]; do
    _i=$((_i + 1)); [ "$_i" -le "$_limit" ] || fail "$1 still running after ${_limit}s"
    sleep 1
  done
  docker inspect -f '{{.State.ExitCode}}' "$1"
}

stop() { docker stop "$1" >/dev/null; }   # clean shutdown, like `docker compose down`
kill9() { docker kill -s KILL "$1" >/dev/null; }

q() { # q CONTAINER USER DB SQL
  docker exec "$1" psql -X -A -t -q -v ON_ERROR_STOP=1 -U "$2" -d "$3" -c "$4"
}

# seed CONTAINER USER — the data set every scenario writes with the OLD image and reads back
# with the new one: a hypertable with geometries and a compressed chunk, a second database
# with its own hypertable, ALTER SYSTEM + postgresql.conf settings.
seed() {
  _c="$1"; _u="$2"
  docker exec -i "$_c" psql -X -q -o /dev/null -v ON_ERROR_STOP=1 -U "$_u" -d "$_u" <<'SQL'
CREATE TABLE readings (ts timestamptz NOT NULL, sensor int, value double precision, location geometry(Point, 4326));
SELECT create_hypertable('readings', 'ts', chunk_time_interval => INTERVAL '1 day');
INSERT INTO readings SELECT now() - (s || ' hours')::interval, s % 5, s, ST_SetSRID(ST_MakePoint(24.94, 60.17), 4326) FROM generate_series(1, 500) s;
CREATE INDEX readings_location_gist ON readings USING gist (location);
ALTER TABLE readings SET (timescaledb.compress, timescaledb.compress_segmentby = 'sensor');
SELECT compress_chunk(c) FROM show_chunks('readings', older_than => INTERVAL '3 days') c;
SELECT add_retention_policy('readings', INTERVAL '10 years');
CREATE DATABASE second;
SQL
  docker exec -i "$_c" psql -X -q -o /dev/null -v ON_ERROR_STOP=1 -U "$_u" -d second <<'SQL'
CREATE EXTENSION timescaledb;
CREATE EXTENSION postgis;
CREATE TABLE metrics (ts timestamptz NOT NULL, v int);
SELECT create_hypertable('metrics', 'ts');
INSERT INTO metrics SELECT now(), 42;
SQL
  q "$_c" "$_u" "$_u" "ALTER SYSTEM SET work_mem = '7MB'" >/dev/null
  docker exec "$_c" sh -c 'echo "max_connections = 123" >> "$PGDATA/postgresql.conf"'
}

# verify CONTAINER USER — everything seed() wrote is there and both extensions are current
verify() {
  _c="$1"; _u="$2"
  assert_eq "postgresql major"     "$PG_MAJOR"            "$(q "$_c" "$_u" "$_u" "SHOW server_version_num" | cut -c1-2)"
  assert_eq "postgis version"      "$POSTGIS_VERSION"     "$(q "$_c" "$_u" "$_u" "SELECT extversion FROM pg_extension WHERE extname = 'postgis'")"
  assert_eq "timescaledb version"  "$TIMESCALEDB_VERSION" "$(q "$_c" "$_u" "$_u" "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
  assert_eq "timescaledb in 2nd db" "$TIMESCALEDB_VERSION" "$(q "$_c" "$_u" second "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
  assert_eq "hypertable rows"      "500"                  "$(q "$_c" "$_u" "$_u" "SELECT count(*) FROM readings")"
  assert_eq "compressed chunk readable" "t"               "$(q "$_c" "$_u" "$_u" "SELECT count(*) > 0 FROM timescaledb_information.chunks WHERE hypertable_name = 'readings' AND is_compressed")"
  assert_eq "geometry survives"    "POINT(24.94 60.17)"   "$(q "$_c" "$_u" "$_u" "SELECT ST_AsText(location) FROM readings LIMIT 1")"
  assert_eq "spatial index usable" "500"                  "$(q "$_c" "$_u" "$_u" "SET enable_seqscan = off; SELECT count(*) FROM readings WHERE location && ST_MakeEnvelope(24, 60, 25, 61, 4326)")"
  assert_eq "retention policy kept" "1"                   "$(q "$_c" "$_u" "$_u" "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name = 'policy_retention' AND hypertable_name = 'readings'")"
  assert_eq "2nd db rows"          "42"                   "$(q "$_c" "$_u" second "SELECT v FROM metrics")"
  assert_eq "ALTER SYSTEM setting" "7MB"                  "$(q "$_c" "$_u" "$_u" "SHOW work_mem")"
  assert_eq "postgresql.conf setting" "123"               "$(q "$_c" "$_u" "$_u" "SHOW max_connections")"
  q "$_c" "$_u" "$_u" "CREATE TABLE after_upgrade (ts timestamptz NOT NULL, v int); SELECT create_hypertable('after_upgrade', 'ts'); INSERT INTO after_upgrade VALUES (now(), 1)" >/dev/null
  assert_eq "new hypertable works"  "1"                   "$(q "$_c" "$_u" "$_u" "SELECT count(*) FROM after_upgrade")"
  assert_eq "data directory stamped" "postgresql=${PG_MAJOR} postgis=${POSTGIS_VERSION} timescaledb=${TIMESCALEDB_VERSION}" \
    "$(docker exec "$_c" sh -c 'cat "$(psql -X -A -t -U '"$_u"' -d postgres -c "SHOW data_directory")/.ppt-versions"')"
}

# restart_is_noop CONTAINER USER — a second start with the same image does no upgrade work
restart_is_noop() {
  docker restart "$1" >/dev/null
  wait_ready "$1" "$2" 120
  assert_eq "no upgrade work on restart" "0" "$(docker logs --since "$(docker inspect -f '{{.State.StartedAt}}' "$1")" "$1" 2>&1 | grep -c 'ppt: \(upgrading\|checking extensions\)' || true)"
}

# --- 1. previously published image, same major ------------------------------------------------

n=0
for prev in $PREVIOUS_IMAGES; do
  n=$((n + 1))
  log "pulling the previously published image ${prev}"
  docker pull -q "$prev" >/dev/null
  prev_major="$(docker run --rm "$prev" sh -c 'echo "$PG_MAJOR"')"
  prev_desc="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.description"}}' "$prev")"
  echo "previous image: PostgreSQL ${prev_major} (${prev_desc})"

  if [ "$prev_major" != "$PG_MAJOR" ]; then
    echo "previous image is PostgreSQL ${prev_major}, this one ${PG_MAJOR}: covered by the major-upgrade scenarios below"
    continue
  fi

  log "scenario 1: ${prev} -> ${IMAGE} on the same volume (clean shutdown)"
  new_volume "prev${n}"; v="$V"
  start "prev${n}-old" "$prev" -v "$v:/var/lib/postgresql" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; c="$C"
  wait_ready "$c" ha; seed "$c" ha; stop "$c"
  start "prev${n}-new" "$IMAGE" -v "$v:/var/lib/postgresql" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; c="$C"
  wait_ready "$c" ha; verify "$c" ha; restart_is_noop "$c" ha

  log "scenario 1b: the same after an unclean shutdown (docker kill) of the previous image"
  new_volume "prev${n}-kill"; v="$V"
  start "prev${n}k-old" "$prev" -v "$v:/var/lib/postgresql" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; c="$C"
  wait_ready "$c" ha; seed "$c" ha; kill9 "$c"
  start "prev${n}k-new" "$IMAGE" -v "$v:/var/lib/postgresql" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; c="$C"
  wait_ready "$c" ha; verify "$c" ha

  log "scenario 1c: the same, container run as an unprivileged user (--user postgres)"
  new_volume "prev${n}-user"; v="$V"
  start "prev${n}u-old" "$prev" --user postgres -v "$v:/var/lib/postgresql" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; c="$C"
  wait_ready "$c" ha; seed "$c" ha; stop "$c"
  start "prev${n}u-new" "$IMAGE" --user postgres -v "$v:/var/lib/postgresql" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; c="$C"
  wait_ready "$c" ha; verify "$c" ha
done

# --- 2. older PostgreSQL majors -----------------------------------------------------------------

UPGRADE_FROM_MAJORS="${UPGRADE_FROM_MAJORS-$(docker run --rm "$IMAGE" sh -c '. /etc/ppt-upgrade-from.env && echo "$PPT_UPGRADE_FROM_MAJORS"')}"
echo "majors with bundled upgrade binaries: ${UPGRADE_FROM_MAJORS:-<none>}"

for major in $UPGRADE_FROM_MAJORS; do
  fixture="${FIXTURE_PREFIX}:pg${major}"
  log "building the PostgreSQL ${major} fixture ${fixture} (postgres:${major}-${DEBIAN_SUITE} + PostGIS ${POSTGIS_VERSION} + TimescaleDB ${TIMESCALEDB_VERSION})"
  docker build -q -t "$fixture" \
    --build-arg PG_VERSION="$major" \
    --build-arg DEBIAN_SUITE="$DEBIAN_SUITE" \
    --build-arg POSTGIS_VERSION="$POSTGIS_VERSION" \
    --build-arg TIMESCALEDB_VERSION="$TIMESCALEDB_VERSION" \
    --build-arg MIN_UPGRADE_FROM_MAJOR="$major" \
    -f Dockerfile . >/dev/null

  log "scenario 2a: PostgreSQL ${major}, volume at /var/lib/postgresql/data -> ${IMAGE} (in place)"
  new_volume "pg${major}-data"; v="$V"
  start "pg${major}a-old" "$fixture" -v "$v:/var/lib/postgresql/data" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; c="$C"
  wait_ready "$c" ha; seed "$c" ha; stop "$c"
  start "pg${major}a-new" "$IMAGE" -v "$v:/var/lib/postgresql/data" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; c="$C"
  wait_ready "$c" ha; verify "$c" ha
  assert_eq "data directory is the mount" "/var/lib/postgresql/data" "$(q "$c" ha ha "SHOW data_directory")"
  assert_eq "old cluster removed after the upgrade" "" "$(docker exec "$c" sh -c 'ls -d /var/lib/postgresql/data/pg*_pre_upgrade 2>/dev/null')"
  restart_is_noop "$c" ha

  log "scenario 2b: PostgreSQL ${major}, volume at /var/lib/postgresql -> ${IMAGE} (relocated to /var/lib/postgresql/${PG_MAJOR}/docker)"
  new_volume "pg${major}-root"; v="$V"
  start "pg${major}b-old" "$fixture" -v "$v:/var/lib/postgresql" -e PGDATA="/var/lib/postgresql/${major}/docker" -e POSTGRES_PASSWORD="$PW"; c="$C"
  wait_ready "$c" postgres; seed "$c" postgres; stop "$c"
  start "pg${major}b-new" "$IMAGE" -v "$v:/var/lib/postgresql" -e POSTGRES_PASSWORD="$PW"; c="$C"
  wait_ready "$c" postgres; verify "$c" postgres
  assert_eq "data directory relocated" "/var/lib/postgresql/${PG_MAJOR}/docker" "$(q "$c" postgres postgres "SHOW data_directory")"
  assert_eq "old cluster removed after the upgrade" "" "$(docker exec "$c" sh -c "ls -d /var/lib/postgresql/${major} 2>/dev/null")"
  restart_is_noop "$c" postgres

  log "scenario 4: an upgrade interrupted right after the cluster was moved aside is resumed"
  new_volume "pg${major}-resume"; v="$V"
  start "pg${major}r-old" "$fixture" -v "$v:/var/lib/postgresql/data" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; c="$C"
  wait_ready "$c" ha; seed "$c" ha; stop "$c"
  # Simulate the interruption: the cluster moved into its subdirectory, nothing else done.
  docker run --rm -v "$v:/var/lib/postgresql/data" --user postgres "$IMAGE" sh -c \
    "cd /var/lib/postgresql/data && mkdir pg${major}_pre_upgrade && for e in * .[!.]*; do [ -e \"\$e\" ] && [ \"\$e\" != pg${major}_pre_upgrade ] && mv \"\$e\" pg${major}_pre_upgrade/; done; true"
  start "pg${major}r-new" "$IMAGE" -v "$v:/var/lib/postgresql/data" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; c="$C"
  wait_ready "$c" ha; verify "$c" ha
  assert_eq "resume was logged" "1" "$(docker logs "$c" 2>&1 | grep -c 'ppt: resuming an interrupted' || true)"
done

# --- 3. opt-out --------------------------------------------------------------------------------

if [ -n "$UPGRADE_FROM_MAJORS" ]; then
  major="${UPGRADE_FROM_MAJORS##* }"
  fixture="${FIXTURE_PREFIX}:pg${major}"
  log "scenario 3: PPT_AUTO_UPGRADE=off refuses a PostgreSQL ${major} directory exactly like the official image"
  new_volume "pg${major}-off"; v="$V"
  start "pg${major}o-old" "$fixture" -v "$v:/var/lib/postgresql/data" -e POSTGRES_PASSWORD="$PW"; c="$C"
  wait_ready "$c" postgres; stop "$c"
  start "pg${major}o-new" "$IMAGE" -v "$v:/var/lib/postgresql/data" -e POSTGRES_PASSWORD="$PW" -e PPT_AUTO_UPGRADE=off; c="$C"
  assert_eq "container refuses to start" "1" "$(wait_exit "$c")"
  assert_eq "official image's explanation printed" "1" "$(docker logs "$c" 2>&1 | grep -c 'pg_upgrade' | sed 's/^[2-9].*/1/')"
  assert_eq "old cluster untouched" "$major" "$(docker run --rm -v "$v:/var/lib/postgresql/data" "$IMAGE" cat /var/lib/postgresql/data/PG_VERSION)"
fi

log "upgrade tests PASSED for ${IMAGE}"
