# shellcheck shell=sh
# Sourced by the CI jobs that need a secret: `. ci/secrets.sh`, then `secrets_load <profile>`.
#
# Every CI secret lives in fnox.toml as age ciphertext, encrypted only to the CI tier that may
# read it (docs/SECRETS.md). A job's GitLab environment (`action: prepare`) selects its tier:
# GitLab gives it ONE protected File variable, FNOX_AGE_KEY_FILE, scoped to that environment —
#   release/publish   `publish image`            profile publish   (Docker Hub)
#   release/versions  `check upstream versions`  profile versions  (the repo-write token)
# fnox decrypts with it. fnox and age (whose age-plugin-pq fnox needs for the post-quantum keys)
# come from mise.lock in locked mode, through the pinned mise of ci/install-mise.sh.
#
# There are no plain CI/CD secret variables any more (removed 2026-11-07 once both tiers had run
# green on fnox): a job without its identity fails here, closed, instead of falling back.
#
# GitLab masks none of the fnox values in the job log (they are not GitLab variables): never
# `set -x`, never echo them.

export FNOX_NON_INTERACTIVE=true

# secrets_load <profile> — export the profile's secrets into THIS shell. Exits the job when an
# identity is present but cannot decrypt the profile (a wrong tier, or fnox.toml without the
# values yet: both are bugs to fix, not to fall back from).
secrets_load() {
  if [ -z "${FNOX_AGE_KEY_FILE:-}" ]; then
    echo "secrets: no FNOX_AGE_KEY_FILE for environment ${CI_ENVIRONMENT_NAME:-none} — this job needs its tier's identity (docs/SECRETS.md, scripts/secrets.sh sync-ci)" >&2
    exit 1
  fi
  if ! command -v mise >/dev/null 2>&1; then
    sh ci/install-mise.sh || exit 1
    PATH="${HOME}/.local/bin:${PATH}"
    export PATH
  fi
  mise install --locked fnox age || exit 1
  if ! _so=$(mise exec fnox age -- fnox export --format shell --no-defaults --if-missing error -P "$1"); then
    echo "secrets: this job's identity cannot decrypt fnox profile '$1' (wrong tier, or fnox.toml lacks its values: scripts/secrets.sh set $1 …)" >&2
    exit 1
  fi
  eval "${_so}"
  unset _so
  echo "secrets: loaded fnox profile '$1'"
}
