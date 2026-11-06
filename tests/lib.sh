# shellcheck shell=bash
# tests/lib.sh — the toolkit of the test steps in tests/Dockerfile. Sourced by tests/smoke.sh,
# tests/compose.sh and tests/upgrade.sh, which run INSIDE a BuildKit `RUN` step of a stage built
# FROM the image under test (or an older image). There is no Docker engine in there, so:
#
#   a "container"  is the image's own ENTRYPOINT + CMD started as a background process of the
#                  step, with exactly the image's environment (captured into /ppt-image.env by
#                  the stage's first RUN, before any ARG exists) plus the `-e` values given —
#                  the real startup path: docker-entrypoint-ppt.sh, the official entrypoint, the
#                  initdb.d scripts, gosu. One container runs at a time. A new container gets a
#                  fresh writable layer where it matters: the image's empty /var/run/postgresql
#                  (socket + lock file) and an empty /tmp; `docker start` keeps them.
#   a "volume"     is the step's `--mount=type=bind,...,rw` at the container's data path: a real
#                  mount point (the entrypoint's layout detection depends on that), seeded from
#                  an earlier stage, its writes discarded when the step ends (vol_save keeps them).
#   docker stop    SIGINT (the postgres images' STOPSIGNAL) and a bounded wait for every process
#                  of the container to exit.
#   docker kill    SIGKILL to every process of the step except this shell and its ancestors —
#                  the step has its own PID namespace, so that is exactly the container.
#   docker logs    one log file per container, stdout + stderr, across restarts.
#   HEALTHCHECK    the CMD of the Dockerfile's HEALTHCHECK (the image under test is built from
#                  it), run like Docker does: `sh -c` with the container's environment.
#
# The steps run with `--network=none`: their own loopback, so port 5432 is never shared with
# another build on the same BuildKit server (whose default RUN network is the host's).
#
# Every wait is bounded and fails with the reason; nothing sleeps "long enough". A failing step
# prints the logs of the containers it started. A passing step writes /results/<step> containing
# "PASS <PPT_TEST_RUN>", which scripts/buildkit-test.sh checks to prove the step really ran in
# this invocation (a step served from the build cache would carry an older token).
set -Eeuo pipefail
shopt -s inherit_errexit

# shellcheck source=scripts/output.sh
. /ppt/scripts/output.sh

: "${PPT_TEST_RUN:?PPT_TEST_RUN (the per-run token) is not set — run the tests through scripts/buildkit-test.sh}"
PPT_IMAGE_ENV=/ppt-image.env
PPT_IMAGE_RUNDIR=/ppt-image.rundir
[ -s "$PPT_IMAGE_ENV" ] && [ -s "$PPT_IMAGE_RUNDIR" ] \
  || { echo "ERROR: /ppt-image.* missing — the stage must capture the image's environment first" >&2; exit 1; }

# Expected versions: build.env (CI, written by scripts/resolve-versions.sh) or versions.env — the
# same files the image was built from. Read into WANT_* so nothing overrides the image's own
# PG_MAJOR / PG_VERSION environment.
_versions=/ppt/versions.env
[ -f /ppt/build.env ] && _versions=/ppt/build.env
want() { sed -n "s/^$1=//p" "$_versions" | tail -n 1; }
WANT_PG_MAJOR="$(want PG_MAJOR)"
WANT_PG_VERSION="$(want PG_VERSION)"
WANT_POSTGIS_VERSION="$(want POSTGIS_VERSION)"
WANT_TIMESCALEDB_VERSION="$(want TIMESCALEDB_VERSION)"
[ -n "$WANT_PG_MAJOR" ] && [ -n "$WANT_PG_VERSION" ] && [ -n "$WANT_POSTGIS_VERSION" ] && [ -n "$WANT_TIMESCALEDB_VERSION" ] \
  || { echo "ERROR: incomplete versions in ${_versions}" >&2; exit 1; }

STEP=''            # set by test_begin
CTR_ROOT=/tmp/ppt-containers
CTR_NAMES=()       # every container started in this step, for the failure logs
CTR_CURRENT=''     # the one that may be running

# --- outcome ------------------------------------------------------------------------------------

fail() { section_close; printf '%sFAIL:%s %s\n' "$C_FAIL" "$C_OFF" "$*" >&2; exit 1; }

assert_eq() { # assert_eq LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then echo "${C_OK}ok:${C_OFF} $1 = $3"; else fail "$1 — expected '$2', got '$3'"; fi
}

memory_peak() {
  local peak
  peak="$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || true)"
  [ -z "$peak" ] || echo "memory peak of this step: $((peak / 1048576)) MiB"
}

