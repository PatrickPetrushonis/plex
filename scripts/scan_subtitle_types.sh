#!/usr/bin/env bash
# scan_subtitle_types.sh: Inventories embedded subtitle tracks across a
# directory of video files, classified by whether the track's codec can
# carry leftover ASS override tags as literal text (e.g. "{\an8}" showing
# on screen) or not. Read-only: runs ffprobe only, never ffmpeg; never
# writes into the scanned directory.
#
# Usage: ./scan_subtitle_types.sh [OPTIONS] <dir>
#
# Options:
#   -r        Recurse into subdirectories
#   -e EXTS   Comma-separated video extensions to scan (default: VIDEO_EXTS
#             from video_exts.sh)
#   -o FILE   Also write a TSV report (file, stream index, codec, language,
#             class) to FILE; the stdout summary always prints regardless.
#             Refuses an existing FILE and, as root, any -o
#   -h        Show this help
#
# Classification (embedded subtitle streams only - sidecar .srt files are
# always TEXT_RISK by construction, see strip_subtitle_tags.py, so are not
# scanned here):
#   TEXT_RISK   codec is subrip or mov_text: plain text, can carry a
#               leftover ASS override tag as literal on-screen text.
#               encode.sh -S sidecar extracts it as a tag-stripped
#               sidecar; -S embed muxes a tag-stripped copy.
#   ASS_NATIVE  codec is ass or ssa: override tags here are genuine
#               positioning/styling, correctly rendered by an ASS-capable
#               player - never a stripping candidate.
#   BITMAP      codec is hdmv_pgs_subtitle, dvd_subtitle, or dvbsub:
#               image-based, no text tags possible.
#   OTHER       any other codec_name ffprobe reports.
#
# Run this before an encode.sh run to see which files have TEXT_RISK
# tracks. A TEXT_RISK track with a sidecar of the same language and type is not
# muxed: the sidecar replaces it (discover_sidecar_subs() in encode.sh).

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require ffprobe
require python3
require find
require grep
require sed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -r "${SCRIPT_DIR}/video_exts.sh" ]] || {
    echo "ERROR: video_exts.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
# shellcheck source=./video_exts.sh
source "${SCRIPT_DIR}/video_exts.sh"

PROBE_PY="${SCRIPT_DIR}/probe_streams.py"
[[ -r "$PROBE_PY" ]] || {
    echo "ERROR: probe_streams.py not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}

RECURSE=0
CUSTOM_EXTS=""
REPORT_FILE=""

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

while getopts ":re:o:h" opt; do
    case $opt in
        r) RECURSE=1 ;;
        e) CUSTOM_EXTS="$OPTARG" ;;
        o) REPORT_FILE="$OPTARG" ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ $# -eq 1 ]] || {
    echo "Usage: $0 [OPTIONS] <dir>" >&2
    echo "  Run $0 -h for full help." >&2
    exit 1
}
TARGET_DIR="$1"
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: not a directory: $TARGET_DIR" >&2; exit 1; }

# Checked before the scan starts: a report that cannot be written should not
# cost a full scan, and an existing file is never truncated.
if [[ -n "$REPORT_FILE" ]]; then
    if [[ $EUID -eq 0 ]]; then
        echo "ERROR: do not run this with sudo and -o, it creates a file a normal user needs to own." >&2
        exit 1
    fi
    [[ ! -e "$REPORT_FILE" ]] || { echo "ERROR: report file already exists: $REPORT_FILE" >&2; exit 1; }
fi

if [[ -n "$CUSTOM_EXTS" ]]; then
    VIDEO_EXT_REGEX="$(echo "$CUSTOM_EXTS" | tr ',' '|' | tr -d ' ')"
else
    VIDEO_EXT_REGEX="$VIDEO_EXTS"
fi

DEPTH_FLAG=()
(( RECURSE )) || DEPTH_FLAG=(-maxdepth 1)

declare -a ALL_FILES=()
while IFS= read -r -d '' f; do
    ALL_FILES+=("$f")
done < <(find "$TARGET_DIR" "${DEPTH_FLAG[@]}" -type f \
             -regextype posix-extended \
             -iregex ".*\.(${VIDEO_EXT_REGEX})" \
             -print0 | sort -z)

if [[ ${#ALL_FILES[@]} -eq 0 ]]; then
    echo "No video files found under: $TARGET_DIR"
    exit 0
fi

echo "Scanning ${#ALL_FILES[@]} video file(s) under: $TARGET_DIR"
echo ""

# Classifies embedded subtitle streams for one file via probe_streams.py.
# Prints "FILE<TAB>INDEX<TAB>CODEC<TAB>LANG<TAB>CLASS" lines, one per subtitle
# stream; nothing if the file has none. Sets no globals: the read loop that
# consumes the lines is the only reader.
probe_subtitle_types() {
    python3 "$PROBE_PY" scan "$1"
}

declare -A CLASS_COUNT=()
declare -a REPORT_LINES=()
FILES_WITH_TEXT_RISK=0
FILES_WITH_NO_SUBS=0

for f in "${ALL_FILES[@]}"; do
    # Reset per-file: must not leak a previous file's "had a risky track"
    # verdict into a file whose own probe finds nothing.
    has_risk=0
    has_any_sub=0
    while IFS=$'\t' read -r _f _idx _codec _lang _cls; do
        [[ -z "$_f" ]] && continue
        has_any_sub=1
        CLASS_COUNT[$_cls]=$(( ${CLASS_COUNT[$_cls]:-0} + 1 ))
        REPORT_LINES+=("${_f}"$'\t'"${_idx}"$'\t'"${_codec}"$'\t'"${_lang}"$'\t'"${_cls}")
        [[ "$_cls" == "TEXT_RISK" ]] && has_risk=1
    done < <(probe_subtitle_types "$f")
    (( has_risk )) && FILES_WITH_TEXT_RISK=$(( FILES_WITH_TEXT_RISK + 1 ))
    (( has_any_sub )) || FILES_WITH_NO_SUBS=$(( FILES_WITH_NO_SUBS + 1 ))
done

echo "-- Summary ------------------------------------------------------------"
for cls in TEXT_RISK ASS_NATIVE BITMAP OTHER; do
    echo "  ${cls}: ${CLASS_COUNT[$cls]:-0} stream(s)"
done
echo ""
echo "  Files with >=1 TEXT_RISK (subrip/mov_text) embedded track: ${FILES_WITH_TEXT_RISK} / ${#ALL_FILES[@]}"
echo "  Files with no embedded subtitle streams at all:            ${FILES_WITH_NO_SUBS} / ${#ALL_FILES[@]}"
echo "-------------------------------------------------------------------------"
echo "  Note: a file's sidecar subtitle of the same language and type replaces"
echo "  its embedded track in encode.sh."

if [[ -n "$REPORT_FILE" ]]; then
    {
        printf 'file\tstream_index\tcodec\tlanguage\tclass\n'
        printf '%s\n' "${REPORT_LINES[@]+"${REPORT_LINES[@]}"}"
    } > "$REPORT_FILE"
    echo ""
    echo "Report written to: $REPORT_FILE"
fi
