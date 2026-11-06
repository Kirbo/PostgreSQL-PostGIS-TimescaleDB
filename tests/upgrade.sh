#!/usr/bin/env bash
# tests/upgrade.sh STEP — one step of the upgrade test, run inside the upgrade stages of
# tests/Dockerfile. Proves that the image under test can take over the data directory of every
# image a user may currently be running, without losing data or needing manual steps:
#
#   1. the previously published image (scripts/buildkit-test.sh passes :latest and the oldest
#      published tag of the same PostgreSQL major, one at a time), possibly older PostGIS /
#      TimescaleDB -> extensions updated in place; then the same after an unclean shutdown
#      (killed), and with the container run as an unprivileged user (--user postgres)
#   2. every older PostgreSQL major the image bundles binaries for (its PPT_UPGRADE_FROM_MAJORS,
#      one fixture image per major, built from this repository's Dockerfile), in both layouts:
#        a. the volume mounted at /var/lib/postgresql/data (the <= 17 official layout)
#           -> upgraded in place, inside the mount
#        b. the volume mounted at /var/lib/postgresql (the 18+ layout)
#           -> upgraded into /var/lib/postgresql/<major>/docker
#      with a custom superuser, several databases, postgresql.conf / ALTER SYSTEM settings,
#      compressed TimescaleDB chunks and PostGIS geometries that all have to come through
#   3. PPT_AUTO_UPGRADE=off leaves a foreign data directory alone
#   4. an interrupted upgrade is resumed on the next start
#   5. (newest bundled major) the container killed at every stage of a major upgrade, in both
#      layouts; a failing pg_upgrade rolled back so the old image starts the volume again;
#      PPT_KEEP_OLD_CLUSTER=1; two clusters in one volume refused instead of guessed
#
# A step runs ONE image; a scenario that switches images (seed with the old one, upgrade with the
# new one, back to the old one) is a chain of stages that hands the volume on with vol_save —
# see tests/Dockerfile for which step runs where, on which volume.
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. /ppt/tests/lib.sh

PW="upgrade-test-only"
# Every scenario is folded in a section; hundreds of ok lines otherwise.
SECTION_COLLAPSED=true

# The volume mount points of the two layouts.
INPLACE=/var/lib/postgresql/data
RELOCATE=/var/lib/postgresql

# The major of a fixture or previous image is its own PG_MAJOR (the step runs in it); the
# image under test is WANT_PG_MAJOR. OLD_MAJOR is passed by the upgrade stages that run the
# image under test against a fixture's volume.
OLD_MAJOR="${OLD_MAJOR:-}"

q() { # q CONTAINER USER DB SQL — DB via PGDATABASE, so names like "a=b" are taken literally
  ctr_exec "$1" env PGDATABASE="$3" psql -X -A -t -q -v ON_ERROR_STOP=1 -U "$2" -c "$4"
}

