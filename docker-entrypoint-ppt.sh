#!/usr/bin/env bash
# docker-entrypoint-ppt.sh — wraps the official image's docker-entrypoint.sh and, BEFORE the
# server is started for real, brings an existing data directory up to date with what this
# image ships:
#
#   * same PostgreSQL major, newer PostGIS / TimescaleDB  -> ALTER EXTENSION ... UPDATE in every
#     database (TimescaleDB's "first command in a fresh session" rule is respected)
#   * older PostgreSQL major                              -> pg_upgrade --link with the bundled
#     binaries of that major (PPT_UPGRADE_FROM_MAJORS), extensions updated on the old cluster
#     first so both sides run the same extension versions, as Timescale requires
#   * data directory from a PostgreSQL <= 17 image layout  -> found and upgraded where it is
#     (/var/lib/postgresql/data), or into /var/lib/postgresql/<major>/docker when the volume
#     is mounted at /var/lib/postgresql
#
# Nothing here runs on a fresh volume (the official init path handles that), and a data
# directory that already matches the image is recognised from a stamp file in one stat call,
# so a normal restart costs nothing.
#
# A major upgrade can be interrupted at any point (docker stop / kill, OOM, host reboot) or
# fail, and the next start does the right thing:
#   * until pg_upgrade has succeeded, the new cluster is built in a STAGING directory next to
#     the final one and nothing points at it; a failure rolls everything back (the old cluster
#     is where it was, startable with the old image), an interruption is redone from scratch
#   * once pg_upgrade has succeeded, a marker in the staging directory makes the NEW cluster
#     the source of truth: the old one is never started again, the next start only finishes
#     the remaining steps and moves the new cluster into place
#
# Knobs (environment):
#   PPT_AUTO_UPGRADE=off        skip all of this and behave exactly like the official image
#   PPT_KEEP_OLD_CLUSTER=1      after a major upgrade, keep the old cluster directory, renamed to
#                               <dir>.ppt-old-<timestamp> so it is never mistaken for a live one,
#                               instead of deleting it (after --link it cannot be started anymore,
#                               it is only useful for forensics)
#   PPT_UPGRADE_MODE=copy       pg_upgrade in copy mode instead of --link (needs 2x the disk,
#                               but the kept old cluster stays startable with the old image)
set -Eeo pipefail

# The official entrypoint defines its functions and returns when sourced.
# shellcheck disable=SC1091
source /usr/local/bin/docker-entrypoint.sh
# PPT_UPGRADE_FROM_MAJORS="16 17": written by the Dockerfile, the majors with bundled binaries.
# shellcheck disable=SC1091
[ -f /etc/ppt-upgrade-from.env ] && source /etc/ppt-upgrade-from.env

STAMP_FILE=".ppt-versions"
STAMP="postgresql=${PG_MAJOR} postgis=${POSTGIS_VERSION} timescaledb=${TIMESCALEDB_VERSION}"
# Major-upgrade state, inside the staging directory:
#   UPGRADE_DONE     "<old major> <old dir>", written the moment pg_upgrade has succeeded
#   UPGRADE_PLACING  the new cluster is stamped and the old one retired; only the move is left
UPGRADE_DONE=".ppt-upgrade-done"
UPGRADE_PLACING=".ppt-upgrade-placing"
# The relocate layout builds the new cluster in $PGDATA$RELOCATE_STAGE_SUFFIX and renames it
# to $PGDATA at the end (same filesystem, so the rename is atomic).
RELOCATE_STAGE_SUFFIX=".ppt-upgrade"
ESCAPE_HINT="PPT_AUTO_UPGRADE=off starts the server without this step (same PostgreSQL major only)"

