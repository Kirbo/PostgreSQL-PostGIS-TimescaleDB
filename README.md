# PostgreSQL + PostGIS + TimescaleDB

Ready-to-use PostgreSQL docker image with PostGIS and TimescaleDB 🐘🌎📈

Published to Docker Hub as [`kirbownz/postgresql-postgis-timescaledb`](https://hub.docker.com/r/kirbownz/postgresql-postgis-timescaledb),
built for `linux/amd64` and `linux/arm64`.

## Current versions

<!-- versions:start -->

* **PostgreSQL 18.6** — [release notes](https://www.postgresql.org/docs/release/)
* **PostGIS 3.6.4** — [release notes](https://github.com/postgis/postgis/releases/tag/3.6.4)
* **TimescaleDB 2.30.0** — [release notes](https://github.com/timescale/timescaledb/releases/tag/2.30.0)

<!-- versions:end -->

Built on the official [`postgres`](https://hub.docker.com/_/postgres) image (Debian trixie).
Both extensions are installed from their upstream apt repositories — PostGIS from
[PGDG](https://apt.postgresql.org), TimescaleDB from
[packagecloud](https://packagecloud.io/timescale/timescaledb) — so an image build is a package
install rather than a source compile, on both architectures.

## Tags

<!-- tags:start -->

| Tag | Points at |
| --- | --- |
| `latest` | the newest build |
| `18` | newest build of that PostgreSQL major |
| `18.6` | newest build of that PostgreSQL version |
| `18.6-postgis3.6.4-timescaledb2.30.0` | that exact version combination |

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
replayed and asserted on every build. All of it still works on PostgreSQL 18 / TimescaleDB
2.29 — the only complaint is TimescaleDB's cosmetic "use TEXT instead of VARCHAR" hint, which
comes from LTSS's own schema.

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
  and `conf.d/` are carried over, every setting explicitly enabled in the old
  `postgresql.conf` is appended to the new one (settings the new major no longer knows are
  kept as comments; the old file stays next to it as `postgresql.conf.pg<major>`), and
  `vacuumdb --analyze-in-stages` runs before the server opens. An interrupted upgrade is
  resumed on the next start; a failed `pg_upgrade` leaves the old cluster untouched and
  startable with the old image.
* **The data directory moved** (PostgreSQL ≤ 17 images kept it at
  `/var/lib/postgresql/data`, 18+ at `/var/lib/postgresql/<major>/docker` inside a volume at
  `/var/lib/postgresql`): both are found. A volume still mounted at
  `/var/lib/postgresql/data` is upgraded in place and keeps being used from there; a data
  directory inside a `/var/lib/postgresql` volume is upgraded into the 18+ location.
* **Downgrades** (a `:17` tag on an 18 directory) are refused with a clear message; a newer
  extension version than the image ships is left alone with a warning.

Knobs, all environment variables:

| Variable | Default | Effect |
| --- | --- | --- |
| `PPT_AUTO_UPGRADE` | `on` | `off` = behave exactly like the official image (no extension updates, no `pg_upgrade`) |
| `PPT_UPGRADE_MODE` | `link` | `copy` = `pg_upgrade` without `--link` (twice the disk, but the old cluster stays startable with the old image) |
| `PPT_KEEP_OLD_CLUSTER` | `0` | `1` = keep the old cluster directory after a successful major upgrade instead of deleting it |

Take a backup before a major upgrade anyway — `pg_upgrade --link` is a one-way street once the
new cluster has started. What the image cannot do is upgrade from a major TimescaleDB has
dropped (there is no TimescaleDB *n* package for it, so the two sides could never match): such
a directory makes the container stop with a message naming the last image tag that can still
upgrade it.

All of this is tested on every build: the previously published image and the oldest published
tag of the same major are started on a volume, seeded (hypertables with compressed chunks and
geometries, a second database, `ALTER SYSTEM` and `postgresql.conf` settings, a custom
superuser), and taken over by the new image — after a clean stop, after `docker kill`, and as
an unprivileged `--user`. Then a real PostgreSQL 16 and 17 data directory (built from this
Dockerfile on the older base image) is upgraded in both volume layouts, an interrupted upgrade
is resumed, and `PPT_AUTO_UPGRADE=off` is checked to refuse like the official image does.

## Building it yourself

```bash
docker build -t postgresql-postgis-timescaledb .            # versions default to the Dockerfile's ARGs
sh scripts/smoke-test.sh postgresql-postgis-timescaledb     # start it and assert it works
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
  pinned to that digest, so a build is reproducible.
* Every pipeline that builds — a push, a merge request, a manual run — builds exactly what
  `versions.env` says. `RESOLVE_MODE=pinned` makes the schedule a no-op, i.e. freezes the
  versions until someone edits the file.

The pins in `versions.env` are also the floor/ceiling for the search: `MIN_PG_MAJOR` /
`MAX_PG_MAJOR` bound it (raise `MAX_PG_MAJOR` when PostgreSQL 21 approaches).

## Pipeline

Runs on the self-hosted "Kirbo Mini" runner (`macos` tag, docker executor). One build, tested,
then re-tagged: the bytes that were tested are the bytes that get published.

| Stage | Job | What it does |
| --- | --- | --- |
| resolve | `resolve versions` | `build.env` = the pins in `versions.env` |
| resolve | `check upstream versions` | **schedule only, and the schedule's only job**: resolves upstream's newest, commits `versions.env` + README when something moved; that commit's pipeline does the rest |
| lint | `shellcheck`, `hadolint`, `resolver` | scripts and Dockerfile lint; the resolver must reproduce `versions.env` in pinned mode and find something at least as new in auto mode |
| build | `build image` | one `buildx` build for every platform, pushed to the project's GitLab container registry as `:ci-<pipeline>`; the digest goes downstream |
| test | `smoke test` (per platform) | pulls that digest and runs it (amd64 under emulation): versions, hypertable, spatial index, LTSS DDL, healthcheck, restart no-op, official defaults |
| test | `upgrade test` | the previously published images and real PostgreSQL 16 / 17 data directories are taken over by the new image, see above |
| test | `compose test` | `docker compose up --wait` with the bundled file comes up healthy |
| test | `vulnerability scan` | Trivy, HIGH/CRITICAL with a fix available; informational (`allow_failure`) |
| publish | `publish image` | `imagetools create` re-tags the tested digest onto the Docker Hub tags (default branch, or a `PUBLISH=1` manual run), then verifies every tag resolves to it with every platform |

Nothing is published unless every test passed on the exact digest being published.

### Required CI/CD settings

| Setting | Needed for | Notes |
| --- | --- | --- |
| Container registry enabled | staging | default on gitlab.com; add a [cleanup policy](https://docs.gitlab.com/user/packages/container_registry/reduce_container_registry_storage/) for tags matching `ci-.*` |
| `DOCKERHUB_USERNAME` | publishing | Docker Hub account |
| `DOCKERHUB_TOKEN` | publishing | Docker Hub access token, **masked** + protected |
| `VERSIONS_PUSH_TOKEN` | the weekly schedule | project access token, `api` + `write_repository`, Maintainer, allowed to push to the protected default branch; the schedule fails without it |

`CI_REGISTRY_USERNAME` / `CI_REGISTRY_PASSWORD` are accepted as aliases for the Docker Hub
credentials, to match the other KirboDev image repositories.

## Developing

```bash
mise install                                                 # shellcheck + hadolint, pinned
sh scripts/docker-buildx-release.sh local                    # builds postgresql-postgis-timescaledb:local
sh scripts/smoke-test.sh postgresql-postgis-timescaledb:local
sh scripts/upgrade-test.sh postgresql-postgis-timescaledb:local   # ~10 min, pulls old images
sh scripts/compose-test.sh postgresql-postgis-timescaledb:local
mise exec -- shellcheck -S warning scripts/*.sh init-*.sh && mise exec -- shellcheck -s bash docker-entrypoint-ppt.sh
mise exec -- hadolint Dockerfile
```

---

Originally a fork of [binakot/PostgreSQL-PostGIS-TimescaleDB](https://github.com/binakot/PostgreSQL-PostGIS-TimescaleDB).
MIT licensed.