# seed CONTAINER USER — the data set every scenario writes with the OLD image and reads back
# with the new one: a hypertable with geometries and a compressed chunk, a second database
# with its own hypertable, ALTER SYSTEM + postgresql.conf settings.
seed() {
  local c="$1" u="$2" db
  ctr_exec "$c" psql -X -q -o /dev/null -v ON_ERROR_STOP=1 -U "$u" -d "$u" <<'SQL'
CREATE TABLE readings (ts timestamptz NOT NULL, sensor int, value double precision, location geometry(Point, 4326));
SELECT create_hypertable('readings', 'ts', chunk_time_interval => INTERVAL '1 day');
INSERT INTO readings SELECT now() - (s || ' hours')::interval, s % 5, s, ST_SetSRID(ST_MakePoint(24.94, 60.17), 4326) FROM generate_series(1, 500) s;
CREATE INDEX readings_location_gist ON readings USING gist (location);
ALTER TABLE readings SET (timescaledb.compress, timescaledb.compress_segmentby = 'sensor');
SELECT compress_chunk(c) FROM show_chunks('readings', older_than => INTERVAL '3 days') c;
SELECT add_retention_policy('readings', INTERVAL '10 years');
CREATE DATABASE second;
SQL
  ctr_exec "$c" psql -X -q -o /dev/null -v ON_ERROR_STOP=1 -U "$u" -d second <<'SQL'
CREATE EXTENSION timescaledb;
CREATE EXTENSION postgis;
CREATE TABLE metrics (ts timestamptz NOT NULL, v int);
SELECT create_hypertable('metrics', 'ts');
INSERT INTO metrics SELECT now(), 42;
SQL
  # Database names that break naive shell handling: whitespace, and "=" (psql -d would read
  # that as a connection string). Both carry an extension the upgrade must update.
  for db in "home assistant" "a=b"; do
    q "$c" "$u" postgres "CREATE DATABASE \"${db}\"" >/dev/null
    q "$c" "$u" "$db" "CREATE EXTENSION timescaledb" >/dev/null
  done
  q "$c" "$u" "$u" "ALTER SYSTEM SET work_mem = '7MB'" >/dev/null
  # postgresql.conf content a major upgrade must carry over intact: a quoted value with " #" in
  # it, and an include_dir with a setting of its own.
  # shellcheck disable=SC2016  # $PGDATA is the container's, expanded in there
  ctr_exec "$c" --user postgres sh -c 'echo "max_connections = 123" >> "$PGDATA/postgresql.conf"
    echo "log_line_prefix = '"'"'%m # '"'"'   # trailing comment" >> "$PGDATA/postgresql.conf"
    mkdir -p "$PGDATA/conf.d" && echo "statement_timeout = 42s" > "$PGDATA/conf.d/ppt-test.conf"
    echo "include_dir '"'"'conf.d'"'"'" >> "$PGDATA/postgresql.conf"'
}

# verify CONTAINER USER — everything seed() wrote is there and both extensions are current
verify() {
  local c="$1" u="$2"
  assert_eq "postgresql major"     "$WANT_PG_MAJOR"            "$(q "$c" "$u" "$u" "SHOW server_version_num" | cut -c1-2)"
  assert_eq "postgis version"      "$WANT_POSTGIS_VERSION"     "$(q "$c" "$u" "$u" "SELECT extversion FROM pg_extension WHERE extname = 'postgis'")"
  assert_eq "timescaledb version"  "$WANT_TIMESCALEDB_VERSION" "$(q "$c" "$u" "$u" "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
  assert_eq "timescaledb in 2nd db" "$WANT_TIMESCALEDB_VERSION" "$(q "$c" "$u" second "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
  assert_eq "hypertable rows"      "500"                  "$(q "$c" "$u" "$u" "SELECT count(*) FROM readings")"
  assert_eq "compressed chunk readable" "t"               "$(q "$c" "$u" "$u" "SELECT count(*) > 0 FROM timescaledb_information.chunks WHERE hypertable_name = 'readings' AND is_compressed")"
  assert_eq "geometry survives"    "POINT(24.94 60.17)"   "$(q "$c" "$u" "$u" "SELECT ST_AsText(location) FROM readings LIMIT 1")"
  assert_eq "spatial index usable" "500"                  "$(q "$c" "$u" "$u" "SET enable_seqscan = off; SELECT count(*) FROM readings WHERE location && ST_MakeEnvelope(24, 60, 25, 61, 4326)")"
  assert_eq "retention policy kept" "1"                   "$(q "$c" "$u" "$u" "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name = 'policy_retention' AND hypertable_name = 'readings'")"
  assert_eq "2nd db rows"          "42"                   "$(q "$c" "$u" second "SELECT v FROM metrics")"
  assert_eq "ALTER SYSTEM setting" "7MB"                  "$(q "$c" "$u" "$u" "SHOW work_mem")"
  assert_eq "postgresql.conf setting" "123"               "$(q "$c" "$u" "$u" "SHOW max_connections")"
  assert_eq "quoted setting with ' #'" "%m # "            "$(q "$c" "$u" "$u" "SHOW log_line_prefix")"
  assert_eq "include_dir setting"  "42s"                  "$(q "$c" "$u" "$u" "SHOW statement_timeout")"
  assert_eq "timescaledb in 'home assistant'" "$WANT_TIMESCALEDB_VERSION" "$(q "$c" "$u" "home assistant" "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
  assert_eq "timescaledb in 'a=b'" "$WANT_TIMESCALEDB_VERSION" "$(q "$c" "$u" "a=b" "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
  q "$c" "$u" "$u" "CREATE TABLE after_upgrade (ts timestamptz NOT NULL, v int); SELECT create_hypertable('after_upgrade', 'ts'); INSERT INTO after_upgrade VALUES (now(), 1)" >/dev/null
  assert_eq "new hypertable works"  "1"                   "$(q "$c" "$u" "$u" "SELECT count(*) FROM after_upgrade")"
  assert_eq "data directory stamped" "postgresql=${WANT_PG_MAJOR} postgis=${WANT_POSTGIS_VERSION} timescaledb=${WANT_TIMESCALEDB_VERSION}" \
    "$(ctr_exec "$c" sh -c 'cat "$(psql -X -A -t -U '"$u"' -d postgres -c "SHOW data_directory")/.ppt-versions"')"
}

