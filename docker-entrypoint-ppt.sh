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
# Knobs (environment):
#   PPT_AUTO_UPGRADE=off        skip all of this and behave exactly like the official image
#   PPT_KEEP_OLD_CLUSTER=1      after a major upgrade, keep the old cluster directory instead of
#                               deleting it (it cannot be started anymore after --link, it is
#                               only useful for forensics)
#   PPT_UPGRADE_MODE=copy       pg_upgrade in copy mode instead of --link (needs 2x the disk,
#                               but the old cluster stays startable with the old image)
set -Eeo pipefail

# The official entrypoint defines its functions and returns when sourced.
# shellcheck disable=SC1091
source /usr/local/bin/docker-entrypoint.sh
# PPT_UPGRADE_FROM_MAJORS="16 17": written by the Dockerfile, the majors with bundled binaries.
# shellcheck disable=SC1091
[ -f /etc/ppt-upgrade-from.env ] && source /etc/ppt-upgrade-from.env

STAMP_FILE=".ppt-versions"
STAMP="postgresql=${PG_MAJOR} postgis=${POSTGIS_VERSION} timescaledb=${TIMESCALEDB_VERSION}"

log()  { printf '%s ppt: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '%s ppt: WARNING: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { printf '%s ppt: ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

is_mountpoint() {
	mountpoint -q "$1" 2>/dev/null || awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo
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

	if ppt_has_cluster "$PGDATA"; then
		CLUSTER_DIR="$PGDATA"
	elif [ "$PGDATA" = "/var/lib/postgresql/$PG_MAJOR/docker" ]; then
		# Same candidates as the official entrypoint's docker_error_old_databases(), which would
		# otherwise refuse to start on top of them.
		local d
		for d in /var/lib/postgresql/data /var/lib/postgresql /var/lib/postgresql/*/docker; do
			if ppt_has_cluster "$d"; then
				CLUSTER_DIR="$d"
				break
			fi
		done
		if [ -n "$CLUSTER_DIR" ]; then
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
		if [ -s "$CLUSTER_DIR/PG_VERSION" ]; then
			CLUSTER_MAJOR="$(tr -d '[:space:]' < "$CLUSTER_DIR/PG_VERSION")"
		else
			# Interrupted in-place upgrade: the cluster was already moved into its subdirectory.
			local shuffled
			shuffled="$(echo "$CLUSTER_DIR"/pg[0-9]*_pre_upgrade)"
			CLUSTER_MAJOR="$(tr -d '[:space:]' < "$shuffled/PG_VERSION")"
		fi
	fi
}

# ppt_has_cluster DIR — a data directory, or one whose in-place upgrade was interrupted after
# the cluster had been moved into DIR/pg<major>_pre_upgrade (see ppt_pg_upgrade).
ppt_has_cluster() {
	[ -s "$1/PG_VERSION" ] && return 0
	local d
	for d in "$1"/pg[0-9]*_pre_upgrade; do
		[ -s "$d/PG_VERSION" ] && return 0
	done
	return 1
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
# to, noisily) while we are in the middle of updating it.
ppt_temp_start() {
	NOTIFY_SOCKET='' "$1/pg_ctl" -D "$2" -w -t 600 -s \
		-o "-c listen_addresses='' -c unix_socket_directories='/var/run/postgresql' -p ${PGPORT:-5432} -c timescaledb.max_background_workers=0" \
		start
}

ppt_temp_stop() {
	"$1/pg_ctl" -D "$2" -m fast -w -s stop
}

# ppt_psql BINDIR DBNAME SQL — one statement, fresh session, no psqlrc, no TimescaleDB
# auto-load unless the statement is the ALTER EXTENSION that needs it.
ppt_psql() {
	PGOPTIONS="${PGOPTIONS:-}" PGHOST=/var/run/postgresql PGPORT="${PGPORT:-5432}" \
		"$1/psql" -X -q -A -t -v ON_ERROR_STOP=1 -U "$SU" -d "$2" -c "$3"
}

# ppt_update_extensions BINDIR — ALTER EXTENSION ... UPDATE for every extension in every
# database that is behind the version this image ships. Each ALTER runs in its own session:
# TimescaleDB insists on being the first command of a fresh session (its loader swaps in the
# new shared library when it sees that statement), and PostGIS wants postgis before
# postgis_topology, which the ORDER BY handles.
ppt_update_extensions() {
	local bindir="$1" db ext have want
	local dbs
	dbs="$(PGOPTIONS='-c timescaledb.disable_load=on' ppt_psql "$bindir" postgres \
		"SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname")"
	for db in $dbs; do
		local pending
		pending="$(PGOPTIONS='-c timescaledb.disable_load=on' ppt_psql "$bindir" "$db" "
			SELECT e.extname || ' ' || e.extversion || ' ' || a.default_version
			  FROM pg_extension e JOIN pg_available_extensions a ON a.name = e.extname
			 WHERE a.default_version IS NOT NULL AND e.extversion <> a.default_version
			 ORDER BY CASE e.extname WHEN 'timescaledb' THEN 0 WHEN 'postgis' THEN 1 ELSE 2 END, e.extname")"
		[ -n "$pending" ] || continue
		while read -r ext have want; do
			[ -n "$ext" ] || continue
			if [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | tail -n 1)" = "$have" ]; then
				warn "database '${db}': extension ${ext} is at ${have}, newer than the ${want} this image ships — this image is OLDER than the one that last ran on this volume. Not touching it."
				continue
			fi
			log "database '${db}': ALTER EXTENSION ${ext} UPDATE (${have} -> ${want})"
			ppt_psql "$bindir" "$db" "ALTER EXTENSION \"${ext}\" UPDATE"
		done <<< "$pending"
	done
}

# --- same-major: extension updates ----------------------------------------------------------

ppt_update_same_major() {
	if [ -f "$PGDATA/$STAMP_FILE" ] && [ "$(cat "$PGDATA/$STAMP_FILE")" = "$STAMP" ]; then
		return 0
	fi
	log "data directory ${PGDATA} was last used by [$(cat "$PGDATA/$STAMP_FILE" 2>/dev/null || echo 'an unstamped image')], image is [${STAMP}] — checking extensions"
	local bindir="/usr/lib/postgresql/$PG_MAJOR/bin"
	ppt_clear_stale_lock "$PGDATA"
	SU="$(ppt_su_name "$PGDATA" "$bindir" || true)"
	[ -n "$SU" ] || die "could not determine the superuser of ${PGDATA} (see the log lines above)"
	ppt_temp_start "$bindir" "$PGDATA"
	# shellcheck disable=SC2064
	trap "ppt_temp_stop '$bindir' '$PGDATA' || true" EXIT
	ppt_update_extensions "$bindir"
	ppt_temp_stop "$bindir" "$PGDATA"
	trap - EXIT
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

# ppt_carry_over_config OLD NEW — the new cluster starts from this image's postgresql.conf
# (which has the right shared_preload_libraries/listen_addresses); every setting the old
# cluster had explicitly enabled is appended if the new server still knows it, and the old file
# is kept next to it for reference.
ppt_carry_over_config() {
	local old="$1" new="$2" newbin="$3" f key val carried=0 dropped=0
	for f in pg_hba.conf pg_ident.conf postgresql.auto.conf; do
		[ -f "$old/$f" ] && cp -p "$old/$f" "$new/$f"
	done
	[ -d "$old/conf.d" ] && cp -pr "$old/conf.d" "$new/conf.d"
	cp -p "$old/postgresql.conf" "$new/postgresql.conf.pg${CLUSTER_MAJOR}"
	# Active "key = value" lines of a postgresql.conf, normalised to "key=value".
	active_settings() {
		grep -E '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*=' "$1" \
			| sed -E 's/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/; s/[[:space:]]+#.*$//; s/[[:space:]]+$//'
	}
	local -A fresh=()
	while IFS='=' read -r key val; do fresh["$key"]="$val"; done < <(active_settings "$new/postgresql.conf")
	{
		printf '\n# --- settings carried over from the PostgreSQL %s data directory by the image upgrade ---\n' "$CLUSTER_MAJOR"
		while IFS='=' read -r key val; do
			case "$key" in
				shared_preload_libraries|listen_addresses|data_directory|hba_file|ident_file|external_pid_file) continue ;;
			esac
			# Same value as the fresh initdb'd conf (the stock docker settings, typically): nothing to carry.
			[ "${fresh[$key]+set}" ] && [ "${fresh[$key]}" = "$val" ] && continue
			if "$newbin/postgres" -C "$key" -D "$new" >/dev/null 2>&1; then
				printf '%s = %s\n' "$key" "$val"; carried=$((carried + 1))
			else
				printf '# dropped (unknown to PostgreSQL %s): %s = %s\n' "$PG_MAJOR" "$key" "$val"; dropped=$((dropped + 1))
			fi
		done < <(active_settings "$old/postgresql.conf")
	} >> "$new/postgresql.conf"
	log "postgresql.conf: ${carried} setting(s) carried over, ${dropped} dropped as unknown (old file kept as postgresql.conf.pg${CLUSTER_MAJOR})"
}

ppt_pg_upgrade() {
	local oldmajor="$CLUSTER_MAJOR"
	local oldbin="/usr/lib/postgresql/${oldmajor}/bin"
	local newbin="/usr/lib/postgresql/${PG_MAJOR}/bin"
	local mode="${PPT_UPGRADE_MODE:-link}"

	[ -x "$oldbin/pg_upgrade" ] || die "the data directory ${CLUSTER_DIR} is PostgreSQL ${oldmajor}, but this image only bundles upgrade binaries for PostgreSQL ${PPT_UPGRADE_FROM_MAJORS:-<none>} (TimescaleDB ${TIMESCALEDB_VERSION} is not available for ${oldmajor}). Upgrade with an intermediate image tag first, or dump with the old image and restore into this one."
	case "$mode" in link|copy) ;; *) die "PPT_UPGRADE_MODE must be link or copy, not '${mode}'" ;; esac

	local olddir newdir
	if [ "$UPGRADE_LAYOUT" = relocate ]; then
		olddir="$CLUSTER_DIR"
		newdir="$PGDATA"
	else
		# The cluster is at the root of the mounted volume: shuffle it into a subdirectory so
		# the new cluster can be built next to it, on the same filesystem (hard links).
		olddir="$PGDATA/pg${oldmajor}_pre_upgrade"
		newdir="$PGDATA/pg${PG_MAJOR}_upgraded"
		if [ -s "$olddir/PG_VERSION" ]; then
			log "resuming an interrupted PostgreSQL ${oldmajor} upgrade in ${PGDATA}"
		else
			mkdir -p "$olddir"
			local entry
			for entry in "$PGDATA"/* "$PGDATA"/.[!.]*; do
				[ -e "$entry" ] || continue
				case "$entry" in "$olddir"|"$newdir") continue ;; esac
				mv "$entry" "$olddir/"
			done
		fi
	fi
	chmod 0700 "$olddir"
	log "upgrading PostgreSQL ${oldmajor} cluster ${olddir} -> PostgreSQL ${PG_MAJOR} ${newdir} (pg_upgrade --${mode})"
	local start_ts
	start_ts="$(date +%s)"

	# Leftovers from an earlier failed attempt: a half-built new cluster is worthless, an old
	# cluster whose pg_control was renamed by pg_upgrade --link needs it back.
	if [ -d "$newdir" ] && [ ! -s "$newdir/$STAMP_FILE" ]; then
		rm -rf "$newdir"
	fi
	[ -f "$olddir/global/pg_control.old" ] && mv "$olddir/global/pg_control.old" "$olddir/global/pg_control"

	ppt_clear_stale_lock "$olddir"
	SU="$(ppt_su_name "$olddir" "$oldbin" || true)"
	[ -n "$SU" ] || die "could not determine the superuser of ${olddir} (see the log lines above)"
	log "bootstrap superuser is '${SU}'"

	# 1. Old cluster: clean shutdown (recovers from a crash if needed), extensions brought to
	#    the versions this image ships FOR THE OLD MAJOR — pg_upgrade needs both sides equal.
	ppt_temp_start "$oldbin" "$olddir"
	# shellcheck disable=SC2064
	trap "ppt_temp_stop '$oldbin' '$olddir' || true" EXIT
	ppt_update_extensions "$oldbin"
	local initdb_args=()
	mapfile -t initdb_args < <(ppt_initdb_args_for "$oldbin")
	ppt_temp_stop "$oldbin" "$olddir"
	trap - EXIT

	# 2. New, empty cluster with matching encoding/locale/checksums.
	mkdir -p "$newdir"
	chmod 0700 "$newdir"
	log "initdb ${initdb_args[*]}"
	"$newbin/initdb" -D "$newdir" -U "$SU" --auth-local=trust --auth-host=scram-sha-256 "${initdb_args[@]}" >/tmp/ppt-initdb.log 2>&1 \
		|| { cat /tmp/ppt-initdb.log >&2; die "initdb failed"; }
	ppt_carry_over_config "$olddir" "$newdir" "$newbin"

	# 3. pg_upgrade. It starts both servers itself, on the socket directory only.
	local link_arg=()
	[ "$mode" = link ] && link_arg=(--link)
	if ! (cd "$newdir" && "$newbin/pg_upgrade" "${link_arg[@]}" -j "$(nproc)" \
			-b "$oldbin" -B "$newbin" -d "$olddir" -D "$newdir" -U "$SU" \
			--socketdir /var/run/postgresql); then
		warn "pg_upgrade failed; its logs are in ${newdir}/pg_upgrade_output.d/"
		find "$newdir/pg_upgrade_output.d" -name '*.log' -exec tail -n 40 {} + 2>/dev/null >&2 || true
		if [ -f "$olddir/global/pg_control.old" ]; then
			mv "$olddir/global/pg_control.old" "$olddir/global/pg_control"
		fi
		die "the PostgreSQL ${oldmajor} cluster is untouched at ${olddir}; fix the reported problem and restart, or start it again with a PostgreSQL ${oldmajor} image"
	fi

	# 4. New cluster: make sure everything loads, refresh planner statistics, stamp it.
	ppt_temp_start "$newbin" "$newdir"
	# shellcheck disable=SC2064
	trap "ppt_temp_stop '$newbin' '$newdir' || true" EXIT
	ppt_update_extensions "$newbin"
	log "vacuumdb --all --analyze-in-stages"
	PGHOST=/var/run/postgresql "$newbin/vacuumdb" -U "$SU" --all --analyze-in-stages -q 2>&1 | grep -v '^Generating' || true
	ppt_temp_stop "$newbin" "$newdir"
	trap - EXIT
	echo "$STAMP" > "$newdir/$STAMP_FILE"
	rm -f "$newdir/delete_old_cluster.sh"

	# 5. Put the new cluster where the server expects it and retire the old one.
	if [ "$UPGRADE_LAYOUT" = inplace ]; then
		local entry
		for entry in "$newdir"/* "$newdir"/.[!.]*; do
			[ -e "$entry" ] || continue
			mv "$entry" "$PGDATA/"
		done
		rmdir "$newdir"
	fi
	if [ "${PPT_KEEP_OLD_CLUSTER:-0}" = 1 ]; then
		warn "old PostgreSQL ${oldmajor} cluster kept at ${olddir} (PPT_KEEP_OLD_CLUSTER=1); with --link it can no longer be started, delete it when done"
	elif rm -rf "$olddir" 2>/dev/null; then
		[ "$UPGRADE_LAYOUT" = relocate ] && rmdir "$(dirname "$olddir")" 2>/dev/null || true
	else
		warn "could not delete the old cluster at ${olddir} (permissions?); it is no longer usable, delete it by hand"
	fi
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
		find "$CLUSTER_DIR" "$PGDATA" /var/run/postgresql \! -user postgres -exec chown postgres '{}' +
		if [ "$UPGRADE_LAYOUT" = relocate ]; then
			# The parents (/var/lib/postgresql/17 and /18) must be writable too: one gets the
			# new cluster, the other is removed once the old one is gone.
			chown postgres "$(dirname "$PGDATA")" "$(dirname "$CLUSTER_DIR")" 2>/dev/null || :
		fi
		exec gosu postgres "${BASH_SOURCE[0]}" "$@"
	fi

	if [ "$CLUSTER_MAJOR" -gt "$PG_MAJOR" ]; then
		die "the data directory ${CLUSTER_DIR} is PostgreSQL ${CLUSTER_MAJOR}, this image is PostgreSQL ${PG_MAJOR} — downgrades are not possible, use a :${CLUSTER_MAJOR} tag of this image"
	elif [ "$CLUSTER_MAJOR" -lt "$PG_MAJOR" ]; then
		ppt_pg_upgrade
	else
		ppt_update_same_major
	fi

	exec docker-entrypoint.sh "$@"
}

if ! _is_sourced; then
	ppt_main "$@"
fi
