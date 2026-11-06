# syntax=docker/dockerfile:1

# The tests, as BuildKit build stages: no Docker engine, no `docker run` — every check runs in a
# RUN step of a stage built FROM the image under test (or an older image), on whatever BuildKit
# the buildx builder points at (CI: the Mac's BuildKit servers). The steps start the image's own
# entrypoint as a background process, wait for it with bounded pg_isready / psql polling, assert,
# and stop it — tests/lib.sh explains how a "container", a "volume", stop and kill map onto a
# RUN step. Run the suites through scripts/buildkit-test.sh (targets: tests/docker-bake.hcl).
#
# Every test step:
#   * is an exec-form RUN of tests/run.sh, the step's PID 1 (it reaps the orphans of killed
#     servers)
#   * has --network=none: a loopback of its own (the BuildKit servers run RUN steps on the host
#     network, so two builds would otherwise share port 5432)
#   * consumes ARG PPT_TEST_RUN, a token unique per invocation, AND is listed in its bake target's
#     no-cache-filter — so it re-runs every time — and writes /results/<step> = "PASS <token>"
#     (exported with --output type=local; scripts/buildkit-test.sh rejects a missing result or
#     an older token)
#   * gets its volume as `--mount=type=bind,...,rw`: a real mount point, seeded from an earlier
#     stage, discarded at the end of the step unless the step saves it (vol_save -> /seeds/<name>)
# Steps that run PostgreSQL are chained one after another (each mounts the previous one's
# /results at /ppt-after), so a suite never runs two servers at once: BuildKit caps the server
# at 3 GiB, shared with every other build on it.

# The image under test, by digest in CI (scripts/buildkit-test.sh passes it), or the named
# context "ppt-under-test" for local runs.
ARG IMAGE=ppt-under-test
# Older images for the upgrade test: a fixture of an older PostgreSQL major (a bake target built
# from ../Dockerfile, named context "ppt-fixture"), and a previously published image. They default
# to the image under test so the stages that use them always resolve.
ARG FIXTURE=${IMAGE}
ARG PREVIOUS=${IMAGE}

# --- the images, as the test stages see them -------------------------------------------------
# Each captures, for tests/lib.sh, its own environment (before any ARG exists in the stage), the
# mode and owner of /var/run/postgresql (restored for every new container) and a copy of its
# volume directories as Docker would populate a fresh volume mounted there.

FROM ${IMAGE} AS image
RUN ["/bin/sh", "-c", "env -0 > /ppt-image.env && stat -c '%a %u %g' /var/run/postgresql > /ppt-image.rundir && cp -a /var/lib/postgresql /ppt-vol-root"]

FROM ${FIXTURE} AS fixture
RUN ["/bin/sh", "-c", "env -0 > /ppt-image.env && stat -c '%a %u %g' /var/run/postgresql > /ppt-image.rundir && cp -a /var/lib/postgresql /ppt-vol-root && cp -a /var/lib/postgresql/data /ppt-vol-data"]

FROM ${PREVIOUS} AS previous
RUN ["/bin/sh", "-c", "env -0 > /ppt-image.env && stat -c '%a %u %g' /var/run/postgresql > /ppt-image.rundir && cp -a /var/lib/postgresql /ppt-vol-root"]

# What the image bundles for the automatic major upgrade (scripts/buildkit-test.sh reads it to
# pick the fixtures).
FROM scratch AS bundled-majors
COPY --from=image /etc/ppt-upgrade-from.env /

# --- smoke: once per platform ------------------------------------------------------------------

FROM image AS smoke
ARG PPT_TEST_RUN
ARG TARGETPLATFORM
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=image,source=/ppt-vol-root,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "smoke", "main"]
# A fresh volume of its own, as a second `docker run` would get — hence a RUN of its own.
# hadolint ignore=DL3059
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=image,source=/ppt-vol-root,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "smoke", "defaults"]

FROM scratch AS smoke-results
COPY --from=smoke /results/ /

# --- compose: docker-compose.yml's service, its environment, a fresh volume ---------------------

FROM image AS compose
ARG PPT_TEST_RUN
ARG COMPOSE_ENV_B64
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=image,source=/ppt-vol-root,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "compose"]

FROM scratch AS compose-results
COPY --from=compose /results/ /

# --- upgrade, scenario 1: a previously published image of the same major -----------------------

FROM previous AS p-seed
ARG PPT_TEST_RUN
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=previous,source=/ppt-vol-root,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "prev-seed", "clean"]
# Each seed starts from a fresh volume (its own rw mount) — separate RUNs on purpose.
# hadolint ignore=DL3059
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=previous,source=/ppt-vol-root,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "prev-seed", "kill"]
# hadolint ignore=DL3059
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=previous,source=/ppt-vol-root,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "prev-seed", "user"]

FROM image AS p-upgrade
ARG PPT_TEST_RUN
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=p-seed,source=/seeds,target=/ppt-seeds \
    --mount=type=bind,from=p-seed,source=/seeds/prev-clean,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "prev-upgrade", "clean"]
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=p-seed,source=/seeds,target=/ppt-seeds \
    --mount=type=bind,from=p-seed,source=/seeds/prev-kill,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "prev-upgrade", "kill"]
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=p-seed,source=/seeds,target=/ppt-seeds \
    --mount=type=bind,from=p-seed,source=/seeds/prev-user,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "prev-upgrade", "user"]

FROM scratch AS upgrade-previous-results
COPY --from=p-seed /results/ /
COPY --from=p-upgrade /results/ /

# --- upgrade, scenarios 2 + 4: an older PostgreSQL major (one fixture per bake call) ------------
# Seeded by the fixture (the old image), upgraded by the image under test.