# restart_is_noop CONTAINER USER — a second start with the same image does no upgrade work
restart_is_noop() {
  ctr_restart "$1"
  ctr_wait_ready "$1" "$2" 120
  assert_eq "no upgrade work on restart" "0" "$(ctr_logs_since_start "$1" | grep -c 'ppt: \(upgrading\|checking extensions\)' || true)"
}

need_old_major() { [ -n "$OLD_MAJOR" ] || fail "OLD_MAJOR is not set (the fixture's PostgreSQL major)"; }

# --- seeds: run in the OLD image (a fixture of an older major, or a previously published image) -

# seed_volume NAME MOUNT USER [ctr options] — a fresh volume (the step's mount) initialised by
# this image, seeded, shut down cleanly, saved for the next stages
seed_volume() {
  local name="$1" mount="$2" u="$3"; shift 3
  section "seeding ${name}: PostgreSQL ${PG_MAJOR} ($(sed -n 's/^PPT_UPGRADE_FROM_MAJORS=//p' /etc/ppt-upgrade-from.env 2>/dev/null || true)) volume at ${mount}"
  ctr_start "$name" "$@" -e POSTGRES_PASSWORD="$PW"
  ctr_wait_ready "$name" "$u"
  seed "$name" "$u"
  ctr_stop "$name"
  vol_save "$mount" "$name"
}

# --- 1. previously published image, same major ----------------------------------------------

# prev_seed VARIANT — in the previous image: clean | kill | user
prev_seed() {
  test_begin "prev-seed-$1"
  if [ "$PG_MAJOR" != "$WANT_PG_MAJOR" ]; then
    mkdir -p /seeds && echo "$PG_MAJOR" > /seeds/prev-major-differs
    test_skip "previous image is PostgreSQL ${PG_MAJOR}, this one ${WANT_PG_MAJOR}: covered by the major-upgrade scenarios"
    return 0
  fi
  echo "previous image: PostgreSQL ${PG_MAJOR}, PostGIS ${POSTGIS_VERSION:-?}, TimescaleDB ${TIMESCALEDB_VERSION:-?}"
  local user_opt=()
  [ "$1" != user ] || user_opt=(--user postgres)
  ctr_start old "${user_opt[@]}" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha
  ctr_wait_ready old ha
  seed old ha
  if [ "$1" = kill ]; then ctr_kill old; else ctr_stop old; fi
  vol_save "$RELOCATE" "prev-$1"
  test_pass
}

# prev_upgrade VARIANT — in the image under test, on the volume prev_seed VARIANT left
prev_upgrade() {
  test_begin "prev-upgrade-$1"
  if [ -e /ppt-seeds/prev-major-differs ]; then
    test_skip "previous image is PostgreSQL $(cat /ppt-seeds/prev-major-differs), this one ${WANT_PG_MAJOR}"
    return 0
  fi
  case "$1" in
    clean) section "scenario 1: previous image -> this image on the same volume (clean shutdown)" ;;
    kill)  section "scenario 1b: the same after an unclean shutdown (killed) of the previous image" ;;
    user)  section "scenario 1c: the same, container run as an unprivileged user (--user postgres)" ;;
  esac
  local user_opt=()
  [ "$1" != user ] || user_opt=(--user postgres)
  ctr_start new "${user_opt[@]}" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha
  ctr_wait_ready new ha
  verify new ha
  [ "$1" != clean ] || restart_is_noop new ha
  ctr_stop new
  test_pass
}

