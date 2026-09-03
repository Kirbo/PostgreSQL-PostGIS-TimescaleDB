# PostgreSQL + PostGIS + TimescaleDB

Ready-to-use PostgreSQL docker image with PostGIS and TimescaleDB 🐘🌎📈

Published to Docker Hub as [`kirbownz/postgresql-postgis-timescaledb`](https://hub.docker.com/r/kirbownz/postgresql-postgis-timescaledb),
built for `linux/amd64` and `linux/arm64`.

## Current versions

<!-- versions:start -->
* **PostgreSQL 18.6** — [release notes](https://www.postgresql.org/docs/release/)
* **PostGIS 3.6.4** — [release notes](https://github.com/postgis/postgis/releases/tag/3.6.4)
* **TimescaleDB 2.29.2** — [release notes](https://github.com/timescale/timescaledb/releases/tag/2.29.2)
<!-- versions:end -->

Built on the official [`postgres`](https://hub.docker.com/_/postgres) image (Debian trixie).
Both extensions are installed from their upstream apt repositories — PostGIS from
[PGDG](https://apt.postgresql.org), TimescaleDB from
[packagecloud](https://packagecloud.io/timescale/timescaledb) — so an image build is a package
install rather than a source compile, on both architectures.

## Tags

| Tag | Points at |
| --- | --- |
<!-- tags:start -->
| `latest` | the newest build |
| `18` | newest build of that PostgreSQL major |
| `18.6` | newest build of that PostgreSQL version |
| `18.6-postgis3.6.4-timescaledb2.29.2` | one exact, immutable combination |
<!-- tags:end -->

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

### Upgrading from an image based on PostgreSQL ≤ 17

Two breaking changes, both from upstream:

1. **The data directory moved.** PostgreSQL 18's official image uses
   `PGDATA=/var/lib/postgresql/18/docker` and declares the volume at `/var/lib/postgresql`.
   Mount `/var/lib/postgresql`, not `/var/lib/postgresql/data`.
2. **A major-version jump needs a dump/restore** (or `pg_upgrade`). An old data directory will
   not start under a newer major. Dump with the OLD image, restore into the new one.

## Building it yourself

```bash
docker build -t postgresql-postgis-timescaledb .            # versions default to versions.env's
sh scripts/smoke-test.sh postgresql-postgis-timescaledb     # start it and assert it works
```

Every version is a build arg, so any combination the apt repos still carry can be built:

```bash
docker build -t pg17 \
  --build-arg PG_VERSION=17.11 \
  --build-arg POSTGIS_VERSION=3.6.4 \
  --build-arg TIMESCALEDB_VERSION=2.29.2 .
```

A version that is not in the repositories fails the build loudly rather than silently
installing something else.

## Staying up to date

`versions.env` is the only file with version numbers in it, and it has two modes:

* **`RESOLVE_MODE=auto`** (default) — CI runs `scripts/resolve-versions.sh`, which asks Docker
  Hub, PGDG and packagecloud what the newest combination they *all* ship is, for *every*
  architecture in `PLATFORMS`, and builds that. Compatibility is not a table anyone maintains:
  a `postgresql-19-postgis-3` package existing is what says PostGIS supports PostgreSQL 19.
  The newest PostgreSQL major with a stable base image plus both extensions wins, so a new
  major is adopted by itself once the extensions catch up — and never before.
* **`RESOLVE_MODE=pinned`** — CI builds exactly what is written in `versions.env`. Edit a
  number, push, get that image.

The pins in `versions.env` double as the fallback if an upstream lookup fails, and
`MIN_PG_MAJOR` / `MAX_PG_MAJOR` bound the search (raise `MAX_PG_MAJOR` when PostgreSQL 21
approaches).

A weekly [pipeline schedule](https://gitlab.com/KirboDev/agentic-coding/postgresql-postgis-timescaledb/-/pipeline_schedules)
rebuilds and republishes even when the versions have not moved, so the Debian base picks up
security updates. When a version *has* moved and `VERSIONS_PUSH_TOKEN` is configured, the
pipeline commits the new numbers back into `versions.env` and this README, so `git log` is the
upgrade history.

## Pipeline

Runs on the self-hosted "Kirbo Mini" runner (`macos` tag, docker executor):

| Stage | Job | What it does |
| --- | --- | --- |
| resolve | `resolve versions` | resolves the version combination into `build.env` (dotenv artifact) |
| build | `build and test image` | builds for the runner's arch, starts it, asserts versions, fills a hypertable, runs a spatial query |
| publish | `publish image` | multi-arch `buildx --push` to Docker Hub (default branch, schedules, or a `PUBLISH=1` manual run) |
| sync | `sync versions.env` | commits the published versions back (only when `VERSIONS_PUSH_TOKEN` is set) |

Nothing is pushed unless the smoke test passed.

### Required CI/CD variables

| Variable | Needed for | Notes |
| --- | --- | --- |
| `DOCKERHUB_USERNAME` | publishing | Docker Hub account |
| `DOCKERHUB_TOKEN` | publishing | Docker Hub access token, **masked** + protected |
| `VERSIONS_PUSH_TOKEN` | optional version commit-back | project access token, `api` + `write_repository`, Maintainer, allowed to push to the protected default branch |

`CI_REGISTRY_USERNAME` / `CI_REGISTRY_PASSWORD` are accepted as aliases for the first two, to
match the other KirboDev image repositories.

---

Originally a fork of [binakot/PostgreSQL-PostGIS-TimescaleDB](https://github.com/binakot/PostgreSQL-PostGIS-TimescaleDB).
MIT licensed.
