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
| CI job images | `.gitlab-ci.yml` (`docker:<ver>-cli`, `alpine:<ver>`, `koalaman/shellcheck-alpine:v<ver>`, `hadolint/hadolint:v<ver>-alpine`, `aquasec/trivy:<ver>`), each **`tag@sha256:digest`** | you — a release at least **7 days old**, never a floating tag (Phase 3.2) |
| BuildKit client certificates | CI/CD **File** variables `BUILDKIT_CA/CERT/KEY` (branch server) + `BUILDKIT_PROTECTED_CA/CERT/KEY` (protected), from 1Password "Kirbo Mini BuildKit branch mTLS" / "Kirbo Mini BuildKit protected mTLS" | the owner — they expire **2029-02-08** (CAs 2036-11-03); rotation: "Rotating the certificates" in `~/Documents/Claude/GitLab/BuildKit.md` (the Mac setup notes) |
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
- **CI never gets a Docker engine.** No `/var/run/docker.sock`, no `DOCKER_HOST`, no
  Docker-in-Docker, no `--driver docker-container`, no `docker run` / `docker pull` /
  `docker compose up` in a job: images are built AND tested on the Mac's BuildKit servers through
  a buildx `remote` builder (`.buildkit` in `.gitlab-ci.yml`: the protected server `:12340` with
  the `BUILDKIT_PROTECTED_*` certificate on protected refs, the branch server `:12341` with
  `BUILDKIT_*` otherwise); registry work is `docker buildx imagetools` / `trivy --image-src
  remote`. A fix that "needs" the engine is redesigned, not given the socket back.
- **Runner routing is `$MAC_DOCKER`**: `default: tags: [$MAC_DOCKER]`, `macos` by default,
  `macos-protected` from the workflow rule of the default branch (its push, web and schedule
  pipelines — they hold the Docker Hub and repo-write tokens). A job never names `macos` itself.
- **The tests are build stages, and must never pass from the cache.** Every test step in
  `tests/Dockerfile` consumes `ARG PPT_TEST_RUN`, its stage is in the bake target's
  `no-cache-filter` (`tests/docker-bake.hcl`), and it writes `PASS <token>` that
  `scripts/buildkit-test.sh` checks against its expected step list. A new step or stage gets all
  three, or the suite fails (by design). Steps run `--network=none` and one PostgreSQL at a time.

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
   with fixes in the Debian packages and whether a base-image refresh would close them.