# --- 2. / 4. older PostgreSQL majors (every bundled one) -------------------------------------------

scenario_2a() {
  test_begin 2a
  need_old_major
  section "scenario 2a: PostgreSQL ${OLD_MAJOR}, volume at ${INPLACE} -> PostgreSQL ${PG_MAJOR} (in place)"
  ctr_start new -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha
  ctr_wait_ready new ha
  verify new ha
  assert_eq "data directory is the mount" "$INPLACE" "$(q new ha ha "SHOW data_directory")"
  assert_eq "old cluster removed after the upgrade" "" "$(ctr_exec new sh -c "ls -d ${INPLACE}/pg*_pre_upgrade 2>/dev/null" || true)"
  restart_is_noop new ha
  ctr_stop new
  test_pass "PostgreSQL ${OLD_MAJOR} -> ${PG_MAJOR}"
}

scenario_2b() {
  test_begin 2b
  need_old_major
  section "scenario 2b: PostgreSQL ${OLD_MAJOR}, volume at ${RELOCATE} -> PostgreSQL ${PG_MAJOR} (relocated to ${RELOCATE}/${PG_MAJOR}/docker)"
  ctr_start new -e POSTGRES_PASSWORD="$PW"
  ctr_wait_ready new postgres
  verify new postgres
  assert_eq "data directory relocated" "${RELOCATE}/${PG_MAJOR}/docker" "$(q new postgres postgres "SHOW data_directory")"
  assert_eq "old cluster removed after the upgrade" "" "$(ctr_exec new sh -c "ls -d ${RELOCATE}/${OLD_MAJOR} 2>/dev/null" || true)"
  restart_is_noop new postgres
  ctr_stop new
  test_pass "PostgreSQL ${OLD_MAJOR} -> ${PG_MAJOR}"
}

scenario_4() {
  test_begin 4
  need_old_major
  section "scenario 4: an upgrade interrupted right after the cluster was moved aside is resumed"
  # Simulate the interruption: the cluster moved into its subdirectory, nothing else done.
  ctr_run move --user postgres -- sh -c \
    "cd ${INPLACE} && mkdir pg${OLD_MAJOR}_pre_upgrade && for e in * .[!.]*; do [ -e \"\$e\" ] && [ \"\$e\" != pg${OLD_MAJOR}_pre_upgrade ] && mv \"\$e\" pg${OLD_MAJOR}_pre_upgrade/; done; true"
  ctr_start new -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha
  ctr_wait_ready new ha
  verify new ha
  assert_eq "resume was logged" "1" "$(ctr_logs new | grep -c 'ppt: resuming an interrupted' || true)"
  ctr_stop new
  test_pass "PostgreSQL ${OLD_MAJOR} -> ${PG_MAJOR}"
}

# --- 5. interruptions, failures, leftovers (newest bundled major only) ----------------------

# layout_mount inplace|relocate
layout_mount() { if [ "$1" = inplace ]; then echo "$INPLACE"; else echo "$RELOCATE"; fi; }
# old_env inplace|relocate — the PGDATA the old image ran that layout with
old_env() { if [ "$1" = inplace ]; then echo "PGDATA=${INPLACE}"; else echo "PGDATA=${RELOCATE}/${2}/docker"; fi; }

# kill_at CONTAINER PATTERN — SIGKILL as soon as PATTERN shows up in its log
kill_at() {
  local i=0
  until ctr_logs "$1" | grep -q "$2"; do
    ctr_running "$1" || fail "$1 exited before '$2' appeared in its log"
    i=$((i + 1)); [ "$i" -le 3000 ] || fail "'$2' never appeared in the log of $1"
    sleep 0.1
  done
  ctr_kill "$1"
}

