#!/usr/bin/env bash
# secrets.sh — manage this repo's CI secrets in fnox.toml (https://fnox.jdx.dev).
# docs/SECRETS.md has the design. Maintainer machines only: CI uses ci/secrets.sh.
#
#   init-keys          one-time: new maintainer + publish + versions keys into 1Password, their
#                      public halves into fnox.toml, then `setup` and `sync-ci`.
#   setup              once per machine: the maintainer identity 1Password -> OS keychain, and a
#                      generated fnox.local.toml pointing every age provider at it.
#   refresh-local      regenerate fnox.local.toml from fnox.toml (after pulling a recipient change).
#   check              every profile that holds secrets decrypts.
#   set <profile> <NAME>
#                      encrypt one value, read from stdin, into that profile (publish|versions).
#   sync-ci [tier]     push the CI identities (publish, versions, or both) 1Password -> GitLab:
#                      File variable FNOX_AGE_KEY_FILE per environment, protected, masked. glab.
#   rotate <maintainer|publish|versions>
#                      new key for one identity: 1Password first, then recipients and
#                      re-encryption, then the keychain / GitLab. Commit fnox.toml after.
#
# Every identity is post-quantum (age-keygen -pq). fnox reaches it through age-plugin-pq, so fnox
# needs the PLUGIN form (AGE-PLUGIN-PQ-1…). Private keys only ever travel through pipes,
# environment variables or 0600 files in a private temp dir, never argv, and are never printed.
# Needs an activated mise (fnox, age, jq, glab), the 1Password CLI `op`, and for sync-ci an
# authenticated `glab`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

FNOX_FILE="fnox.toml"
LOCAL_FILE="fnox.local.toml"
KEYCHAIN_SERVICE="postgresql-postgis-timescaledb.fnox"
IDENTITY_SECRET="PPT_AGE_IDENTITY"
OP_ACCOUNT="${OP_ACCOUNT:-my.1password.com}"
OP_VAULT="${OP_VAULT:-Personal}"
OP_ITEM="PostgreSQL PostGIS TimescaleDB fnox keys"
# Named explicitly so sync-ci never depends on the git remote (a moved project's old path
# refuses writes).
GITLAB_PROJECT="KirboDev/agentic-coding/postgresql-postgis-timescaledb"
# Profile = CI tier = provider suffix; each tier's job runs in GitLab environment release/<tier>.
PROFILES=(publish versions)

export FNOX_NON_INTERACTIVE=true

die() {
  echo "secrets: $*" >&2
  exit 1
}

need() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "'${cmd}' not on PATH (activate mise; install the 1Password CLI)"
  done
}

is_tier() { [[ " ${PROFILES[*]} " == *" $1 "* ]]; }

op_() { op "$@" --account "${OP_ACCOUNT}"; }

op_signin() {
  need op
  op whoami --account "${OP_ACCOUNT}" >/dev/null 2>&1 && return 0
  echo "Not signed in to 1Password (${OP_ACCOUNT}), running 'op signin'…" >&2
  # eval exports a printed session token (CLI without app integration); a no-op otherwise.
  eval "$(op signin --account "${OP_ACCOUNT}")" || true
  op whoami --account "${OP_ACCOUNT}" >/dev/null 2>&1 || die "still not signed in to 1Password"
}

op_field() { op_ read "op://${OP_VAULT}/${OP_ITEM}/$1"; }

# with_template <jq filter> <op args…> — render an item template with jq (secret values come
# from the environment as $ENV.*, never argv) into a 0600 file in a private temp dir, and run
# `op <args> --template <file>`. op has no stdin form for field values.
with_template() {
  local filter="$1" dir rc=0
  shift
  dir=$(mktemp -d)
  (umask 077 && jq -n "${filter}" >"${dir}/item.json") || rc=$?
  [[ "${rc}" -eq 0 ]] && { op_ "$@" --template "${dir}/item.json" >/dev/null || rc=$?; }
  rm -rf "${dir}"
  return "${rc}"
}

