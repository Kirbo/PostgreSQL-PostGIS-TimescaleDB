#!/bin/sh
# sync-versions.sh — after a publish, write the versions that were actually built back into
# versions.env and the README, and commit them to the default branch. Turns `git log` into the
# upgrade history of the published image and keeps the repo honest about what :latest holds.
#
# No-ops when nothing changed. Needs VERSIONS_PUSH_TOKEN (project access token, api +
# write_repository, allowed to push to the protected default branch) — the CI job token cannot
# push. The push uses `-o ci.skip` so this commit does not trigger another pipeline.
set -eu

[ -f build.env ] || { echo "build.env missing — nothing to sync"; exit 0; }

# shellcheck disable=SC1091
. ./build.env
NEW_PG_MAJOR="$PG_MAJOR"; NEW_PG="$PG_VERSION"
NEW_GIS="$POSTGIS_VERSION"; NEW_TS="$TIMESCALEDB_VERSION"
NEW_SUITE="$DEBIAN_SUITE"

# shellcheck disable=SC1091
. ./versions.env

if [ "$NEW_PG" = "$PG_VERSION" ] && [ "$NEW_GIS" = "$POSTGIS_VERSION" ] &&
   [ "$NEW_TS" = "$TIMESCALEDB_VERSION" ] && [ "$NEW_PG_MAJOR" = "$PG_MAJOR" ]; then
  echo "versions.env already matches what was published (PostgreSQL ${NEW_PG}, PostGIS ${NEW_GIS}, TimescaleDB ${NEW_TS}) — nothing to commit"
  exit 0
fi

echo "==> updating versions.env: PostgreSQL ${PG_VERSION} -> ${NEW_PG}, PostGIS ${POSTGIS_VERSION} -> ${NEW_GIS}, TimescaleDB ${TIMESCALEDB_VERSION} -> ${NEW_TS}"

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
    print "* **PostgreSQL " pg "** — [release notes](https://www.postgresql.org/docs/release/)"
    print "* **PostGIS " gis "** — [release notes](https://github.com/postgis/postgis/releases/tag/" gis ")"
    print "* **TimescaleDB " ts "** — [release notes](https://github.com/timescale/timescaledb/releases/tag/" ts ")"
    skip = 1
    next
  }
  /<!-- versions:end -->/ { skip = 0 }
  !skip { print }
' README.md > README.md.new && mv README.md.new README.md

awk -v maj="$NEW_PG_MAJOR" -v pg="$NEW_PG" -v gis="$NEW_GIS" -v ts="$NEW_TS" '
  /<!-- tags:start -->/ {
    print
    print "| `latest` | the newest build |"
    print "| `" maj "` | newest build of that PostgreSQL major |"
    print "| `" pg "` | newest build of that PostgreSQL version |"
    print "| `" pg "-postgis" gis "-timescaledb" ts "` | one exact, immutable combination |"
    skip = 1
    next
  }
  /<!-- tags:end -->/ { skip = 0 }
  !skip { print }
' README.md > README.md.new && mv README.md.new README.md

if git diff --quiet -- versions.env README.md; then
  echo "no textual change after rewrite — nothing to commit"
  exit 0
fi

git config user.email "${GITLAB_USER_EMAIL:-ci@noreply.gitlab.com}"
git config user.name "${GITLAB_USER_NAME:-GitLab CI}"
git add versions.env README.md
git commit -m "chore: PostgreSQL ${NEW_PG} + PostGIS ${NEW_GIS} + TimescaleDB ${NEW_TS}

Published by pipeline ${CI_PIPELINE_ID:-local}."

git push -o ci.skip \
  "https://oauth2:${VERSIONS_PUSH_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" \
  "HEAD:${CI_DEFAULT_BRANCH}"
echo "==> pushed to ${CI_DEFAULT_BRANCH}"
