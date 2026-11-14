#!/usr/bin/env bash
# Runs apply_plex_labels.py on ../data/plex_labels.csv (the output of
# get_plex_labels.sh). Paths are relative to this script.
# Needs PLEX_TOKEN (Plex token) and PLEX_URL (server address with scheme and port,
# e.g. http://192.0.2.10:32400). Optional: PLEX_LIBRARY (one library title; omit to search all show and movie libraries).
# Extra arguments pass through to apply_plex_labels.py: --dry-run, --library, --url, --log.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require python3

# apply_plex_labels.py creates a log file the normal user must own.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates files a normal user needs to own." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_CSV="${SCRIPT_DIR}/../data/plex_labels.csv"
LABEL_SCRIPT="${SCRIPT_DIR}/apply_plex_labels.py"

[[ -f "$LABEL_SCRIPT" ]] || { echo "ERROR: not found: $LABEL_SCRIPT" >&2; exit 1; }
[[ -f "$SRC_CSV" ]] || { echo "ERROR: not found: $SRC_CSV (run get_plex_labels.sh first)" >&2; exit 1; }
[[ -n "${PLEX_URL:-}" ]] || { echo "ERROR: set PLEX_URL to the Plex server address, e.g. http://192.0.2.10:32400" >&2; exit 1; }
[[ -n "${PLEX_TOKEN:-}" ]] || { echo "ERROR: set PLEX_TOKEN to your Plex token" >&2; exit 1; }

ARGS=()
if [[ -n "${PLEX_LIBRARY:-}" ]]; then
    ARGS+=(--library "$PLEX_LIBRARY")
fi

exec python3 "$LABEL_SCRIPT" "$SRC_CSV" ${ARGS[@]+"${ARGS[@]}"} "$@"