# op_set_fields <label>… — set the named fields (values in $ENV[label with spaces → _]) on the
# item, keeping every other field. An edit template replaces the whole item, so it starts from
# the item as 1Password holds it.
op_set_fields() {
  local current dir rc=0
  current=$(op_ item get "${OP_ITEM}" --vault "${OP_VAULT}" --reveal --format json)
  dir=$(mktemp -d)
  (
    umask 077
    printf '%s' "${current}" | jq --args '
      reduce $ARGS.positional[] as $label (.;
        ($ENV[$label | gsub(" "; "_")]) as $value
        | (($label | endswith("identity")) | if . then "CONCEALED" else "STRING" end) as $type
        | if any(.fields[]; .label == $label)
          then .fields |= map(if .label == $label then .value = $value | .type = $type else . end)
          else .fields += [{label: $label, type: $type, value: $value}]
          end)' "$@" >"${dir}/item.json"
  ) || rc=$?
  [[ "${rc}" -eq 0 ]] && { op_ item edit "${OP_ITEM}" --vault "${OP_VAULT}" --template "${dir}/item.json" >/dev/null || rc=$?; }
  rm -rf "${dir}"
  return "${rc}"
}

# new_identity — sets NEW_IDENTITY (plugin form) and NEW_RECIPIENT. Memory only.
new_identity() {
  local native
  native=$(age-keygen -pq 2>/dev/null)
  NEW_RECIPIENT=$(printf '%s\n' "${native}" | age-keygen -y)
  NEW_IDENTITY=$(printf '%s\n' "${native}" | age-plugin-pq -identity | grep '^AGE-PLUGIN-PQ-1')
  unset native
  [[ "${NEW_RECIPIENT}" == age1pq1* && -n "${NEW_IDENTITY}" ]] || die "age-keygen -pq / age-plugin-pq gave no post-quantum key"
}

# set_recipient <label> <recipient> — rewrite every `# <label>` recipient line in fnox.toml.
set_recipient() {
  grep -q "\", # $1\$" "${FNOX_FILE}" || die "${FNOX_FILE} has no '# $1' recipient line"
  sed -i.bak -E "s|\"age1[a-z0-9-]+\", # $1\$|\"$2\", # $1|" "${FNOX_FILE}"
  rm -f "${FNOX_FILE}.bak"
}

# profiles_with_secrets — the profiles fnox.toml holds values for (fnox refuses the others).
profiles_with_secrets() {
  local p
  for p in "${PROFILES[@]}"; do
    if grep -q "^\[profiles\.${p}\.secrets\]" "${FNOX_FILE}"; then echo "${p}"; fi
  done
}

