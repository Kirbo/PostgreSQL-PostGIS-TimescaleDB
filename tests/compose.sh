#!/usr/bin/env bash
# tests/compose.sh — the compose test, run inside the `compose` stage of tests/Dockerfile (FROM
# the image under test). scripts/buildkit-test.sh has already validated docker-compose.yml with
# `docker compose config` (no engine) and checked it runs the image under test with nothing this
# step does not reproduce (no command / entrypoint / user / healthcheck override, one volume at
# /var/lib/postgresql); it passes the service's environment as COMPOSE_ENV_B64 (base64 of
# NUL-separated KEY=VALUE). This step starts the service the way `docker compose up --wait`
# would — that environment, a fresh volume at /var/lib/postgresql — waits for the image's
# HEALTHCHECK to pass, and checks both extensions are in the database the file asks for.
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. /ppt/tests/lib.sh

test_begin compose
: "${COMPOSE_ENV_B64:?COMPOSE_ENV_B64 is not set — run the compose test through scripts/buildkit-test.sh}"

envs=()
mapfile -d '' -t envs < <(printf '%s' "$COMPOSE_ENV_B64" | base64 -d)
[ "${#envs[@]}" -gt 0 ] || fail "the compose service has no environment (COMPOSE_ENV_B64 decoded to nothing)"
args=()
for e in "${envs[@]}"; do
  echo "environment: ${e%%=*}=…"
  args+=(-e "$e")
done

section "starting the compose service the way \`docker compose up --wait\` does"
ctr_start postgres "${args[@]}"
# `up --wait --wait-timeout 300`: healthy within 300 s. The HEALTHCHECK goes over TCP, so it only
# passes once the entrypoint's socket-only init server has made way for the real one.
ctr_wait_healthy postgres 300
echo "${C_OK}ok:${C_OFF} healthy after ${HEALTHY_AFTER}s: $(healthcheck_cmd)"

section "asserting both extensions are in the homeassistant database"
exts="$(ctr_exec postgres psql -X -A -t -U homeassistant -d homeassistant \
  -c "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname <> 'plpgsql'")"
assert_eq "extensions" "postgis,postgis_topology,timescaledb" "$exts"

section "docker compose down"
ctr_stop postgres
test_pass
