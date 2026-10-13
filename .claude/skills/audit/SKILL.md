---
name: audit
description: Full first-party audit of this image repo — data safety of the auto-upgrade entrypoint first, then security/supply chain, CI/publish correctness, tests and doc/code sync. Lint + build + tests, manual review, adversarially-verified findings, report, optional fix. Use when the user runs /audit or asks for a review/hardening pass of the repo.
disable-model-invocation: true
---

# Audit — data safety first, security second, quality third

You run the review yourself, in-loop, at the current session model — the repo is ~2k lines of shell,
one Dockerfile and one CI file, small enough that one reviewer tracing across files beats a fan-out.
The one exception: every Critical/High candidate goes to a fresh **`audit-verifier`** agent
(Phase 4). Never pass it a `model:` override; it inherits the session's model on purpose.

Strict phases, in order. Report after each phase before starting the next.

## Why the bar is high

This image **rewrites users' data directories on start** — `ALTER EXTENSION … UPDATE` in every
database, `pg_upgrade --link` from bundled older majors, moving clusters between volume layouts,
`rm -rf` of the old cluster — and a weekly schedule republishes `:latest` **unattended**. Its users
(Home Assistant LTSS among them) run `docker compose pull && up` and never read a changelog. A defect
in the upgrade path is not a failed build; it is someone's years of time-series data gone, or a
container that will not start after an automatic update. Review at that stake.

## Ground rules

- **Evidence or it isn't a finding.** Every finding cites `path:line` and a concrete path: *what
  state/input* (volume layout, env var, `--user`, upstream response, CI trigger) → *what happens*.
  "Could be fragile" is not a finding.
- **Ground truth is the code.** README and header comments describe intent; where they disagree with
  the code, that gap is itself a finding (users make upgrade decisions from the README).
- **Read the official entrypoint too.** `docker-entrypoint-ppt.sh` sources the base image's
  `/usr/local/bin/docker-entrypoint.sh` and relies on its functions (`docker_setup_env`,
  `_pg_want_help`, `_is_sourced`, init). Read the real one: `docker run --rm --entrypoint cat
  postgres:$(. ./versions.env; echo "$PG_VERSION-$DEBIAN_SUITE") /usr/local/bin/docker-entrypoint.sh`.
- **No praise, no padding.** A clean area gets one line in the coverage table.
- **Don't fix while auditing** (Phase 6 does that, on approval). Exception: a live secret in git
  history or a defect that the *next scheduled publish* would ship to users with data loss — stop,
  tell the user immediately, send a `PushNotification`, and recommend `RESOLVE_MODE=pinned` until
  fixed.
- **Scope:** this working tree, locally built/pulled images, read-only GitLab/Docker Hub/apt
  metadata. Never push, never start a container on a real user volume, never call a mutating API.

## Arguments

- `/audit` — full run, every phase.
- `/audit <area>` — one of `entrypoint` | `image` | `ci` | `resolver` | `scripts` | `docs`. Still
  run Phases 1, 4, 5.
- `/audit --quick` — Phases 1, 5 only (automated checks + report). Pre-push sanity, not an audit.
- `/audit --fix` — run Phase 6 without the approval gate for Critical/High; still ask for the rest.

## Phase 1 — Automated checks

Run all of them regardless of failures; capture output verbatim. No fixes.

```
mise exec -- shellcheck -S warning scripts/*.sh init-*.sh
mise exec -- shellcheck -S warning -s bash docker-entrypoint-ppt.sh
mise exec -- shellcheck -o all scripts/*.sh init-*.sh; mise exec -- shellcheck -o all -s bash docker-entrypoint-ppt.sh   # NIT-level only
mise exec -- hadolint Dockerfile
RESOLVE_MODE_OVERRIDE=pinned sh scripts/resolve-versions.sh pinned.env   # must equal versions.env
RESOLVE_MODE_OVERRIDE=auto   sh scripts/resolve-versions.sh auto.env     # must say RESOLVED_FROM=auto
sh scripts/docker-buildx-release.sh local
sh scripts/smoke-test.sh postgresql-postgis-timescaledb:local
sh scripts/compose-test.sh postgresql-postgis-timescaledb:local
sh scripts/upgrade-test.sh postgresql-postgis-timescaledb:local          # ~10 min; skip only with --quick, and say so
trivy image --severity HIGH,CRITICAL --ignore-unfixed postgresql-postgis-timescaledb:local
```