log()  { printf '%s ppt: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '%s ppt: WARNING: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { printf '%s ppt: ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

is_mountpoint() {
	mountpoint -q "$1" 2>/dev/null || awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo
}

# --- leaving cleanly ------------------------------------------------------------------------

# Whatever ends the script (die, a failing command under set -e, a normal exit), a temporary
# server must not be left running, and an unfinished major upgrade must be rolled back.
TEMP_BIN=''
TEMP_DIR=''
ROLLBACK_OLDDIR=''
ROLLBACK_STAGEDIR=''
ppt_on_exit() {
	local status=$?
	if [ -n "$TEMP_DIR" ]; then
		"$TEMP_BIN/pg_ctl" -D "$TEMP_DIR" -m fast -w -s stop || true
	fi
	if [ "$status" != 0 ] && [ -n "$ROLLBACK_OLDDIR" ]; then
		ppt_rollback || warn "rollback incomplete — see the messages above"
	fi
}

# ppt_rollback — undo an upgrade that failed BEFORE pg_upgrade succeeded. The new cluster was
# never started on the linked files at that point, so it is worthless and the old cluster is
# unchanged (pg_upgrade --link only renames its global/pg_control once linking starts).
ppt_rollback() {
	warn "upgrade failed; rolling back"
	rm -rf "$ROLLBACK_STAGEDIR"
	if [ -f "$ROLLBACK_OLDDIR/global/pg_control.old" ]; then
		mv "$ROLLBACK_OLDDIR/global/pg_control.old" "$ROLLBACK_OLDDIR/global/pg_control"
	fi
	if [ "$UPGRADE_LAYOUT" = inplace ]; then
		# Back to the root of the volume, where the old image expects it.
		local entry
		for entry in "$ROLLBACK_OLDDIR"/* "$ROLLBACK_OLDDIR"/.[!.]*; do
			[ -e "$entry" ] || continue
			mv "$entry" "$PGDATA/"
		done
		rmdir "$ROLLBACK_OLDDIR"
	fi
	ROLLBACK_OLDDIR=''
	log "rolled back: the PostgreSQL ${CLUSTER_MAJOR} cluster is unchanged at ${CLUSTER_DIR} and starts with a PostgreSQL ${CLUSTER_MAJOR} image"
}

# --- locating the cluster -------------------------------------------------------------------

# Sets CLUSTER_DIR (existing cluster, or empty), CLUSTER_MAJOR and UPGRADE_LAYOUT:
#   inplace   the cluster lives in $PGDATA itself (possibly the mount point) -> upgrade inside it
#   relocate  the cluster is a sibling directory inside the /var/lib/postgresql volume
#             (e.g. /var/lib/postgresql/data or /var/lib/postgresql/17/docker) -> upgrade into
#             $PGDATA, which is what the official 18+ layout expects
ppt_locate_cluster() {
	CLUSTER_DIR=''
	CLUSTER_MAJOR=''
	UPGRADE_LAYOUT='inplace'
	local default="/var/lib/postgresql/$PG_MAJOR/docker"

	# A relocate upgrade whose pg_upgrade had already succeeded, interrupted before the new
	# cluster was moved into place: finish it.
	if [ "$PGDATA" = "$default" ] && [ -s "${PGDATA}${RELOCATE_STAGE_SUFFIX}/$UPGRADE_DONE" ]; then
		read -r CLUSTER_MAJOR CLUSTER_DIR < "${PGDATA}${RELOCATE_STAGE_SUFFIX}/$UPGRADE_DONE"
		UPGRADE_LAYOUT='relocate'
		return 0
	fi

	if ppt_has_cluster "$PGDATA"; then
		CLUSTER_DIR="$PGDATA"
	elif [ "$PGDATA" = "$default" ]; then
		# Same candidates as the official entrypoint's docker_error_old_databases(), which would
		# otherwise refuse to start on top of them. Never a guess between several: an old
		# cluster left next to the live one would be upgraded INSTEAD of it.
		local d found=()
		for d in /var/lib/postgresql/data /var/lib/postgresql /var/lib/postgresql/*/docker; do
			if ppt_has_cluster "$d"; then
				found+=("$d")
			fi
		done
		if [ "${#found[@]}" -gt 1 ]; then
			die "found more than one PostgreSQL data directory: ${found[*]} — refusing to guess which one is current. Move the ones that are not (e.g. an old cluster kept by PPT_KEEP_OLD_CLUSTER=1) out of the way, e.g. rename them to <dir>.old, and start again."
		fi
		if [ "${#found[@]}" -eq 1 ]; then
			CLUSTER_DIR="${found[0]}"
			if [ "$CLUSTER_DIR" = /var/lib/postgresql ] || is_mountpoint "$CLUSTER_DIR"; then
				# The cluster IS the mounted volume: upgrading "next to it" would land outside the
				# volume. Keep using that directory as PGDATA, upgrade in place.
				export PGDATA="$CLUSTER_DIR"
				log "using existing data directory ${PGDATA} (PostgreSQL <= 17 image layout)"
			else
				UPGRADE_LAYOUT='relocate'
			fi
		fi
	fi

	if [ -n "$CLUSTER_DIR" ]; then
		CLUSTER_MAJOR="$(ppt_cluster_major "$CLUSTER_DIR")"
	fi
}

# ppt_has_cluster DIR — a data directory, or one with an in-place upgrade in progress: the
# cluster moved into DIR/pg<major>_pre_upgrade, or the new one finished in DIR/pg<major>_upgraded.
ppt_has_cluster() {
	[ -s "$1/PG_VERSION" ] && return 0
	local d
	for d in "$1"/pg[0-9]*_pre_upgrade; do
		[ -s "$d/PG_VERSION" ] && return 0
	done
	for d in "$1"/pg[0-9]*_upgraded; do
		[ -s "$d/$UPGRADE_DONE" ] && return 0
	done
	return 1
}

# ppt_cluster_major DIR — the major the cluster in DIR is at. An in-place upgrade in progress
# counts as the OLD major (even when part of the new cluster is already at the root), so that
# main() routes it back into ppt_pg_upgrade to be finished.
ppt_cluster_major() {
	local d major
	for d in "$1"/pg[0-9]*_upgraded; do
		if [ -s "$d/$UPGRADE_DONE" ]; then
			read -r major _ < "$d/$UPGRADE_DONE"
			echo "$major"
			return 0
		fi
	done
	if [ -s "$1/PG_VERSION" ]; then
		tr -d '[:space:]' < "$1/PG_VERSION"
		return 0
	fi
	for d in "$1"/pg[0-9]*_pre_upgrade; do
		if [ -s "$d/PG_VERSION" ]; then
			tr -d '[:space:]' < "$d/PG_VERSION"
			return 0
		fi
	done
}

# --- helpers around a temporarily started server --------------------------------------------

# ppt_clear_stale_lock DATADIR — a container that was killed (docker kill, OOM, host reboot)
# leaves postmaster.pid behind, and the PID in it is 1: in a fresh container that is THIS
# script, so postgres would refuse to start ("Is another postmaster (PID 1) running?"). The
# real postmaster only tolerates that because it IS pid 1 when exec'd; the single-user backend
# and pg_ctl below are not. Nothing else runs in a container at this point, so if no postgres
# process exists here at all, the lock is stale by construction.
ppt_clear_stale_lock() {
	[ -f "$1/postmaster.pid" ] || return 0
	local p
	for p in /proc/[0-9]*; do
		if [ "$(cat "$p/comm" 2>/dev/null)" = postgres ]; then
			return 0
		fi
	done
	log "removing stale postmaster.pid from ${1} (unclean shutdown, no postgres running in this container)"
	rm -f "$1/postmaster.pid"
}

# ppt_su_name DATADIR BINDIR — the bootstrap superuser (oid 10) of a cluster, found in
# single-user mode so it works whatever POSTGRES_USER was at initdb time and needs no auth.
ppt_su_name() {
	echo "SELECT rolname FROM pg_authid WHERE oid = 10" \
		| "$2/postgres" --single -D "$1" -c timescaledb.disable_load=on postgres 2> >(grep -Ev ' (LOG|DEBUG):  ' >&2) \
		| sed -n 's/^[[:space:]]*1: rolname = "\([^"]*\)".*/\1/p'
}

# ppt_temp_start BINDIR DATADIR — socket-only server, like the official init does. No
# TimescaleDB background workers: they would load the extension's OLD shared library (or fail
# to, noisily) while we are in the middle of updating it. ppt_on_exit stops it if we die.
ppt_temp_start() {
	NOTIFY_SOCKET='' "$1/pg_ctl" -D "$2" -w -t 600 -s \
		-o "-c listen_addresses='' -c unix_socket_directories='/var/run/postgresql' -p ${PGPORT:-5432} -c timescaledb.max_background_workers=0" \
		start
	TEMP_BIN="$1"
	TEMP_DIR="$2"
}

ppt_temp_stop() {
	"$TEMP_BIN/pg_ctl" -D "$TEMP_DIR" -m fast -w -s stop
	TEMP_BIN=''
	TEMP_DIR=''
}

# ppt_psql BINDIR DBNAME SQL — one statement, fresh session, no psqlrc, no TimescaleDB
# auto-load unless the statement is the ALTER EXTENSION that needs it. The database name goes
# through PGDATABASE, which libpq takes literally: `psql -d` would parse a name containing "="
# as a connection string.
ppt_psql() {
	PGOPTIONS="${PGOPTIONS:-}" PGHOST=/var/run/postgresql PGPORT="${PGPORT:-5432}" PGDATABASE="$2" \
		"$1/psql" -X -q -A -t -v ON_ERROR_STOP=1 -U "$SU" -c "$3"
}

# ppt_update_extensions BINDIR — ALTER EXTENSION ... UPDATE for every extension in every
# database that is behind the version this image ships. Each ALTER runs in its own session:
# TimescaleDB insists on being the first command of a fresh session (its loader swaps in the
# new shared library when it sees that statement), and PostGIS wants postgis before
# postgis_topology, which the ORDER BY handles.
ppt_update_extensions() {
	local bindir="$1" out db ext have want pending
	local -a dbs=()
	out="$(PGOPTIONS='-c timescaledb.disable_load=on' ppt_psql "$bindir" postgres \
		"SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname")" \
		|| die "could not list the databases (see the error above); ${ESCAPE_HINT}"
	# One name per line, whatever characters it contains (a name with a newline in it is not
	# something PostgreSQL users create).
	mapfile -t dbs <<< "$out"
	for db in "${dbs[@]}"; do
		[ -n "$db" ] || continue
		pending="$(PGOPTIONS='-c timescaledb.disable_load=on' ppt_psql "$bindir" "$db" "
			SELECT e.extname || ' ' || e.extversion || ' ' || a.default_version
			  FROM pg_extension e JOIN pg_available_extensions a ON a.name = e.extname
			 WHERE a.default_version IS NOT NULL AND e.extversion <> a.default_version
			 ORDER BY CASE e.extname WHEN 'timescaledb' THEN 0 WHEN 'postgis' THEN 1 ELSE 2 END, e.extname")" \
			|| die "database '${db}': could not read its extensions (see the error above); ${ESCAPE_HINT}"
		[ -n "$pending" ] || continue
		while read -r ext have want; do
			[ -n "$ext" ] || continue
			if [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | tail -n 1)" = "$have" ]; then
				warn "database '${db}': extension ${ext} is at ${have}, newer than the ${want} this image ships — this image is OLDER than the one that last ran on this volume. Not touching it."
				continue
			fi
			log "database '${db}': ALTER EXTENSION ${ext} UPDATE (${have} -> ${want})"
			ppt_psql "$bindir" "$db" "ALTER EXTENSION \"${ext}\" UPDATE" \
				|| die "database '${db}': ALTER EXTENSION ${ext} UPDATE failed (see the error above); ${ESCAPE_HINT}"
		done <<< "$pending"
	done
}

# --- same-major: extension updates ----------------------------------------------------------

ppt_update_same_major() {
	# Left behind if a relocate upgrade was interrupted right after its final rename.
	rm -f "$PGDATA/$UPGRADE_DONE" "$PGDATA/$UPGRADE_PLACING"
	if [ -f "$PGDATA/$STAMP_FILE" ] && [ "$(cat "$PGDATA/$STAMP_FILE")" = "$STAMP" ]; then
		return 0
	fi
	log "data directory ${PGDATA} was last used by [$(cat "$PGDATA/$STAMP_FILE" 2>/dev/null || echo 'an unstamped image')], image is [${STAMP}] — checking extensions"
	local bindir="/usr/lib/postgresql/$PG_MAJOR/bin"
	ppt_clear_stale_lock "$PGDATA"
	SU="$(ppt_su_name "$PGDATA" "$bindir" || true)"
	[ -n "$SU" ] || die "could not determine the superuser of ${PGDATA} (see the log lines above)"
	ppt_temp_start "$bindir" "$PGDATA"
	ppt_update_extensions "$bindir"
	ppt_temp_stop
	echo "$STAMP" > "$PGDATA/$STAMP_FILE"
	log "extensions are up to date"
}

# --- older major: pg_upgrade ------------------------------------------------------------------

# ppt_initdb_args_for OLDBIN — initdb flags that make the new cluster compatible with the old
# one (pg_upgrade refuses otherwise): encoding, locale/collation provider, checksums, WAL
# segment size. Queried from the running old cluster.
ppt_initdb_args_for() {
	local oldbin="$1" row
	row="$(PGOPTIONS='-c timescaledb.disable_load=on' ppt_psql "$oldbin" postgres "
		SELECT pg_encoding_to_char(d.encoding), d.datcollate, d.datctype, d.datlocprovider,
		       coalesce(to_jsonb(d)->>'datlocale', to_jsonb(d)->>'daticulocale', ''),
		       coalesce(to_jsonb(d)->>'daticurules', ''),
		       current_setting('data_checksums'), current_setting('wal_segment_size')
		  FROM pg_database d WHERE datname = 'template0'")"
	local enc collate ctype provider locale rules checksums walseg
	IFS='|' read -r enc collate ctype provider locale rules checksums walseg <<< "$row"
	local args=(--encoding="$enc" --lc-collate="$collate" --lc-ctype="$ctype")
	case "$provider" in
		i) args+=(--locale-provider=icu --icu-locale="$locale"); [ -n "$rules" ] && args+=(--icu-rules="$rules") ;;
		b) args+=(--locale-provider=builtin --builtin-locale="$locale") ;;
		*) args+=(--locale-provider=libc) ;;
	esac
	if [ "$checksums" = on ]; then args+=(--data-checksums); else args+=(--no-data-checksums); fi
	# wal_segment_size reads as e.g. 16MB; initdb wants megabytes.
	args+=(--wal-segsize="${walseg%MB}")
	printf '%s\n' "${args[@]}"
}

