#!/usr/bin/env bash
# subtitle_embed_params.sh: Muxes a sidecar subtitle file (.srt, .vtt, .ass,
# .ssa, or a text .sub) into a video as a new
# subtitle stream, without re-encoding video or audio. This is
# encoder_params.sh's sidecar-embedding mechanism (subtitle_tag_strip.sh +
# subtitle_mux.sh), pulled out as its own tool for embedding a subtitle
# into an already-encoded file, outside of a full batch encode.
#
# Usage:  ./subtitle_embed_params.sh [OPTIONS] <video_input> [<srt_input>]
#
# Options:
#   -o PATH     Output file path (default: alongside input,
#               "<name>.subtitled.<ext>", same container as input)
#   -l LANGS    Comma-separated 3-letter language codes.
#               - With an explicit <srt_input>: single code, the language
#                 of that file (default: eng).
#               - Without <srt_input> (auto-discover mode): languages to
#                 look for as sidecars next to <video_input>, Plex-style
#                 (Movie.en.srt / Movie.en.cc.srt / Movie.en.forced.srt),
#                 same convention encoder_params.sh's -l uses (default: eng).
#   -t TYPE     Subtitle type for an explicit <srt_input> only: target, cc,
#               or forced (default: target). Ignored in auto-discover mode,
#               where type comes from each discovered file's own suffix.
#   -I DIR      Fallback resolution base: if <video_input> (or an explicit
#               <srt_input>) doesn't exist as given, try DIR/<path> before
#               failing. A path that already resolves is never rewritten.
#               Intended for a wrapper to pass a shared base directory
#               (e.g. config.sh's INPUT_DIR) as an explicit value.
#   -s          Skip (do not overwrite) if the output file already exists
#               (default: overwrite)
#   -n          Dry run: print the plan, write nothing
#   -h          Show this help
#
# Notes:
#   * Supports mkv and mp4 input/output only (the two subtitle_output_codec()
#     knows); any other container extension is rejected rather than guessed at
#   * Video and audio are copied untouched (-map 0:v -c:v copy, -map 0:a?
#     -c:a copy); each pre-existing subtitle stream is also copied, mapped
#     explicitly by its own absolute index rather than via a blanket "-map 0
#     -c copy" - ffmpeg treats a blanket copy plus the newly-embedded
#     track's own explicit codec override as a genuine multiple-codec-option
#     conflict on that output index, so every stream is enumerated
#     individually instead. Only the newly embedded track(s) are new.
#   * Every subrip-codec sidecar muxed in - explicit or auto-discovered - has
#     ASS override tags (e.g. {\an8}) stripped first via subtitle_tag_strip.sh;
#     the original file is never modified. ASS/SSA, WebVTT and MicroDVD
#     sidecars are not stripped: ASS keeps its tags as positioning (copied in
#     MKV, converted to mov_text in MP4); WebVTT and MicroDVD convert to srt
#     in MKV and mov_text in MP4
#   * A sidecar is embedded even when the video already has an embedded track
#     of the same language and type; both tracks are present in the output
#   * Output is written atomically (.tmp -> rename) so an interrupted run is
#     retry-safe; the output's subtitle stream count is probed against the
#     number of streams the command emitted before the rename, and a
#     mismatch rejects the output
#   * Locked per input file (canonical path), so two runs can't race on the
#     same video; runs against different videos are not blocked by each other

set -euo pipefail

# -- Bash version guard ---------------------------------------------------------
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require ffmpeg
require ffprobe
require flock
require sed
require iconv

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates an output file a normal user needs to own." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lang_table.sh
source "$SCRIPT_DIR/lang_table.sh"
declare -F canon_lang >/dev/null || {
    echo "ERROR: canon_lang is not defined; lang_table.sh is not the version this script requires" >&2
    exit 1
}
# shellcheck source=./subtitle_tag_strip.sh
source "$SCRIPT_DIR/subtitle_tag_strip.sh"
# shellcheck source=./subtitle_mux.sh
source "$SCRIPT_DIR/subtitle_mux.sh"

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

OUTPUT=""
SUB_LANGS="eng"
EXPLICIT_TYPE="target"
SKIP_EXISTING=0
DRY_RUN=0
BASE_DIR=""

while getopts ":o:l:t:I:snh" opt; do
    case $opt in
        o) OUTPUT="$OPTARG" ;;
        l) SUB_LANGS="$OPTARG" ;;
        t) EXPLICIT_TYPE="$OPTARG" ;;
        I) BASE_DIR="$OPTARG" ;;
        s) SKIP_EXISTING=1 ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 [OPTIONS] <video_input> [<srt_input>]" >&2
    echo "  Run $0 -h for full help." >&2
    exit 1
fi
INPUT="$1"
EXPLICIT_SRT="${2:-}"