cmd_refresh_local() {
  [[ -f "${LOCAL_FILE}" || "${1:-}" == "--create" ]] || return 0
  local tmp="${LOCAL_FILE}.tmp.$$"
  (
    umask 077
    {
      echo "# GENERATED by scripts/secrets.sh refresh-local from ${FNOX_FILE} — do not edit, do not commit."
      echo "# fnox merges providers whole, so each age provider is repeated with this machine's"
      echo "# identity: the maintainer key, held in the OS keychain (never on disk)."
      echo ""
      echo "[providers.keychain]"
      echo "type = \"keychain\""
      echo "service = \"${KEYCHAIN_SERVICE}\""
      echo ""
      awk -v key="${IDENTITY_SECRET}" '
        /^\[/ { inage = ($0 ~ /^\[providers\.age_[a-z0-9_]+\]/) }
        inage {
          print
          if ($0 ~ /^type = "age"/) print "identity = { provider = \"keychain\", value = \"" key "\" }"
        }
      ' "${FNOX_FILE}"
      echo ""
      echo "[secrets]"
      echo "${IDENTITY_SECRET} = { provider = \"keychain\", value = \"${IDENTITY_SECRET}\", env = false }"
    } >"${tmp}"
  )
  mv "${tmp}" "${LOCAL_FILE}"
  echo "secrets: regenerated ${LOCAL_FILE} from ${FNOX_FILE}"
}

# store_keychain — the identity on stdin into the OS keychain, via fnox's keychain provider.
store_keychain() {
  fnox -c "${LOCAL_FILE}" set "${IDENTITY_SECRET}" --provider keychain >/dev/null
  # `fnox set` also records the entry in the file; put the generated text back.
  cmd_refresh_local
}

cmd_check() {
  local p found=0
  for p in $(profiles_with_secrets); do
    fnox check --no-defaults -P "${p}"
    found=1
  done
  [[ "${found}" -eq 1 ]] || echo "secrets: no profile holds secrets yet (scripts/secrets.sh set …)"
}

cmd_setup() {
  need fnox age-plugin-pq
  grep -q '"age1placeholder-' "${FNOX_FILE}" && die "${FNOX_FILE} has no keys yet — run 'scripts/secrets.sh init-keys'"
  op_signin
  cmd_refresh_local --create
  echo "Storing the maintainer identity in the OS keychain…"
  op_field "maintainer identity" | store_keychain
  cmd_check
  echo "✓ fnox ready on this machine."
}

# sync_tier <tier> — that tier's identity 1Password -> GitLab, scoped to release/<tier>.
sync_tier() {
  local tier="$1" identity scope="release/$1"
  identity=$(op_field "${tier} identity")
  [[ "${identity}" == AGE-PLUGIN-PQ-1* ]] || die "1Password \"${OP_ITEM}\" has no ${tier} identity"
  # ONE line, no trailing newline: GitLab masks only single-line values.
  local flags=(--repo "${GITLAB_PROJECT}" --type file --protected --masked --raw --scope "${scope}")
  if glab variable get FNOX_AGE_KEY_FILE --repo "${GITLAB_PROJECT}" --scope "${scope}" >/dev/null 2>&1; then
    printf '%s' "${identity}" | glab variable update FNOX_AGE_KEY_FILE "${flags[@]}" >/dev/null
  else
    printf '%s' "${identity}" | glab variable set FNOX_AGE_KEY_FILE "${flags[@]}" >/dev/null
  fi
  unset identity
  echo "✓ FNOX_AGE_KEY_FILE set in GitLab (${GITLAB_PROJECT}) for environment ${scope}"
}

cmd_sync_ci() {
  need glab
  op_signin
  local tier
  if [[ -n "${1:-}" ]]; then
    is_tier "$1" || die "usage: scripts/secrets.sh sync-ci [$(IFS='|'; echo "${PROFILES[*]}")]"
    sync_tier "$1"
  else
    for tier in "${PROFILES[@]}"; do sync_tier "${tier}"; done
  fi
}

cmd_init_keys() {
  need fnox age-keygen age-plugin-pq jq
  grep -q '"age1placeholder-' "${FNOX_FILE}" || die "${FNOX_FILE} already has keys. If init-keys stopped early, finish with 'setup' and/or 'sync-ci'; to replace a key, use 'rotate'"
  op_signin
  if op_ item get "${OP_ITEM}" --vault "${OP_VAULT}" >/dev/null 2>&1; then
    die "1Password already has \"${OP_ITEM}\" — delete it or finish with 'setup' + 'sync-ci'"
  fi

  new_identity
  local m_rec="${NEW_RECIPIENT}" m_id="${NEW_IDENTITY}"
  new_identity
  local p_rec="${NEW_RECIPIENT}" p_id="${NEW_IDENTITY}"
  new_identity
  local v_rec="${NEW_RECIPIENT}" v_id="${NEW_IDENTITY}"
  unset NEW_IDENTITY

  # 1Password first: from here on nothing is lost if a later step fails.
  # shellcheck disable=SC2016 # $ENV.* is jq, not shell
  M_ID="${m_id}" M_REC="${m_rec}" P_ID="${p_id}" P_REC="${p_rec}" V_ID="${v_id}" V_REC="${v_rec}" \
    TITLE="${OP_ITEM}" with_template '{
      title: $ENV.TITLE, category: "SECURE_NOTE",
      fields: [
        {label: "maintainer identity", type: "CONCEALED", value: $ENV.M_ID},
        {label: "maintainer public key", type: "STRING", value: $ENV.M_REC},
        {label: "publish identity", type: "CONCEALED", value: $ENV.P_ID},
        {label: "publish public key", type: "STRING", value: $ENV.P_REC},
        {label: "versions identity", type: "CONCEALED", value: $ENV.V_ID},
        {label: "versions public key", type: "STRING", value: $ENV.V_REC}
      ]}' item create --vault "${OP_VAULT}"
  unset m_id p_id v_id
  echo "secrets: keys stored in 1Password \"${OP_ITEM}\""

  set_recipient maintainer "${m_rec}"
  set_recipient publish "${p_rec}"
  set_recipient versions "${v_rec}"
  echo "secrets: recipients written to ${FNOX_FILE}"

  cmd_setup
  cmd_sync_ci
  echo "✓ Keys set up. Add the values (docs/SECRETS.md), then commit ${FNOX_FILE}."
}

