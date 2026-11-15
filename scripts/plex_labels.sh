#!/usr/bin/env bash
# Runs the Plex label pipeline, or one stage of it. Paths are relative to this script, not
# the caller's directory.
#
# Usage: plex_labels.sh [all] [-n|--dry-run] [--check-source-route] [-h]
#        plex_labels.sh sync|get|apply [ARGS...]
#
#   all (default)         Runs sync, get and apply in order.
#     -n, --dry-run         Every stage runs with --dry-run: nothing is looked up, written
#                           or changed (sync only reports what it would add or remove).
#                           The apply stage reads the plex_labels.csv left by an earlier
#                           run, so it must exist.
#     --check-source-route  Passes --check-source-route to the get stage.
#     Needs MAL_CLIENT_ID, TMDB_API_KEY (not for --dry-run), PLEX_URL and PLEX_TOKEN, all
#     checked before the sync stage; PLEX_LIBRARY is optional. The run stops at the first
#     stage that exits non-zero, so nothing is applied to Plex from a partial result.
#     Exit code 2 from sync or get means some lookups failed; re-run to retry only those
#     (finished lookups are cached). Exit code 2 from apply means the labels were applied
#     but some folders were not found in Plex or some rows were skipped.
#
#   sync                  Runs sync_plex_folders.py on ../data/plex_folders.csv: creates it
#                         on the first run, and afterwards adds the folders new to the Plex
#                         library and removes the ones no longer in it. Needs PLEX_TOKEN and
#                         PLEX_URL (server address with scheme and port, e.g.
#                         http://192.0.2.10:32400) unless --dir is passed. Optional:
#                         PLEX_LIBRARY (one library title; omit to list every show library).
#                         ARGS pass through: --dry-run, --force, --dir, --library, --url, --log.
#
#   get                   Runs get_plex_labels.py on ../data/plex_folders.csv and writes
#                         ../data/plex_labels.csv. Matching uses the Plex IDs and titles the
#                         sync stage wrote into plex_folders.csv; to correct a folder, fix its
#                         match in Plex and sync again. Source-work demographics need
#                         --source mal-api (and MAL_CLIENT_ID); TMDB needs TMDB_API_KEY.
#                         ARGS pass through: --source, --dry-run, --force, --cache, --log,
#                         --no-tmdb, --no-idmap, --refresh-idmap, --idmap, --no-source-works,
#                         --check-source-route, --assess-genres.
#
#   apply                 Runs apply_plex_labels.py on ../data/plex_labels.csv (the output of
#                         the get stage). Needs PLEX_TOKEN and PLEX_URL. Optional:
#                         PLEX_LIBRARY (one library title; omit to search all show and movie
#                         libraries). ARGS pass through: --dry-run, --library, --url, --log.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require python3

# The stages create caches, logs and output files the normal user must own.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates files a normal user needs to own." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
FOLDERS_CSV="${DATA_DIR}/plex_folders.csv"
LABELS_CSV="${DATA_DIR}/plex_labels.csv"
SYNC_PY="${SCRIPT_DIR}/sync_plex_folders.py"
LABELS_PY="${SCRIPT_DIR}/get_plex_labels.py"
APPLY_PY="${SCRIPT_DIR}/apply_plex_labels.py"

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

# Each run_* function checks its own inputs, then runs its Python script with ARGS.
run_sync() {
    [[ -f "$SYNC_PY" ]] || { echo "ERROR: not found: $SYNC_PY" >&2; exit 1; }
    mkdir -p -- "$DATA_DIR" || { echo "ERROR: cannot create $DATA_DIR" >&2; exit 1; }
    local args=()
    [[ -z "${PLEX_LIBRARY:-}" ]] || args+=(--library "$PLEX_LIBRARY")
    python3 "$SYNC_PY" "$FOLDERS_CSV" ${args[@]+"${args[@]}"} "$@"
}

run_get() {
    [[ -f "$LABELS_PY" ]] || { echo "ERROR: not found: $LABELS_PY" >&2; exit 1; }
    [[ -f "$FOLDERS_CSV" ]] || { echo "ERROR: not found: $FOLDERS_CSV (run '${0##*/} sync' first)" >&2; exit 1; }
    python3 "$LABELS_PY" "$FOLDERS_CSV" "$LABELS_CSV" "$@"
}

