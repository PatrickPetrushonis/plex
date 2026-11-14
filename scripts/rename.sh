#!/usr/bin/env bash
# rename.sh: Renames the files under $DOWNLOADS_INPUT_DIR into Plex naming.
#
# Usage: ./rename.sh [-n]
#   -n    Dry run: preview only, nothing is renamed. Run this first.
#   -h    Show this help
#
# Prints [DRY RUN] or [LIVE] first, so a real run is never mistaken for a preview.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./config.sh
source ./config.sh

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

DRY_ARGS=()
MODE="LIVE"
while getopts ":nh" opt; do
    case $opt in
        n) DRY_ARGS=(-n); MODE="DRY RUN" ;;
        h) usage ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))
[[ $# -eq 0 ]] || { echo "Usage: $0 [-n]" >&2; exit 1; }

echo "[$MODE] rename.sh"

# -O takes the base directory, not the log directory: rename_params.sh appends
# /Logs and /.locks itself, giving $DOWNLOADS_BASE/Logs and $DOWNLOADS_BASE/.locks.
./rename_params.sh ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} -O "$DOWNLOADS_BASE" "$DOWNLOADS_INPUT_DIR"