# scenario_5a LAYOUT — the volume is mounted rw at the layout's mount point and read-only at
# /ppt-seed (the same seed), so every kill point starts from a fresh copy of it
scenario_5a() {
  test_begin "5a-$1"
  need_old_major
  local layout="$1" mount at n=0 tag
  mount="$(layout_mount "$layout")"
  for at in 'ppt: initdb' 'carried over' 'ppt: vacuumdb'; do
    n=$((n + 1)); tag="k${n}"
    section "scenario 5a: ${layout} layout, PostgreSQL ${OLD_MAJOR} upgrade killed at '${at}', then started again"
    [ "$n" = 1 ] || vol_reset "$mount" /ppt-seed
    ctr_start "${tag}-new" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha
    kill_at "${tag}-new" "$at"
    ctr_start "${tag}-again" -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha
    ctr_wait_ready "${tag}-again" ha
    verify "${tag}-again" ha
    assert_eq "no staging or old cluster left behind" "" \
      "$(ctr_exec "${tag}-again" sh -c "ls -d ${RELOCATE}/*/docker.ppt-* ${INPLACE}/pg[0-9]*_* ${RELOCATE}/${OLD_MAJOR} 2>/dev/null" || true)"
    ctr_stop "${tag}-again"
  done
  test_pass "${layout}, PostgreSQL ${OLD_MAJOR} -> ${PG_MAJOR}"
}

# 5b, in four steps across both images — LAYOUT is inplace|relocate:
#   block  (fixture)  a table pg_upgrade refuses (reg* column) is added to the seeded cluster
#   fail   (new)      the upgrade fails and is rolled back; a restart fails the same way
#   old    (fixture)  the old image serves the untouched data; the blocker is dropped
#   fixed  (new)      the upgrade now succeeds
scenario_5b_block() {
  test_begin "5b-block-$1"
  local mount; mount="$(layout_mount "$1")"
  section "scenario 5b: ${1} layout — the old image adds a table pg_upgrade refuses"
  ctr_start block -e "$(old_env "$1" "$PG_MAJOR")" -e POSTGRES_PASSWORD="$PW"
  ctr_wait_ready block ha
  # reg* columns other than regclass/regrole/regtype make pg_upgrade's checks refuse.
  q block ha ha "CREATE TABLE upgrade_blocker (p regproc)" >/dev/null
  ctr_stop block
  vol_save "$mount" "5b-$1"
  test_pass
}

scenario_5b_fail() {
  test_begin "5b-fail-$1"
  need_old_major
  local mount; mount="$(layout_mount "$1")"
  section "scenario 5b: ${1} layout, pg_upgrade fails -> rolled back"
  ctr_start new -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha
  ctr_wait_exit new 300
  assert_eq "container stops on the failed pg_upgrade" "1" "$(ctr_exit_code new)"
  assert_eq "rollback was logged" "1" "$(ctr_logs new | grep -c 'ppt: rolled back' || true)"
  ctr_launch new
  ctr_wait_exit new 300
  assert_eq "a restart fails the same way (no empty cluster)" "1" "$(ctr_exit_code new)"
  vol_save "$mount" "5b-$1-failed"
  test_pass
}

scenario_5b_old() {
  test_begin "5b-old-$1"
  local mount; mount="$(layout_mount "$1")"
  section "scenario 5b: ${1} layout, the old image starts the rolled-back volume again"
  ctr_start oldagain -e "$(old_env "$1" "$PG_MAJOR")" -e POSTGRES_PASSWORD="$PW"
  ctr_wait_ready oldagain ha
  assert_eq "old image serves the untouched data" "500" "$(q oldagain ha ha "SELECT count(*) FROM readings")"
  q oldagain ha ha "DROP TABLE upgrade_blocker" >/dev/null
  ctr_stop oldagain
  vol_save "$mount" "5b-$1-unblocked"
  test_pass
}

scenario_5b_fixed() {
  test_begin "5b-fixed-$1"
  need_old_major
  section "scenario 5b: ${1} layout, the blocker gone, the upgrade succeeds"
  ctr_start fixed -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha
  ctr_wait_ready fixed ha
  verify fixed ha
  ctr_stop fixed
  test_pass "PostgreSQL ${OLD_MAJOR} -> ${PG_MAJOR}"
}

scenario_5c() {
  test_begin 5c
  need_old_major
  section "scenario 5c: PPT_KEEP_OLD_CLUSTER=1 keeps the old cluster under a name that is never picked up again"
  ctr_start keep -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha -e PPT_KEEP_OLD_CLUSTER=1
  ctr_wait_ready keep ha
  verify keep ha
  assert_eq "old cluster kept, renamed" "1" "$(ctr_exec keep sh -c "ls -d ${RELOCATE}/${OLD_MAJOR}/docker.ppt-old-* | wc -l")"
  restart_is_noop keep ha
  ctr_stop keep
  test_pass
}

scenario_5d() {
  test_begin 5d
  need_old_major
  section "scenario 5d: two clusters in one volume are refused, not guessed between"
  local stale=$((OLD_MAJOR - 1))
  # A second, stale cluster next to the live one, as an orphan or a hand-kept copy would be.
  ctr_run copy --user postgres --entrypoint sh -- -c \
    "mkdir -p ${RELOCATE}/${stale} && cp -a ${RELOCATE}/${OLD_MAJOR}/docker ${RELOCATE}/${stale}/docker"
  ctr_start two -e POSTGRES_PASSWORD="$PW" -e POSTGRES_USER=ha -e POSTGRES_DB=ha
  ctr_wait_exit two 120
  assert_eq "container refuses to start" "1" "$(ctr_exit_code two)"
  assert_eq "refusal names both directories" "1" \
    "$(ctr_logs two | grep 'more than one PostgreSQL data directory' | grep "/${stale}/docker" | grep -c "/${OLD_MAJOR}/docker" || true)"
  assert_eq "nothing was upgraded" "" "$(ctr_run look --entrypoint sh -- -c "ls -d ${RELOCATE}/${PG_MAJOR} 2>/dev/null; true")"
  test_pass
}

scenario_3() {
  test_begin 3
  need_old_major
  section "scenario 3: PPT_AUTO_UPGRADE=off refuses a PostgreSQL ${OLD_MAJOR} directory exactly like the official image"
  ctr_start off -e POSTGRES_PASSWORD="$PW" -e PPT_AUTO_UPGRADE=off
  ctr_wait_exit off 120
  assert_eq "container refuses to start" "1" "$(ctr_exit_code off)"
  assert_eq "official image's explanation printed" "1" "$(ctr_logs off | grep -c 'pg_upgrade' | sed 's/^[2-9].*/1/')"
  assert_eq "old cluster untouched" "$OLD_MAJOR" "$(ctr_run cat -- cat "${INPLACE}/PG_VERSION")"
  test_pass
}