Plus, not run in CI:
- **Secrets in tree and history**: `git log -p --all | grep -nE 'glpat-|dckr_pat_|ghp_|-----BEGIN|oauth2:[^$]'`
  and the same over the working tree. The repo is **public**.
- **Last CI runs**: `glab api "projects/86056054/pipelines?per_page=10"` — any red job on `main` or
  the schedule, and the latest `vulnerability scan` counts.
- **What users actually pull**: `docker buildx imagetools inspect
  docker.io/kirbownz/postgresql-postgis-timescaledb:latest` — platforms present, attestations present,
  digest matches the last `main` pipeline's publish job.

## Phase 2 — Inventory (regenerate, don't trust this list)

| Surface | Where | Input controlled by |
| --- | --- | --- |
| Start-up upgrade logic (runs as root, then `gosu postgres`) | `docker-entrypoint-ppt.sh` | the user's volume contents + layout, env vars, `--user` |
| Fresh-volume init | `init-*.sh` → `/docker-entrypoint-initdb.d/` | `POSTGRES_*` env |
| Image build | `Dockerfile` | build args, PGDG + packagecloud repos, packagecloud GPG key (fetched at build) |
| Version resolution | `scripts/resolve-versions.sh` | Docker Hub API, PGDG + packagecloud `Packages` indexes (parsed with sed/awk) |
| Auto-commit to `main` | `scripts/commit-versions.sh`, `check upstream versions` job | resolver output, `VERSIONS_PUSH_TOKEN` |
| Build → stage → publish | `.gitlab-ci.yml`, `scripts/docker-buildx-release.sh` | CI rules, staging registry, Docker Hub creds, floating CI images |
| Tests | `scripts/smoke-test.sh`, `upgrade-test.sh`, `compose-test.sh` | — (they are the safety net; audit what they do NOT cover) |
| Secret tooling | `scripts/rotate-gitlab-pat.sh`, `gitlab-set-ci-var.sh`, `op-ensure-signin.sh` | 1Password, GitLab API |
| User-facing contract | `README.md`, `docker-compose.yml` | — |

## Phase 3 — Manual review

Work every item by reading the actual code. The list is a floor — flag unlisted issues too.

### 1. Data safety of the upgrade path (highest weight)
- [ ] Every path that deletes or moves data (`rm -rf`, `mv` loops, `pg_control.old` restore,
      `delete_old_cluster.sh`) — can it run when the new cluster is not yet complete and stamped?
      What if the container is killed between any two steps? Is resume-on-next-start correct from
      **each** intermediate state, in **both** layouts (`inplace` and `relocate`)?
- [ ] `set -Eeo pipefail` semantics: failures swallowed by `$(…)` in `local x=$(…)`, `while read`
      over a here-string, `|| true`, pipelines into `grep -v` — does any silently continue to a
      destructive step?
- [ ] `ppt_locate_cluster` candidates (`/var/lib/postgresql/data`, `/var/lib/postgresql`,
      `/var/lib/postgresql/*/docker`): what if more than one holds a cluster? Glob ordering? A
      custom `PGDATA`? A bind mount vs a named volume?
- [ ] Stamp file: written only after success? Can a stale/forged stamp skip a needed update?
      Image *older* than the stamp (rollback to a previous tag) — handled safely?
- [ ] `pg_upgrade` prerequisites: initdb flags derived from the old cluster (encoding, locale
      provider, ICU, checksums, WAL segment size) — any provider/combination missed? Carried-over
      config: can a carried `postgresql.conf`/`postgresql.auto.conf` setting stop the new server
      starting (and is that recoverable)?
- [ ] Extension updates: TimescaleDB "first statement in a fresh session" rule; ordering; databases
      with `datallowconn = false`; extensions other than these two that are behind; downgrade
      detection with `sort -V` on versions like `3.6.4` vs `3.6.4next`.
- [ ] Root phase: `find … -exec chown` scope, `chown` of parent dirs, behaviour under `--user`
      (non-root) and on a read-only/rootless setup.
