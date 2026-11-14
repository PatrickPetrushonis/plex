#!/usr/bin/env bash
# encoder.sh: Encodes $INPUT_DIR with the settings in config.sh.
#
# Usage: ./encoder.sh [-n]
#   -n    Dry run: preview only, writes nothing. Run this first.
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

echo "[$MODE] encoder.sh"

./encoder_params.sh ${ENCODER_ARGS[@]+"${ENCODER_ARGS[@]}"} ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} "$INPUT_DIR"