# ppt_old_file_settings OLDBIN — the settings in the old cluster's postgresql.conf, as
# "name=value" lines, read by the running old server itself (pg_file_settings): its own parser
# handles quoting and comments, the value is exactly what the file says, and a setting
# overridden on the command line (like the temporary server's) is still reported.
ppt_old_file_settings() {
	PGOPTIONS='-c timescaledb.disable_load=on' ppt_psql "$1" postgres "
		SELECT f.name || '=' || f.setting
		  FROM pg_file_settings f
		 WHERE f.sourcefile = current_setting('config_file') AND f.error IS NULL
		   AND f.seqno = (SELECT max(g.seqno) FROM pg_file_settings g
		                   WHERE g.sourcefile = f.sourcefile AND g.name = f.name)
		 ORDER BY f.seqno"
}

# ppt_carry_over_config OLD NEW NEWBIN — the new cluster starts from this image's
# postgresql.conf (which has the right shared_preload_libraries/listen_addresses); every setting
# the old postgresql.conf had (OLD_FILE_SETTINGS, read while the old server ran) is appended if
# the new server still knows it and it differs, quoted, along with the old file's include
# directives. The old file is kept next to it for reference.
ppt_carry_over_config() {
	local old="$1" new="$2" newbin="$3" f line key val carried=0 dropped=0
	for f in pg_hba.conf pg_ident.conf postgresql.auto.conf server.crt server.key root.crt root.crl; do
		[ -f "$old/$f" ] && cp -p "$old/$f" "$new/$f"
	done
	# Files an include directive may point at, relative to the data directory.
	for f in "$old"/*.conf; do
		[ -f "$f" ] && [ ! -e "$new/${f##*/}" ] && cp -p "$f" "$new/"
	done
	[ -d "$old/conf.d" ] && cp -pr "$old/conf.d" "$new/conf.d"
	cp -p "$old/postgresql.conf" "$new/postgresql.conf.pg${CLUSTER_MAJOR}"

	# What the fresh conf already says (initdb's own output: plain "key = value" lines).
	local -A fresh=() known=()
	while IFS='=' read -r key val; do
		val="${val#\'}"; fresh["$key"]="${val%\'}"
	done < <(grep -E '^[[:space:]]*[a-z_][a-z0-9_.]*[[:space:]]*=' "$new/postgresql.conf" \
		| sed -E "s/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/; s/[[:space:]]+#[^']*$//; s/[[:space:]]+$//")
	while IFS=$'\t' read -r key _; do known["$key"]=1; done < <("$newbin/postgres" --describe-config)

	{
		printf '\n# --- settings carried over from the PostgreSQL %s data directory by the image upgrade ---\n' "$CLUSTER_MAJOR"
		grep -E '^[[:space:]]*include(_dir|_if_exists)?([[:space:]]|=)' "$old/postgresql.conf" || true
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			key="${line%%=*}"; val="${line#*=}"
			case "$key" in
				shared_preload_libraries|listen_addresses|data_directory|config_file|hba_file|ident_file|external_pid_file) continue ;;
			esac
			# Same value as the fresh initdb'd conf (the stock docker settings, typically): nothing to carry.
			[ "${fresh[$key]+set}" ] && [ "${fresh[$key]}" = "$val" ] && continue
			# Dotted names are extension settings: always accepted (as placeholders, if nothing
			# defines them). Core names the new major dropped are kept as a comment.
			if [ "${key#*.}" != "$key" ] || [ "${known[$key]+set}" ]; then
				printf "%s = '%s'\n" "$key" "${val//\'/\'\'}"; carried=$((carried + 1))
			else
				printf "# dropped (unknown to PostgreSQL %s): %s = '%s'\n" "$PG_MAJOR" "$key" "${val//\'/\'\'}"; dropped=$((dropped + 1))
			fi
		done <<< "$OLD_FILE_SETTINGS"
	} >> "$new/postgresql.conf"
	log "postgresql.conf: ${carried} setting(s) carried over, ${dropped} dropped as unknown (old file kept as postgresql.conf.pg${CLUSTER_MAJOR})"
}