# -I is a fallback resolution base, not a rewrite of what was given: if
# INPUT doesn't exist as a literal path (relative to cwd or absolute) but
# does exist under BASE_DIR, use that. A path that already resolves is
# never second-guessed. Lets a wrapper pass its own base directory (e.g.
# config.sh's INPUT_DIR) as an explicit CLI value instead of relying on
# process-environment inheritance, which "source config.sh; exec ..."
# does not provide - config.sh never exports its variables.
if [[ ! -f "$INPUT" && -n "$BASE_DIR" && -f "${BASE_DIR}/${INPUT}" ]]; then
    INPUT="${BASE_DIR}/${INPUT}"
fi

[[ -f "$INPUT" ]] || { echo "ERROR: input video not found: $INPUT" >&2; exit 1; }
if [[ -n "$EXPLICIT_SRT" ]]; then
    if [[ ! -f "$EXPLICIT_SRT" && -n "$BASE_DIR" && -f "${BASE_DIR}/${EXPLICIT_SRT}" ]]; then
        EXPLICIT_SRT="${BASE_DIR}/${EXPLICIT_SRT}"
    fi
    [[ -f "$EXPLICIT_SRT" ]] || { echo "ERROR: subtitle input not found: $EXPLICIT_SRT" >&2; exit 1; }
    EXPLICIT_CODEC="$(probe_sidecar_codec "$EXPLICIT_SRT")" || EXPLICIT_CODEC=""
    [[ " $SUBTITLE_MUX_CODECS " == *" $EXPLICIT_CODEC "* ]] || {
        echo "ERROR: unsupported subtitle codec '${EXPLICIT_CODEC:-unreadable}' in $EXPLICIT_SRT (supported: $SUBTITLE_MUX_CODECS)" >&2
        exit 1
    }
    iconv -f UTF-8 -t UTF-8 "$EXPLICIT_SRT" >/dev/null 2>&1 || {
        echo "ERROR: $EXPLICIT_SRT is not valid UTF-8; convert it first (iconv -f <source charset> -t UTF-8)" >&2
        exit 1
    }
    case "$EXPLICIT_TYPE" in
        target|cc|forced) ;;
        *) echo "ERROR: -t must be target, cc, or forced (got: $EXPLICIT_TYPE)" >&2; exit 1 ;;
    esac
fi

EXT="${INPUT##*.}"
OUT_FORMAT="${EXT,,}"
case "$OUT_FORMAT" in
    mkv|mp4) ;;
    *) echo "ERROR: unsupported container '.$EXT' - only .mkv and .mp4 are supported" >&2; exit 1 ;;
esac

[[ -z "$OUTPUT" ]] && OUTPUT="$(dirname "$INPUT")/$(basename "${INPUT%.*}").subtitled.${EXT}"
OUTPUT_TMP="$(dirname "$OUTPUT")/.$(basename "${OUTPUT%.*}").tmp.${EXT}"

if [[ -f "$OUTPUT" ]] && (( SKIP_EXISTING )); then
    echo "SKIP: output already exists (-s): $OUTPUT"
    exit 2
fi

# -- Concurrency lock (per input file, not per output dir - see
# Linux_Script_Style_Guide.md section 5: hash the canonical path, not the raw
# argument, so two different relative paths to the same file collide) -----
INPUT_REAL="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
LOCK_DIR="${TMPDIR:-/tmp}/subtitle_embed_locks"
mkdir -p -- "$LOCK_DIR"
LOCK_HASH="$(printf '%s' "$INPUT_REAL" | sha256sum | cut -d' ' -f1)"
LOCK_FILE="${LOCK_DIR}/${LOCK_HASH}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another embed run is already active against $INPUT" >&2
    exit 1
fi
trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT

if (( ! DRY_RUN )); then
    init_subtitle_tag_strip || exit 1
    trap 'rm -f "$LOCK_FILE" 2>/dev/null || true; cleanup_stripped_subs' EXIT
fi

CURRENT_TMP=""
# SIGINT/SIGTERM handler. Removes the in-progress .tmp output named by
# CURRENT_TMP, then exits 1 (the EXIT trap removes the lock and the
# stripped-subtitle scratch directory). SIG is the signal name in the message.
cleanup() {
    local SIG="$1"
    echo "" >&2
    echo "subtitle_embed_params.sh: caught $SIG, aborting." >&2
    [[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]] && rm -f -- "$CURRENT_TMP"
    exit 1
}
trap 'cleanup SIGINT'  INT
trap 'cleanup SIGTERM' TERM

# -- Collect the (LANG TYPE PATH) lines to embed -----------------------------
declare -a SRT_LINES=()
if [[ -n "$EXPLICIT_SRT" ]]; then
    SRT_LINES+=("${SUB_LANGS} ${EXPLICIT_TYPE} ${EXPLICIT_SRT}")
else
    while IFS= read -r line; do
        [[ -n "$line" ]] && SRT_LINES+=("$line")
    done < <(discover_sidecar_subs "$INPUT")
fi

