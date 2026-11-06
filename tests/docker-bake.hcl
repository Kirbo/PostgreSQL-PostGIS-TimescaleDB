# tests/docker-bake.hcl — the test suites of tests/Dockerfile as bake targets. Bake rather than
# plain `docker buildx build` because the upgrade test needs a second image built from the
# repository's Dockerfile with other build args (the older-major fixture), linked in as the
# named context "ppt-fixture" — one solve, no registry round trip.
#
# Don't call this directly: scripts/buildkit-test.sh sets the variables, runs the targets one
# after another and checks every step's result file.

# The image under test: a registry reference (CI: the staging digest) or, with
# TEST_IMAGE_CONTEXT set, the named context "ppt-under-test" (oci-layout://..., docker-image://...).
variable "TEST_IMAGE" { default = "" }
variable "TEST_IMAGE_CONTEXT" { default = "" }
# The per-invocation token every test step writes into its result (and its cache key).
variable "PPT_TEST_RUN" { default = "" }
# Where the result files are exported (--output type=local).
variable "TEST_RESULTS_DIR" { default = "test-results" }
# smoke: the platform to test (linux/amd64, linux/arm64); empty = the builder's own.
variable "TEST_PLATFORM" { default = "" }
# compose: the service's environment, base64 of NUL-separated KEY=VALUE.
variable "COMPOSE_ENV_B64" { default = "" }
# upgrade: the older major of the fixture, and the previously published image (name@digest).
variable "TEST_OLD_MAJOR" { default = "" }
variable "TEST_PREVIOUS" { default = "" }
# From build.env / versions.env (scripts/buildkit-test.sh exports them): the fixture is built
# with the same Debian suite and extension versions as the image under test.
variable "DEBIAN_SUITE" { default = "" }
variable "POSTGIS_VERSION" { default = "" }
variable "TIMESCALEDB_VERSION" { default = "" }

function "under_test" {
  params = []
  result = TEST_IMAGE_CONTEXT != "" ? { "ppt-under-test" = TEST_IMAGE_CONTEXT } : {}
}

target "_suite" {
  context    = "."
  dockerfile = "tests/Dockerfile"
  args = {
    IMAGE        = TEST_IMAGE_CONTEXT != "" ? "ppt-under-test" : TEST_IMAGE
    PPT_TEST_RUN = PPT_TEST_RUN
  }
  contexts = under_test()
  output   = ["type=local,dest=${TEST_RESULTS_DIR}"]
}

target "bundled-majors" {
  inherits = ["_suite"]
  target   = "bundled-majors"
}

target "smoke" {
  inherits        = ["_suite"]
  target          = "smoke-results"
  platforms       = TEST_PLATFORM != "" ? [TEST_PLATFORM] : []
  no-cache-filter = ["smoke"]
}

target "compose" {
  inherits        = ["_suite"]
  target          = "compose-results"
  args            = { COMPOSE_ENV_B64 = COMPOSE_ENV_B64 }
  no-cache-filter = ["compose"]
}

target "upgrade-previous" {
  inherits        = ["_suite"]
  target          = "upgrade-previous-results"
  args            = { PREVIOUS = TEST_PREVIOUS }
  no-cache-filter = ["p-seed", "p-upgrade"]
}

# The PostgreSQL <TEST_OLD_MAJOR> image a user of an older major runs: this repository's
# Dockerfile on postgres:<major>-<suite>, same extension versions, bundling nothing.
target "fixture" {
  context    = "."
  dockerfile = "Dockerfile"
  args = {
    PG_VERSION             = TEST_OLD_MAJOR
    DEBIAN_SUITE           = DEBIAN_SUITE
    POSTGIS_VERSION        = POSTGIS_VERSION
    TIMESCALEDB_VERSION    = TIMESCALEDB_VERSION
    MIN_UPGRADE_FROM_MAJOR = TEST_OLD_MAJOR
  }
}

target "upgrade-major" {
  inherits        = ["_suite"]
  target          = "upgrade-major-results"
  args            = { FIXTURE = "ppt-fixture", OLD_MAJOR = TEST_OLD_MAJOR }
  # Not named "fixture": a named context replaces the Dockerfile stage of the same name.
  contexts        = merge(under_test(), { "ppt-fixture" = "target:fixture" })
  no-cache-filter = ["u-seed", "u-2a", "u-2b", "u-4"]
}

target "upgrade-newest" {
  inherits = ["upgrade-major"]
  target   = "upgrade-newest-results"
  no-cache-filter = [
    "u-seed", "u-2a", "u-2b", "u-4", "u-seed-newest", "u-5a", "u-5b-block", "u-5b-fail",
    "u-5b-old", "u-5b-fixed", "u-5c", "u-5d", "u-3",
  ]
}
