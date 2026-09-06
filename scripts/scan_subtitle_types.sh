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
#   -e EXTS   Comma-separated video extensions to scan (default: same list
#             as encoder_params.sh's VIDEO_EXT_REGEX)
#   -o FILE   Also write a TSV report (file, stream index, codec, language,
#             class) to FILE; the stdout summary always prints regardless
#   -h        Show this help
#
# Classification (embedded subtitle streams only - sidecar .srt files are
# always TEXT_RISK by construction, see subtitle_tag_strip.sh, so are not
# scanned here):
#   TEXT_RISK   codec is subrip or mov_text: plain text, can carry a
#               leftover ASS override tag as literal on-screen text. Run
#               subtitle_extract_params.sh against a TEXT_RISK hit to turn
#               it into a tag-stripped sidecar.
#   ASS_NATIVE  codec is ass or ssa: override tags here are genuine
#               positioning/styling, correctly rendered by an ASS-capable
#               player - never a stripping candidate.
#   BITMAP      codec is hdmv_pgs_subtitle, dvd_subtitle, or dvbsub:
#               image-based, no text tags possible.
#   OTHER       any other codec_name ffprobe reports.
#
# Run this to find which files are worth running subtitle_extract_params.sh
# against: if TEXT_RISK count is 0 (or every hit is already covered by a
# sidecar .srt, which discover_sidecar_subs() in encoder_params.sh prefers
# over the embedded track anyway), there's nothing to extract.

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require ffprobe
require python3

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
    echo "Usage: $0 [OPTIONS] <dir>"
    echo "  Run $0 -h for full help."
    exit 1
}
TARGET_DIR="$1"
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: not a directory: $TARGET_DIR" >&2; exit 1; }

if [[ -n "$CUSTOM_EXTS" ]]; then
    VIDEO_EXT_REGEX="$(echo "$CUSTOM_EXTS" | tr ',' '|' | tr -d ' ')"
else
    # Same literal default as encoder_params.sh's VIDEO_EXT_REGEX. Kept as a
    # documented, hand-synced duplicate rather than pulled into a shared
    # module: this is a single constant string, not shared logic, and this
    # is the only other place that needs it. If the embedded-track
    # extraction work (see header) gets built, that will also need
    # encoder_params.sh's collect_files()/probe_file() shape and is the
    # point where extracting a real shared module (this constant plus the
    # file-collection and ffprobe-parsing logic) pays for itself - not
    # worth it for one string today.
    VIDEO_EXT_REGEX="mp4|mkv|avi|mov|ts|m4v|wmv|flv|webm|vob|ogv|3gp|mpg|mpeg|divx"
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

# Classifies embedded subtitle streams for one file via ffprobe. Prints
# "FILE<TAB>INDEX<TAB>CODEC<TAB>LANG<TAB>CLASS" lines, one per subtitle
# stream; nothing if the file has none. Unlike encoder_params.sh's
# probe_file(), this sets no globals and returns nothing but stdout - there
# is no downstream step in this script that needs the values to outlive the
# read loop that consumes them.
probe_subtitle_types() {
    local INPUT="$1"
    python3 - "$INPUT" << 'PYEOF'
import json, sys, subprocess

input_file = sys.argv[1]

result = subprocess.run(
    ['ffprobe', '-v', 'quiet', '-print_format', 'json', '-show_streams',
     '-select_streams', 's', input_file],
    capture_output=True, text=True
)
if result.returncode != 0:
    print(f"{input_file}\tERROR\tERROR\tERROR\tPROBE_FAILED:{result.stderr.strip()}")
    sys.exit(0)

try:
    streams = json.loads(result.stdout).get('streams', [])
except json.JSONDecodeError as e:
    print(f"{input_file}\tERROR\tERROR\tERROR\tPARSE_FAILED:{e}")
    sys.exit(0)

TEXT_RISK  = {'subrip', 'mov_text'}
ASS_NATIVE = {'ass', 'ssa'}
BITMAP     = {'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvbsub'}

for s in streams:
    idx   = s.get('index', 0)
    codec = s.get('codec_name', 'unknown')
    lang  = s.get('tags', {}).get('language', 'und')
    if codec in TEXT_RISK:
        cls = 'TEXT_RISK'
    elif codec in ASS_NATIVE:
        cls = 'ASS_NATIVE'
    elif codec in BITMAP:
        cls = 'BITMAP'
    else:
        cls = 'OTHER'
    print(f"{input_file}\t{idx}\t{codec}\t{lang}\t{cls}")
PYEOF
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
echo "  Note: a file's sidecar .srt (if any) already wins over its embedded"
echo "  track in encoder_params.sh - cross-check TEXT_RISK hits against your"
echo "  library's sidecar coverage before sizing the extraction-pass work."

if [[ -n "$REPORT_FILE" ]]; then
    {
        printf 'file\tstream_index\tcodec\tlanguage\tclass\n'
        printf '%s\n' "${REPORT_LINES[@]+"${REPORT_LINES[@]}"}"
    } > "$REPORT_FILE"
    echo ""
    echo "Report written to: $REPORT_FILE"
fi