case "${1:-}" in
  seed-inplace-ha)        test_begin "$1"; seed_volume inplace-ha "$INPLACE" ha -e POSTGRES_USER=ha -e POSTGRES_DB=ha; test_pass ;;
  seed-relocate-postgres) test_begin "$1"; seed_volume relocate-postgres "$RELOCATE" postgres -e "PGDATA=${RELOCATE}/${PG_MAJOR}/docker"; test_pass ;;
  seed-relocate-ha)       test_begin "$1"; seed_volume relocate-ha "$RELOCATE" ha -e "PGDATA=${RELOCATE}/${PG_MAJOR}/docker" -e POSTGRES_USER=ha -e POSTGRES_DB=ha; test_pass ;;
  prev-seed)    prev_seed "$2" ;;
  prev-upgrade) prev_upgrade "$2" ;;
  2a) scenario_2a ;;
  2b) scenario_2b ;;
  4)  scenario_4 ;;
  5a) scenario_5a "$2" ;;
  5b-block) scenario_5b_block "$2" ;;
  5b-fail)  scenario_5b_fail "$2" ;;
  5b-old)   scenario_5b_old "$2" ;;
  5b-fixed) scenario_5b_fixed "$2" ;;
  5c) scenario_5c ;;
  5d) scenario_5d ;;
  3)  scenario_3 ;;
  *) echo "usage: upgrade.sh STEP [ARG] (see the case at the end)" >&2; exit 2 ;;
esac
