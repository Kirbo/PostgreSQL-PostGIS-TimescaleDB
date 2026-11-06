# Secrets

The pipeline needs two secrets: the **Docker Hub** credentials (`publish image`) and the **repo-write
token** that lets the weekly schedule commit a version bump (`check upstream versions`). They live in
**`fnox.toml`** as [age](https://age-encryption.org) ciphertext and are read with
[fnox](https://fnox.jdx.dev). GitLab holds only one age identity per CI tier. fnox and age are pinned
in [`mise.toml`](../mise.toml) and locked in `mise.lock`.

Contributors need none of this: building and testing the image use no secrets.

> **Status: transition.** `fnox.toml` is wired but holds no keys yet (its recipients are
> `placeholder`s). Until the maintainer runs the [one-time setup](#setting-it-up-once), the same
> jobs keep reading the plain GitLab CI/CD variables `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` and
> `VERSIONS_PUSH_TOKEN`, exactly as before. Once a tier's key is in GitLab, its job reads fnox,
> and fnox's values win over any plain variable of the same name.

## Who can read what

A fnox **provider** encrypts to a fixed set of recipients (public keys), so the provider a secret
uses decides who can read it. Each **profile** is one CI tier's secrets.

| Profile | Secrets | Provider | Readers | Job (GitLab environment) |
|---|---|---|---|---|
| `publish` | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (push access to `kirbownz/postgresql-postgis-timescaledb`) | `age_publish` | maintainer, publish | `publish image` (`release/publish`) |
| `versions` | `VERSIONS_PUSH_TOKEN` (project access token: `api` + `write_repository`, Maintainer, may push to `main`) | `age_versions` | maintainer, versions | `check upstream versions` (`release/versions`) |

All keys are post-quantum (`age-keygen -pq`). fnox reaches them through `age-plugin-pq`, which ships
with mise's age (≥ 1.3.2), so fnox needs each identity in its plugin form (`AGE-PLUGIN-PQ-1…`).

## Identities

| Identity | Where it lives |
|---|---|
| maintainer | 1Password item "PostgreSQL PostGIS TimescaleDB fnox keys" (Personal vault, field `maintainer identity`). On each maintainer machine also in the OS keychain (service `postgresql-postgis-timescaledb.fnox`), put there by `scripts/secrets.sh setup`. |
| publish | The same item (field `publish identity`), and GitLab: File variable `FNOX_AGE_KEY_FILE`, environment scope `release/publish`, protected + masked. |
| versions | The same item (field `versions identity`), and GitLab: `FNOX_AGE_KEY_FILE`, scope `release/versions`, protected + masked. |

`fnox.toml` names no identity, so it works unchanged everywhere. The gitignored `fnox.local.toml`
is **generated** by `scripts/secrets.sh` and points every age provider at the keychain. fnox merges
a provider whole, so that file repeats each provider's recipients: after pulling a recipient
change, run `scripts/secrets.sh refresh-local`.

## Setting it up (once)

Needs `mise install` done (fnox, age, jq, glab), the 1Password CLI (`op`) signed in, and an
authenticated `glab`.

1. `scripts/secrets.sh init-keys` generates the three identities, stores them in 1Password, writes
   their public keys into `fnox.toml`, puts the maintainer identity in the keychain and the two CI
   identities in GitLab (`FNOX_AGE_KEY_FILE` for `release/publish` and `release/versions`).
2. Add the values, each read from stdin (never as an argument):

   ```sh
   printf '%s' 'kirbownz' | scripts/secrets.sh set publish DOCKERHUB_USERNAME
   pbpaste                | scripts/secrets.sh set publish DOCKERHUB_TOKEN   # a Docker Hub access token (Read & Write)
   op read 'op://Personal/PostgreSQL PostGIS TimescaleDB - GitLab API Token/password' \
     | scripts/secrets.sh set versions VERSIONS_PUSH_TOKEN
   ```

3. `scripts/secrets.sh check`, then commit `fnox.toml` and push. That `main` pipeline's
   `publish image` already reads fnox (its log says `secrets: loaded fnox profile 'publish'`);
   the next scheduled `check upstream versions` reads `versions`.
4. Once both have run green on fnox, delete the plain `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` and
   `VERSIONS_PUSH_TOKEN` CI/CD variables (Settings → CI/CD → Variables), and drop the transition
   notes here and in `ci/secrets.sh`.

On another maintainer machine, only `scripts/secrets.sh setup` is needed.

## Commands

| Command | What |
|---|---|
| `scripts/secrets.sh setup` | Once per machine: maintainer identity 1Password → keychain, generate `fnox.local.toml`, check |
| `scripts/secrets.sh check` | Every profile that holds secrets decrypts |
| `scripts/secrets.sh set <profile> <NAME>` | Encrypt one value (stdin) into that profile |
| `scripts/secrets.sh sync-ci [publish\|versions]` | Push the CI identities 1Password → GitLab again |
| `scripts/secrets.sh rotate maintainer\|publish\|versions` | New key: 1Password first, then recipients and re-encryption, then keychain / GitLab. Commit `fnox.toml` afterwards. |
| `mise run gitlab:rotate-pat` | Rotates `VERSIONS_PUSH_TOKEN` itself (`scripts/rotate-gitlab-pat.sh`): 1Password, then `fnox.toml` once it holds the token (commit + push it at once: the old token is already revoked), then the plain CI variable while that still exists — never re-creating it |
| `fnox exec --no-defaults -P <profile> -- <cmd>` | Anything else |

## CI

A job's `environment:` (`action: prepare`, so no deployment is recorded) selects its tier, and so
the one `FNOX_AGE_KEY_FILE` GitLab gives it. The variables are protected, so only `main` pipelines
get them — the same pipelines the protected runner (`macos-protected`) takes.

[`ci/secrets.sh`](../ci/secrets.sh) provides `secrets_load <profile>`: with an identity present it
installs the pinned mise ([`ci/install-mise.sh`](../ci/install-mise.sh): version + sha256 in the
script), then fnox + age from `mise.lock` in locked mode, and exports the profile into the job
shell. An identity that cannot decrypt its profile fails the job — a wrong tier, or a `fnox.toml`
without the values, is a bug, not a reason to fall back. Without an identity it leaves the job on
the plain variables (the transition above).

GitLab masks none of the fnox values, so jobs never `set -x` or echo them: the Docker Hub token is
piped into `docker login --password-stdin`, and the scheduled push hands `VERSIONS_PUSH_TOKEN` to
git through a credential helper that reads it from the environment (`scripts/commit-versions.sh`),
never in the URL.

The BuildKit client certificates (`BUILDKIT_*`, `BUILDKIT_PROTECTED_*` File variables) stay in
GitLab: they are credentials of the Mac Mini runner, shared by every project on it, and GitLab's
protected flag is what keeps the protected server's certificate out of branch pipelines.

## Rotation and leaks

Re-encrypting does not revoke ciphertext already in git history. If an identity leaks, rotate it
**and** change the values it could read (a new Docker Hub token; `mise run gitlab:rotate-pat`), then
commit. The maintainer identity is the backup of record: losing it and 1Password together loses
access to every value (each is also re-issuable at its source).