if [[ ${#SRT_LINES[@]} -eq 0 ]]; then
    echo "No subtitle file to embed: no explicit srt given and no sidecar found next to $(basename "$INPUT") for language(s): $SUB_LANGS" >&2
    exit 1
fi

# -- Existing embedded subtitle streams: absolute indices, so new tracks
# are numbered starting after them rather than colliding with their own
# output indices --------------------------------------------------------------
declare -a EXISTING_SUB_ABS_IDX=()
while IFS= read -r idx; do
    [[ -n "$idx" ]] && EXISTING_SUB_ABS_IDX+=("$idx")
done < <(ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$INPUT")
EXISTING_SUB_COUNT=${#EXISTING_SUB_ABS_IDX[@]}

# -- Strip tags, build ffmpeg args -----------------------------------------
declare -a INPUT_ARGS=(-i "$INPUT")
declare -a EXTSUB_WITH_IDX=()
NEXT_INPUT_IDX=1
for LINE in "${SRT_LINES[@]}"; do
    read -r LINE_LANG LINE_TYPE LINE_PATH <<< "$LINE"
    MUX_PATH="$LINE_PATH"
    if ! sidecar_needs_tag_strip "$LINE_PATH"; then
        :
    elif (( DRY_RUN )); then
        echo " [DRY RUN] Would strip ASS override tags from: $(basename "$LINE_PATH")"
    elif strip_sidecar_sub "$LINE_PATH"; then
        MUX_PATH="$STRIPPED_SUB_PATH"
    else
        echo " WARNING: tag-strip failed for $(basename "$LINE_PATH"); embedding original (may still show {\\an8}-style text on screen)" >&2
    fi
    INPUT_ARGS+=(-i "$MUX_PATH")
    EXTSUB_WITH_IDX+=("${LINE_LANG} ${LINE_TYPE} ${NEXT_INPUT_IDX} ${MUX_PATH}")
    NEXT_INPUT_IDX=$(( NEXT_INPUT_IDX + 1 ))
done

declare -a FF_ARGS=("${INPUT_ARGS[@]}" -map 0:v -c:v copy -map 0:a? -c:a copy -map_metadata 0)
SUB_OUT_IDX=0
# Every pre-existing subtitle stream is mapped and given its own explicit
# -c:s:N copy, by absolute input index, rather than relying on a blanket
# "-map 0" plus a type-general "-c:s copy": ffmpeg treats that combination
# as a genuine multiple-codec-option conflict for any output index that
# also gets an explicit override below (it warns and picks one, but the
# ambiguity itself is worth avoiding in a tool meant for reliable batch
# use - matching encoder_params.sh's own approach of never using a blanket
# codec option, always enumerating per stream).
for ABS_IDX in "${EXISTING_SUB_ABS_IDX[@]+"${EXISTING_SUB_ABS_IDX[@]}"}"; do
    FF_ARGS+=(-map "0:${ABS_IDX}" "-c:s:${SUB_OUT_IDX}" copy)
    SUB_OUT_IDX=$(( SUB_OUT_IDX + 1 ))
done
build_external_subtitle_args FF_ARGS SUB_OUT_IDX "${EXTSUB_WITH_IDX[@]}"

echo ""
echo "Input:  $INPUT (existing embedded subtitle streams: $EXISTING_SUB_COUNT)"
echo "Output: $OUTPUT"
for LINE in "${SRT_LINES[@]}"; do
    read -r LINE_LANG LINE_TYPE LINE_PATH <<< "$LINE"
    echo "  + $(basename "$LINE_PATH")  [$LINE_LANG/$LINE_TYPE]"
done

if (( DRY_RUN )); then
    echo ""
    echo "[DRY RUN] ffmpeg ${FF_ARGS[*]} \"$OUTPUT_TMP\" && mv -> \"$OUTPUT\""
    exit 0
fi

echo ""
echo "Running ffmpeg..."
CURRENT_TMP="$OUTPUT_TMP"
# A stale .tmp from a run killed past this script's own cleanup would make
# ffmpeg prompt on stdin; it is this script's private scratch file, so it is
# removed up front and -y is passed as defense in depth.
rm -f -- "$OUTPUT_TMP"
if ffmpeg -y -hide_banner -loglevel warning -nostats "${FF_ARGS[@]}" "$OUTPUT_TMP"; then
    if [[ ! -s "$OUTPUT_TMP" ]]; then
        echo "ERROR: ffmpeg exited 0 but output is empty" >&2
        rm -f -- "$OUTPUT_TMP"
        CURRENT_TMP=""
        exit 1
    fi
    if ! verify_subtitle_count "$OUTPUT_TMP" "$SUB_OUT_IDX"; then
        echo "ERROR: output has ${SUB_COUNT_ACTUAL:-an unreadable number of} subtitle streams, expected $SUB_OUT_IDX; not promoted" >&2
        rm -f -- "$OUTPUT_TMP"
        CURRENT_TMP=""
        exit 1
    fi
    mv -- "$OUTPUT_TMP" "$OUTPUT"
    CURRENT_TMP=""
    echo "Done -> $OUTPUT"
else
    RC=$?
    echo "ERROR: ffmpeg exited $RC" >&2
    rm -f -- "$OUTPUT_TMP"
    CURRENT_TMP=""
    exit 1
fi