4. **Runners**: `glab api runners/51355423` ("Kirbo Mini", tag `macos`) and `glab api
   runners/58628941` ("Kirbo Mini Protected", tag `macos-protected`, ref-protected) → `status`,
   `contacted_at`; both must be assigned to the project (`glab api
   "projects/86056054/runners?type=project_type"` or the project's runner list). Offline → memory
   `kirbodev-gitlab-runners` has the host ops; the Mac setup (BuildKit servers, runner config) is
   `~/Documents/Claude/GitLab/BuildKit.md`. A green default-branch pipeline whose jobs ran on
   `macos` (not `macos-protected`) means the `MAC_DOCKER` workflow rule broke.
5. **Token expiry**: `op item get "PostgreSQL PostGIS TimescaleDB - GitLab API Token"
   --account my.1password.com --vault Personal --fields expires` (a unix timestamp; without
   `--account` the default account has no `Personal` vault) (if `op` is not signed in, ask the user to run
   `! op signin` rather than guessing). < 30 days left → recommend rotating (ask before doing it).
   **BuildKit client certificates**: expire 2029-02-08 (`op item get "Kirbo Mini BuildKit protected
   mTLS" --account my.1password.com --vault Personal --fields client.pem | openssl x509 -noout
   -enddate`, same for the branch item — a certificate, not a secret). < 90 days left → report it;
   the rotation is the owner's (new pair from the CA, the Mac's server files, both projects' File
   variables).
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
2. **CI images** — every `image:` in `.gitlab-ci.yml` is `name:<version>@sha256:<digest>`. For each,
   find the newest release (Docker Hub tags API, `?ordering=last_updated`) that is **at least 7 days
   old** (a fresh release has had no time to be pulled back or fixed); never a moving tag (`latest`,
   `stable`, `alpine:3`, `docker:cli`). Bump the tag and its digest together:
   `docker buildx imagetools inspect <name>:<version> --format '{{json .Manifest.Digest}}'` (the
   index digest, so every platform stays covered). Check the image still has what the job calls
   (`docker run --rm <image> <tool> --version`; for the `docker:<ver>-cli` image: `docker buildx
   version` and `docker compose version`; buildx must still speak the BuildKit servers' version).
   Keep mise's shellcheck / hadolint equal to the CI images' versions — a newer one in CI is how
   "green locally, red in CI" happens. Don't touch the BuildKit server image (`moby/buildkit`, the
   Mac's — the owner's setup), but report when it is older than the newest release ≥ 7 days old.
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
mise exec -- shellcheck -S warning scripts/*.sh init-*.sh tests/run.sh
mise exec -- shellcheck -S warning -s bash docker-entrypoint-ppt.sh scripts/output.sh tests/lib.sh tests/smoke.sh tests/compose.sh tests/upgrade.sh
mise exec -- hadolint Dockerfile tests/Dockerfile
glab ci lint .gitlab-ci.yml
# resolver: Phase 2.1 again, if Phase 3 touched versions.env or the resolver
sh scripts/docker-buildx-release.sh local
# The suites are BuildKit build stages (tests/Dockerfile); Docker Desktop's default builder sees
# the local image. Each must end with every step "ran and passed" under this run's token.
sh scripts/buildkit-test.sh smoke docker-image://postgresql-postgis-timescaledb:local
sh scripts/buildkit-test.sh compose docker-image://postgresql-postgis-timescaledb:local   # needs jq
```

Run `sh scripts/buildkit-test.sh upgrade docker-image://postgresql-postgis-timescaledb:local`
(~15 min, pulls the published images, builds the older-major fixtures) when the `Dockerfile`,
`docker-entrypoint-ppt.sh`, `init-*.sh`, `tests/`, `DEBIAN_SUITE` or any upgrade bound changed.
Local runs cover the host arch only (`PLATFORM=linux/amd64` runs the smoke suite under emulation,
slowly); amd64 is otherwise covered by CI's smoke-test matrix — say so in the report rather than
claiming it. A changed CI job image or buildx: also prove the cache-bust — run a suite twice;
the second run's test steps must execute again (no `CACHED` on them, a new token in
`test-results/`).

`trivy image --scanners vuln --pkg-types os --severity HIGH,CRITICAL --ignore-unfixed
postgresql-postgis-timescaledb:local` — informational, as in CI (Debian packages only). The base
image's `gosu` is the one Go binary; check it for REACHABLE vulnerabilities, which is what
version-matching scanners cannot tell:

```
docker run --rm --entrypoint cat postgresql-postgis-timescaledb:local /usr/local/bin/gosu > "$TMPDIR/gosu"
docker run --rm -v "$TMPDIR/gosu:/gosu:ro" golang:1 sh -c \
  'go install golang.org/x/vuln/cmd/govulncheck@latest >/dev/null 2>&1 && govulncheck -mode binary /gosu'
```

"affected by 0 vulnerabilities" is the expected result; anything else is a report item (only a
new upstream postgres image can fix it — check whether one is out).

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
  jobs actually require (incl. the six `BUILDKIT_*` File variables and the protected runner);
- the test stages in `tests/Dockerfile` ⇄ the expected step lists in `scripts/buildkit-test.sh`
  ⇄ the `no-cache-filter` lists in `tests/docker-bake.hcl`; the README "Tests" fidelity notes ⇄
  what `tests/lib.sh` actually emulates;
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
1. **Health** — schedule / last pipelines / both runners + routing / token expiry / BuildKit
   certificate expiry / Docker Hub vs git, one line each.
2. **Changes** — every pin from → to; anything skipped, with the reason.
3. **Upstream watch items** — next PostgreSQL major ETA vs extension support, Debian suite, key
   expiry, open BuildKit workaround, Trivy counts.
4. **Verification** — each Phase 4 command and its result; what was not run and why.
5. **Docs / memory changes** per file.
6. **Needs a decision** — anything outward-facing you did not do (play the schedule, rotate the
   token, suite move).

Then `git pull --ff-only` and commit in logical units (Conventional Commits, `Co-Authored-By`
trailer): tooling pins (`chore(tooling): …`), CI changes and CI image pins (`ci: …`), test changes
(`test: …`), Dockerfile defaults/bounds
(`chore: …`), resolver/script fixes (`fix(…): …`), docs (`docs: …`). Leave `versions.env`
version pins to the schedule. **Never push** — the user pushes, and a push to `main` publishes.
