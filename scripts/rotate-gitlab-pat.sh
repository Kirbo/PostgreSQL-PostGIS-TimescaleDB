#!/usr/bin/env bash
set -euo pipefail

# Self-rotate the GitLab access token used for this project's CI/CD + API automation, then write the
# new token back to 1Password and into the VERSIONS_PUSH_TOKEN CI/CD variable. The token rotates
# ITSELF (the `self/rotate` endpoint), so the old value is revoked the instant the new one is issued —
# run this before the `expires` date in the 1Password item (the item is the expiry tracker).
#
# The token is a PROJECT access token (created 2026-09-15; scoped to this repo only; Maintainer role,
# `api` + `write_repository` + `self_rotate` scopes — Maintainer because gitlab-set-ci-var.sh updates
# CI/CD variables and the scheduled pipeline pushes to the protected default branch).
# `personal_access_tokens/self/rotate` accepts project access tokens too, so this script is
# token-kind-agnostic. Same script as switchboard / albumize / electrolux-to-mqtt use.
#
# 1Password item "PostgreSQL PostGIS TimescaleDB - GitLab API Token" (Personal vault), value in the
# `password` field, expiry in the `expires` date field.

# --- Config ------------------------------------------------------------------
VAULT="Personal"
ITEM="PostgreSQL PostGIS TimescaleDB - GitLab API Token"
OP_ACCOUNT="my.1password.com" # the personal-account sign-in address that `op --account` resolves —
                              # matches the sops-*.sh scripts.
GITLAB_HOST="https://gitlab.com"
EXPIRY="1 year" # "<N> <unit>", unit ∈ year|month|week|day. NOTE: gitlab.com caps access-token
                # lifetime at 365 days — if the API rejects the expiry, shorten this (e.g. "11 months").

# --- Preconditions -----------------------------------------------------------
for cmd in op curl jq date; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

# shellcheck source=scripts/op-ensure-signin.sh
. "$(dirname "$0")/op-ensure-signin.sh"
op_ensure_signin "${OP_ACCOUNT}"

# --- Compute expiration date (cross-platform: BSD `date -v` / GNU `date -d`) --
read -r EXPIRY_AMOUNT EXPIRY_UNIT <<< "${EXPIRY}"

if ! [[ "${EXPIRY_AMOUNT}" =~ ^[0-9]+$ ]] || [[ "${EXPIRY_AMOUNT}" -lt 1 ]]; then
  echo "Error: EXPIRY amount must be a positive integer, got '${EXPIRY_AMOUNT}'" >&2
  exit 1
fi

case "$(echo "${EXPIRY_UNIT}" | tr '[:upper:]' '[:lower:]')" in
  year|years)   BSD_UNIT="y"; GNU_UNIT="year" ;;
  month|months) BSD_UNIT="m"; GNU_UNIT="month" ;;
  week|weeks)   BSD_UNIT="w"; GNU_UNIT="week" ;;
  day|days)     BSD_UNIT="d"; GNU_UNIT="day" ;;
  *) echo "Error: invalid EXPIRY unit '${EXPIRY_UNIT}' (use year|month|week|day)" >&2; exit 1 ;;
esac

if date -v +1d >/dev/null 2>&1; then
  EXPIRES_AT=$(date -v "+${EXPIRY_AMOUNT}${BSD_UNIT}" +%Y-%m-%d)
else
  EXPIRES_AT=$(date -d "+${EXPIRY_AMOUNT} ${GNU_UNIT}" +%Y-%m-%d)
fi

echo "New expiration: ${EXPIRES_AT}"

# --- Read current token from 1Password ---------------------------------------
CURRENT_TOKEN=$(op read "op://${VAULT}/${ITEM}/password" --account "${OP_ACCOUNT}") || {
  echo "Error: failed to read current token from 1Password" >&2
  exit 1
}

if [[ -z "${CURRENT_TOKEN}" ]]; then
  echo "Error: current token is empty" >&2
  exit 1
fi

# --- Rotate via GitLab API ---------------------------------------------------
# Auth header via --config process substitution so the PAT never sits in curl's argv (`ps`-visible).
HTTP_RESPONSE=$(curl --silent --show-error --write-out "\n%{http_code}" \
  --request POST \
  --config <(printf 'header = "PRIVATE-TOKEN: %s"' "${CURRENT_TOKEN}") \
  --url "${GITLAB_HOST}/api/v4/personal_access_tokens/self/rotate?expires_at=${EXPIRES_AT}")

HTTP_CODE=$(echo "${HTTP_RESPONSE}" | tail -n1)
BODY=$(echo "${HTTP_RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" -lt 200 || "${HTTP_CODE}" -ge 300 ]]; then
  echo "Error: GitLab API returned HTTP ${HTTP_CODE}" >&2
  echo "${BODY}" | jq . >&2 2>/dev/null || echo "${BODY}" >&2
  exit 1
fi

NEW_TOKEN=$(echo "${BODY}" | jq -r '.token // empty')

if [[ -z "${NEW_TOKEN}" || "${NEW_TOKEN}" == "null" ]]; then
  echo "Error: no token in response body" >&2
  echo "${BODY}" | jq . >&2 2>/dev/null || echo "${BODY}" >&2
  exit 1
fi

# --- Save the new token back to 1Password ------------------------------------
# (`expires` date field is created if the item lacks it — harmless, gives an at-a-glance expiry.)
# NOTE: `op item edit` has no stdin form for field values, so the token IS in op's argv for the
# call's duration (ps-visible) — accepted on this single-user machine.
if ! op item edit "${ITEM}" --vault "${VAULT}" --account "${OP_ACCOUNT}" \
    "password=${NEW_TOKEN}" \
    "expires[date]=${EXPIRES_AT}" >/dev/null; then
  echo "Error: failed to update 1Password item" >&2
  echo "CRITICAL: a new token was issued but NOT saved. Save it manually NOW:" >&2
  echo "${NEW_TOKEN}" >&2
  exit 1
fi

echo "Token rotated and saved to 1Password (expires ${EXPIRES_AT})."

# --- Mirror the new token into the VERSIONS_PUSH_TOKEN CI/CD variable -------------------------------
# The weekly `check upstream versions` job pushes the version-bump commit with VERSIONS_PUSH_TOKEN, so
# it must track the rotated token or the schedule breaks. Auth with the NEW token itself (valid
# immediately post-rotation). Non-fatal: the token is already safe in 1Password, so a CI hiccup
# shouldn't fail the rotation — re-run after fixing access. gitlab-set-ci-var.sh updates only the
# value, preserving the variable's existing masking/protection.
if ! GITLAB_PAT="${NEW_TOKEN}" CI_VAR_KEY="VERSIONS_PUSH_TOKEN" CI_VAR_VALUE="${NEW_TOKEN}" \
    "$(dirname "$0")/gitlab-set-ci-var.sh"; then
  echo "WARNING: the new token is saved in 1Password, but updating the VERSIONS_PUSH_TOKEN CI/CD variable" >&2
  echo "         failed — set it manually in the project's CI/CD settings or re-run after fixing access." >&2
fi