_test_exit() {
  local status=$?
  section_close
  if [ "$status" != 0 ]; then
    local n
    for n in "${CTR_NAMES[@]}"; do
      echo "--- log of container ${n} (last 80 lines) ---"
      tail -n 80 "$CTR_ROOT/$n/log" 2>/dev/null || true
    done
    printf '%s==> step %s FAILED%s\n' "$C_FAIL" "$STEP" "$C_OFF" >&2
  fi
  memory_peak
  exit "$status"
}

test_begin() { # test_begin STEP — names the result file
  STEP="$1"
  trap _test_exit EXIT
  # The stage's earlier steps' containers are in this rootfs too; they are not ours.
  rm -rf "$CTR_ROOT"
  echo "test step ${STEP} (run ${PPT_TEST_RUN}) on $(uname -m), image PostgreSQL ${PG_MAJOR:-?}"
}

test_pass() { # test_pass [MESSAGE]
  section_close
  mkdir -p /results
  echo "PASS ${PPT_TEST_RUN}" > "/results/${STEP}"
  printf '%s==> %s PASSED%s%s\n' "$C_PASS" "$STEP" "${1:+: $1}" "$C_OFF"
}

test_skip() { # test_skip REASON — the step had nothing to test; recorded, not silently green
  section_close
  mkdir -p /results
  echo "SKIP ${PPT_TEST_RUN} $1" > "/results/${STEP}"
  printf '%s==> %s SKIPPED:%s %s\n' "$C_WARN" "$STEP" "$C_OFF" "$1"
}

# --- processes ----------------------------------------------------------------------------------

# proc_stat PID — sets P_STATE and P_PPID from /proc/PID/stat (no subshell: the kill loop below
# must not create processes it would then have to tell apart). Returns 1 if PID is gone.
proc_stat() {
  local line rest
  { read -r line < "/proc/$1/stat"; } 2>/dev/null || return 1
  rest="${line##*) }"            # after "pid (comm) " — comm may contain spaces and parens
  P_STATE="${rest%% *}"
  rest="${rest#* }"
  P_PPID="${rest%% *}"
}

# _container_pids — every live process of the step except this shell and its ancestors, into
# PIDS. A zombie child of this shell (a container's main process) counts as gone — its exit
# code is collected by _ctr_reap; zombies of PID 1 (orphans) are reaped by PID 1 itself.
_container_pids() {
  local p self="$BASHPID"
  local -A keep=([1]=1)
  p="$self"
  while [ "$p" -gt 1 ] && proc_stat "$p"; do keep[$p]=1; p="$P_PPID"; done
  PIDS=()
  for p in /proc/[0-9]*; do
    p="${p#/proc/}"
    [ -z "${keep[$p]:-}" ] || continue
    proc_stat "$p" || continue
    [ "$P_STATE" = Z ] && [ "$P_PPID" = "$self" ] && continue
    PIDS+=("$p")
  done
}

# _await_no_processes SECS WHAT [SIGNAL] — until no container process is left; SIGNAL is re-sent
# to whatever is still there (a process forked between two scans gets it too)
_await_no_processes() {
  local limit="$1" what="$2" sig="${3:-}" i=0 p
  while :; do
    _container_pids
    [ "${#PIDS[@]}" -gt 0 ] || return 0
    if [ -n "$sig" ]; then
      for p in "${PIDS[@]}"; do kill "-$sig" "$p" 2>/dev/null || true; done
    fi
    i=$((i + 1))
    [ "$i" -le $((limit * 10)) ] || fail "${what}: processes still running after ${limit}s: ${PIDS[*]}"
    sleep 0.1
  done
}

# --- containers ---------------------------------------------------------------------------------

# _fresh_rootfs — the parts of the root filesystem a container writes to, as a new container
# from the image has them. /var/run/postgresql above all: a killed server leaves its socket lock
# file there, naming a PID that in a later step (PIDs restart at 1) may well be alive.
_fresh_rootfs() {
  local mode uid gid
  read -r mode uid gid < "$PPT_IMAGE_RUNDIR"
  find /var/run/postgresql/ -mindepth 1 -delete
  chown "$uid:$gid" /var/run/postgresql/
  chmod "$mode" /var/run/postgresql/
  find /tmp -mindepth 1 -maxdepth 1 ! -path "$CTR_ROOT" -exec rm -rf {} +
}

