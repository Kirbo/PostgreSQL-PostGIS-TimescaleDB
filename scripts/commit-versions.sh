#!/bin/sh
# commit-versions.sh — write the versions the resolver found (build.env) into versions.env and
# the README and push that as a commit to the default branch. The push starts an ordinary
# branch pipeline, which builds, tests and publishes exactly what the commit says — so every
# published image corresponds to a commit, `git log` is the upgrade history, and a bump can be
# reverted like any other change.
#
# Prints CHANGED=true/false (also written to versions-commit.env for the dotenv report) so the
# scheduled pipeline knows whether to stop here (a new pipeline is on its way) or to carry on
# and rebuild the unchanged versions for the Debian security updates.
#
# Needs VERSIONS_PUSH_TOKEN (project access token, api + write_repository, allowed to push to
# the protected default branch) — the CI job token cannot push.
set -eu

[ -f build.env ] || { echo "build.env missing — nothing to commit"; exit 1; }

emit() { echo "CHANGED=$1" | tee versions-commit.env; }

# shellcheck disable=SC1091
. ./build.env
NEW_PG_MAJOR="$PG_MAJOR"; NEW_PG="$PG_VERSION"
NEW_GIS="$POSTGIS_VERSION"; NEW_TS="$TIMESCALEDB_VERSION"
NEW_SUITE="$DEBIAN_SUITE"

# shellcheck disable=SC1091
. ./versions.env

if [ "$NEW_PG" = "$PG_VERSION" ] && [ "$NEW_GIS" = "$POSTGIS_VERSION" ] &&
   [ "$NEW_TS" = "$TIMESCALEDB_VERSION" ] && [ "$NEW_PG_MAJOR" = "$PG_MAJOR" ]; then
  echo "versions.env already holds the newest upstream combination (PostgreSQL ${NEW_PG}, PostGIS ${NEW_GIS}, TimescaleDB ${NEW_TS}) — nothing to commit"
  emit false
  exit 0
fi

echo "==> updating versions.env: PostgreSQL ${PG_VERSION} -> ${NEW_PG}, PostGIS ${POSTGIS_VERSION} -> ${NEW_GIS}, TimescaleDB ${TIMESCALEDB_VERSION} -> ${NEW_TS}"
if [ -z "${VERSIONS_PUSH_TOKEN:-}" ]; then
  echo "ERROR: VERSIONS_PUSH_TOKEN is not set — cannot push the version bump" >&2
  exit 1
fi

set_var() { # set_var KEY VALUE FILE — replace the value of an existing KEY=... line
  sed -i "s|^$1=.*|$1=$2|" "$3"
}
set_var PG_MAJOR "$NEW_PG_MAJOR" versions.env
set_var PG_VERSION "$NEW_PG" versions.env
set_var POSTGIS_VERSION "$NEW_GIS" versions.env
set_var TIMESCALEDB_VERSION "$NEW_TS" versions.env
set_var DEBIAN_SUITE "$NEW_SUITE" versions.env

# README carries the same numbers between the markers, regenerated wholesale.
awk -v pg="$NEW_PG" -v gis="$NEW_GIS" -v ts="$NEW_TS" '
  /<!-- versions:start -->/ {
    print
    print ""
    print "* **PostgreSQL " pg "** — [release notes](https://www.postgresql.org/docs/release/)"
    print "* **PostGIS " gis "** — [release notes](https://github.com/postgis/postgis/releases/tag/" gis ")"
    print "* **TimescaleDB " ts "** — [release notes](https://github.com/timescale/timescaledb/releases/tag/" ts ")"
    print ""
    skip = 1
    next
  }
  /<!-- versions:end -->/ { skip = 0 }
  !skip { print }
' README.md > README.md.new && mv README.md.new README.md

awk -v maj="$NEW_PG_MAJOR" -v pg="$NEW_PG" -v gis="$NEW_GIS" -v ts="$NEW_TS" '
  /<!-- tags:start -->/ {
    print
    print ""
    print "| Tag | Points at |"
    print "| --- | --- |"
    print "| `latest` | the newest build |"
    print "| `" maj "` | newest build of that PostgreSQL major |"
    print "| `" pg "` | newest build of that PostgreSQL version |"
    print "| `" pg "-postgis" gis "-timescaledb" ts "` | that exact version combination |"
    print ""
    skip = 1
    next
  }
  /<!-- tags:end -->/ { skip = 0 }
  !skip { print }
' README.md > README.md.new && mv README.md.new README.md

if git diff --quiet -- versions.env README.md; then
  echo "no textual change after rewrite — nothing to commit"
  emit false
  exit 0
fi

git config user.email "${GITLAB_USER_EMAIL:-ci@noreply.gitlab.com}"
git config user.name "${GITLAB_USER_NAME:-GitLab CI}"
git add versions.env README.md
git commit -q -m "chore: PostgreSQL ${NEW_PG} + PostGIS ${NEW_GIS} + TimescaleDB ${NEW_TS}

Resolved from upstream by scheduled pipeline ${CI_PIPELINE_ID:-local}; the pipeline of this
commit builds, tests and publishes it."

# No ci.skip on purpose: this push IS what triggers the build of the new versions.
git push \
  "https://oauth2:${VERSIONS_PUSH_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" \
  "HEAD:${CI_DEFAULT_BRANCH}"
echo "==> pushed to ${CI_DEFAULT_BRANCH}; its pipeline will build and publish these versions"
emit true
