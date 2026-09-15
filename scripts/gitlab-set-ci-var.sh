#!/usr/bin/env bash
set -euo pipefail

# Create-or-update a single GitLab CI/CD variable via the API. Shared by the secret-rotation scripts
# (rotate-gitlab-pat.sh). Inputs come via the ENVIRONMENT, and the PAT + value are
# fed to curl via process substitution / stdin (a bash-builtin printf pipe), so neither this script's
# NOR curl's argv ever carries a secret (`ps`-safe):
#   GITLAB_PAT     (required) — PAT with `api` scope + Maintainer+ on the project (authenticates).
#   CI_VAR_KEY     (required) — variable name, e.g. VERSIONS_PUSH_TOKEN.
#   CI_VAR_VALUE   (required) — the value to store.
#   CI_PROJECT_ID  (optional) — defaults to 86056054 (postgresql-postgis-timescaledb).
#   GITLAB_API     (optional) — defaults to https://gitlab.com/api/v4.
#
# CREATE: sets the value masked + protected + raw + scope '*'. Protected = only pipelines on protected
# refs (main, v* tags) can read it — branch pipelines that need it must run from a protected ref. If
# GitLab refuses to MASK the value (its masking charset can reject some symbols) it retries UNMASKED
# with a warning — tolerable because variables aren't shown to non-members and callers never echo
# them, but prefer a File-type variable in that case.
# UPDATE: changes ONLY the value and re-sends the variable's EXISTING masked/protected/raw/scope (read
# back first), so rotating a value never silently weakens a variable's protection.

: "${GITLAB_PAT:?GITLAB_PAT must be set}"
: "${CI_VAR_KEY:?CI_VAR_KEY must be set}"
: "${CI_VAR_VALUE:?CI_VAR_VALUE must be set}"
PROJECT_ID="${CI_PROJECT_ID:-86056054}"
API="${GITLAB_API:-https://gitlab.com/api/v4}"

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

VAR_URL="${API}/projects/${PROJECT_ID}/variables"

# Auth header via process substitution: curl reads it from a /dev/fd path, so the PAT never appears
# in curl's argv (visible to every local user via `ps`/`/proc/*/cmdline` for the request duration).
auth() { printf 'header = "PRIVATE-TOKEN: %s"' "${GITLAB_PAT}"; }

# Look the variable up (also the existence check) so an UPDATE can preserve its flags.
CUR_RESP=$(curl --silent --show-error --write-out "\n%{http_code}" \
  --config <(auth) --url "${VAR_URL}/${CI_VAR_KEY}")
CUR_CODE=$(echo "${CUR_RESP}" | tail -n1)
CUR_BODY=$(echo "${CUR_RESP}" | sed '$d')

fail() {
  echo "Error: GitLab API returned HTTP $1 for ${CI_VAR_KEY}" >&2
  echo "$2" | jq . >&2 2>/dev/null || echo "$2" >&2
  exit 1
}

if [[ "${CUR_CODE}" == "200" ]]; then
  # --- UPDATE: change only the value; preserve the existing masked/protected/raw/scope. ---
  masked=$(echo "${CUR_BODY}" | jq -r '.masked // false')
  protected=$(echo "${CUR_BODY}" | jq -r '.protected // false')
  raw=$(echo "${CUR_BODY}" | jq -r '.raw // false')
  scope=$(echo "${CUR_BODY}" | jq -r '.environment_scope // "*"')
  echo "Updating CI/CD variable ${CI_VAR_KEY} (value only; keeping masked=${masked} protected=${protected})…"
  # value@- reads the secret from stdin (builtin printf — no extra process, nothing in argv).
  RESP=$(printf '%s' "${CI_VAR_VALUE}" | curl --silent --show-error --write-out "\n%{http_code}" --request PUT \
    --config <(auth) \
    --data-urlencode "value@-" \
    --data-urlencode "masked=${masked}" \
    --data-urlencode "protected=${protected}" \
    --data-urlencode "raw=${raw}" \
    --data-urlencode "environment_scope=${scope}" \
    --url "${VAR_URL}/${CI_VAR_KEY}")
  CODE=$(echo "${RESP}" | tail -n1); BODY=$(echo "${RESP}" | sed '$d')
  if [[ "${CODE}" == "400" ]] && echo "${BODY}" | grep -qi "mask"; then
    echo "Error: the new value can't satisfy this variable's existing masking — set it manually or" >&2
    echo "       recreate ${CI_VAR_KEY} unmasked / as a File-type variable." >&2
    fail "${CODE}" "${BODY}"
  fi
  [[ "${CODE}" -ge 200 && "${CODE}" -lt 300 ]] || fail "${CODE}" "${BODY}"

elif [[ "${CUR_CODE}" == "404" ]]; then
  # --- CREATE: masked + protected by default, with an unmasked fallback. ---
  # A *_FILE key is created as a File-type variable (GitLab materializes the value as a temp file
  # and the env var holds its path — keeps the secret out of the job environment block).
  VAR_TYPE="env_var"
  [[ "${CI_VAR_KEY}" == *_FILE ]] && VAR_TYPE="file"
  create() { # $1 = masked flag
    printf '%s' "${CI_VAR_VALUE}" | curl --silent --show-error --write-out "\n%{http_code}" --request POST \
      --config <(auth) \
      --data-urlencode "key=${CI_VAR_KEY}" \
      --data-urlencode "value@-" \
      --data-urlencode "masked=$1" \
      --data-urlencode "protected=true" \
      --data-urlencode "raw=true" \
      --data-urlencode "variable_type=${VAR_TYPE}" \
      --data-urlencode "environment_scope=*" \
      --url "${VAR_URL}"
  }
  echo "Creating CI/CD variable ${CI_VAR_KEY} (masked + protected)…"
  RESP=$(create true); CODE=$(echo "${RESP}" | tail -n1); BODY=$(echo "${RESP}" | sed '$d')
  if [[ "${CODE}" == "400" ]] && echo "${BODY}" | grep -qi "mask"; then
    echo "WARNING: GitLab won't mask ${CI_VAR_KEY} (value has chars outside its masking charset) —" >&2
    echo "         creating it UNMASKED (still protected). Variables aren't shown to non-members and" >&2
    echo "         callers don't echo the value, but prefer recreating it as a File-type variable." >&2
    RESP=$(create false); CODE=$(echo "${RESP}" | tail -n1); BODY=$(echo "${RESP}" | sed '$d')
  fi
  [[ "${CODE}" -ge 200 && "${CODE}" -lt 300 ]] || fail "${CODE}" "${BODY}"

else
  fail "${CUR_CODE}" "${CUR_BODY}"
fi

echo "✓ ${CI_VAR_KEY} set in GitLab CI/CD (project ${PROJECT_ID})."