# ctr_create NAME [--user USER] [--entrypoint PROG] [-e KEY=VALUE]... [-- ARG...]
#   like `docker create`: the image's entrypoint (docker-entrypoint-ppt.sh where the image has it,
#   the official docker-entrypoint.sh otherwise) and CMD `postgres` unless ARGs are given.
ctr_create() {
  local name="$1"; shift
  local dir="$CTR_ROOT/$name" user='' entrypoint='' envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      --entrypoint) entrypoint="$2"; shift 2 ;;
      -e) envs+=("$2"); shift 2 ;;
      --) shift; args=("$@"); break ;;
      *) fail "ctr_create: unknown option '$1'" ;;
    esac
  done
  [ ! -e "$dir" ] || fail "ctr_create: container ${name} exists already"
  if [ -n "$CTR_CURRENT" ] && ctr_running "$CTR_CURRENT"; then
    fail "ctr_create ${name}: ${CTR_CURRENT} is still running (one container at a time)"
  fi
  _fresh_rootfs
  if [ -z "$entrypoint" ]; then
    if command -v docker-entrypoint-ppt.sh >/dev/null; then entrypoint=docker-entrypoint-ppt.sh; else entrypoint=docker-entrypoint.sh; fi
    [ "${#args[@]}" -gt 0 ] || args=(postgres)
  fi
  mkdir -p "$dir"
  local image_env=()
  mapfile -d '' -t image_env < "$PPT_IMAGE_ENV"
  # Later entries win, as with `docker run -e`.
  printf '%s\0' "${image_env[@]}" "${envs[@]}" > "$dir/env"
  printf '%s\0' "$entrypoint" "${args[@]}" > "$dir/cmd"
  printf '%s' "$user" > "$dir/user"
  : > "$dir/log"
  CTR_NAMES+=("$name")
}

# ctr_launch NAME — like `docker start`: runs the container in the background
ctr_launch() {
  local name="$1" dir="$CTR_ROOT/$1" env=() cmd=() user
  if [ -n "$CTR_CURRENT" ] && ctr_running "$CTR_CURRENT"; then
    fail "ctr_launch ${name}: ${CTR_CURRENT} is still running (one container at a time)"
  fi
  _await_no_processes 30 "before starting ${name}"
  mapfile -d '' -t env < "$dir/env"
  mapfile -d '' -t cmd < "$dir/cmd"
  user="$(cat "$dir/user")"
  [ -z "$user" ] || cmd=(gosu "$user" "${cmd[@]}")
  stat -c %s "$dir/log" > "$dir/log-offset"
  rm -f "$dir/exit"
  (cd / && exec env -i "${env[@]}" "${cmd[@]}") < /dev/null >> "$dir/log" 2>&1 &
  echo "$!" > "$dir/pid"
  CTR_CURRENT="$name"
}

# ctr_start NAME [ctr_create options] — like `docker run -d`
ctr_start() { ctr_create "$@"; ctr_launch "$1"; }

# ctr_run NAME [ctr_create options] -- ARG... — like `docker run --rm`: in the foreground, prints
# its output, returns its exit code
ctr_run() {
  local name="$1"
  ctr_create "$@"
  ctr_launch "$name"
  ctr_wait_exit "$name" 300
  cat "$CTR_ROOT/$name/log"
  return "$(ctr_exit_code "$name")"
}

ctr_pid() { cat "$CTR_ROOT/$1/pid"; }

ctr_running() { # ctr_running NAME — its main process is alive (not a zombie)
  [ -f "$CTR_ROOT/$1/pid" ] || return 1
  [ ! -f "$CTR_ROOT/$1/exit" ] || return 1
  proc_stat "$(ctr_pid "$1")" || return 1
  [ "$P_STATE" != Z ]
}

# _ctr_reap NAME — collect the exit code of a finished container (once). Must run in the shell
# that launched it — `wait` only knows its own children — so never inside $(...).
_ctr_reap() {
  local dir="$CTR_ROOT/$1" status=0
  [ ! -f "$dir/exit" ] || return 0
  wait "$(ctr_pid "$1")" 2>/dev/null || status=$?
  echo "$status" > "$dir/exit"
}

ctr_exit_code() { cat "$CTR_ROOT/$1/exit"; }

# ctr_wait_exit NAME [SECS] — until it stops on its own (then: ctr_exit_code NAME)
ctr_wait_exit() {
  local limit="${2:-120}" i=0
  while ctr_running "$1"; do
    i=$((i + 1)); [ "$i" -le $((limit * 10)) ] || fail "$1 still running after ${limit}s"
    sleep 0.1
  done
  _ctr_reap "$1"
  # Whatever it left behind (the official entrypoint's temporary server, say) goes too.
  _await_no_processes 60 "after $1 exited" KILL
}

# ctr_stop NAME [SECS] — like `docker stop` / `docker compose down`: SIGINT, then every process
# of the container must be gone within SECS (a shutdown that hangs is a failure, not a kill)
ctr_stop() {
  local limit="${2:-120}" pid i=0
  pid="$(ctr_pid "$1")"
  ctr_running "$1" || fail "ctr_stop $1: not running"
  kill -INT "$pid"
  while ctr_running "$1"; do
    i=$((i + 1)); [ "$i" -le $((limit * 10)) ] || fail "$1 did not stop within ${limit}s of SIGINT"
    sleep 0.1
  done
  _ctr_reap "$1"
  _await_no_processes "$limit" "stopping $1"
}

