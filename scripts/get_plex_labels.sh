#!/usr/bin/env bash
# Runs get_plex_labels.py against ../data/plex_folders.csv (relative to this script,
# not the caller's directory) and writes ../data/plex_labels.csv.
# Matching uses the Plex IDs and titles the sync stage wrote into plex_folders.csv; to correct a
# folder, fix its match in Plex and sync again.
# Extra arguments pass through to get_plex_labels.py: --source, --dry-run, --force, --cache,
# --log, --no-tmdb, --no-idmap, --refresh-idmap, --idmap, --no-source-works,
# --check-source-route, --assess-genres.
# Source-work demographics need --source mal-api (and MAL_CLIENT_ID); TMDB needs TMDB_API_KEY.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require python3

# get_plex_labels.py creates a cache, log and output file the normal user must own.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates files a normal user needs to own." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
SRC_CSV="${DATA_DIR}/plex_folders.csv"
DST_CSV="${DATA_DIR}/plex_labels.csv"
LABEL_SCRIPT="${SCRIPT_DIR}/get_plex_labels.py"

[[ -f "$LABEL_SCRIPT" ]] || { echo "ERROR: not found: $LABEL_SCRIPT" >&2; exit 1; }
[[ -f "$SRC_CSV" ]] || { echo "ERROR: not found: $SRC_CSV" >&2; exit 1; }

exec python3 "$LABEL_SCRIPT" "$SRC_CSV" "$DST_CSV" "$@"