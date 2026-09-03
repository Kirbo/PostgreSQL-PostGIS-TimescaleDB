#!/bin/sh
# resolve-versions.sh [OUTFILE] — work out the newest PostgreSQL + PostGIS + TimescaleDB
# combination that upstream ACTUALLY ships, for every architecture in PLATFORMS, and write it
# as KEY=VALUE to OUTFILE (default build.env). CI consumes that file as a dotenv artifact, so
# every later job sees the resolved versions as environment variables.
#
# The compatibility check is not a table anyone has to maintain — it is package existence:
#   * postgres:<major>.<minor>-<suite> exists on Docker Hub   -> that PostgreSQL is released
#     (a "<major>.<minor>" tag also excludes 19beta3-style pre-releases by construction)
#   * postgresql-<major>-postgis-3 in PGDG for <suite>        -> PostGIS supports that major
#   * timescaledb-2-postgresql-<major> on packagecloud        -> TimescaleDB supports it
# The newest major that satisfies all three FOR EVERY ARCH wins, so a new PostgreSQL major is
# adopted on its own the week both extensions catch up — and never before.
#
# If RESOLVE_MODE is not "auto", or a lookup fails, the pins in versions.env are used verbatim.
# Needs: curl, awk, sed, sort, gzip.
set -eu

OUT="${1:-build.env}"
. ./versions.env

emit() {
  cat > "$OUT" <<EMIT
RESOLVED_FROM=$1
DEBIAN_SUITE=${DEBIAN_SUITE}
PLATFORMS=${PLATFORMS}
PG_MAJOR=$2
PG_VERSION=$3
POSTGIS_VERSION=$4
TIMESCALEDB_VERSION=$5
EMIT
  echo "--- ${OUT} ---"
  cat "$OUT"
}

if [ "${RESOLVE_MODE}" != "auto" ]; then
  echo "RESOLVE_MODE=${RESOLVE_MODE} — using the pins in versions.env"
  emit pinned "$PG_MAJOR" "$PG_VERSION" "$POSTGIS_VERSION" "$TIMESCALEDB_VERSION"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { curl -fsSL --retry 3 --retry-delay 2 --max-time 120 "$1"; }

# Debian arch names for the target platforms (linux/amd64 -> amd64).
ARCHES="$(echo "$PLATFORMS" | tr ',' '\n' | sed 's|.*/||' | tr '\n' ' ')"
ARCH_COUNT="$(echo "$ARCHES" | wc -w | tr -d ' ')"

echo "==> fetching package indexes for suite '${DEBIAN_SUITE}', arches: ${ARCHES}"
for arch in $ARCHES; do
  fetch "https://apt.postgresql.org/pub/repos/apt/dists/${DEBIAN_SUITE}-pgdg/main/binary-${arch}/Packages.gz" \
    | gzip -dc > "$TMP/pgdg-$arch" 2>/dev/null || : > "$TMP/pgdg-$arch"
  fetch "https://packagecloud.io/timescale/timescaledb/debian/dists/${DEBIAN_SUITE}/main/binary-${arch}/Packages" \
    > "$TMP/ts-$arch" 2>/dev/null || : > "$TMP/ts-$arch"
  if [ ! -s "$TMP/pgdg-$arch" ] || [ ! -s "$TMP/ts-$arch" ]; then
    echo "WARNING: could not read an upstream package index for ${arch} — falling back to the pins in versions.env" >&2
    emit "pinned-fallback" "$PG_MAJOR" "$PG_VERSION" "$POSTGIS_VERSION" "$TIMESCALEDB_VERSION"
    exit 0
  fi
done

# Highest version of PKG that is present in EVERY arch's index, reduced to its upstream form
# (3.6.4+dfsg-2.pgdg13+1 -> 3.6.4, 2.29.2~debian13-1806 -> 2.29.2, 1:3.6.4-1 -> 3.6.4).
common_max_version() { # common_max_version <index-prefix> <package>
  for arch in $ARCHES; do
    awk -v pkg="$2" '$1 == "Package:" { p = ($2 == pkg); next } p && $1 == "Version:" { print $2 }' "$TMP/$1-$arch" \
      | sed 's/^[0-9]*://; s/[^0-9.].*$//; s/\.$//' \
      | sort -u
  done | sort | uniq -c | awk -v n="$ARCH_COUNT" '$1 == n { print $2 }' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

# Newest STABLE postgres:<major>.<minor>-<suite> tag on Docker Hub, as "<major>.<minor>".
latest_pg_patch() { # latest_pg_patch <major>
  fetch "https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100&name=$1." 2>/dev/null \
    | tr ',{' '\n\n' \
    | sed -n "s/.*\"name\": *\"\([0-9][0-9.]*\)-${DEBIAN_SUITE}\".*/\1/p" \
    | grep "^$1\." \
    | sort -t. -k1,1n -k2,2n | tail -n 1
}

major="$MAX_PG_MAJOR"
while [ "$major" -ge "$MIN_PG_MAJOR" ]; do
  echo "==> checking PostgreSQL ${major}"
  pg_patch="$(latest_pg_patch "$major" || true)"
  if [ -z "$pg_patch" ]; then
    echo "    no stable postgres:${major}.x-${DEBIAN_SUITE} image"
    major=$((major - 1))
    continue
  fi

  gis="$(common_max_version pgdg "postgresql-${major}-postgis-3")"
  ts="$(common_max_version ts "timescaledb-2-postgresql-${major}")"
  echo "    image=postgres:${pg_patch}-${DEBIAN_SUITE} postgis=${gis:-none} timescaledb=${ts:-none}"

  if [ -n "$gis" ] && [ -n "$ts" ]; then
    emit auto "$major" "$pg_patch" "$gis" "$ts"
    exit 0
  fi
  major=$((major - 1))
done

echo "WARNING: no PostgreSQL major between ${MIN_PG_MAJOR} and ${MAX_PG_MAJOR} had both extensions — falling back to the pins in versions.env" >&2
emit "pinned-fallback" "$PG_MAJOR" "$PG_VERSION" "$POSTGIS_VERSION" "$TIMESCALEDB_VERSION"
