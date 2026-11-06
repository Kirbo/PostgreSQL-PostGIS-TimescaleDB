#!/bin/sh
# buildkit-test.sh smoke|compose|upgrade IMAGE — run one test suite of tests/Dockerfile on a
# BuildKit (the current buildx builder, or BUILDER_NAME — in CI the Mac's BuildKit server) and
# prove that every one of its test steps ran in THIS invocation.
#
#   smoke    the image started, versions asserted, both extensions exercised, the Home Assistant
#            LTSS DDL replayed, the HEALTHCHECK and the defaults checked (tests/smoke.sh), on
#            PLATFORM (linux/amd64 | linux/arm64; default: the builder's own)
#   compose  docker-compose.yml validated with `docker compose config` (no engine), then its
#            service started as compose would: its environment, a fresh volume, healthy within
#            the --wait timeout, both extensions in its database (tests/compose.sh)
#   upgrade  the previously published images and every bundled older PostgreSQL major, both
#            volume layouts, kills, rollback, opt-out (tests/upgrade.sh) — one bake call per
#            previous image and per older major, one after another
#
# IMAGE is the image under test: a registry reference (CI: the staging digest,
# <registry>/<project>@sha256:...), or a buildx context source for local runs
# (docker-image://postgresql-postgis-timescaledb:local with the docker driver,
# oci-layout://DIR@sha256:... with any).
#
# THE CACHE TRAP: BuildKit would happily serve a test step from its cache and "pass" without
# running anything. So every test step consumes PPT_TEST_RUN, a token unique to this invocation,
# every test stage is in its bake target's no-cache-filter, and each step's result file must
# contain this token — a missing file, an older token or an unexpected file fails the suite.
#
# Env: BUILDER_NAME, PLATFORM (smoke), PREVIOUS_IMAGES (upgrade; space-separated, default: the
#      published :latest AND the oldest published tag of the same PostgreSQL major — so the
#      extension-update path is exercised even when :latest is already current; "" skips),
#      UPGRADE_FROM_MAJORS (upgrade; default: what the image bundles), TEST_RESULTS (default
#      test-results). Versions from build.env (CI) or versions.env.
set -eu
# shellcheck source=scripts/output.sh
. "$(dirname "$0")/output.sh"
trap section_close EXIT

SUITE="${1:?usage: buildkit-test.sh smoke|compose|upgrade IMAGE}"
IMAGE_REF="${2:?usage: buildkit-test.sh smoke|compose|upgrade IMAGE}"

# shellcheck disable=SC1091
if [ -f build.env ]; then . ./build.env; else . ./versions.env; fi
export DEBIAN_SUITE POSTGIS_VERSION TIMESCALEDB_VERSION

fail() { section_close; printf '%sFAIL:%s %s\n' "$C_FAIL" "$C_OFF" "$*" >&2; exit 1; }

case "$IMAGE_REF" in
  *://*) TEST_IMAGE=ppt-under-test; TEST_IMAGE_CONTEXT="$IMAGE_REF" ;;
  *)     TEST_IMAGE="$IMAGE_REF";   TEST_IMAGE_CONTEXT='' ;;
esac
PPT_TEST_RUN="$(date -u +%Y%m%dT%H%M%SZ)-${CI_PIPELINE_ID:-local}-${CI_JOB_ID:-0}-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
export TEST_IMAGE TEST_IMAGE_CONTEXT PPT_TEST_RUN
RESULTS_ROOT="${TEST_RESULTS:-test-results}"
echo "test run ${PPT_TEST_RUN}: ${SUITE} of ${IMAGE_REF}"

# bake TARGET RESULTS_SUBDIR — one suite target; its result files land in RESULTS_ROOT/SUBDIR
bake() {
  TEST_RESULTS_DIR="${RESULTS_ROOT}/$2"
  export TEST_RESULTS_DIR
  rm -rf "$TEST_RESULTS_DIR"
  section "docker buildx bake $1 (${TEST_RESULTS_DIR})"
  # shellcheck disable=SC2086
  docker buildx bake ${BUILDER_NAME:+--builder "$BUILDER_NAME"} --progress plain -f tests/docker-bake.hcl "$1"
  section_close
}

# expect_results SUBDIR STEP... — each step left "PASS|SKIP <this run's token>", and nothing else
# is there (a step added to tests/Dockerfile but not here, or the other way round, fails too)
expect_results() {
  dir="${RESULTS_ROOT}/$1"; shift
  for step in "$@"; do
    [ -f "$dir/$step" ] || fail "test step '${step}' left no result in ${dir} — it did not run"
    read -r verdict token rest < "$dir/$step" || true
    [ "$token" = "$PPT_TEST_RUN" ] \
      || fail "test step '${step}' carries the token '${token}', not this run's '${PPT_TEST_RUN}' — it was served from the build cache instead of running"
    case "$verdict" in
      PASS) echo "${C_OK}ok:${C_OFF} ${step} ran and passed" ;;
      SKIP) echo "${C_WARN}skipped:${C_OFF} ${step} — ${rest}" ;;
      *) fail "test step '${step}': unexpected result '${verdict}'" ;;
    esac
  done
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    case " $* " in
      *" ${f##*/} "*) ;;
      *) fail "unexpected result file ${f} — update the step list in scripts/buildkit-test.sh" ;;
    esac
  done
}

