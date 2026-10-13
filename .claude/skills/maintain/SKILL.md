---
name: maintain
description: Full maintenance pass — check the auto-update machinery is healthy (schedule, runner, token, resolver), bump tool/CI-image pins, reconcile version drift, docs and memories, verify with a local build + tests, report, commit. Use when the user runs /maintain or asks for a maintenance/housekeeping pass.
disable-model-invocation: true
---

# Maintain — keep the image and its auto-update machinery healthy

You run this yourself, in-loop, at the current session model. No subagent spawning. Work from
ground truth (upstream registries, GitLab, the code) — never from memory of what was recently
built. Finish with a report and logically-scoped commits. **Never push.**

This repo has no package manager. Its "dependencies" are:

| What | Pinned in | Who moves it |
| --- | --- | --- |
| PostgreSQL / PostGIS / TimescaleDB / base image digest | `versions.env` (+ README markers) | the weekly schedule (`scripts/commit-versions.sh`), never you by hand unless the schedule is broken |
| Resolver search bounds | `versions.env` `MIN_PG_MAJOR` / `MAX_PG_MAJOR` / `DEBIAN_SUITE` / `PLATFORMS` | you |
| Bare-`docker build` defaults | `Dockerfile` `ARG PG_VERSION` / `POSTGIS_VERSION` / `TIMESCALEDB_VERSION` / `MIN_UPGRADE_FROM_MAJOR` | you (nothing syncs them) |
| Local lint toolchain | `mise.toml` `[tools]` (shellcheck, hadolint) | you |
| CI job images | `.gitlab-ci.yml` (`docker:cli`, `alpine:3`, `koalaman/shellcheck-alpine:stable`, `hadolint/hadolint:latest-alpine`, `aquasec/trivy:latest`) | floating tags — you check they still work |
| TimescaleDB apt signing key | fetched in the `Dockerfile` from packagecloud | upstream — you check it has not expired/rotated |
| `VERSIONS_PUSH_TOKEN` | 1Password item + CI variable | `mise run gitlab:rotate-pat` |

**Hard rules**
- **Never run `scripts/commit-versions.sh` locally** — it rewrites `versions.env` and **pushes to
  the default branch**. A version bump the schedule missed is fixed by fixing the schedule, or by
  playing it (outward-facing: ask first).
- **Never run `scripts/rotate-gitlab-pat.sh` / `mise run gitlab:rotate-pat` without asking** — it
  revokes the live token the instant it rotates.
- No version table, no Renovate config — package existence is the compatibility matrix (see memory
  `postgresql-postgis-timescaledb-autoupdate`).
- The schedule pushes to `main` on its own: `git pull --ff-only` before starting and before
  committing.

## Phase 1 — Survey (read-only)

1. `git pull --ff-only`; `git status` clean. Read `git log --oneline -20` — the schedule's
   `chore: PostgreSQL …` / `chore: rebuild on the refreshed …` commits are the upgrade history.
2. **Schedule health** (project `86056054`, schedule `4423362`):
   - `glab api projects/86056054/pipeline_schedules/4423362` → `active`, `next_run_at`, and
     `last_pipeline.status`.
   - `glab api "projects/86056054/pipelines?source=schedule&per_page=5"` — every recent one green?
     A failed `check upstream versions` job means the auto-update is silently stalled; read its log
     (`glab ci trace <job-id>` / `glab api projects/86056054/jobs/<id>/trace`).
3. **Last `main` pipeline**: `glab api "projects/86056054/pipelines?ref=main&per_page=5"`. Read
   the `vulnerability scan` job even when green-with-warning (`allow_failure`) — count HIGH/CRITICAL
   with fixes and whether a base-image refresh would close them.
4. **Runner**: `glab api runners/51355423` → `status`, `contacted_at` (offline → memory
   `kirbodev-gitlab-runners` has the host ops).