run_apply() {
    [[ -f "$APPLY_PY" ]] || { echo "ERROR: not found: $APPLY_PY" >&2; exit 1; }
    [[ -f "$LABELS_CSV" ]] || { echo "ERROR: not found: $LABELS_CSV (run '${0##*/} get' first)" >&2; exit 1; }
    [[ -n "${PLEX_URL:-}" ]] || { echo "ERROR: set PLEX_URL to the Plex server address, e.g. http://192.0.2.10:32400" >&2; exit 1; }
    [[ -n "${PLEX_TOKEN:-}" ]] || { echo "ERROR: set PLEX_TOKEN to your Plex token" >&2; exit 1; }
    local args=()
    [[ -z "${PLEX_LIBRARY:-}" ]] || args+=(--library "$PLEX_LIBRARY")
    python3 "$APPLY_PY" "$LABELS_CSV" ${args[@]+"${args[@]}"} "$@"
}

# stage NAME LAST COMMAND...: runs one stage in a subshell. Exit 2 from a stage means it
# completed but some lookups or rows need attention (see its summary). For a stage before
# the last that stops the pipeline, so a partial result is never applied to Plex; for the
# last stage (LAST=1) the work is already done, so it is reported and the run exits 2 at
# the end.
NEEDS_ATTENTION=0
stage() {
    local name="$1" last="$2"; shift 2
    echo "==> ${name}"
    local rc=0
    ( "$@" ) || rc=$?
    if (( rc == 2 )) && (( last )); then
        echo "NOTE: ${name} completed with items needing attention (exit 2); see its summary." >&2
        NEEDS_ATTENTION=1
    elif (( rc == 2 )); then
        echo "STOPPED: ${name} completed with failed lookups (exit 2); later stages were not run, so no partial result is applied." >&2
        exit 2
    elif (( rc != 0 )); then
        echo "FAILED: ${name} (exit ${rc}); later stages were not run." >&2
        exit "$rc"
    fi
}

run_all() {
    local dry_run=0 check_route=0 arg
    for arg in "$@"; do
        case "$arg" in
            -n|--dry-run) dry_run=1 ;;
            --check-source-route) check_route=1 ;;
            -h|--help) usage ;;
            *) echo "ERROR: unknown argument: $arg" >&2
               echo "Usage: ${0##*/} [all] [-n|--dry-run] [--check-source-route] [-h]" >&2
               echo "       ${0##*/} sync|get|apply [ARGS...]" >&2
               exit 1 ;;
        esac
    done

    require flock

    local missing=() var
    for var in MAL_CLIENT_ID PLEX_URL PLEX_TOKEN; do
        [[ -n "${!var:-}" ]] || missing+=("$var")
    done
    if (( ! dry_run )) && [[ -z "${TMDB_API_KEY:-}" ]]; then
        missing+=("TMDB_API_KEY")
    fi
    if (( ${#missing[@]} )); then
        echo "ERROR: environment variable(s) not set: ${missing[*]}" >&2
        exit 1
    fi
    if (( dry_run )) && [[ ! -f "$LABELS_CSV" ]]; then
        echo "ERROR: --dry-run needs $LABELS_CSV from an earlier run" >&2
        exit 1
    fi

    # One pipeline at a time. The lock file is removed when the run ends.
    LOCK="${SCRIPT_DIR}/.plex_labels.lock"
    exec 9>"$LOCK"
    if ! flock -n 9; then
        echo "ERROR: another ${0##*/} run is in progress (lock: $LOCK)" >&2
        exit 1
    fi
    trap 'rm -f -- "$LOCK"' EXIT

    local dry_args=() labels_args=(--source mal-api --force)
    (( dry_run )) && dry_args=(--dry-run)
    (( check_route )) && labels_args+=(--check-source-route)

    stage "Stage 1/3: sync folder list" 0 run_sync ${dry_args[@]+"${dry_args[@]}"}
    stage "Stage 2/3: get labels (MAL, then TMDB)" 0 run_get "${labels_args[@]}" ${dry_args[@]+"${dry_args[@]}"}
    stage "Stage 3/3: apply to Plex" 1 run_apply ${dry_args[@]+"${dry_args[@]}"}
    if (( NEEDS_ATTENTION )); then
        echo "==> Done, with items needing attention"
        exit 2
    fi
    echo "==> Done"
}

COMMAND="all"
case "${1:-}" in
    all|sync|get|apply) COMMAND="$1"; shift ;;
esac

case "$COMMAND" in
    sync)   run_sync "$@" ;;
    get)    run_get "$@" ;;
    apply)  run_apply "$@" ;;
    all)    run_all "$@" ;;
esac