# ppt_retire_old_cluster OLDMAJOR OLDDIR — after a successful upgrade. Renamed first, so that
# whatever happens next it no longer looks like a data directory to ppt_locate_cluster.
ppt_retire_old_cluster() {
	local oldmajor="$1" olddir="$2" ts
	[ -e "$olddir" ] || return 0
	ts="$(date -u +%Y%m%d%H%M%S)"
	if [ "${PPT_KEEP_OLD_CLUSTER:-0}" = 1 ]; then
		mv "$olddir" "${olddir}.ppt-old-${ts}"
		warn "old PostgreSQL ${oldmajor} cluster kept at ${olddir}.ppt-old-${ts} (PPT_KEEP_OLD_CLUSTER=1); after --link it can no longer be started, delete it when done"
		return 0
	fi
	mv "$olddir" "${olddir}.ppt-retired-${ts}"
	if rm -rf "${olddir}.ppt-retired-${ts}" 2>/dev/null; then
		[ "$UPGRADE_LAYOUT" = relocate ] && rmdir "$(dirname "$olddir")" 2>/dev/null || true
	else
		warn "could not delete the old cluster at ${olddir}.ppt-retired-${ts} (permissions?); it is no longer usable, delete it by hand"
	fi
}

# ppt_finish_upgrade OLDMAJOR OLDDIR STAGEDIR — everything after a successful pg_upgrade, and
# safe to repeat from any point: the new cluster in STAGEDIR is the source of truth.
ppt_finish_upgrade() {
	local oldmajor="$1" olddir="$2" stagedir="$3"
	local newbin="/usr/lib/postgresql/${PG_MAJOR}/bin"

	if [ ! -e "$stagedir/$UPGRADE_PLACING" ]; then
		# 4. New cluster: make sure everything loads, refresh planner statistics, stamp it.
		if [ "$(cat "$stagedir/$STAMP_FILE" 2>/dev/null)" != "$STAMP" ]; then
			ppt_clear_stale_lock "$stagedir"
			[ -n "${SU:-}" ] || SU="$(ppt_su_name "$stagedir" "$newbin" || true)"
			[ -n "$SU" ] || die "could not determine the superuser of ${stagedir} (see the log lines above)"
			ppt_temp_start "$newbin" "$stagedir"
			ppt_update_extensions "$newbin"
			log "vacuumdb --all --analyze-in-stages"
			PGHOST=/var/run/postgresql "$newbin/vacuumdb" -U "$SU" --all --analyze-in-stages -q 2>&1 | grep -v '^Generating' || true
			ppt_temp_stop
			rm -f "$stagedir/delete_old_cluster.sh"
			echo "$STAMP" > "$stagedir/$STAMP_FILE"
		fi
		ppt_retire_old_cluster "$oldmajor" "$olddir"
		: > "$stagedir/$UPGRADE_PLACING"
	fi

	# 5. Put the new cluster where the server expects it.
	if [ "$UPGRADE_LAYOUT" = relocate ]; then
		# The root phase may have created an empty $PGDATA; `mv` would move INTO it.
		rmdir "$PGDATA" 2>/dev/null || true
		[ ! -e "$PGDATA" ] || die "cannot move the upgraded cluster ${stagedir} to ${PGDATA}: it is not empty"
		mv "$stagedir" "$PGDATA"
	else
		local entry
		for entry in "$stagedir"/* "$stagedir"/.[!.]*; do
			[ -e "$entry" ] || continue
			case "${entry##*/}" in "$UPGRADE_DONE"|"$UPGRADE_PLACING") continue ;; esac
			mv "$entry" "$PGDATA/"
		done
		rm -f "$stagedir/$UPGRADE_DONE" "$stagedir/$UPGRADE_PLACING"
		rmdir "$stagedir"
	fi
	rm -f "$PGDATA/$UPGRADE_DONE" "$PGDATA/$UPGRADE_PLACING"
}

