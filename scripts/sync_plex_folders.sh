#!/usr/bin/env bash
# Runs sync_plex_folders.py on ../data/plex_folders.csv (relative to this script, not the
# caller's directory): creates it on the first run, and afterwards adds the folders new to
# the Plex library and removes the ones no longer in it.
# Needs PLEX_TOKEN and PLEX_URL (server address with scheme and port, e.g.
# http://192.0.2.10:32400) unless --dir is passed. Optional: PLEX_LIBRARY (one library
# title; omit to list every show library).
# Extra arguments pass through to sync_plex_folders.py: --dry-run, --force, --dir,
# --library, --url, --log.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require python3

# sync_plex_folders.py creates a CSV and a log file the normal user must own.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates files a normal user needs to own." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
DST_CSV="${DATA_DIR}/plex_folders.csv"
SYNC_SCRIPT="${SCRIPT_DIR}/sync_plex_folders.py"

[[ -f "$SYNC_SCRIPT" ]] || { echo "ERROR: not found: $SYNC_SCRIPT" >&2; exit 1; }
mkdir -p -- "$DATA_DIR"

ARGS=()
if [[ -n "${PLEX_LIBRARY:-}" ]]; then
    ARGS+=(--library "$PLEX_LIBRARY")
fi

exec python3 "$SYNC_SCRIPT" "$DST_CSV" ${ARGS[@]+"${ARGS[@]}"} "$@"
