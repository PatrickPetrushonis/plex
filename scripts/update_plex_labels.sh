#!/usr/bin/env bash
# Runs the whole label pipeline in order: sync_plex_folders.sh, get_plex_labels.sh,
# apply_plex_labels.sh. Paths are relative to this script, not the caller's directory.
#
# Needs MAL_CLIENT_ID, TMDB_API_KEY (not for --dry-run), PLEX_URL and PLEX_TOKEN;
# PLEX_LIBRARY is optional (see apply_plex_labels.sh). All are checked before stage 1.
#
# Usage: update_plex_labels.sh [--dry-run] [--check-source-route]
#   --dry-run             Every stage runs with --dry-run: nothing is looked up, written
#                         or changed (the folder sync only reports what it would add or remove). The apply stage reads the
#                         plex_labels.csv left by an earlier run, so it must exist.
#   --check-source-route  Passes --check-source-route to the labels stage.
#
# The run stops at the first stage that exits non-zero, so nothing is applied to Plex
# from a partial result. Exit code 2 from a stage means some lookups failed; re-run to
# retry only those (finished lookups are cached).
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require python3
require flock

# The stages create caches, logs and output files the normal user must own.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates files a normal user needs to own." >&2
    exit 1
fi

DRY_RUN=false
CHECK_ROUTE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --check-source-route) CHECK_ROUTE=true ;;
        *) echo "ERROR: unknown argument: $arg" >&2
           echo "Usage: ${0##*/} [--dry-run] [--check-source-route]" >&2
           exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
SYNC_SH="${SCRIPT_DIR}/sync_plex_folders.sh"
LABELS_SH="${SCRIPT_DIR}/get_plex_labels.sh"
APPLY_SH="${SCRIPT_DIR}/apply_plex_labels.sh"

for f in "$SYNC_SH" "$LABELS_SH" "$APPLY_SH"; do
    [[ -x "$f" ]] || { echo "ERROR: not found or not executable: $f" >&2; exit 1; }
done

missing=()
for var in MAL_CLIENT_ID PLEX_URL PLEX_TOKEN; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
done
if [[ "$DRY_RUN" == false && -z "${TMDB_API_KEY:-}" ]]; then
    missing+=("TMDB_API_KEY")
fi
if (( ${#missing[@]} )); then
    echo "ERROR: environment variable(s) not set: ${missing[*]}" >&2
    exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
    [[ -f "${DATA_DIR}/plex_labels.csv" ]] || { echo "ERROR: --dry-run needs ${DATA_DIR}/plex_labels.csv from an earlier run" >&2; exit 1; }
fi

# One pipeline at a time. The lock file is removed when the run ends.
LOCK="${SCRIPT_DIR}/.update_plex_labels.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "ERROR: another update_plex_labels.sh run is in progress (lock: $LOCK)" >&2
    exit 1
fi
trap 'rm -f "$LOCK"' EXIT

DRY_ARGS=()
[[ "$DRY_RUN" == true ]] && DRY_ARGS=(--dry-run)
LABELS_ARGS=(--source mal-api --force)
[[ "$CHECK_ROUTE" == true ]] && LABELS_ARGS+=(--check-source-route)

# stage NAME LAST COMMAND...: runs one stage. Exit 2 from a stage means it completed but
# some lookups or rows need attention (see its summary). For a stage before the last that
# stops the pipeline, so a partial result is never applied to Plex; for the last stage
# (LAST=true) the work is already done, so it is reported and the script exits 2 at the end.
NEEDS_ATTENTION=false
stage() {
    local name="$1" last="$2"; shift 2
    echo "==> ${name}"
    local rc=0
    "$@" || rc=$?
    if (( rc == 2 )) && [[ "$last" == true ]]; then
        echo "NOTE: ${name} completed with items needing attention (exit 2); see its summary." >&2
        NEEDS_ATTENTION=true
    elif (( rc == 2 )); then
        echo "STOPPED: ${name} completed with failed lookups (exit 2); later stages were not run, so no partial result is applied." >&2
        exit 2
    elif (( rc != 0 )); then
        echo "FAILED: ${name} (exit ${rc}); later stages were not run." >&2
        exit "$rc"
    fi
}

stage "Stage 1/3: sync folder list" false "$SYNC_SH" ${DRY_ARGS[@]+"${DRY_ARGS[@]}"}
stage "Stage 2/3: labels (MAL, then TMDB)" false "$LABELS_SH" "${LABELS_ARGS[@]}" ${DRY_ARGS[@]+"${DRY_ARGS[@]}"}
stage "Stage 3/3: apply to Plex" true "$APPLY_SH" ${DRY_ARGS[@]+"${DRY_ARGS[@]}"}
if [[ "$NEEDS_ATTENTION" == true ]]; then
    echo "==> Done, with items needing attention"
    exit 2
fi
echo "==> Done"