ppt_pg_upgrade() {
	local oldmajor="$CLUSTER_MAJOR"
	local oldbin="/usr/lib/postgresql/${oldmajor}/bin"
	local newbin="/usr/lib/postgresql/${PG_MAJOR}/bin"
	local mode="${PPT_UPGRADE_MODE:-link}"
	local olddir stagedir start_ts
	start_ts="$(date +%s)"

	if [ "$UPGRADE_LAYOUT" = relocate ]; then
		stagedir="${PGDATA}${RELOCATE_STAGE_SUFFIX}"
	else
		stagedir="$PGDATA/pg${PG_MAJOR}_upgraded"
	fi

	if [ -s "$stagedir/$UPGRADE_DONE" ]; then
		read -r oldmajor olddir < "$stagedir/$UPGRADE_DONE"
		log "resuming: pg_upgrade of the PostgreSQL ${oldmajor} cluster had already succeeded, finishing the upgrade in ${stagedir}"
		ppt_finish_upgrade "$oldmajor" "$olddir" "$stagedir"
		log "PostgreSQL ${oldmajor} -> ${PG_MAJOR} upgrade finished; data directory is ${PGDATA}"
		return 0
	fi

	[ -x "$oldbin/pg_upgrade" ] || die "the data directory ${CLUSTER_DIR} is PostgreSQL ${oldmajor}, but this image only bundles upgrade binaries for PostgreSQL ${PPT_UPGRADE_FROM_MAJORS:-<none>} (TimescaleDB ${TIMESCALEDB_VERSION} is not available for ${oldmajor}). Upgrade with an intermediate image tag first, or dump with the old image and restore into this one."
	case "$mode" in link|copy) ;; *) die "PPT_UPGRADE_MODE must be link or copy, not '${mode}'" ;; esac

	# From here until pg_upgrade has succeeded, any failure rolls back (ppt_on_exit).
	if [ "$UPGRADE_LAYOUT" = relocate ]; then
		olddir="$CLUSTER_DIR"
		ROLLBACK_OLDDIR="$olddir"
		ROLLBACK_STAGEDIR="$stagedir"
		mkdir -p "$(dirname "$stagedir")"
	else
		# The cluster is at the root of the mounted volume: shuffle it into a subdirectory so
		# the new cluster can be built next to it, on the same filesystem (hard links).
		olddir="$PGDATA/pg${oldmajor}_pre_upgrade"
		ROLLBACK_OLDDIR="$olddir"
		ROLLBACK_STAGEDIR="$stagedir"
		if [ -s "$olddir/PG_VERSION" ]; then
			log "resuming an interrupted PostgreSQL ${oldmajor} upgrade in ${PGDATA}"
		else
			mkdir -p "$olddir"
			local entry
			for entry in "$PGDATA"/* "$PGDATA"/.[!.]*; do
				[ -e "$entry" ] || continue
				case "$entry" in "$olddir"|"$stagedir") continue ;; esac
				mv "$entry" "$olddir/"
			done
		fi
	fi
	chmod 0700 "$olddir"
	log "upgrading PostgreSQL ${oldmajor} cluster ${olddir} -> PostgreSQL ${PG_MAJOR} (pg_upgrade --${mode}, staged in ${stagedir})"

	# A leftover from an interrupted attempt is in the same state as a failed one: no new
	# cluster has ever been started on the old cluster's files yet, so it is discarded and the
	# old one restored.
	rm -rf "$stagedir"
	[ -f "$olddir/global/pg_control.old" ] && mv "$olddir/global/pg_control.old" "$olddir/global/pg_control"

	ppt_clear_stale_lock "$olddir"
	SU="$(ppt_su_name "$olddir" "$oldbin" || true)"
	[ -n "$SU" ] || die "could not determine the superuser of ${olddir} (see the log lines above)"
	log "bootstrap superuser is '${SU}'"

	# 1. Old cluster: clean shutdown (recovers from a crash if needed), extensions brought to
	#    the versions this image ships FOR THE OLD MAJOR — pg_upgrade needs both sides equal.
	ppt_temp_start "$oldbin" "$olddir"
	ppt_update_extensions "$oldbin"
	local initdb_args=()
	mapfile -t initdb_args < <(ppt_initdb_args_for "$oldbin")
	OLD_FILE_SETTINGS="$(ppt_old_file_settings "$oldbin")"
	ppt_temp_stop

	# 2. New, empty cluster with matching encoding/locale/checksums.
	mkdir -p "$stagedir"
	chmod 0700 "$stagedir"
	log "initdb ${initdb_args[*]}"
	"$newbin/initdb" -D "$stagedir" -U "$SU" --auth-local=trust --auth-host=scram-sha-256 "${initdb_args[@]}" >/tmp/ppt-initdb.log 2>&1 \
		|| { cat /tmp/ppt-initdb.log >&2; die "initdb failed"; }
	ppt_carry_over_config "$olddir" "$stagedir" "$newbin"

	# 3. pg_upgrade. It starts both servers itself, on the socket directory only.
	local link_arg=()
	[ "$mode" = link ] && link_arg=(--link)
	if ! (cd "$stagedir" && "$newbin/pg_upgrade" "${link_arg[@]}" -j "$(nproc)" \
			-b "$oldbin" -B "$newbin" -d "$olddir" -D "$stagedir" -U "$SU" \
			--socketdir /var/run/postgresql); then
		find "$stagedir/pg_upgrade_output.d" -name '*.log' -exec tail -n 40 {} + 2>/dev/null >&2 || true
		die "pg_upgrade failed (its output is above)"
	fi
	# The new cluster is the source of truth from here on: no rollback, ever.
	ROLLBACK_OLDDIR=''
	printf '%s %s\n' "$oldmajor" "$olddir" > "$stagedir/$UPGRADE_DONE"

	ppt_finish_upgrade "$oldmajor" "$olddir" "$stagedir"
	log "PostgreSQL ${oldmajor} -> ${PG_MAJOR} upgrade finished in $(( $(date +%s) - start_ts ))s; data directory is ${PGDATA}"
}

# --- main -----------------------------------------------------------------------------------

ppt_main() {
	if [ "${1:0:1}" = '-' ]; then
		set -- postgres "$@"
	fi
	if [ "$1" != 'postgres' ] || _pg_want_help "$@" || [ "${PPT_AUTO_UPGRADE:-on}" = off ]; then
		exec docker-entrypoint.sh "$@"
	fi

	docker_setup_env
	ppt_locate_cluster
	if [ -z "$CLUSTER_DIR" ]; then
		# Fresh volume: the official init path takes over (and stamps the directory via
		# /docker-entrypoint-initdb.d/9.ppt-stamp.sh).
		exec docker-entrypoint.sh "$@"
	fi

	if [ "$(id -u)" = '0' ]; then
		mkdir -p "$PGDATA" /var/run/postgresql
		chmod 03775 /var/run/postgresql || :
		local d own=("$PGDATA" /var/run/postgresql)
		for d in "$CLUSTER_DIR" "${PGDATA}${RELOCATE_STAGE_SUFFIX}"; do
			[ -e "$d" ] && own+=("$d")
		done
		find "${own[@]}" \! -user postgres -exec chown postgres '{}' +
		if [ "$UPGRADE_LAYOUT" = relocate ]; then
			# The parents (/var/lib/postgresql/17 and /18) must be writable too: one gets the
			# new cluster, the other is removed once the old one is gone.
			chown postgres "$(dirname "$PGDATA")" "$(dirname "$CLUSTER_DIR")" 2>/dev/null || :
		fi
		exec gosu postgres "${BASH_SOURCE[0]}" "$@"
	fi

	trap ppt_on_exit EXIT
	if [ "$CLUSTER_MAJOR" -gt "$PG_MAJOR" ]; then
		die "the data directory ${CLUSTER_DIR} is PostgreSQL ${CLUSTER_MAJOR}, this image is PostgreSQL ${PG_MAJOR} — downgrades are not possible, use a :${CLUSTER_MAJOR} tag of this image"
	elif [ "$CLUSTER_MAJOR" -lt "$PG_MAJOR" ]; then
		ppt_pg_upgrade
	else
		ppt_update_same_major
	fi
	trap - EXIT

	exec docker-entrypoint.sh "$@"
}

if ! _is_sourced; then
	ppt_main "$@"
fi