5. **Token expiry**: `op item get "PostgreSQL PostGIS TimescaleDB - GitLab API Token"
   --account my.1password.com --vault Personal --fields expires` (a unix timestamp; without
   `--account` the default account has no `Personal` vault) (if `op` is not signed in, ask the user to run
   `! op signin` rather than guessing). < 30 days left → recommend rotating (ask before doing it).
6. **Docker Hub matches git**: `docker buildx imagetools inspect
   docker.io/kirbownz/postgresql-postgis-timescaledb:latest` — its `org.opencontainers.image.description`
   / tag set should be what `versions.env` says. A mismatch means the last publish failed.

## Phase 2 — Upstream (what should move)

1. **Resolver, both modes** — reproduce the CI `resolver` lint job locally:
   ```
   RESOLVE_MODE_OVERRIDE=pinned sh scripts/resolve-versions.sh pinned.env
   RESOLVE_MODE_OVERRIDE=auto   sh scripts/resolve-versions.sh auto.env
   ```
   `pinned.env` must equal `versions.env`; `auto.env` must say `RESOLVED_FROM=auto` (anything else
   = an upstream API/format changed — that is a bug to fix in the resolver, not a skip). If `auto.env`
   is newer than `versions.env` and the last schedule run was green, it is just waiting for Monday;
   if the schedule is red, Phase 1 already found why.
