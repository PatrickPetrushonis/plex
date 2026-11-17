#!/usr/bin/env bash
# media.sh: Runs a pipeline stage with the settings in config.sh.
#
# Usage: ./media.sh <encode|rename|ingest|release> [-n] [release options and items]
#   encode   Runs encode.sh on $INPUT_DIR.
#   rename   Runs rename.sh on $DOWNLOADS_INPUT_DIR, renaming the files into Plex naming.
#   ingest   Runs ingest.sh: waits for $DOWNLOADS_INPUT_DIR to settle, previews the rename,
#            renames for real only when the preview is clean, then moves each renamed
#            entry to $UNENCODED_DIR. Exits 2 and writes a review file when the preview
#            needs a decision.
#   release  Runs release.sh: moves held entries from $UNENCODED_DIR to $INPUT_DIR.
#            Everything after "release" goes to release.sh: -a (all), item names, and --
#            to end the options. With neither -a nor an item, it lists the held entries.
#   -n       Dry run: preview only, writes nothing and renames nothing. Run this first.
#   -h       Show this help
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
PASS_ARGS=()
MODE="LIVE"
END_OF_OPTIONS=0
while (( $# )); do
    arg="$1"; shift
    # After "release", every argument except -n and -h belongs to release.sh:
    # an item name is never read as a command, and "--" ends option parsing.
    if [[ "$COMMAND" == "release" ]]; then
        if (( END_OF_OPTIONS )); then
            PASS_ARGS+=("$arg")
            continue
        fi
        case "$arg" in
            -n) DRY_ARGS=(-n); MODE="DRY RUN" ;;
            -h|--help) usage ;;
            --) END_OF_OPTIONS=1; PASS_ARGS+=("$arg") ;;
            *) PASS_ARGS+=("$arg") ;;
        esac
        continue
    fi
    case "$arg" in
        -n) DRY_ARGS=(-n); MODE="DRY RUN" ;;
        -h|--help) usage ;;
        encode|rename|ingest|release)
            [[ -z "$COMMAND" ]] || { echo "ERROR: more than one command: $COMMAND, $arg" >&2; exit 1; }
            COMMAND="$arg" ;;
        *) echo "ERROR: unknown argument: $arg" >&2
           echo "Usage: $0 <encode|rename|ingest|release> [-n]" >&2
           exit 1 ;;
    esac
done
[[ -n "$COMMAND" ]] || { echo "Usage: $0 <encode|rename|ingest|release> [-n]" >&2; exit 1; }

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
    ingest)
        # Same -O as rename: ingest.sh keeps its lock, log and review file under
        # $DOWNLOADS_BASE, beside rename.sh's, never inside the directory it processes.
        ./ingest.sh ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} -w "$INGEST_SETTLE_SECONDS" -O "$DOWNLOADS_BASE" \
            "$DOWNLOADS_INPUT_DIR" "$UNENCODED_DIR"
        ;;
    release)
        # -O puts release logs beside encode.sh's in $OUTPUT_DIR/Logs.
        ./release.sh ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} -S "$UNENCODED_DIR" -D "$INPUT_DIR" \
            -O "$OUTPUT_DIR" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
        ;;
esac
