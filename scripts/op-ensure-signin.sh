#!/usr/bin/env bash
# shellcheck shell=bash
#
# Sourced helper: ensure an active 1Password CLI session, running `op signin` when needed instead of
# erroring out. Source it, then call `op_ensure_signin <account>` before any `op` command:
#   . "$(dirname "$0")/op-ensure-signin.sh"
#   op_ensure_signin "my.1password.com"
#
# Already-authenticated sessions (incl. a service-account token via OP_SERVICE_ACCOUNT_TOKEN, used for
# headless/scheduled runs) pass the first check and skip the interactive signin entirely.

op_ensure_signin() {
  local account="${1:?op_ensure_signin: account argument required}"

  if ! command -v op >/dev/null 2>&1; then
    echo "Error: 1Password CLI 'op' not found in PATH" >&2
    return 1
  fi

  # Already signed in? Nothing to do.
  if op whoami --account "${account}" >/dev/null 2>&1; then
    return 0
  fi

  echo "Not signed in to 1Password (${account}) — running 'op signin'…" >&2
  # eval so a printed session token (CLI WITHOUT 1Password-app integration) is exported into this
  # shell; a harmless no-op under app integration (signin unlocks via Touch ID and prints nothing to
  # eval). `|| true` because the real gate is the re-check below — an empty eval always succeeds.
  eval "$(op signin --account "${account}")" || true

  if ! op whoami --account "${account}" >/dev/null 2>&1; then
    echo "Error: still not signed in to 1Password (${account}) after 'op signin'." >&2
    return 1
  fi
}