2. **Search bounds**:
   - `MAX_PG_MAJOR` must stay ≥ the next unreleased PostgreSQL major (check
     https://www.postgresql.org/support/versioning/ — raise it when the one after next is announced).
   - `MIN_PG_MAJOR` / `Dockerfile` `MIN_UPGRADE_FROM_MAJOR`: a major past its PostgreSQL EOL that
     TimescaleDB also dropped is dead weight — raise them, and say so in the report (it narrows which
     old volumes auto-upgrade).
   - `DEBIAN_SUITE`: is there a newer Debian stable with `postgres:<ver>-<suite>` tags AND PGDG
     (`apt.postgresql.org/pub/repos/apt/dists/<suite>-pgdg/`) AND packagecloud
     (`packagecloud.io/timescale/timescaledb/debian/dists/<suite>/`) for every arch in `PLATFORMS`?
     A suite move is a deliberate, separate commit (the upgrade test then covers volumes from the old
     suite's image), never bundled with anything else. A suite nearing Debian EOL is a report item.
3. **TimescaleDB apt key**: `curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | gpg
   --show-keys` — expiry within 90 days, or a fingerprint different from the one the last build
   used, goes in the report.
4. **BuildKit attestation workaround**: `docker-buildx-release.sh` sets
   `BUILDX_NO_DEFAULT_OCI_ARTIFACT=1` for moby/buildkit#7007 (GitLab registry rejects OCI-artifact
   attestations). Check whether that issue is closed and GitLab accepts the default form; if so,
   propose dropping the workaround (don't drop it blind — only a real CI build proves it).

## Phase 3 — Apply

1. **mise tools**: `mise outdated` / `mise latest shellcheck` / `mise latest hadolint`; bump
   `mise.toml` to the latest stable, `mise install`.
2. **CI images**: confirm each floating tag in `.gitlab-ci.yml` still exists and still contains the
   tool the job calls (`docker run --rm <image> <tool> --version`). Report the versions CI currently
   gets next to the mise pins — a shellcheck/hadolint newer in CI than locally is how "green locally,
   red in CI" happens; bump mise to match.
3. **Dockerfile ARG defaults** → set `PG_VERSION` / `POSTGIS_VERSION` / `TIMESCALEDB_VERSION` to
   the values in `versions.env` (CI always overrides them; they only matter for the README's bare
   `docker build .`, which must build something current). Same for `DEBIAN_SUITE`.
4. **Bounds** from Phase 2.2, if any moved.
5. **Any upstream breakage found** (resolver parse failure, key rotation, a removed CI image tag,
   a lint rule newly firing): fix forward. Keep every `# shellcheck disable` / `# hadolint ignore`
   justified — delete ones that are no longer needed (run the linter without them to check).

## Phase 4 — Verify (fix forward until green)

Run all of these; Docker must be running.

```
mise exec -- shellcheck -S warning scripts/*.sh init-*.sh
mise exec -- shellcheck -S warning -s bash docker-entrypoint-ppt.sh
mise exec -- hadolint Dockerfile
# resolver: Phase 2.1 again, if Phase 3 touched versions.env or the resolver
sh scripts/docker-buildx-release.sh local
sh scripts/smoke-test.sh postgresql-postgis-timescaledb:local
sh scripts/compose-test.sh postgresql-postgis-timescaledb:local
```

Run `sh scripts/upgrade-test.sh postgresql-postgis-timescaledb:local` (~10 min, pulls old
images) when the `Dockerfile`, `docker-entrypoint-ppt.sh`, `init-*.sh`, `DEBIAN_SUITE` or any
upgrade bound changed. Local runs cover the host arch only; amd64 is covered by CI's smoke-test
matrix — say so in the report rather than claiming it.

`trivy image --severity HIGH,CRITICAL --ignore-unfixed postgresql-postgis-timescaledb:local` —
informational, as in CI.

A check that fails and cannot be fixed without a redesign → stop, report the failing command, its
output and your diagnosis. No broken commit.

## Phase 5 — Docs and memories (reconcile with ground truth)

**Docs.** Scope the drift: `LAST=$(git log -1 --format=%H -- README.md); git log --oneline
$LAST..HEAD -- . ':!versions.env'`. Verify every claim in `README.md` against the code:
- the marker blocks (`versions:`, `tags:`) match `versions.env` (the schedule writes them; a hand
  edit outside them is fine, inside them is a bug);
- prose that hardcodes versions or majors outside the markers (e.g. "16 and 17 at the time of
  writing", "TimescaleDB 2.29") — reword to not go stale, or update;
- the knobs table vs the `PPT_*` variables `docker-entrypoint-ppt.sh` actually reads;
- the pipeline table vs the jobs in `.gitlab-ci.yml`; the CI/CD settings table vs the variables the
  jobs actually require;
- the "Developing" commands still run as written (copy-paste them — Phase 4 did);
- the long header comments in `.gitlab-ci.yml`, `Dockerfile`, `versions.env` and the scripts
  describe what the code does today.

**Memories.** The project memory dir
(`~/.claude/projects/-Users-kimmo-saari-Work-Projects-PostgreSQL-PostGIS-TimescaleDB/memory/` +
`MEMORY.md`): verify every named file, id (project `86056054`, schedule `4423362`, runner
`51355423`), command and version still holds; update drift, delete what the repo now records, merge
near-duplicates, keep the index in sync. Record new non-obvious quirks found this pass (an upstream
API change the resolver had to absorb, a CI image that broke, a key rotation). Never persist secrets.

## Phase 6 — Report, then commit

Report to the user:
1. **Health** — schedule / last pipelines / runner / token expiry / Docker Hub vs git, one line each.
2. **Changes** — every pin from → to; anything skipped, with the reason.
3. **Upstream watch items** — next PostgreSQL major ETA vs extension support, Debian suite, key
   expiry, open BuildKit workaround, Trivy counts.
4. **Verification** — each Phase 4 command and its result; what was not run and why.
5. **Docs / memory changes** per file.
6. **Needs a decision** — anything outward-facing you did not do (play the schedule, rotate the
   token, suite move).

Then `git pull --ff-only` and commit in logical units (Conventional Commits, `Co-Authored-By`
trailer): tooling pins (`chore(tooling): …`), CI changes (`ci: …`), Dockerfile defaults/bounds
(`chore: …`), resolver/script fixes (`fix(…): …`), docs (`docs: …`). Leave `versions.env`
version pins to the schedule. **Never push** — the user pushes, and a push to `main` publishes.
