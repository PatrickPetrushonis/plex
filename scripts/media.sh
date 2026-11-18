#!/usr/bin/env bash
# media.sh: Runs a pipeline stage with the settings in config.sh.
#
# Usage: ./media.sh <encode|rename|ingest|release|archive> [-n] [release options and items]
#   encode   Runs media_encode.sh on $INPUT_DIR.
#   rename   Runs media_rename.sh on $DOWNLOADS_INPUT_DIR, renaming the files into Plex naming.
#   ingest   Runs media_ingest.sh: waits for $DOWNLOADS_INPUT_DIR to settle, previews the rename,
#            renames for real only when the preview is clean, then moves each renamed
#            entry to $UNENCODED_DIR. Exits 2 and writes a review file when the preview
#            needs a decision.
#   release  Runs media_release.sh: moves held entries from $UNENCODED_DIR to $INPUT_DIR.
#            Everything after "release" goes to media_release.sh: -a (all), item names, and --
#            to end the options. With neither -a nor an item, it lists the held entries.
#   archive  Runs media_archive.sh: moves the encoded files in $ARCHIVE_DIR to $NAS_ARCHIVE_DIR,
#            category by category, merging into the folders already there. Needs the share
#            mounted at $NAS_MOUNT. Exits 2 when a file collides or a top-level entry is not
#            a category folder on the NAS.
#   -n      Dry run: preview only, writes nothing and renames nothing. Run this first.
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
    # After "release", every argument except -n and -h belongs to media_release.sh:
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
        encode|rename|ingest|release|archive)
            [[ -z "$COMMAND" ]] || { echo "ERROR: more than one command: $COMMAND, $arg" >&2; exit 1; }
            COMMAND="$arg" ;;
        *) echo "ERROR: unknown argument: $arg" >&2
           echo "Usage: $0 <encode|rename|ingest|release|archive> [-n]" >&2
           exit 1 ;;
    esac
done
[[ -n "$COMMAND" ]] || { echo "Usage: $0 <encode|rename|ingest|release|archive> [-n]" >&2; exit 1; }

echo "[$MODE] media.sh $COMMAND"

case "$COMMAND" in
    encode)
        ./media_encode.sh ${ENCODER_ARGS[@]+"${ENCODER_ARGS[@]}"} ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} "$INPUT_DIR"
        ;;
    rename)
        # -O takes the base directory, not the log directory: media_rename.sh appends
        # /Logs and /.locks itself, giving $DOWNLOADS_BASE/Logs and $DOWNLOADS_BASE/.locks.
        ./media_rename.sh ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} -O "$DOWNLOADS_BASE" "$DOWNLOADS_INPUT_DIR"
        ;;
    ingest)
        # Same -O as rename: media_ingest.sh keeps its lock, log and review file under
        # $DOWNLOADS_BASE, beside media_rename.sh's, never inside the directory it processes.
        ./media_ingest.sh ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} -w "$INGEST_SETTLE_SECONDS" -O "$DOWNLOADS_BASE" \
            "$DOWNLOADS_INPUT_DIR" "$UNENCODED_DIR"
        ;;
    release)
        # -O puts release logs beside media_encode.sh's in $OUTPUT_DIR/Logs.
        ./media_release.sh ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} -S "$UNENCODED_DIR" -D "$INPUT_DIR" \
            -O "$OUTPUT_DIR" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
        ;;
    archive)
        # -O puts archive logs beside media_encode.sh's and media_release.sh's in $OUTPUT_DIR/Logs.
        ./media_archive.sh ${DRY_ARGS[@]+"${DRY_ARGS[@]}"} -m "$NAS_MOUNT" -w "$ARCHIVE_SETTLE_SECONDS" \
            -O "$OUTPUT_DIR" "$ARCHIVE_DIR" "$NAS_ARCHIVE_DIR"
        ;;
esac
