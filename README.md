# PostgreSQL + PostGIS + TimescaleDB

Ready-to-use PostgreSQL docker image with PostGIS and TimescaleDB 🐘🌎📈

Published to Docker Hub as [`kirbownz/postgresql-postgis-timescaledb`](https://hub.docker.com/r/kirbownz/postgresql-postgis-timescaledb),
built for `linux/amd64` and `linux/arm64`.

## Current versions

<!-- versions:start -->

* **PostgreSQL 18.6** — [release notes](https://www.postgresql.org/docs/release/)
* **PostGIS 3.7.0** — [release notes](https://github.com/postgis/postgis/releases/tag/3.7.0)
* **TimescaleDB 2.31.0** — [release notes](https://github.com/timescale/timescaledb/releases/tag/2.31.0)

<!-- versions:end -->

Built on the official [`postgres`](https://hub.docker.com/_/postgres) image (Debian trixie).
Both extensions are installed from their upstream apt repositories — PostGIS from
[PGDG](https://apt.postgresql.org), TimescaleDB from
[packagecloud](https://packagecloud.io/timescale/timescaledb) — so an image build is a package
install rather than a source compile, on both architectures. The build also applies Debian's
pending updates (`apt-get upgrade`) on top of the base image, so a Debian security fix is in
the next build even before docker-library rebuilds `postgres`; the base image's PostgreSQL
packages are held for that step, so the PostgreSQL version stays the one listed above.

## Tags

<!-- tags:start -->

| Tag | Points at |
| --- | --- |
| `latest` | the newest build |
| `18` | newest build of that PostgreSQL major |
| `18.6` | newest build of that PostgreSQL version |
| `18.6-postgis3.7.0-timescaledb2.31.0` | that exact version combination |

<!-- tags:end -->

All four are the same digest from one build. They are pushed most-specific first and `latest`
last, so Docker Hub's last-pushed ordering puts `latest` at the top of the tag list.

## Usage

```bash
docker run -d --name postgres -e POSTGRES_PASSWORD=postgres \
  kirbownz/postgresql-postgis-timescaledb
```

Or with the bundled compose file (PostgreSQL on port 5432, pgAdmin available commented out):

```bash
docker compose up
```

The compose file is for trying the image out: its password is `homeassistant` and it publishes
port 5432 on every interface of the host. Change the password before keeping any data in it, and
drop the `ports:` mapping when the clients (Home Assistant, say) run in the same compose project
and reach the database over its network anyway.

Every environment variable of the [official image](https://hub.docker.com/_/postgres)
(`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `PGDATA`, …) works unchanged.

On first start, in `$POSTGRES_DB`:

* `postgis` and `postgis_topology` are created
* `timescaledb` is created
* a `template_postgis` template database is created, so `CREATE DATABASE gis TEMPLATE template_postgis;`
  gives you a PostGIS-enabled database later

For a new TimescaleDB database, create the extension in it directly —
`CREATE DATABASE metrics;` then `CREATE EXTENSION timescaledb;`. Timescale does not support
using a database with TimescaleDB installed as a `TEMPLATE`, which is why this image no longer
creates a `template_timescaledb` (older `binakot/*` tags did).

### Home Assistant: LTSS / LTSS Turbo

This is the combination [LTSS](https://github.com/freol35241/ltss) and
[LTSS Turbo](https://github.com/velaar/ltss-turbo) need — nothing LTSS-specific is baked into
the image, both just want PostGIS and TimescaleDB in the same server:

```yaml
ltss_turbo:
  db_url: postgresql://homeassistant:password@postgres:5432/homeassistant
```

`CREATE EXTENSION` is issued by the integration itself, so any database works; the compose
file's `homeassistant` database already has both extensions loaded.

Their DDL is part of the smoke test, so the weekly auto-update cannot quietly break it: the
legacy positional `create_hypertable()` signature, the pre-hypercore `timescaledb.compress`
table options with `add_compression_policy`/`add_retention_policy`, a GIST index over a PostGIS
point column, an EWKT insert, chunk compression, and a `time_bucket()` aggregation are all
replayed and asserted on every build, i.e. on the versions listed above. The only complaint is
TimescaleDB's cosmetic "use TEXT instead of VARCHAR" hint, which comes from LTSS's own schema.

### Upgrades are automatic

The image brings an existing data directory up to date **by itself, on start**, before the
server is opened to clients — the weekly auto-update therefore never leaves a volume behind:

* **PostGIS / TimescaleDB moved** (same PostgreSQL major): `ALTER EXTENSION … UPDATE` is run in
  every database that is behind, TimescaleDB first and in a fresh session as Timescale
  requires. A data directory that already matches the image is recognised from a stamp file,
  so a normal restart costs nothing.
* **PostgreSQL moved to a new major**: the image bundles the server binaries (plus PostGIS and
  TimescaleDB at the same versions) of the previous majors that TimescaleDB still supports —
  the ones that have a TimescaleDB package at the built version, 16 and 17 at the time of
  writing (`docker run --rm <image> cat /etc/ppt-upgrade-from.env` tells) — and runs
  `pg_upgrade --link` (seconds, no second copy of the data). Before that, the extensions are
  updated on the old cluster so both sides run identical versions (Timescale's requirement),
  the new cluster is initialised with the old one's encoding, locale provider, checksum setting
  and WAL segment size, `pg_hba.conf`, `pg_ident.conf`, `postgresql.auto.conf` (`ALTER SYSTEM`)
  and `conf.d/` (plus any other `*.conf` file and the TLS `server.crt`/`server.key`/`root.crt`/
  `root.crl` next to them) are carried over, every setting in the old `postgresql.conf` that
  differs from the new one's is appended to it as the old server read it, quoting and all, along
  with its `include` directives (settings the new major no longer knows are kept as comments;
  the old file stays next to it as `postgresql.conf.pg<major>`), and
  `vacuumdb --analyze-in-stages` runs before the server opens.
* **An upgrade that is interrupted or fails** costs nothing but time. Until `pg_upgrade` has
  succeeded, the new cluster is built in a staging directory next to the final one: a failure
  rolls back (the old cluster is exactly where and how it was, startable with the old image,
  and the container stops with the reason), and a `docker stop`/`kill`, an OOM kill or a host
  reboot in the middle is simply redone on the next start. From the moment `pg_upgrade` has
  succeeded, the new cluster is the one that counts: the next start only finishes the
  remaining steps, the old cluster is never started again.
* **The data directory moved** (PostgreSQL ≤ 17 images kept it at
  `/var/lib/postgresql/data`, 18+ at `/var/lib/postgresql/<major>/docker` inside a volume at
  `/var/lib/postgresql`): both are found. A volume still mounted at
  `/var/lib/postgresql/data` is upgraded in place and keeps being used from there; a data
  directory inside a `/var/lib/postgresql` volume is upgraded into the 18+ location.
* **Downgrades** (a `:17` tag on an 18 directory) are refused with a clear message; a newer
  extension version than the image ships is left alone with a warning.
* **More than one data directory** in a `/var/lib/postgresql` volume (an old cluster copied
  or kept next to the live one) is refused with both paths named, rather than guessing which
  one is current.

Knobs, all environment variables:

| Variable | Default | Effect |
| --- | --- | --- |
| `PPT_AUTO_UPGRADE` | `on` | `off` = behave exactly like the official image (no extension updates, no `pg_upgrade`) |
| `PPT_UPGRADE_MODE` | `link` | `copy` = `pg_upgrade` without `--link` (twice the disk, but the old cluster stays startable with the old image) |
| `PPT_KEEP_OLD_CLUSTER` | `0` | `1` = keep the old cluster directory after a successful major upgrade instead of deleting it, renamed to `<dir>.ppt-old-<timestamp>` so it is never mistaken for a live one |

Take a backup before a major upgrade anyway — `pg_upgrade --link` is a one-way street once the
new cluster has started. What the image cannot do is upgrade from a major TimescaleDB has
dropped (there is no TimescaleDB *n* package for it, so the two sides could never match): such
a directory makes the container stop with a message naming the last image tag that can still
upgrade it.

All of this is tested on every build: the previously published image and the oldest published
tag of the same major are started on a volume, seeded (hypertables with compressed chunks and
geometries, a second database, `ALTER SYSTEM` and `postgresql.conf` settings, a custom
superuser, databases named `home assistant` and `a=b`, a quoted `postgresql.conf` value with a
`#` in it and an `include_dir`), and taken over by the new image — after a clean stop, after
a kill, and as an unprivileged `--user`. Then a real PostgreSQL 16 and 17 data directory
(built from this Dockerfile on the older base image) is upgraded in both volume layouts; the
newest of them is also killed at every stage of the upgrade and started again, made to fail
`pg_upgrade` (rolled back, started with the old image, fixed, upgraded), upgraded with
`PPT_KEEP_OLD_CLUSTER=1`, and put next to a second cluster in one volume (refused); and
`PPT_AUTO_UPGRADE=off` is checked to refuse like the official image does. Every build also
asserts, on every platform, that the previous PostgreSQL major is among the bundled ones, so an
image that could not upgrade last week's `:latest` is never published. (How the tests run
without a Docker engine: [Tests](#tests).)

## Building it yourself

```bash
docker build -t postgresql-postgis-timescaledb .            # versions default to the Dockerfile's ARGs
# start it and assert it works (Docker Desktop's default builder sees local images)
sh scripts/buildkit-test.sh smoke docker-image://postgresql-postgis-timescaledb
```

Every version is a build arg, so any combination the apt repos still carry can be built:

```bash
docker build -t pg17 \
  --build-arg PG_VERSION=17.11 \
  --build-arg POSTGIS_VERSION=3.6.4 \
  --build-arg TIMESCALEDB_VERSION=2.30.0 .
```

A version that is not in the repositories fails the build loudly rather than silently
installing something else. `MIN_UPGRADE_FROM_MAJOR` (default 15) is the oldest PostgreSQL
major whose binaries are bundled for the automatic `pg_upgrade`; majors without a TimescaleDB
package at the built version are skipped, so the list follows Timescale's support window.

## Staying up to date

`versions.env` is the only file with version numbers in it, and **every published image
corresponds to a commit of it**:

* A weekly [pipeline schedule](https://gitlab.com/KirboDev/agentic-coding/postgresql-postgis-timescaledb/-/pipeline_schedules)
  runs one job: `scripts/resolve-versions.sh` asks Docker Hub, PGDG and packagecloud what the
  newest combination they *all* ship is, for *every* architecture in `PLATFORMS`, plus the
  digest of the official `postgres` base image. Compatibility is not a table anyone maintains:
  a `postgresql-19-postgis-3` package existing is what says PostGIS supports PostgreSQL 19.
  The newest PostgreSQL major with a stable base image plus both extensions wins, so a new
  major is adopted by itself once the extensions catch up — and never before.
* If anything differs from `versions.env`, the schedule **commits the new numbers** (this
  file's version list and tag table included) to the default branch. The push pipeline of
  that commit builds, tests and publishes them — so `git log` is the upgrade history and a
  bump can be reverted like any other change. Nothing newer: no commit, no pipeline.
* The base image digest is part of that: when docker-library rebuilds
  `postgres:18.6-trixie` for Debian security updates, the digest moves, the schedule commits
  it, and the image is republished — without any version number changing. The `FROM` is
  pinned to that digest, so the PostgreSQL / PostGIS / TimescaleDB versions of a build are
  reproducible; the other Debian packages are whatever the Debian archive's `apt-get upgrade`
  brings at build time (fixes that land between two base image rebuilds).
* Every pipeline that builds — a push, a merge request, a manual run — builds exactly what
  `versions.env` says. `RESOLVE_MODE=pinned` makes the schedule a no-op, i.e. freezes the
  versions until someone edits the file.

The pins in `versions.env` are also the floor/ceiling for the search: `MIN_PG_MAJOR` /
`MAX_PG_MAJOR` bound it (raise `MAX_PG_MAJOR` when PostgreSQL 21 approaches).

## Pipeline

Runs on the self-hosted "Kirbo Mini" Mac Mini: every job takes the runner tag in `$MAC_DOCKER`
— `macos-protected` (a ref-protected Docker runner with its own cache) for pipelines of the
default branch, which hold the Docker Hub and repository-write tokens, and the shared `macos`
Docker runner for branches and merge requests. No job gets a Docker engine (no socket, no
Docker-in-Docker, no privileged mode): builds and tests go to a BuildKit server on the Mac over
mutual TLS — the protected one for protected refs, the branch one otherwise — and registry work
talks to the registries directly. One build, tested, then re-tagged: the bytes that were tested
are the bytes that get published.

| Stage | Job | What it does |
| --- | --- | --- |
| resolve | `resolve versions` | `build.env` = the pins in `versions.env` |
| resolve | `check upstream versions` | **schedule only, and the schedule's only job**: resolves upstream's newest, commits `versions.env` + README when something moved; that commit's pipeline does the rest |
| lint | `shellcheck`, `hadolint`, `mise lock`, `resolver` | scripts and Dockerfile lint; `mise.lock` must cover every pin in `mise.toml`; the resolver must reproduce `versions.env` in pinned mode and find something at least as new in auto mode |
| build | `build image` | one `buildx` build for every platform on the BuildKit server, pushed to the project's GitLab container registry as `:ci-<pipeline>`; the digest goes downstream |
| test | `smoke test` (per platform) | build stages FROM that digest start it and check it (amd64 under emulation): versions, hypertable, spatial index, LTSS DDL, healthcheck, restart no-op, official defaults |
| test | `upgrade test` | the previously published images and real PostgreSQL 16 / 17 data directories are taken over by the new image, see above |
| test | `compose test` | `docker compose config` validates the bundled file; its service (environment, volume, the image's healthcheck) comes up healthy in a build stage |
| test | `vulnerability scan` | Trivy over the Debian packages of the staging image, read from the registry, HIGH/CRITICAL with a fix available; informational (`allow_failure`) |
| publish | `publish image` | `imagetools create` re-tags the tested digest onto the Docker Hub tags (default branch, or a `PUBLISH=1` manual run), then verifies every tag resolves to it with every platform |

Nothing is published unless lint and every test passed, the tests on the exact digest being published.

### Tests

The tests are BuildKit build stages ([`tests/Dockerfile`](tests/Dockerfile), driven by
[`scripts/buildkit-test.sh`](scripts/buildkit-test.sh) through
[`tests/docker-bake.hcl`](tests/docker-bake.hcl)) built FROM the staging digest — there is no
`docker run` anywhere. Each test step is a `RUN` that starts the image's own entrypoint in the
background (the real startup path: `docker-entrypoint-ppt.sh`, the official entrypoint, the
initdb scripts), waits for it with bounded `pg_isready` / `psql` polling, asserts, and stops it
with the image's stop signal; a "volume" is the step's read-write bind mount, a real mount point
seeded from an earlier stage. The upgrade test chains stages across images — seed with the old
image, upgrade with the new one, back to the old one — and runs one PostgreSQL server at a time
(the BuildKit server's memory cap is shared by every build on it). The older-major fixtures are bake targets
built from this repository's `Dockerfile` on the older `postgres` base image.
[`tests/lib.sh`](tests/lib.sh) has the details, including what a step does instead of `docker
stop`, `docker kill`, `docker logs` and the HEALTHCHECK.

BuildKit would serve an unchanged test step from its cache and "pass" without running it. So
every test step consumes a token unique to the run (`PPT_TEST_RUN`) and is in its target's
`no-cache-filter`, writes `PASS <token>` to its result file, and `buildkit-test.sh` fails the
job if any step's result is missing or carries another token. The result files are the jobs'
`test-results/` artifacts.

Fidelity notes — what a build stage cannot reproduce exactly: the test steps run with
`--network=none` (a private loopback, since the BuildKit servers run steps on the host network),
so there is no IPv6 loopback and `pg_isready -h localhost` waits out `::1` before `127.0.0.1`;
the HEALTHCHECK is the Dockerfile's `CMD`, run like Docker does (without Docker's timeout and
retry bookkeeping); a container's processes are not PID 1; the compose test reproduces the
service's environment and volume, not Docker networking or port publishing.

### Required CI/CD settings

| Setting | Needed for | Notes |
| --- | --- | --- |
| Container registry enabled | staging | default on gitlab.com; add a [cleanup policy](https://docs.gitlab.com/user/packages/container_registry/reduce_container_registry_storage/) for tags matching `ci-.*` |
| `FNOX_AGE_KEY_FILE` (scope `release/publish`) | publishing | **File** variable, protected + masked: the `publish` tier's age identity, which decrypts the Docker Hub credentials (`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`) from `fnox.toml` — [docs/SECRETS.md](docs/SECRETS.md) |
| `FNOX_AGE_KEY_FILE` (scope `release/versions`) | the weekly schedule | the same for the `versions` tier: `VERSIONS_PUSH_TOKEN`, a project access token (`api` + `write_repository`, Maintainer, allowed to push to the protected default branch); the schedule fails without it |
| `BUILDKIT_CA`, `BUILDKIT_CERT`, `BUILDKIT_KEY` | build + tests on branches / MRs | **File** variables: the Mac's branch BuildKit server CA and client certificate + key (1Password "Kirbo Mini BuildKit branch mTLS"); not protected |
| `BUILDKIT_PROTECTED_CA`, `BUILDKIT_PROTECTED_CERT`, `BUILDKIT_PROTECTED_KEY` | build + tests on the default branch | **File** variables, **protected**: the protected BuildKit server's (1Password "Kirbo Mini BuildKit protected mTLS"); the client certificates expire 2029-02-08 |
| "Kirbo Mini Protected" runner | default-branch pipelines | the ref-protected `macos-protected` Docker runner, assigned to the project |

`CI_REGISTRY_USERNAME` / `CI_REGISTRY_PASSWORD` are accepted as aliases for the Docker Hub
credentials, to match the other KirboDev image repositories.

`VERSIONS_PUSH_TOKEN` lives in 1Password ("PostgreSQL PostGIS TimescaleDB - GitLab API Token",
Personal vault, with its expiry in the `expires` field). `mise run gitlab:rotate-pat` (or
`scripts/rotate-gitlab-pat.sh`) rotates it through GitLab's self-rotate endpoint, writes the new
token and expiry back to 1Password, re-encrypts it into `fnox.toml` once that holds it (commit
and push that at once), and updates the plain CI/CD variable while it still exists — the same
script the other KirboDev repositories carry, so one command per project keeps every token
current.

Secrets: [docs/SECRETS.md](docs/SECRETS.md) — who can read what, the one-time key setup
(`scripts/secrets.sh init-keys`), rotation.

## Developing

```bash
mise install       # shellcheck, hadolint, jq, fnox, age, trivy, glab — exact pins, mise.lock
sh scripts/docker-buildx-release.sh local                    # builds postgresql-postgis-timescaledb:local
# The test suites, on the current buildx builder (Docker Desktop's default one sees local images;
# any other takes the image as oci-layout://DIR@sha256:...):
sh scripts/buildkit-test.sh smoke docker-image://postgresql-postgis-timescaledb:local
sh scripts/buildkit-test.sh upgrade docker-image://postgresql-postgis-timescaledb:local   # ~15 min
sh scripts/buildkit-test.sh compose docker-image://postgresql-postgis-timescaledb:local  # needs jq
mise exec -- shellcheck -S warning scripts/*.sh ci/*.sh init-*.sh tests/run.sh
mise exec -- shellcheck -S warning -s bash docker-entrypoint-ppt.sh scripts/output.sh tests/lib.sh tests/smoke.sh tests/compose.sh tests/upgrade.sh
mise exec -- hadolint Dockerfile tests/Dockerfile
docker buildx build --check .                                # BuildKit's build checks: no warnings
```

The toolchain is pinned exactly in [`mise.toml`](mise.toml) and locked (URL + sha256 per platform)
in `mise.lock`; CI installs from the lock only (`mise install --locked`). After bumping a pin, run
`mise lock` and commit both files — the `mise lock` CI job fails a lock that lags behind.

---

Originally a fork of [binakot/PostgreSQL-PostGIS-TimescaleDB](https://github.com/binakot/PostgreSQL-PostGIS-TimescaleDB).
MIT licensed.