# ctr_kill NAME — like `docker kill -s KILL`: every process of the container, at once
ctr_kill() {
  _container_pids
  local p
  for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
  _await_no_processes 30 "killing $1" KILL
  _ctr_reap "$1"
}

ctr_restart() { ctr_stop "$1"; ctr_launch "$1"; }  # like `docker restart`

ctr_logs() { cat "$CTR_ROOT/$1/log"; }
# ctr_logs_since_start NAME — what the latest start of NAME logged (`docker logs --since <StartedAt>`)
ctr_logs_since_start() { tail -c "+$(( $(cat "$CTR_ROOT/$1/log-offset") + 1 ))" "$CTR_ROOT/$1/log"; }

# ctr_exec NAME [--user USER] CMD... — like `docker exec`: the container's environment, as root
# unless USER is given
ctr_exec() {
  local name="$1" env=(); shift
  local user=''
  if [ "${1:-}" = --user ]; then user="$2"; shift 2; fi
  mapfile -d '' -t env < "$CTR_ROOT/$name/env"
  if [ -n "$user" ]; then
    env -i "${env[@]}" gosu "$user" "$@"
  else
    env -i "${env[@]}" "$@"
  fi
}

# ctr_wait_ready NAME USER [SECS] — until the server's TCP listener answers. The entrypoints'
# temporary init / upgrade servers listen on the socket only, so this is "initialisation done".
ctr_wait_ready() {
  local limit="${3:-300}" i=0
  while :; do
    if ! ctr_running "$1"; then
      _ctr_reap "$1"
      fail "container $1 exited (exit code $(ctr_exit_code "$1")) before it was ready"
    fi
    ctr_exec "$1" pg_isready -q -h 127.0.0.1 -U "$2" && return 0
    i=$((i + 1)); [ "$i" -le "$limit" ] || fail "$1 not ready after ${limit}s"
    sleep 1
  done
}

# ctr_wait_socket NAME USER DB [SECS] — until the server answers on its Unix socket (true already
# during the entrypoint's temporary init server)
ctr_wait_socket() {
  local limit="${4:-120}" i=0
  until ctr_exec "$1" pg_isready -q -U "$2" -d "$3"; do
    ctr_running "$1" || { _ctr_reap "$1"; fail "container $1 exited (exit code $(ctr_exit_code "$1"))"; }
    i=$((i + 1)); [ "$i" -le "$limit" ] || fail "server in $1 did not accept connections within ${limit}s"
    sleep 1
  done
}

# healthcheck_cmd — the shell form CMD of the Dockerfile's HEALTHCHECK, continuation lines joined
healthcheck_cmd() {
  local hc
  hc="$(awk '
    /^HEALTHCHECK[[:space:]]/ { on = 1 }
    on { line = $0; cont = sub(/\\[[:space:]]*$/, "", line); buf = buf " " line; if (!cont) { print buf; exit } }
  ' /ppt/Dockerfile)"
  case "$hc" in
    *" CMD ["*) fail "the Dockerfile's HEALTHCHECK is in exec form; tests/lib.sh only runs the shell form" ;;
    *" CMD "*) printf '%s\n' "${hc#* CMD }" ;;
    *) fail "no HEALTHCHECK ... CMD found in the Dockerfile" ;;
  esac
}

# ctr_wait_healthy NAME SECS — run the HEALTHCHECK command (as Docker does: `sh -c`, the
# container's environment, as root) until it succeeds; HEALTHY_AFTER = the seconds it took.
# Not in $(...): a failure must end the step, and only this shell can reap the container.
ctr_wait_healthy() {
  local limit="$2" cmd i=0
  cmd="$(healthcheck_cmd)"
  until ctr_exec "$1" /bin/sh -c "$cmd" >/dev/null 2>&1; do
    ctr_running "$1" || { _ctr_reap "$1"; fail "container $1 exited (exit code $(ctr_exit_code "$1"))"; }
    i=$((i + 1)); [ "$i" -le "$limit" ] || fail "$1 not healthy within ${limit}s (healthcheck: ${cmd})"
    sleep 1
  done
  # shellcheck disable=SC2034  # read by the test scripts that source this file
  HEALTHY_AFTER="$i"
}

# --- volumes ------------------------------------------------------------------------------------

# vol_save MOUNT NAME — keep the volume's current state as /seeds/NAME in this stage's layer
# (the rw bind mount itself is discarded when the step ends); a later stage mounts it again
vol_save() {
  mkdir -p /seeds
  rm -rf "/seeds/$2"
  cp -a "$1" "/seeds/$2"
}

# vol_reset MOUNT SEED — put the volume back to SEED's state (a fresh copy of the same volume)
vol_reset() {
  find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -a "$2/." "$1/"
  chown --reference="$2" "$1"
  chmod --reference="$2" "$1"
}