cmd_set() {
  [[ $# -eq 2 ]] || die "usage: scripts/secrets.sh set <$(IFS='|'; echo "${PROFILES[*]}")> <NAME>  (value on stdin)"
  is_tier "$1" || die "unknown profile '$1'"
  [[ -f "${LOCAL_FILE}" ]] || die "no ${LOCAL_FILE} — run 'scripts/secrets.sh setup' first"
  fnox set --no-defaults -P "$1" "$2" --provider "age_$1"
}

cmd_rotate() {
  local who="${1:-}"
  [[ "${who}" == maintainer ]] || is_tier "${who}" ||
    die "usage: scripts/secrets.sh rotate maintainer|$(IFS='|'; echo "${PROFILES[*]}")"
  need fnox age-keygen age-plugin-pq jq
  [[ -f "${LOCAL_FILE}" ]] || die "no ${LOCAL_FILE} — run 'scripts/secrets.sh setup' first (re-encrypting needs the maintainer identity)"
  op_signin

  new_identity
  # 1Password first, so a failure later never strands a key.
  export "${who}_identity=${NEW_IDENTITY}" "${who}_public_key=${NEW_RECIPIENT}"
  op_set_fields "${who} identity" "${who} public key"
  unset "${who}_identity" "${who}_public_key"
  echo "secrets: new ${who} key stored in 1Password \"${OP_ITEM}\""

  on_exit() {
    local code=$?
    [[ "${code}" -eq 0 ]] && return
    echo "secrets: rotating ${who} failed (exit ${code}). 1Password already holds the NEW key;" >&2
    echo "  fix the cause and finish by hand: recipients in ${FNOX_FILE}, 'fnox reencrypt', then" >&2
    echo "  'setup' (maintainer) or 'sync-ci ${who}' (a CI tier)." >&2
  }
  trap on_exit EXIT

  # Re-encrypt to the new recipients, decrypting with the current keychain identity.
  set_recipient "${who}" "${NEW_RECIPIENT}"
  cmd_refresh_local
  local p
  for p in $(profiles_with_secrets); do
    fnox reencrypt -f --no-defaults -P "${p}" >/dev/null
  done
  echo "secrets: re-encrypted every profile"

  if [[ "${who}" == maintainer ]]; then
    printf '%s' "${NEW_IDENTITY}" | store_keychain
  else
    cmd_sync_ci "${who}"
  fi
  unset NEW_IDENTITY
  cmd_check
  echo "✓ ${who} rotated. Commit ${FNOX_FILE}: pipelines on older commits can no longer decrypt."
}

case "${1:-}" in
  init-keys) cmd_init_keys ;;
  setup) cmd_setup ;;
  refresh-local) cmd_refresh_local ;;
  check) cmd_check ;;
  set)
    shift
    cmd_set "$@"
    ;;
  sync-ci) cmd_sync_ci "${2:-}" ;;
  rotate) cmd_rotate "${2:-}" ;;
  *)
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