- [ ] Disk space: `--link` vs `copy`, what happens on ENOSPC mid-upgrade.
- [ ] `PPT_AUTO_UPGRADE=off` really is byte-for-byte the official behaviour.

### 2. Security
- [ ] Temporary servers are socket-only (`listen_addresses=''`) during every update/upgrade window;
      the healthcheck cannot report healthy before the real server is up.
- [ ] Auth after an upgrade: new cluster's `pg_hba.conf` is the old one (not initdb's
      `--auth-local=trust` default left in place); `POSTGRES_HOST_AUTH_METHOD` semantics preserved;
      superuser identity (`oid 10`) preserved.
- [ ] SQL/shell built from cluster-controlled strings: extension names, database names, role names,
      config keys/values in `ppt_carry_over_config` (a value containing quotes/newlines/`#`),
      `printf '%s = %s'` re-emission. Database names with spaces/quotes in `for db in $dbs`.
- [ ] Predictable temp paths (`/tmp/ppt-initdb.log`) and file permissions on anything written into
      the data dir.
- [ ] Image defaults: `docker-compose.yml` ships `homeassistant/homeassistant` and publishes
      `5432` on all interfaces — is that clearly labelled as a demo in the README?
- [ ] Supply chain: base image pinned by digest; apt packages pinned to exact versions; the
      packagecloud GPG key is fetched over HTTPS at build time **without fingerprint pinning**
      (assess); CI job images on floating tags (`latest`, `stable`, `alpine:3`, `docker:cli`) in jobs
      that hold `DOCKERHUB_TOKEN` / `VERSIONS_PUSH_TOKEN`.
- [ ] Secrets: `VERSIONS_PUSH_TOKEN` in the `git push` URL (could it reach the log on failure?),
      masked + protected flags, which branches/triggers can read each secret, `PUBLISH` manual runs
      from non-default branches. Rotation scripts keep secrets off argv (`ps`-safe) as they claim.
- [ ] Provenance/SBOM actually present on the published manifest; the "retry without
      attestations" fallback in `docker-buildx-release.sh` — is its use visible, or silent?

### 3. Resolver and auto-commit correctness
- [ ] JSON parsed with `sed`/`tr`: Docker Hub pagination (`page_size=100` — can the newest
      `<major>.<minor>-<suite>` tag fall off page 1?), field-order assumptions, the
      manifest-list-vs-per-arch digest extraction.
- [ ] Version comparison (`sort -t. -kN,Nn`) on upstream versions with suffixes, epochs, `~rc`.
      Could a pre-release TimescaleDB/PostGIS be adopted?
- [ ] Every failure mode falls back to the pins (never to a partial/empty value), and the
      `resolver` lint job would catch a format change before Monday.
- [ ] `commit-versions.sh`: README marker rewrite is idempotent; a concurrent human push to `main`
      makes the job fail loudly rather than force anything.
- [ ] A new PostgreSQL major is adopted only when it can also be *upgraded into* — i.e. the
      previous published major is in the new image's `PPT_UPGRADE_FROM_MAJORS`.

### 4. CI / publish
- [ ] Nothing reaches Docker Hub unless smoke (every platform), upgrade and compose tests passed
      on **the same digest**; check `needs:`, `rules:`, `allow_failure`, `interruptible`.
- [ ] Tag order and moving tags (`latest`, `<major>`, `<version>`) — can a publish from an older
      commit (re-run, manual `PUBLISH`) move `latest` backwards?
- [ ] Builder/container/image cleanup in `after_script` on every path; unique names across
      parallel jobs on the shared Docker Desktop daemon.

### 5. Tests (absent coverage on a data path is a MAJOR finding, not a nit)
- [ ] For each Phase 3.1 state/branch, name the test that exercises it, or record that none does.
- [ ] Both architectures smoke-tested; upgrade tests run on the runner arch only — is any
      arch-specific upgrade risk uncovered?
- [ ] Tests assert outcomes (row counts, versions, settings carried over), not just "started".

### 6. Doc / code / version sync
- [ ] README knobs table ⇄ `PPT_*` vars read by the entrypoint; pipeline table ⇄ CI jobs; CI
      settings table ⇄ variables the jobs require; "Developing" commands run as written.
