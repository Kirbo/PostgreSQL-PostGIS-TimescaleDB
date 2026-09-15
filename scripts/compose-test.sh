#!/bin/sh
# compose-test.sh IMAGE — the bundled docker-compose.yml must come up healthy with IMAGE, i.e.
# `docker compose up --wait` (what a user runs) works, and the healthcheck it relies on is
# sane. The compose project is torn down with its volume afterwards.
set -eu

IMAGE="${1:?usage: compose-test.sh IMAGE}"
# Unique per run even on a shared daemon: CI jobs all start with the same PIDs, so $$ alone
# would collide across parallel jobs (and one job's cleanup would remove another's container).
RUN_ID="${CI_JOB_ID:-$$}-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PROJECT="ppt-compose-${RUN_ID}"

cleanup() {
  if [ "${KEEP_LOGS:-1}" = "1" ]; then
    echo "--- compose logs ---"
    PPT_IMAGE="$IMAGE" docker compose -p "$PROJECT" logs --tail 60 2>&1 || true
  fi
  PPT_IMAGE="$IMAGE" docker compose -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> docker compose up --wait with ${IMAGE}"
# The compose file publishes 5432; in CI another container may hold it, so an override file
# drops the port mapping (everything else is the user's file, untouched).
cat > "compose-${PROJECT}.override.yml" <<'YML'
services:
  postgres:
    ports: !reset []
YML
PPT_IMAGE="$IMAGE" docker compose -p "$PROJECT" -f docker-compose.yml -f "compose-${PROJECT}.override.yml" \
  up -d --wait --wait-timeout 300
rm -f "compose-${PROJECT}.override.yml"

echo "==> asserting the service is healthy and both extensions are in the homeassistant database"
status="$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose -p "$PROJECT" ps -q postgres)")"
[ "$status" = healthy ] || { echo "FAIL: service status is '${status}', expected healthy" >&2; exit 1; }
exts="$(docker compose -p "$PROJECT" exec -T postgres psql -X -A -t -U homeassistant -d homeassistant \
  -c "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname <> 'plpgsql'")"
[ "$exts" = "postgis,postgis_topology,timescaledb" ] || { echo "FAIL: extensions are '${exts}'" >&2; exit 1; }
echo "ok: healthy, extensions = ${exts}"

KEEP_LOGS=0
echo "==> compose test PASSED for ${IMAGE}"