case "$SUITE" in
  smoke)
    export TEST_PLATFORM="${PLATFORM:-}"
    sub="smoke-$(echo "${PLATFORM:-native}" | tr '/' '-')"
    bake smoke "$sub"
    expect_results "$sub" smoke-main smoke-defaults
    ;;

  compose)
    section "docker compose config (no engine): docker-compose.yml with PPT_IMAGE=${IMAGE_REF}"
    command -v jq >/dev/null || fail "jq is required for the compose test"
    cfg="$(PPT_IMAGE="$IMAGE_REF" docker compose -f docker-compose.yml config --format json)"
    svc() { printf '%s' "$cfg" | jq -c ".services.postgres$1"; }
    [ "$(svc .image)" = "\"${IMAGE_REF}\"" ] || fail "the compose service runs $(svc .image), not the image under test"
    # What the compose stage reproduces is the service's environment and its one volume; it uses
    # the image's own entrypoint, command, user and HEALTHCHECK. Anything else in the file would
    # silently go untested, so it fails here instead.
    for key in command entrypoint user healthcheck working_dir; do
      [ "$(svc ".${key} // empty")" = "" ] \
        || fail "docker-compose.yml sets services.postgres.${key} = $(svc ".${key}"); tests/compose.sh does not reproduce that — extend it"
    done
    [ "$(svc '.volumes // [] | map(.target)')" = '["/var/lib/postgresql"]' ] \
      || fail "docker-compose.yml's volumes are $(svc '.volumes'); the compose stage mounts one at /var/lib/postgresql — update tests/Dockerfile"
    [ "$(svc '.environment // {} | map_values(select(. == null)) | length')" = 0 ] \
      || fail "docker-compose.yml passes environment variables without a value; tests/compose.sh cannot reproduce those"
    COMPOSE_ENV_B64="$(printf '%s' "$cfg" | jq -j '.services.postgres.environment // {} | to_entries[] | "\(.key)=\(.value)\u0000"' | base64 | tr -d '\n')"
    export COMPOSE_ENV_B64
    echo "${C_OK}ok:${C_OFF} docker-compose.yml is valid and runs the image under test"
    section_close
    bake compose compose
    expect_results compose compose
    ;;

  upgrade)
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

    if [ "${UPGRADE_FROM_MAJORS+set}" != set ]; then
      bake bundled-majors bundled-majors
      UPGRADE_FROM_MAJORS="$(sed -n 's/^PPT_UPGRADE_FROM_MAJORS="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${RESULTS_ROOT}/bundled-majors/ppt-upgrade-from.env")"
    fi
    echo "previously published images: ${PREVIOUS_IMAGES:-<none>}"
    echo "majors with bundled upgrade binaries: ${UPGRADE_FROM_MAJORS:-<none>}"

    n=0
    for prev in $PREVIOUS_IMAGES; do
      n=$((n + 1))
      # Pinned for the whole run, and named in the log: a moving tag must not change mid-test.
      digest="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$prev")"
      TEST_PREVIOUS="${prev}@${digest}"
      export TEST_PREVIOUS
      echo "scenario 1 #${n}: ${TEST_PREVIOUS}"
      bake upgrade-previous "previous-${n}"
      expect_results "previous-${n}" prev-seed-clean prev-seed-kill prev-seed-user \
        prev-upgrade-clean prev-upgrade-kill prev-upgrade-user
    done

    newest="${UPGRADE_FROM_MAJORS##* }"
    major_steps="seed-inplace-ha seed-relocate-postgres 2a 2b 4"
    for major in $UPGRADE_FROM_MAJORS; do
      TEST_OLD_MAJOR="$major"
      export TEST_OLD_MAJOR
      if [ "$major" = "$newest" ]; then
        bake upgrade-newest "pg${major}"
        # shellcheck disable=SC2086
        expect_results "pg${major}" $major_steps seed-relocate-ha 5a-inplace 5a-relocate \
          5b-block-inplace 5b-block-relocate 5b-fail-inplace 5b-fail-relocate \
          5b-old-inplace 5b-old-relocate 5b-fixed-inplace 5b-fixed-relocate 5c 5d 3
      else
        bake upgrade-major "pg${major}"
        # shellcheck disable=SC2086
        expect_results "pg${major}" $major_steps
      fi
    done
    ;;

  *)
    fail "unknown suite '${SUITE}' (expected smoke|compose|upgrade)"
    ;;
esac

section_close
printf '%s==> %s test PASSED for %s (run %s)%s\n' "$C_PASS" "$SUITE" "$IMAGE_REF" "$PPT_TEST_RUN" "$C_OFF"