FROM fixture AS u-seed
ARG PPT_TEST_RUN
# The <= 17 layout: volume at /var/lib/postgresql/data, custom superuser.
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=fixture,source=/ppt-vol-data,target=/var/lib/postgresql/data,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "seed-inplace-ha"]
# The 18+ layout: volume at /var/lib/postgresql, cluster in <major>/docker, default superuser.
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=fixture,source=/ppt-vol-root,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "seed-relocate-postgres"]

FROM image AS u-2a
ARG PPT_TEST_RUN
ARG OLD_MAJOR
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-seed,source=/seeds/inplace-ha,target=/var/lib/postgresql/data,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "2a"]

FROM image AS u-2b
ARG PPT_TEST_RUN
ARG OLD_MAJOR
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-2a,source=/results,target=/ppt-after \
    --mount=type=bind,from=u-seed,source=/seeds/relocate-postgres,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "2b"]

FROM image AS u-4
ARG PPT_TEST_RUN
ARG OLD_MAJOR
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-2b,source=/results,target=/ppt-after \
    --mount=type=bind,from=u-seed,source=/seeds/inplace-ha,target=/var/lib/postgresql/data,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "4"]

FROM scratch AS upgrade-major-results
COPY --from=u-seed /results/ /
COPY --from=u-2a /results/ /
COPY --from=u-2b /results/ /
COPY --from=u-4 /results/ /

# --- upgrade, scenarios 5 + 3: the newest bundled major only -------------------------------------

FROM fixture AS u-seed-newest
ARG PPT_TEST_RUN
# The 18+ layout with the custom superuser (what scenario 5 starts from in that layout).
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-4,source=/results,target=/ppt-after \
    --mount=type=bind,from=fixture,source=/ppt-vol-root,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "seed-relocate-ha"]

# 5a: killed at every stage of the upgrade, then started again. The seed is also mounted
# read-only at /ppt-seed, so each kill point starts from a fresh copy of it.
FROM image AS u-5a
ARG PPT_TEST_RUN
ARG OLD_MAJOR
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-seed-newest,source=/results,target=/ppt-after \
    --mount=type=bind,from=u-seed,source=/seeds/inplace-ha,target=/ppt-seed \
    --mount=type=bind,from=u-seed,source=/seeds/inplace-ha,target=/var/lib/postgresql/data,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5a", "inplace"]
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-seed-newest,source=/seeds/relocate-ha,target=/ppt-seed \
    --mount=type=bind,from=u-seed-newest,source=/seeds/relocate-ha,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5a", "relocate"]

# 5b: a pg_upgrade that fails is rolled back; the old image starts the volume again; once the
# cause is gone the upgrade succeeds. Four stages, alternating between the two images.
FROM fixture AS u-5b-block
ARG PPT_TEST_RUN
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-5a,source=/results,target=/ppt-after \
    --mount=type=bind,from=u-seed,source=/seeds/inplace-ha,target=/var/lib/postgresql/data,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5b-block", "inplace"]
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-seed-newest,source=/seeds/relocate-ha,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5b-block", "relocate"]

FROM image AS u-5b-fail
ARG PPT_TEST_RUN
ARG OLD_MAJOR
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-5b-block,source=/seeds/5b-inplace,target=/var/lib/postgresql/data,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5b-fail", "inplace"]
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-5b-block,source=/seeds/5b-relocate,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5b-fail", "relocate"]

FROM fixture AS u-5b-old
ARG PPT_TEST_RUN
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-5b-fail,source=/seeds/5b-inplace-failed,target=/var/lib/postgresql/data,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5b-old", "inplace"]
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-5b-fail,source=/seeds/5b-relocate-failed,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5b-old", "relocate"]

FROM image AS u-5b-fixed
ARG PPT_TEST_RUN
ARG OLD_MAJOR
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-5b-old,source=/seeds/5b-inplace-unblocked,target=/var/lib/postgresql/data,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5b-fixed", "inplace"]
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-5b-old,source=/seeds/5b-relocate-unblocked,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5b-fixed", "relocate"]

# 5c: PPT_KEEP_OLD_CLUSTER=1. 5d: two clusters in one volume. 3: PPT_AUTO_UPGRADE=off.
FROM image AS u-5c
ARG PPT_TEST_RUN
ARG OLD_MAJOR
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-5b-fixed,source=/results,target=/ppt-after \
    --mount=type=bind,from=u-seed-newest,source=/seeds/relocate-ha,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5c"]

FROM image AS u-5d
ARG PPT_TEST_RUN
ARG OLD_MAJOR
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-5c,source=/results,target=/ppt-after \
    --mount=type=bind,from=u-seed-newest,source=/seeds/relocate-ha,target=/var/lib/postgresql,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "5d"]

FROM image AS u-3
ARG PPT_TEST_RUN
ARG OLD_MAJOR
RUN --network=none \
    --mount=type=bind,target=/ppt \
    --mount=type=bind,from=u-5d,source=/results,target=/ppt-after \
    --mount=type=bind,from=u-seed,source=/seeds/inplace-ha,target=/var/lib/postgresql/data,rw \
    ["/bin/sh", "/ppt/tests/run.sh", "upgrade", "3"]

FROM scratch AS upgrade-newest-results
COPY --from=u-seed /results/ /
COPY --from=u-2a /results/ /
COPY --from=u-2b /results/ /
COPY --from=u-4 /results/ /
COPY --from=u-seed-newest /results/ /
COPY --from=u-5a /results/ /
COPY --from=u-5b-block /results/ /
COPY --from=u-5b-fail /results/ /
COPY --from=u-5b-old /results/ /
COPY --from=u-5b-fixed /results/ /
COPY --from=u-5c /results/ /
COPY --from=u-5d /results/ /
COPY --from=u-3 /results/ /
