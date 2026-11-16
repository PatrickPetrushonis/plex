#!/usr/bin/env bash
# media.sh: Encodes $INPUT_DIR or renames $DOWNLOADS_INPUT_DIR, with the settings in config.sh.
#
# Usage: ./media.sh <encode|rename> [-n]
#   encode  Runs encode.sh on $INPUT_DIR.
#   rename  Runs rename.sh on $DOWNLOADS_INPUT_DIR, renaming the files into Plex naming.
#   -n      Dry run: preview only, writes nothing and renames nothing. Run this first.
#   -h      Show this help
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

COMMAND=""
DRY_ARGS=()
MODE="LIVE"
for arg in "$@"; do
    case "$arg" in
        -n) DRY_ARGS=(-n); MODE="DRY RUN" ;;
        -h|--help) usage ;;
        encode|rename)
            [[ -z "$COMMAND" ]] || { echo "ERROR: more than one command: $COMMAND, $arg" >&2; exit 1; }
            COMMAND="$arg" ;;
        *) echo "ERROR: unknown argument: $arg" >&2
           echo "Usage: $0 <encode|rename> [-n]" >&2
           exit 1 ;;
    esac
done
[[ -n "$COMMAND" ]] || { echo "Usage: $0 <encode|rename> [-n]" >&2; exit 1; }

echo "[$MODE] media.sh $COMMAND"

case "$COMMAND" in
    encode)
        ./encode.sh ${ENCODER_ARGS[@]+"${ENCODER_ARGS[@]}"} ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} "$INPUT_DIR"
        ;;
    rename)
        # -O takes the base directory, not the log directory: rename.sh appends
        # /Logs and /.locks itself, giving $DOWNLOADS_BASE/Logs and $DOWNLOADS_BASE/.locks.
        ./rename.sh ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} -O "$DOWNLOADS_BASE" "$DOWNLOADS_INPUT_DIR"
        ;;
esac