- [ ] Version numbers outside the README markers; `Dockerfile` ARG defaults ⇄ `versions.env`;
      `MIN_UPGRADE_FROM_MAJOR` ⇄ `MIN_PG_MAJOR`; mise pins ⇄ the tool versions in the CI images.
- [ ] `.dockerignore` allowlist ⇄ every `COPY` in the Dockerfile; `.gitignore` covers every file
      the scripts write.
- [ ] Header comments in scripts/CI/Dockerfile still describe the code.

## Phase 4 — Verify (kill false positives)

Spawn one **`audit-verifier`** agent per Critical/High candidate (and any Medium you are unsure of),
in parallel, giving it the finding verbatim with its `path:line` and claimed path. It returns
CONFIRMED / DOWNGRADE / FALSE POSITIVE. A fresh agent, not you re-checking: the reporter is anchored
on its own conclusion. Fold each **Residual** back into the pool and verify those too.

Verify the rest yourself by re-reading the full path. Where cheap, **prove it**: a reproduction
built from the existing test harness (a throwaway volume + `docker run`, like `upgrade-test.sh`
does) that fails now and would pass after the fix. Drop what you cannot stand behind. Eight real
findings beat forty the user has to triage.

Severity:
- **Critical** — data loss or an unstartable database reachable by a normal user through the
  automatic update path; secret disclosure; anything that lets an outsider publish to
  `kirbownz/*` or push to `main`.
- **High** — data loss / corruption needing an unusual-but-real precondition (layout, `--user`,
  interrupted upgrade, specific locale); auth weakened after an upgrade; an untested destructive
  branch; a broken trust anchor (unpinned key used for package verification, unverified digest).
- **Medium** — publish/auto-update failures that stall updates silently, resolver mis-parses with a
  safe fallback, supply-chain hardening gaps with a real path, misleading upgrade docs.
- **Low** — defense in depth, floating CI tags in jobs without secrets, lint-level issues.
- **Quality** — bugs and refactors with no data or security consequence.

## Phase 5 — Report

Write `audit-report.md` in the repo root (gitignored — the repo is public and the report lists
unfixed defects; never commit it). Prose, full sentences:

1. **Verdict** — 3–5 blunt sentences: is the automatic upgrade safe to leave running for users
   today? Name the model the audit ran on and the date.
2. **Findings table** — ID (`PPT-A-001`), severity, area, title, `path:line`, verifier verdict.
3. **One section per finding** — path, evidence (`path:line` + snippet), impact, fix, effort.
4. **Coverage** — every Phase 2 surface: reviewed / not reviewed. An unreviewed surface is listed,
   never implied clean.
5. **Phase 1 output** — verbatim counts and failures.
6. **Delta** vs the previous `audit-report.md` if one exists — fixed, regressed, still open.

Then give the user a terminal summary: verdict, Critical/High list, recommended fix order. Any
Critical → `PushNotification`.

## Phase 6 — Triage + fix (approval gate)

Zero findings → Phase 7. Otherwise present a fix plan with Critical/High/Medium pre-marked, Low and
Quality listed unmarked, and **wait for explicit approval** (`--fix` pre-approves Critical/High
only). For each approved fix: add or extend a test in `scripts/*-test.sh` that fails before and
passes after where the finding is on a data path, make the fix, re-run the Phase 1 commands
relevant to the changed files (`upgrade-test.sh` for any entrypoint/Dockerfile change). Still
failing → stop and report; don't loop.

Commit approved fixes one logical change per commit (Conventional Commits, `Co-Authored-By`
trailer), after `git pull --ff-only` — the schedule pushes to `main` too. **Never push**: a push to
`main` publishes to every user.

## Phase 7 — Memory reconciliation

Runs every invocation, even with zero findings. Update the project memory dir
(`~/.claude/projects/-Users-kimmo-saari-Work-Projects-PostgreSQL-PostGIS-TimescaleDB/memory/` +
`MEMORY.md`) to the END state: recurring defect patterns with a detection hint (grep, file),
upstream quirks the resolver depends on, decided trade-offs the user accepted (with the assumption
that would void them, so the next audit doesn't re-flag them blindly). Not: one-off findings, open
issue lists, anything the code or README already records.
