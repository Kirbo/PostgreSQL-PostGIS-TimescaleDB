#!/bin/sh
# tests/run.sh SUITE [ARG...] — PID 1 of every test step in tests/Dockerfile (exec-form RUN, so
# no `sh -c` decides whether it stays around). Runs tests/SUITE.sh in a child and waits for it.
#
# Why a separate PID 1: the steps start the image's entrypoint as background "containers" and
# SIGKILL them (tests/lib.sh ctr_kill). The killed server's children are re-parented to PID 1,
# and must be reaped there — a postgres zombie still looks like a running server to the
# entrypoint's stale-lock check. dash's `wait` reaps every child that exits, its own or adopted.
set -eu
[ "$$" = 1 ] || { echo "ERROR: tests/run.sh must be PID 1 of the step (an exec-form RUN)" >&2; exit 1; }
suite="${1:?usage: run.sh SUITE [ARG...]}"
shift
bash "/ppt/tests/${suite}.sh" "$@" &
wait "$!"
