#!/usr/bin/env bash
# encoder_params.sh: Batch video encoder with stream-aware copy/transcode decisions
#
# Usage:  ./encoder_params.sh [OPTIONS] <input_file|dir|glob> [<input2> ...]
#
# Options:
#   -o DIR          Output directory (default: <script directory>/encoded)
#   -c INT          CRF quality, 0-51, lower = better (default: 18)
#   -p PRESET       x264 preset: ultrafast..veryslow (default: slow)
#   -b BITRATE      Audio fallback encode bitrate (default: 192k)
#   -H HEIGHT       Max output height in px; taller sources are scaled down (default: 1080)
#   -f FORMAT       Output container: mkv or mp4 (default: mkv)
#   -l LANGS        Comma-separated subtitle languages to keep, as primary 3-letter
#                   codes from lang_table.tsv (default: eng)
#   -a CODECS       Comma-separated audio codecs to copy without re-encode
#                   (default: aac,ac3,eac3,dts,truehd,flac,opus)
#   -e EXTS         Comma-separated input extensions to scan (default: see VIDEO_EXTS)
#   -L DIR          Log directory (default: OUTPUT_DIR/Logs)
#   -r              Recurse into subdirectories, mirroring folder structure in output
#   -F              Flat output: do not mirror directory structure (default when
#                   input is a file or glob; ignored for directory inputs unless set)
#   -n              Dry run: print decisions, do not encode
#   -s              Skip if output file already exists (default: overwrite)
#   -M PATH         After encode: cp output to this path (NAS/SMB mount), verify size, remove original
#   -A PATH         After encode: mv source input and its muxed sidecar subtitle files to this
#                   path, mirroring directory structure (flat by file name for file and glob inputs)
#   -S MODE         Subtitle delivery (default: @DEFAULT_SUB_MODE@): embed muxes subtitles into
#                   the output; sidecar extracts text subtitle tracks and writes input
#                   sidecars next to the output as Plex-named files (see Notes)
#   -d BYTES        Minimum free disk space before aborting, in bytes (default: 10737418240)
#   -P SIZE         ffmpeg -analyzeduration and -probesize value (default: 10M)
#   -h              Show this help
#
# Notes:
#   * Requires bash 4.0+, ffmpeg (built with the zscale and tonemap filters),
#     ffprobe, python3, flock, sed
#   * Video is copied if already h264, 8-bit 4:2:0, SDR (colour transfer not PQ or
#     HLG), and within MAX_HEIGHT; otherwise re-encoded to x264
#   * PQ and HLG sources are tone-mapped to SDR BT.709 and tagged bt709, since
#     libx264 writes the source's colour tags into the output unless they are
#     set explicitly (see README: HEVC and HDR sources)
#   * Each encoded file's video stream is probed before it is moved to its final
#     path; an output that still carries a PQ or HLG transfer is rejected, so
#     -M and -A never act on it
#   * Each encoded file's subtitle stream count is probed against the number of
#     streams the encoder emitted before it is moved to its final path; a
#     mismatch rejects the output, so -M and -A never act on it
#   * Audio streams are copied if their codec is in the copy list; otherwise -> aac
#   * Subtitles: only target languages included; Signs & Songs tracks excluded
#   * Subtitle codec is container-aware: srt/ass in MKV; mov_text in MP4 (subtitle_mux.sh)
#   * Sidecar subtitle files (<name>.<lang2>[.cc|.sdh|.forced].<ext>, ext in
#     srt vtt ass ssa sub, claimed by probed codec subrip/webvtt/ass/microdvd;
#     first ext in that order wins per language and type) are muxed. In MKV,
#     webvtt and microdvd convert to srt and ass is copied; in MP4 all become
#     mov_text. Subrip sidecars have leftover ASS override tags (e.g. {\an8})
#     stripped before muxing (subtitle_tag_strip.sh); ass is left untouched.
#     A sidecar replaces an embedded track of the same
#     language and the same type (standard, CC, forced); language codes are
#     compared after alias resolution and an untagged track counts as eng
#   * Subtitle-extension files next to a video that discovery does not embed
#     (.idx, .sup, .smi, a bitmap .sub, a lower-precedence duplicate format,
#     a language outside -l, an unrecognized modifier)
#     are reported as warnings, are not embedded, and stay where they are
#   * -S sidecar: embedded text tracks (subrip, mov_text, webvtt, microdvd, ass/ssa) in target
#     languages are extracted, and input sidecars are written, next to the output as
#     <output name>.<lang2>[.cc|.forced].<ext> (srt; ass for ASS/SSA; vtt for WebVTT), in
#     the same ffmpeg run that encodes the video. Extracted srt files have ASS override
#     tags stripped. Bitmap tracks (PGS, VobSub) stay embedded in MKV and are dropped in
#     MP4. Sidecars are promoted before the video, so an existing output video implies a
#     complete set; a failed video promote removes the sidecars already promoted. -M
#     copies the sidecars with the video. A second track with the same language and type,
#     and a track whose language has no 2-letter code, are dropped. Input sidecars are
#     written first, so they win a name collision. Existing sidecar files at the
#     destination are overwritten, as the video is (-s skips on the video only)
#   * -S embed: an embedded track that needs tag stripping is not handled here: run
#     subtitle_extract_params.sh first, and the sidecar it writes is picked up
#     on the next encode
#   * Output is written atomically (.tmp -> rename) so interrupted runs are retry-safe
#   * On SIGINT/SIGTERM: partial .tmp file is removed, summary written to log
#   * -M uses cp + size verify + rm (safe for cross-device/NAS destinations); a
#     failed archive leaves the output in place, skips -A for that file, and
#     counts the file as failed
#   * -A uses mv; source is only moved after a successful encode and archive. If
#     a sidecar move fails, the source video stays in place with its remaining
#     sidecars. A backup destination that already exists is never overwritten
#   * Both -M and -A mirror the same relative directory structure as the output
#   * HEVC sources are always re-encoded to x264 and logged with the source codec label;
#     the output can be larger than the source, and the post-encode size check
#     reports the change (see README: HEVC and HDR sources)
#   * Only one run may target a given -o OUTPUT_DIR at a time; a second run against
#     the same OUTPUT_DIR exits immediately instead of racing on shared .tmp/log files

set -euo pipefail

# -- Bash version guard ---------------------------------------------------------
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates output files a normal user needs to own." >&2
    exit 1
fi

# -- Defaults --------------------------------------------------------------------
OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/encoded"
CRF=18
PRESET="slow"
AUDIO_BITRATE="192k"
MAX_HEIGHT=1080
OUT_FORMAT="mkv"
SUB_LANGS="eng"
AUDIO_COPY_CODECS="aac,ac3,eac3,dts,truehd,flac,opus"
CUSTOM_EXTS=""
RECURSE=0
FLAT_OUTPUT=0
DRY_RUN=0
SKIP_EXISTING=0
LOG_DIR=""
DISK_WARN_BYTES=$(( 10 * 1024 * 1024 * 1024 ))  # 10 GB
PROBE_SIZE="10M"    # -P: analyzeduration / probesize passed to ffmpeg
ARCHIVE_DIR=""      # -M: cp output here after encode (cross-device safe)
BACKUP_DIR=""       # -A: mv source input here after encode
SUB_MODE_CHOICES=(embed sidecar)   # valid -S values
DEFAULT_SUB_MODE="embed"           # subtitle delivery when -S is not given: one of SUB_MODE_CHOICES
SUB_MODE="$DEFAULT_SUB_MODE"       # -S: set from the option, validated in validate_params

# Filter chain applied to PQ and HLG sources: linearize, convert primaries to
# BT.709, tone-map, then convert to the BT.709 transfer and matrix at 8-bit
# 4:2:0. Tuning this constant changes only the look of converted sources.
SDR_TONEMAP_CHAIN="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

# -- Counters ----------------------------------------------------------------------
ENCODE_OK=0
ENCODE_FAIL=0
ENCODE_SKIP=0
ENCODE_DRYRUN=0

# Set by verify_sdr_output(): 1 if the probed file carries a Dolby Vision
# configuration record, else 0.
OUTPUT_DOVI=0

# -- Usage -----------------------------------------------------------------------
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' \
        | sed "s/@DEFAULT_SUB_MODE@/${DEFAULT_SUB_MODE}/" || true
    exit 0
}

# -- Arg parsing -------------------------------------------------------------------
while getopts ":o:c:p:b:H:f:l:a:e:L:M:A:S:d:P:rFnsh" opt; do
    case $opt in
        o) OUTPUT_DIR="$OPTARG" ;;
        c) CRF="$OPTARG" ;;
        p) PRESET="$OPTARG" ;;
        b) AUDIO_BITRATE="$OPTARG" ;;
        H) MAX_HEIGHT="$OPTARG" ;;
        f) OUT_FORMAT="$OPTARG" ;;
        l) SUB_LANGS="$OPTARG" ;;
        a) AUDIO_COPY_CODECS="$OPTARG" ;;
        e) CUSTOM_EXTS="$OPTARG" ;;
        L) LOG_DIR="$OPTARG" ;;
        d) DISK_WARN_BYTES="$OPTARG" ;;
        P) PROBE_SIZE="$OPTARG" ;;
        M) ARCHIVE_DIR="$OPTARG" ;;
        A) BACKUP_DIR="$OPTARG" ;;
        S) SUB_MODE="$OPTARG" ;;
        r) RECURSE=1 ;;
        F) FLAT_OUTPUT=1 ;;
        n) DRY_RUN=1 ;;
        s) SKIP_EXISTING=1 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ $# -lt 1 ]] && {
    echo "Usage: $0 [OPTIONS] <input_file|dir|glob> ..."
    echo "  Run $0 -h for full help."
    exit 1
}

# -- Parameter validation -----------------------------------------------------------
validate_params() {
    local errors=0
    local -a _LANGS=()
    local lang

    if ! [[ "$CRF" =~ ^[0-9]+$ ]] || (( CRF > 51 )); then
        echo "ERROR: CRF must be an integer 0-51 (got: $CRF)" >&2
        (( errors++ )) || true
    fi

    local valid_presets="ultrafast superfast veryfast faster fast medium slow slower veryslow"
    if [[ ! " $valid_presets " == *" $PRESET "* ]]; then
        echo "ERROR: Invalid preset '$PRESET'. Valid: $valid_presets" >&2
        (( errors++ )) || true
    fi

    if [[ "$OUT_FORMAT" != "mkv" && "$OUT_FORMAT" != "mp4" ]]; then
        echo "ERROR: Format must be 'mkv' or 'mp4' (got: $OUT_FORMAT)" >&2
        (( errors++ )) || true
    fi

    local m valid_mode=0
    for m in "${SUB_MODE_CHOICES[@]}"; do
        [[ "$SUB_MODE" == "$m" ]] && valid_mode=1
    done
    if (( ! valid_mode )); then
        echo "ERROR: -S must be one of: ${SUB_MODE_CHOICES[*]} (got: $SUB_MODE)" >&2
        (( errors++ )) || true
    fi

    if ! [[ "$MAX_HEIGHT" =~ ^[0-9]+$ ]] || (( MAX_HEIGHT < 1 )); then
        echo "ERROR: MAX_HEIGHT must be a positive integer (got: $MAX_HEIGHT)" >&2
        (( errors++ )) || true
    fi

    if ! [[ "$DISK_WARN_BYTES" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Disk threshold (-d) must be a positive integer in bytes (got: $DISK_WARN_BYTES)" >&2
        (( errors++ )) || true
    fi

    IFS=',' read -ra _LANGS <<< "$SUB_LANGS"
    for lang in "${_LANGS[@]}"; do
        if ! [[ "$lang" =~ ^[a-zA-Z]{2,3}$ ]]; then
            echo "WARNING: Subtitle language '$lang' looks malformed (expected 2-3 alpha chars)" >&2
        fi
    done

    [[ $errors -eq 0 ]] || exit 1
}

validate_params

# -- Dependency check -----------------------------------------------------------------
require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require ffmpeg
require ffprobe
require python3
require flock
require sed
require iconv

# zscale (libzimg) and tonemap convert HDR sources to SDR; checked here so a
# batch fails before any work instead of on the first HDR file. The filter
# list is captured into a variable first: piping ffmpeg into `grep -q` under
# pipefail can report a false negative when grep exits before ffmpeg finishes
# writing.
FFMPEG_FILTERS="$(ffmpeg -hide_banner -filters 2>/dev/null)"
for _filter in zscale tonemap; do
    grep -qE " ${_filter} " <<< "$FFMPEG_FILTERS" || {
        echo "ERROR: ffmpeg lacks the '${_filter}' filter, required for HDR-to-SDR conversion" >&2
        exit 1
    }
done

# -- Directory and log setup -------------------------------------------------------
[[ -z "$LOG_DIR" ]] && LOG_DIR="$OUTPUT_DIR/Logs"
if (( ! DRY_RUN )); then
    mkdir -p -- "$OUTPUT_DIR" "$LOG_DIR"
fi

# -- Concurrency lock --------------------------------------------------------------
# Only one run may target a given OUTPUT_DIR at a time: two runs sharing it
# would race on the same deterministic .tmp output path per input file, and
# on the same Log_InProgress.txt. Exclusive, non-blocking.
# A dry run against an OUTPUT_DIR that does not exist yet has nothing to race
# on and creates nothing, so it takes no lock.
LOCK_FILE=""
if (( ! DRY_RUN )) || [[ -d "$OUTPUT_DIR" ]]; then
    LOCK_FILE="$OUTPUT_DIR/.media.lock"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "ERROR: another run is already active against $OUTPUT_DIR (lock: $LOCK_FILE)" >&2
        exit 1
    fi
fi
# Registered only after the lock is acquired, so a failed acquisition never
# deletes another process's lock file. Removes the lock file on any exit:
# normal completion, a `set -e` error, or SIGINT/SIGTERM (cleanup() calls
# `exit 1`, which still fires this trap; only SIGKILL skips it). Accepted
# race: a process that locks this path between this process finishing and
# this trap firing can have the file unlinked from under it; negligible for a
# single-user batch tool.
#
# Re-registered below, right after init_subtitle_tag_strip creates its temp
# directory, so each trap is added immediately after the state it undoes.
trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT

# A dry run writes no log: every log() call and the header block go to
# /dev/null.
if (( DRY_RUN )); then
    LOG_FILE_TEMP="/dev/null"
else
    LOG_FILE_TEMP="$OUTPUT_DIR/Log_InProgress.txt"
fi
if [[ -f "$LOG_FILE_TEMP" ]]; then
    # A leftover Log_InProgress.txt means the previous run failed or was
    # interrupted (a clean run always moves it to LOG_DIR before exiting).
    # Preserve it under LOG_DIR instead of letting the write below clobber it.
    PRIOR_LOG_STAMP="$(date -r "$LOG_FILE_TEMP" '+%Y-%m-%d_%H%M' 2>/dev/null || date '+%Y-%m-%d_%H%M')"
    PRIOR_LOG_DEST="$LOG_DIR/Log_FAILED_${PRIOR_LOG_STAMP}.txt"
    # Avoid collision if one already exists for that timestamp
    if [[ -f "$PRIOR_LOG_DEST" ]]; then
        PRIOR_LOG_DEST="$LOG_DIR/Log_FAILED_${PRIOR_LOG_STAMP}_$(date '+%s').txt"
    fi
    mv -- "$LOG_FILE_TEMP" "$PRIOR_LOG_DEST"
    echo "WARNING: found leftover $LOG_FILE_TEMP from a previous failed/interrupted run; preserved as $PRIOR_LOG_DEST" >&2
fi

{
    echo "encoder_params.sh Batch Processing Log: $(date)"
    echo "Output:  $OUTPUT_DIR"
    echo "Logs:    $LOG_DIR"
    [[ -n "$ARCHIVE_DIR" ]] && echo "Archive: $ARCHIVE_DIR"
    [[ -n "$BACKUP_DIR"  ]] && echo "Backup:  $BACKUP_DIR"
    printf 'Args:    %s\n' "$*"
    echo "------------------------------------------"
    echo " Settings"
    echo "  CRF:          $CRF"
    echo "  Preset:       $PRESET"
    echo "  Format:       $OUT_FORMAT"
    echo "  Max height:   ${MAX_HEIGHT}p"
    echo "  Sub langs:    $SUB_LANGS"
    echo "  Audio copy:   $AUDIO_COPY_CODECS"
    echo "  Probe size:   $PROBE_SIZE"
    echo "------------------------------------------"
} > "$LOG_FILE_TEMP"

SCRIPT_START=$(date +%s)

# -- Log helper --------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE_TEMP"; }

# -- Summary printer -----------------------------------------------------------------
print_summary() {
    local LABEL="${1:-Batch complete}"
    local TOTAL_DUR="${2:-0}"
    echo ""
    echo "------------------------------------------"
    echo " ${LABEL}"
    echo "  OK:        $ENCODE_OK"
    echo "  Skipped:   $ENCODE_SKIP"
    [[ $ENCODE_DRYRUN -gt 0 ]] && echo "  Previewed: $ENCODE_DRYRUN  (dry run: nothing written; re-run without -n to encode)"
    echo "  Failed:    $ENCODE_FAIL"
    [[ "$TOTAL_DUR" -gt 0 ]] && echo "  Runtime:   $(( TOTAL_DUR / 60 ))m $(( TOTAL_DUR % 60 ))s"
    echo " Output:  $OUTPUT_DIR"
    echo "------------------------------------------"
    {
        echo ""
        echo "------------------------------------------"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${LABEL}"
        echo "  OK:        $ENCODE_OK"
        echo "  Skipped:   $ENCODE_SKIP"
        [[ $ENCODE_DRYRUN -gt 0 ]] && echo "  Previewed: $ENCODE_DRYRUN  (dry run: nothing written)"
        echo "  Failed:    $ENCODE_FAIL"
        [[ "$TOTAL_DUR" -gt 0 ]] && echo "  Runtime:   $(( TOTAL_DUR / 60 ))m $(( TOTAL_DUR % 60 ))s"
        echo "------------------------------------------"
    } >> "$LOG_FILE_TEMP" 2>/dev/null || true
}

# -- Signal handling -----------------------------------------------------------------
CURRENT_TMP=""
CURRENT_STDERR_CAPTURE=""
CURRENT_FFMPEG_PID=""
# Sidecar .tmp files of the encode in progress (-S sidecar); the signal handler
# and discard_encode_artifacts() remove them.
declare -a CURRENT_SIDECAR_TMPS=()
# Set by build_subtitle_args() in -S sidecar mode: one "SRC_IDX CODEC TYPE LANG3"
# line per embedded text track to extract. process_file() resets it per file.
declare -a SIDECAR_EXTRACT_LINES=()

# SIGINT/SIGTERM handler. Stops the running ffmpeg, removes the partial .tmp
# output and the stderr capture, prints the summary labelled ABORTED, and exits
# 1 (which fires the EXIT trap that removes the lock and the stripped-subtitle
# scratch directory). SIG is the signal name used in the messages.
cleanup() {
    local SIG="$1"
    echo "" >&2
    echo "encoder_params.sh: caught $SIG, aborting." >&2
    if [[ -n "$CURRENT_FFMPEG_PID" ]]; then
        kill "$CURRENT_FFMPEG_PID" 2>/dev/null
        wait "$CURRENT_FFMPEG_PID" 2>/dev/null
        CURRENT_FFMPEG_PID=""
    fi
    if [[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]]; then
        echo "  Removing partial output: $CURRENT_TMP" >&2
        rm -f "$CURRENT_TMP"
    fi
    local _t
    for _t in "${CURRENT_SIDECAR_TMPS[@]+"${CURRENT_SIDECAR_TMPS[@]}"}"; do
        rm -f -- "$_t"
    done
    [[ -n "$CURRENT_STDERR_CAPTURE" && -f "$CURRENT_STDERR_CAPTURE" ]] && rm -f "$CURRENT_STDERR_CAPTURE"
    print_summary "ABORTED by $SIG"
    (( DRY_RUN )) || echo "Log retained at: $LOG_FILE_TEMP" >&2
    exit 1
}

trap 'cleanup SIGINT'  INT
trap 'cleanup SIGTERM' TERM

# -- Extension list ----------------------------------------------------------------
if [[ -n "$CUSTOM_EXTS" ]]; then
    VIDEO_EXT_REGEX="$(echo "$CUSTOM_EXTS" | tr ',' '|' | tr -d ' ')"
else
    VIDEO_EXT_REGEX="mp4|mkv|avi|mov|ts|m4v|wmv|flv|webm|vob|ogv|3gp|mpg|mpeg|divx"
fi

# -- File collection -----------------------------------------------------------------
declare -a ALL_FILES=()
declare -a ALL_ROOTS=()
FILE_NUM=0  # current file index, incremented in main loop

# Appends the video files named by TARGET to ALL_FILES, with ROOT appended to
# ALL_ROOTS at the same index. TARGET is a video file (kept if its extension
# is in VIDEO_EXT_REGEX), a directory (scanned, one level unless -r), or a glob
# pattern (expanded, each match handled as above). ROOT is the scanned
# directory for directory input and empty for file and glob input. Warns and
# adds nothing for a non-video file or a pattern that matches nothing.
collect_files() {
    local TARGET="$1"
    local ROOT="$2"
    local f m

    if [[ -f "$TARGET" ]]; then
        local EXT="${TARGET##*.}"
        if [[ "${EXT,,}" =~ ^(${VIDEO_EXT_REGEX})$ ]]; then
            ALL_FILES+=("$TARGET")
            ALL_ROOTS+=("$ROOT")
        else
            echo "WARNING: Skipping non-video file: $TARGET" >&2
        fi
    elif [[ -d "$TARGET" ]]; then
        local DEPTH_FLAG=()
        (( RECURSE )) || DEPTH_FLAG=(-maxdepth 1)
        while IFS= read -r -d '' f; do
            ALL_FILES+=("$f")
            ALL_ROOTS+=("$TARGET")
        done < <(find "$TARGET" ${DEPTH_FLAG[@]+"${DEPTH_FLAG[@]}"} -type f \
                     -regextype posix-extended \
                     -iregex ".*\.(${VIDEO_EXT_REGEX})" \
                     -print0 | sort -z)
    else
        shopt -s nullglob nocaseglob
        # shellcheck disable=SC2206  # intentional: $TARGET is a glob pattern, meant to word-split/expand here
        local -a MATCHES=($TARGET)
        shopt -u nullglob nocaseglob
        if [[ ${#MATCHES[@]} -eq 0 ]]; then
            echo "WARNING: No files matched: $TARGET" >&2
            return
        fi
        for m in "${MATCHES[@]}"; do
            collect_files "$m" "$ROOT"
        done
    fi
}

for ARG in "$@"; do
    if [[ -d "$ARG" ]]; then
        collect_files "$ARG" "${ARG%/}"
    else
        collect_files "$ARG" ""
    fi
done

if [[ ${#ALL_FILES[@]} -eq 0 ]]; then
    echo "No video files found."
    exit 1
fi

echo "Files to process: ${#ALL_FILES[@]}"
log "Files to process: ${#ALL_FILES[@]}"
[[ $DRY_RUN -eq 1 ]] && echo "[DRY RUN: no encoding will occur]"

# -- Disk space check -----------------------------------------------------------------
# Echoes the free space, in bytes, of the filesystem holding OUTPUT_DIR.
free_bytes() {
    df -Pk "$OUTPUT_DIR" | awk 'NR==2 {print $4 * 1024}'
}

# Returns 0 when free space is at least DISK_WARN_BYTES. Otherwise logs,
# prints the summary labelled "Batch aborted: disk space", and exits 1.
check_disk_space() {
    local available
    available=$(free_bytes)
    if (( available < DISK_WARN_BYTES )); then
        local available_gb
        available_gb=$(( available / 1024 / 1024 / 1024 ))
        local threshold_gb
        threshold_gb=$(( DISK_WARN_BYTES / 1024 / 1024 / 1024 ))
        echo "ERROR: Less than ${threshold_gb}GB free in $OUTPUT_DIR (${available_gb}GB available). Aborting." >&2
        log "ABORTED: insufficient disk space (${available_gb}GB free)"
        print_summary "Batch aborted: disk space"
        exit 1
    fi
}

# -- Compute output path ---------------------------------------------------------------
compute_output_path() {
    local INPUT="$1"
    local ROOT="$2"
    local BASENAME
    BASENAME="$(basename "${INPUT%.*}")"

    if [[ -z "$ROOT" ]] || (( FLAT_OUTPUT )); then
        echo "${OUTPUT_DIR}/${BASENAME}.${OUT_FORMAT}"
    else
        local REL_DIR
        REL_DIR="$(dirname "${INPUT#"${ROOT}"/}")"
        if [[ "$REL_DIR" == "." ]]; then
            echo "${OUTPUT_DIR}/${BASENAME}.${OUT_FORMAT}"
        else
            echo "${OUTPUT_DIR}/${REL_DIR}/${BASENAME}.${OUT_FORMAT}"
        fi
    fi
}

# -- Stream probe ------------------------------------------------------------------
# Prints one line per stream group for the caller to parse:
#   VIDEO <codec> <height> <fps> <label>
#   VIDEOFMT <pix_fmt>                       ("unknown" when the probe reports none)
#   VIDEOCOLOR <color_transfer> <has_dovi>   (transfer is "unknown" when untagged;
#                                             has_dovi is 1 if the video stream
#                                             carries a Dolby Vision configuration record)
#   AUDIO ... / SUB ...
#   ERROR <message>   (on probe failure)
probe_file() {
    local INPUT="$1"
    python3 - "$INPUT" "$SUB_LANGS" "$LANG_TABLE_TSV" << 'PYEOF'
import json, sys, subprocess

input_file    = sys.argv[1]
sub_langs     = set(sys.argv[2].split(','))
lang_table_tsv = sys.argv[3]

result = subprocess.run(
    ['ffprobe', '-v', 'quiet', '-print_format', 'json', '-show_streams', input_file],
    capture_output=True, text=True
)

if result.returncode != 0:
    print(f"ERROR ffprobe exited {result.returncode}: {result.stderr.strip()}")
    sys.exit(0)

try:
    streams = json.loads(result.stdout).get('streams', [])
except json.JSONDecodeError as e:
    print(f"ERROR failed to parse ffprobe output: {e}")
    sys.exit(0)

VIDEO_CODEC_NAMES = {
    'h264':        'H.264',
    'hevc':        'H.265',
    'mpeg2video':  'MPEG-2',
    'mpeg4':       'MPEG-4',
    'vp8':         'VP8',
    'vp9':         'VP9',
    'av1':         'AV1',
    'vc1':         'VC-1',
    'theora':      'Theora',
    'mjpeg':       'MJPEG',
    'prores':      'ProRes',
}

AUDIO_CODEC_NAMES = {
    'aac':         'AAC',
    'ac3':         'Dolby Digital',
    'eac3':        'Dolby Digital Plus',
    'dts':         'DTS',
    'truehd':      'TrueHD',
    'flac':        'FLAC',
    'opus':        'Opus',
    'mp3':         'MP3',
    'vorbis':      'Vorbis',
    'pcm_s16le':   'PCM',
    'pcm_s24le':   'PCM',
    'pcm_s32le':   'PCM',
}

def load_lang_names(tsv_path):
    """Reads the shared lang_table.tsv (also loaded by lang_table.sh for the
    bash side). Maps every code3 and every listed alias to its display label."""
    names = {}
    try:
        with open(tsv_path, encoding='utf-8') as f:
            for line in f:
                line = line.rstrip('\n')
                if not line or line.startswith('#'):
                    continue
                parts = line.split('\t')
                if len(parts) < 3:
                    continue
                code3, _code2, label = parts[0], parts[1], parts[2]
                aliases = parts[3].split(',') if len(parts) > 3 and parts[3] != '-' else []
                names[code3] = label
                for alias in aliases:
                    names[alias] = label
    except OSError as e:
        print(f"ERROR could not read lang_table_tsv ({tsv_path}): {e}", file=sys.stderr)
    return names

LANG_NAMES = load_lang_names(lang_table_tsv)

def lang_name(code):
    return LANG_NAMES.get(code.lower(), code.upper())

def match_lang(code):
    """und (untagged) tracks are treated as English for matching purposes."""
    return 'eng' if code == 'und' else code

video = [s for s in streams if s.get('codec_type') == 'video']
audio = [s for s in streams if s.get('codec_type') == 'audio']
subs  = [s for s in streams if s.get('codec_type') == 'subtitle']

if not video:
    print("ERROR no video stream found in file")
else:
    v = video[0]
    fps = v.get('r_frame_rate', '24/1')
    if fps in ('0/0', '0'):
        fps = '24/1'
    codec_raw   = v.get('codec_name', '')
    codec_label = VIDEO_CODEC_NAMES.get(codec_raw, codec_raw.upper())
    height      = v.get('height', 0)
    print(f"VIDEO {codec_raw} {height} {fps} {codec_label}")

    # Pixel format drives the copy/encode decision in build_video_args.
    print(f"VIDEOFMT {v.get('pix_fmt', 'unknown')}")

    # Colour transfer and Dolby Vision presence drive the HDR-to-SDR decision
    # in build_video_args; an untagged transfer is reported as "unknown".
    transfer = v.get('color_transfer', 'unknown')
    has_dovi = int(any(sd.get('side_data_type') == 'DOVI configuration record'
                       for sd in v.get('side_data_list', [])))
    print(f"VIDEOCOLOR {transfer} {has_dovi}")

CHANNEL_LAYOUTS = {
    'mono':            'Mono',
    'stereo':          'Stereo',
    '2.1':             '2.1',
    '3.0':             '3.0',
    '3.0(back)':       '3.0',
    'quad':            '4.0',
    'quad(side)':      '4.0',
    '4.0':             '4.0',
    '4.1':             '4.1',
    '5.0':             '5.0',
    '5.0(side)':       '5.0',
    '5.1':             '5.1',
    '5.1(side)':       '5.1',
    '6.0':             '6.0',
    '6.1':             '6.1',
    '7.0':             '7.0',
    '7.1':             '7.1',
    '7.1(wide)':       '7.1',
    '7.1(wide-side)':  '7.1',
    'hexagonal':       '6.0',
    'octagonal':       '8.0',
}

for s in audio:
    idx           = s.get('index', 0)
    codec         = s.get('codec_name', 'unknown')
    lang          = s.get('tags', {}).get('language', 'und')
    out_lang      = match_lang(lang)
    layout_raw    = s.get('channel_layout', '')
    channels      = s.get('channels', 0)
    codec_label   = AUDIO_CODEC_NAMES.get(codec, codec.upper())
    lang_label    = lang_name(out_lang)
    if layout_raw and layout_raw in CHANNEL_LAYOUTS:
        layout_label = CHANNEL_LAYOUTS[layout_raw]
    elif channels == 1:
        layout_label = 'Mono'
    elif channels == 2:
        layout_label = 'Stereo'
    elif channels > 0:
        layout_label = f"{channels}ch"
    else:
        layout_label = ''
    track_title = f"{codec_label} {lang_label} {layout_label}".strip()
    print(f"AUDIO {idx} {codec} {out_lang} {track_title}")

CC_TERMS = {'sdh', 'cc', 'hi', 'hearing impaired', 'closed caption', 'closed captions'}

for s in subs:
    idx        = s.get('index', 0)
    codec      = s.get('codec_name', 'unknown')
    lang       = s.get('tags', {}).get('language', 'und')
    src_title  = s.get('tags', {}).get('title', '')
    title_low  = src_title.lower()
    disp       = s.get('disposition', {})
    is_forced  = int(disp.get('forced', 0) == 1)
    is_hi      = int(disp.get('hearing_impaired', 0) == 1)
    is_target  = int(match_lang(lang) in sub_langs)
    is_signs   = int(any(w in title_low for w in ('sign', 'song')))
    is_cc      = int(is_hi or any(t in title_low for t in CC_TERMS))
    lang_label = lang_name(lang)
    print(f"SUB {idx} {codec} {lang} {is_target} {is_forced} {is_signs} {is_cc} {lang_label}")
PYEOF
}

# -- Sidecar subtitle support (Plex-style Movie.en.srt / Movie.en.cc.vtt) ----------
# LANG_TABLE, LANG_3TO2, LANG_LABEL_BASH, LANG_ALIASES, LANG_CANON and
# canon_lang() come from the shared lang_table.sh / lang_table.tsv (same
# directory), also the source the Python probe step's LANG_NAMES reads (see
# probe_file()).
# shellcheck source=./lang_table.sh
source "$(dirname "${BASH_SOURCE[0]}")/lang_table.sh"
declare -F canon_lang >/dev/null || {
    echo "ERROR: canon_lang is not defined; lang_table.sh is not the version this script requires" >&2
    exit 1
}

# subtitle_output_codec(), sidecar_output_codec(), probe_sidecar_codec(),
# sidecar_needs_tag_strip(), find_sidecar_file(), discover_sidecar_subs(),
# report_unclaimed_sidecars(), subtitle_track_type(), subtitle_track_key(),
# verify_subtitle_count() and build_external_subtitle_args() come from the shared subtitle_mux.sh (same
# directory), also used by subtitle_embed_params.sh, so the container-aware
# codec decision, the sidecar matching, and the sidecar-mux ffmpeg-arg logic
# exist in one place.
# shellcheck source=./subtitle_mux.sh
source "$(dirname "${BASH_SOURCE[0]}")/subtitle_mux.sh"

# TAG_STRIP_PATTERN, init_subtitle_tag_strip, cleanup_stripped_subs and
# strip_sidecar_sub come from the shared subtitle_tag_strip.sh (same
# directory), also used by subtitle_embed_params.sh and
# subtitle_extract_params.sh. This script strips sidecars only.
# shellcheck source=./subtitle_tag_strip.sh
source "$(dirname "${BASH_SOURCE[0]}")/subtitle_tag_strip.sh"

# Runs once, after the concurrency lock above is held, and only for a real
# run: a dry run prints decisions and touches nothing, so it must not create
# even a scratch temp directory. A failure here aborts the run the same way
# a missing dependency does (require()) rather than falling back to muxing
# unstripped sidecars silently.
if (( ! DRY_RUN )); then
    init_subtitle_tag_strip || exit 1
    # Re-registers the EXIT trap now that the temp directory exists (see the
    # lock's trap above).
    trap 'rm -f "$LOCK_FILE" 2>/dev/null || true; cleanup_stripped_subs' EXIT
fi

# Removes empty directories from the one holding $1 upward, stopping before
# STOP_AT and never removing a directory that sits directly inside STOP_AT
# (e.g. INPUT/Movies, one level under the scanned root passed to the script):
# only the per-title folders below that are candidates, so the PARENT of the
# current directory is checked against STOP_AT before attempting the rmdir.
# An empty STOP_AT (file and glob inputs have no scanned root) removes nothing.
cleanup_empty_dirs() {
    local DIR
    DIR="$(dirname "$1")"
    local STOP_AT="$2"

    [[ -n "$STOP_AT" ]] || return 0

    while [[ "$DIR" != "$STOP_AT" && "$DIR" != "/" && "$DIR" != "." ]]; do
        [[ "$(dirname "$DIR")" == "$STOP_AT" ]] && break
        rmdir "$DIR" 2>/dev/null || break
        DIR="$(dirname "$DIR")"
    done
}

# Copies SRC (an encoded output) to the same relative path under DEST_BASE,
# verifies the copy by byte size, then removes SRC. ROOT is accepted for call
# symmetry with backup_input() and is unused: the relative path is taken from
# OUTPUT_DIR. A destination that already exists is never overwritten. Returns
# 0 on success; returns 1 with SRC kept in place on any failure. In a dry run
# it prints the plan and returns 0 without touching disk.
archive_output() {
    local SRC="$1"
    local ROOT="$2"
    local DEST_BASE="$3"

    local REL="${SRC#"${OUTPUT_DIR}"/}"
    local DEST="${DEST_BASE}/${REL}"
    local DEST_DIR
    DEST_DIR="$(dirname "$DEST")"

    if (( DRY_RUN )); then
        echo " [DRY RUN] Would archive: $SRC -> $DEST"
        return 0
    fi
    if [[ -e "$DEST" ]]; then
        echo " WARNING: archive destination already exists, not overwriting: $DEST" >&2
        log "ARCHIVE FAILED (destination exists): $SRC"
        return 1
    fi

    echo " Archive -> $DEST"
    mkdir -p -- "$DEST_DIR" || {
        echo " WARNING: could not create archive directory: $DEST_DIR" >&2
        log "ARCHIVE FAILED (mkdir): $SRC"
        return 1
    }

    cp -- "$SRC" "$DEST" || {
        echo " WARNING: cp failed: $SRC -> $DEST" >&2
        log "ARCHIVE FAILED (cp): $SRC"
        return 1
    }

    local SRC_SIZE DEST_SIZE
    if ! SRC_SIZE=$(stat -c '%s' "$SRC" 2>/dev/null); then
        echo " WARNING: could not stat source for size verification: $SRC" >&2
        log "ARCHIVE FAILED (stat src): $SRC"
        return 1
    fi
    if ! DEST_SIZE=$(stat -c '%s' "$DEST" 2>/dev/null); then
        echo " WARNING: could not stat destination for size verification: $DEST" >&2
        log "ARCHIVE FAILED (stat dest): $SRC"
        return 1
    fi

    if [[ "$SRC_SIZE" != "$DEST_SIZE" ]]; then
        echo " WARNING: size mismatch after copy (src: ${SRC_SIZE}B, dest: ${DEST_SIZE}B); destination removed" >&2
        log "ARCHIVE FAILED (size mismatch): $SRC"
        rm -f "$DEST"
        return 1
    fi

    rm -- "$SRC" || {
        echo " WARNING: archive copy verified but could not remove source: $SRC" >&2
        log "ARCHIVE WARNING (rm failed): $SRC"
        return 1
    }

    cleanup_empty_dirs "$SRC" "$OUTPUT_DIR"
    echo " Archive OK"
    log "ARCHIVED: $(basename "$SRC")"
}

# Moves SRC under DEST_BASE, mirroring its path relative to ROOT (flat by file
# name when ROOT is empty). Refuses to overwrite an existing destination.
# LABEL ("" or " (sidecar)") is appended to messages. Returns 0 on success, 1
# on any failure; every failure is logged.
move_into_backup() {
    local SRC="$1" ROOT="$2" DEST_BASE="$3" LABEL="$4"
    local REL DEST DEST_DIR

    if [[ -n "$ROOT" ]]; then
        REL="${SRC#"${ROOT}"/}"
    else
        REL="$(basename "$SRC")"
    fi
    DEST="${DEST_BASE}/${REL}"
    DEST_DIR="$(dirname "$DEST")"

    if [[ -e "$DEST" ]]; then
        echo " WARNING: backup destination already exists, not overwriting${LABEL}: $DEST" >&2
        log "BACKUP FAILED (destination exists)${LABEL}: $SRC"
        return 1
    fi
    if (( DRY_RUN )); then
        echo " [DRY RUN] Would move${LABEL}: $SRC -> $DEST"
        return 0
    fi
    mkdir -p -- "$DEST_DIR" || {
        echo " WARNING: could not create backup directory${LABEL}: $DEST_DIR" >&2
        log "BACKUP FAILED (mkdir)${LABEL}: $SRC"
        return 1
    }
    mv -- "$SRC" "$DEST" || {
        echo " WARNING: mv failed${LABEL}: $SRC -> $DEST" >&2
        log "BACKUP FAILED (mv)${LABEL}: $SRC"
        return 1
    }

    echo " Backup  -> ${DEST}${LABEL}"
    log "BACKED UP: $(basename "$SRC")${LABEL}"
}

# Moves the source video into the backup tree, then removes the per-title
# directories it emptied.
backup_input() {
    local SRC="$1"
    local ROOT="$2"
    local DEST_BASE="$3"

    move_into_backup "$SRC" "$ROOT" "$DEST_BASE" "" || return 1
    cleanup_empty_dirs "$SRC" "$ROOT"
}

# Moves each sidecar subtitle file that was muxed into the output to BACKUP_DIR,
# mirrored relative to ROOT the same way backup_input() moves the source
# video, so the backup tree keeps a video and its sidecar subs together.
# Moves the ORIGINAL sidecar file, not the stripped mux copy used to feed
# ffmpeg (that copy lives under subtitle_tag_strip.sh's temp dir and is
# swept by cleanup_stripped_subs, not backed up).
# Called only after a successful encode with -A set. Takes ROOT and
# DEST_BASE as its last two args; preceding args are "LANG TYPE PATH" lines
# from discover_sidecar_subs (may be zero of them). Returns 1 if any sidecar
# failed to move.
backup_sidecar_subs() {
    local ROOT="${*: -2:1}"
    local DEST_BASE="${*: -1}"
    local -a LINES=()
    if [[ $# -gt 2 ]]; then
        LINES=("${@:1:$#-2}")
    fi

    local FAILED=0 line _lang _type SIDECAR_SRC
    for line in "${LINES[@]+"${LINES[@]}"}"; do
        read -r _lang _type SIDECAR_SRC <<< "$line"
        move_into_backup "$SIDECAR_SRC" "$ROOT" "$DEST_BASE" " (sidecar)" || FAILED=1
    done
    return "$FAILED"
}

# -- is_hdr_transfer ---------------------------------------------------------------
# Returns 0 if the given colour transfer name is an HDR curve (PQ or HLG),
# 1 otherwise. The transfer function, not the primaries, defines HDR: BT.2020
# primaries describe gamut and can accompany an SDR curve.
is_hdr_transfer() {
    [[ "$1" == "smpte2084" || "$1" == "arib-std-b67" ]]
}

# -- build_video_args ---------------------------------------------------------------
# Appends the video-stream ffmpeg args to the array named by $1.
# Args: array name, source codec, source height, source fps, source colour
# transfer, source Dolby Vision flag (0/1), source pixel format.
# Copy path: h264, within MAX_HEIGHT, not PQ/HLG, and 8-bit 4:2:0 (yuv420p or
# yuvj420p; an unreported pixel format is treated as eligible).
# Encode path: everything else; PQ/HLG sources are tone-mapped to SDR and
# tagged bt709, because libx264 writes the source's colour tags into the output
# header unless they are set explicitly.
build_video_args() {
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _FF="$1"
    local VID_CODEC="$2" SRC_HEIGHT="$3" SRC_FPS="$4" SRC_TRANSFER="$5" SRC_DOVI="$6" SRC_PIXFMT="$7"
    local OUT_HEIGHT VID_TITLE ENCODE_DESC
    local NEEDS_SDR=0 NEEDS_FMT=0
    local -a VF=()

    if is_hdr_transfer "$SRC_TRANSFER"; then
        NEEDS_SDR=1
    fi
    case "$SRC_PIXFMT" in
        yuv420p|yuvj420p|unknown) ;;
        *) NEEDS_FMT=1 ;;
    esac
    if (( SRC_DOVI )); then
        echo " WARNING: source carries a Dolby Vision configuration record" >&2
    fi

    if [[ "$VID_CODEC" == "h264" ]] && (( SRC_HEIGHT <= MAX_HEIGHT )) && (( ! NEEDS_SDR )) && (( ! NEEDS_FMT )); then
        echo " Video: COPY (already h264, SDR, 8-bit 4:2:0, within ${MAX_HEIGHT}p)"
        _FF+=(-map 0:v:0 -c:v copy)
        VID_TITLE="H.264 ${SRC_HEIGHT}p"
    else
        _FF+=(-map 0:v:0)
        if [[ "$VID_CODEC" == "hevc" ]]; then
            echo " WARNING: source is HEVC: the x264 re-encode can be larger than the source; the post-encode size check reports the change (see README: HEVC and HDR sources)." >&2
        fi
        if (( SRC_HEIGHT > MAX_HEIGHT )); then
            OUT_HEIGHT=$MAX_HEIGHT
            ENCODE_DESC="x264 @ ${OUT_HEIGHT}p (source: ${SRC_HEIGHT}p)"
            # -2 derives an even width from the source aspect ratio.
            VF+=("scale=-2:${OUT_HEIGHT}")
        else
            OUT_HEIGHT=$SRC_HEIGHT
            ENCODE_DESC="x264 @ native ${OUT_HEIGHT}p (source codec: $VID_CODEC)"
        fi
        if (( NEEDS_FMT )); then
            ENCODE_DESC+=", pixel format $SRC_PIXFMT converted to yuv420p"
        fi
        if (( NEEDS_SDR )); then
            ENCODE_DESC+=", HDR ($SRC_TRANSFER) tone-mapped to SDR BT.709"
            VF+=("$SDR_TONEMAP_CHAIN")
        fi
        echo " Video: ENCODE -> $ENCODE_DESC"

        if (( ${#VF[@]} > 0 )); then
            local VF_JOINED
            VF_JOINED="$(IFS=,; echo "${VF[*]}")"
            _FF+=(-vf "$VF_JOINED")
        fi
        _FF+=(
            -c:v libx264
            -crf "$CRF"
            -preset "$PRESET"
            -r "$SRC_FPS"
            -pix_fmt yuv420p
            -profile:v high
            -level:v 4.1
        )
        # Explicit tags: without them libx264 carries the source's tags over.
        if (( NEEDS_SDR )); then
            _FF+=(-color_primaries bt709 -color_trc bt709 -colorspace bt709)
        fi
        VID_TITLE="H.264 ${OUT_HEIGHT}p"
    fi
    _FF+=(-metadata:s:v:0 "title=${VID_TITLE}")
}

# -- build_audio_args ---------------------------------------------------------------
build_audio_args() {
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _FF="$1"
    shift
    local -a AUDIO_LINES=("$@")
    local -a _CODECS=()
    local c line

    if [[ ${#AUDIO_LINES[@]} -eq 0 ]]; then
        echo " Audio: no streams found in source"
        return
    fi

    local -A COPY_SET=()
    IFS=',' read -ra _CODECS <<< "$AUDIO_COPY_CODECS"
    for c in "${_CODECS[@]}"; do COPY_SET["$c"]=1; done

    local OUT_AUDIO_IDX=0
    for line in "${AUDIO_LINES[@]}"; do
        local _ SRC_IDX ACODEC AUDIO_LANG AUDIO_TITLE
        read -r _ SRC_IDX ACODEC AUDIO_LANG AUDIO_TITLE <<< "$line"
        _FF+=(-map "0:${SRC_IDX}")
        if [[ -n "${COPY_SET[$ACODEC]+_}" ]]; then
            echo " Audio[src:$SRC_IDX -> out:$OUT_AUDIO_IDX]: COPY ($ACODEC / $AUDIO_LANG)"
            _FF+=("-c:a:${OUT_AUDIO_IDX}" copy)
        else
            echo " Audio[src:$SRC_IDX -> out:$OUT_AUDIO_IDX]: ENCODE -> aac @ ${AUDIO_BITRATE} (source: $ACODEC / $AUDIO_LANG)"
            _FF+=("-c:a:${OUT_AUDIO_IDX}" aac "-b:a:${OUT_AUDIO_IDX}" "$AUDIO_BITRATE")
            AUDIO_TITLE="AAC ${AUDIO_TITLE#* }"  # replace codec, keep language + layout
        fi
        _FF+=("-metadata:s:a:${OUT_AUDIO_IDX}" "language=${AUDIO_LANG}")
        _FF+=("-metadata:s:a:${OUT_AUDIO_IDX}" "title=${AUDIO_TITLE}")
        OUT_AUDIO_IDX=$(( OUT_AUDIO_IDX + 1 ))
    done
}

# -- build_subtitle_args -------------------------------------------------------------
# Selects embedded subtitle tracks. In -S embed mode each kept track becomes an
# embedded stream in the output. In -S sidecar mode a kept track that has a text
# sidecar form (see sidecar_output_spec) is appended to SIDECAR_EXTRACT_LINES as
# "SRC_IDX CODEC TYPE LANG3" and written as a file by build_sidecar_outputs();
# bitmap tracks stay embedded. This function does not strip ASS override tags
# (e.g. {\an8}): -S sidecar strips the extracted srt files, and in -S embed mode
# subtitle_extract_params.sh writes a stripped sidecar that discover_sidecar_subs()
# finds on the next encode.
# A second standard (non-CC, non-forced) embedded track of the same primary
# language is dropped; the language is compared after alias resolution.
build_subtitle_args() {
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _FF="$1"
    local -n _OUT_IDX="$2"
    shift 2
    local -a SUB_LINES=("$@")
    local line

    local -A _LANG_COUNT=()

    for line in "${SUB_LINES[@]+"${SUB_LINES[@]}"}"; do
        local _ SRC_IDX SUB_CODEC SUB_LANG IS_TARGET IS_FORCED IS_SIGNS IS_CC LANG_LABEL
        read -r _ SRC_IDX SUB_CODEC SUB_LANG IS_TARGET IS_FORCED IS_SIGNS IS_CC LANG_LABEL <<< "$line"

        if [[ "$IS_TARGET" == "0" ]]; then
            echo " Subtitle[src:$SRC_IDX]: SKIP ($SUB_LANG, not in target languages)"
            continue
        fi
        if [[ "$IS_SIGNS" == "1" ]]; then
            echo " Subtitle[src:$SRC_IDX]: SKIP ($SUB_LANG, Signs & Songs)"
            continue
        fi

        local OUT_SUB_CODEC
        OUT_SUB_CODEC="$(subtitle_output_codec "$SUB_CODEC")"

        if [[ "$OUT_SUB_CODEC" == "DROP" ]]; then
            echo " Subtitle[src:$SRC_IDX]: DROP ($SUB_LANG, $SUB_CODEC bitmap format incompatible with MP4)"
            continue
        fi

        local SUB_TITLE
        if [[ "$IS_CC" == "1" ]]; then
            SUB_TITLE="${LANG_LABEL} CC"
        elif [[ "$IS_FORCED" == "1" ]]; then
            SUB_TITLE="${LANG_LABEL} Forced"
        else
            local _lang_key
            _lang_key="$(canon_lang "$SUB_LANG")"
            _LANG_COUNT[$_lang_key]=$(( ${_LANG_COUNT[$_lang_key]:-0} + 1 ))
            if (( ${_LANG_COUNT[$_lang_key]} > 1 )); then
                echo " Subtitle[src:$SRC_IDX]: DROP ($SUB_LANG, duplicate standard track: no distinguishing title)"
                continue
            fi
            SUB_TITLE="${LANG_LABEL}"
        fi

        if [[ "$SUB_MODE" == "sidecar" ]] && sidecar_output_spec "$SUB_CODEC" >/dev/null; then
            echo " Subtitle[src:$SRC_IDX]: SIDECAR: $SUB_TITLE ($SUB_CODEC)"
            SIDECAR_EXTRACT_LINES+=("${SRC_IDX} ${SUB_CODEC} $(subtitle_track_type "$IS_FORCED" "$IS_CC") ${SUB_LANG}")
            continue
        fi

        echo " Subtitle[src:$SRC_IDX -> out:${_OUT_IDX}]: INCLUDE: $SUB_TITLE ($SUB_CODEC -> $OUT_SUB_CODEC)"

        _FF+=(
            -map "0:${SRC_IDX}"
            "-c:s:${_OUT_IDX}" "$OUT_SUB_CODEC"
            "-metadata:s:s:${_OUT_IDX}" "language=${SUB_LANG}"
            "-metadata:s:s:${_OUT_IDX}" "title=${SUB_TITLE}"
        )

        if [[ "$IS_FORCED" == "1" ]]; then
            _FF+=("-disposition:s:${_OUT_IDX}" forced)
        elif [[ "$IS_CC" == "1" ]]; then
            _FF+=("-disposition:s:${_OUT_IDX}" hearing_impaired)
        else
            _FF+=("-disposition:s:${_OUT_IDX}" 0)
        fi

        _OUT_IDX=$(( _OUT_IDX + 1 ))
    done
    unset _LANG_COUNT
}

# -- build_sidecar_outputs ------------------------------------------------------------
# -S sidecar mode. Plans one standalone sidecar file per input sidecar line
# ("LANG TYPE INPUT_IDX PATH", the ffmpeg input each was opened as) and per
# extracted embedded track (SIDECAR_EXTRACT_LINES). Args: output base name,
# output directory, the names of the ffmpeg output-argument array and the job
# array, then the input sidecar lines. Appends to the first array the ffmpeg
# arguments that follow the main output, and to the second one tab-separated
# line per file: "STRIP<TAB>TMP_PATH<TAB>FINAL_PATH", where STRIP is 1 for an
# extracted srt file that still needs its ASS override tags stripped. Input
# sidecars are planned first, so on a name collision they win; a later track
# with the same final name is dropped, as is a track whose language has no
# 2-letter code. Final names are <base>.<lang2>[.cc|.forced].<ext>.
build_sidecar_outputs() {
    local OUT_BASE="$1" OUT_DIR="$2"
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _SFF="$3"
    local -n _JOBS="$4"
    shift 4
    local -a PLAN=()
    local line

    for line in "$@"; do
        local I_LANG I_TYPE I_IDX I_PATH I_CODEC
        read -r I_LANG I_TYPE I_IDX I_PATH <<< "$line"
        I_CODEC="$(probe_sidecar_codec "$I_PATH")" || I_CODEC=""
        PLAN+=("${I_IDX}:0"$'\t'"${I_CODEC}"$'\t'"${I_TYPE}"$'\t'"${I_LANG}"$'\t'"0"$'\t'"external:$(basename "$I_PATH")")
    done
    for line in "${SIDECAR_EXTRACT_LINES[@]+"${SIDECAR_EXTRACT_LINES[@]}"}"; do
        local X_IDX X_CODEC X_TYPE X_LANG
        read -r X_IDX X_CODEC X_TYPE X_LANG <<< "$line"
        PLAN+=("0:${X_IDX}"$'\t'"${X_CODEC}"$'\t'"${X_TYPE}"$'\t'"${X_LANG}"$'\t'"1"$'\t'"src:${X_IDX}")
    done

    local -A SEEN=()
    for line in "${PLAN[@]+"${PLAN[@]}"}"; do
        local P_MAP P_CODEC P_TYPE P_LANG P_STRIP P_LABEL P_SPEC P_EXT P_CODEC_OUT P_FMT P_NAME P_TMP
        IFS=$'\t' read -r P_MAP P_CODEC P_TYPE P_LANG P_STRIP P_LABEL <<< "$line"
        if ! P_SPEC="$(sidecar_output_spec "$P_CODEC")"; then
            echo " Sidecar[$P_LABEL]: DROP (no text sidecar form for codec '${P_CODEC:-unreadable}')"
            continue
        fi
        read -r P_EXT P_CODEC_OUT P_FMT <<< "$P_SPEC"
        if ! P_NAME="$(sidecar_file_name "$OUT_BASE" "$P_LANG" "$P_TYPE" "$P_EXT")"; then
            echo " Sidecar[$P_LABEL]: DROP ($P_LANG has no 2-letter code in the language table)"
            continue
        fi
        if [[ -n "${SEEN[$P_NAME]+_}" ]]; then
            echo " Sidecar[$P_LABEL]: DROP (duplicate of $P_NAME)"
            continue
        fi
        SEEN["$P_NAME"]=1
        [[ "$P_EXT" == "srt" ]] || P_STRIP=0
        P_TMP="${OUT_DIR}/.${P_NAME%.*}.tmp.${P_EXT}"
        _SFF+=(-map "$P_MAP" -c:s "$P_CODEC_OUT" -f "$P_FMT" "$P_TMP")
        _JOBS+=("${P_STRIP}"$'\t'"${P_TMP}"$'\t'"${OUT_DIR}/${P_NAME}")
        echo " Sidecar[$P_LABEL]: WRITE $P_NAME ($P_CODEC -> $P_CODEC_OUT)"
    done
}

# Checks each sidecar .tmp file named by the job array (arg 1) is non-empty and
# strips ASS override tags from the ones marked for it, replacing the .tmp file
# in place. A failed strip keeps the unstripped file with a warning. Returns 1
# on the first empty or missing file.
prepare_sidecars() {
    local -n _PJOBS="$1"
    local job p_strip p_tmp p_final
    for job in "${_PJOBS[@]+"${_PJOBS[@]}"}"; do
        IFS=$'\t' read -r p_strip p_tmp p_final <<< "$job"
        if [[ ! -s "$p_tmp" ]]; then
            echo " ERROR: sidecar is empty or missing: $(basename "$p_final")" >&2
            return 1
        fi
        [[ "$p_strip" == "1" ]] || continue
        if strip_sidecar_sub "$p_tmp" && mv -- "$STRIPPED_SUB_PATH" "$p_tmp"; then
            :
        else
            echo " WARNING: tag-strip failed for $(basename "$p_final"); keeping the unstripped file" >&2
            log "SUBTITLE TAG STRIP FAILED: $p_final (written unstripped)"
        fi
    done
}

# Moves each sidecar .tmp file named by the job array (arg 1) to its final
# path (mv -T, so an existing directory at the final path is an error, not a
# move into it). On a failed move, removes the sidecars already moved and returns 1.
promote_sidecars() {
    local -n _MJOBS="$1"
    local job m_strip m_tmp m_final
    local -a moved=()
    for job in "${_MJOBS[@]+"${_MJOBS[@]}"}"; do
        IFS=$'\t' read -r m_strip m_tmp m_final <<< "$job"
        if ! mv -T -- "$m_tmp" "$m_final"; then
            echo " ERROR: could not move sidecar into place: $m_final" >&2
            local f
            for f in "${moved[@]+"${moved[@]}"}"; do rm -f -- "$f"; done
            return 1
        fi
        moved+=("$m_final")
    done
}

# Removes the final sidecar files named by the job array (arg 1).
remove_sidecar_finals() {
    local -n _RJOBS="$1"
    local job r_strip r_tmp r_final
    for job in "${_RJOBS[@]+"${_RJOBS[@]}"}"; do
        IFS=$'\t' read -r r_strip r_tmp r_final <<< "$job"
        rm -f -- "$r_final"
    done
}

# -- log_ffmpeg_warnings --------------------------------------------------------------
log_ffmpeg_warnings() {
    local CAPTURE="$1"
    local INPUT="$2"

    [[ -s "$CAPTURE" ]] || return 0

    # All patterns matched in a single grep pass to avoid duplicate log entries
    # when a single ffmpeg warning line matches more than one pattern.
    local PATTERN_EXPR
    PATTERN_EXPR="Could not find codec parameters|Invalid data found|Error while decoding|Error while opening|non-existing PPS|missing reference picture|concealing.*errors|corrupt decoded frame|Application provided invalid|unspecified frame size"

    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && log "FFMPEG WARNING: $(basename "$INPUT") | ${line}"
    done < <(grep -iE "$PATTERN_EXPR" "$CAPTURE" 2>/dev/null \
        | grep -iv "attachment" \
        | sed 's/stream [0-9]* (Subtitle: hdmv_pgs_subtitle[^)]*)/stream (Subtitle: hdmv_pgs_subtitle/g' \
        | sort -u)
}

# -- verify_sdr_output ----------------------------------------------------------------
# Probes the video stream of an encoded file. Returns 0 if its colour transfer
# is not PQ or HLG, 1 if it is (or if ffprobe fails). Sets OUTPUT_DOVI to 1 if
# the stream carries a Dolby Vision configuration record, else 0.
verify_sdr_output() {
    local FILE="$1" STREAM_INFO TRANSFER
    OUTPUT_DOVI=0
    STREAM_INFO="$(ffprobe -v error -select_streams v:0 -show_streams "$FILE" 2>/dev/null)" || return 1
    TRANSFER="$(grep -m1 '^color_transfer=' <<< "$STREAM_INFO" | cut -d= -f2)" || true
    if grep -q 'side_data_type=DOVI configuration record' <<< "$STREAM_INFO"; then
        OUTPUT_DOVI=1
    fi
    ! is_hdr_transfer "${TRANSFER:-unknown}"
}

# -- discard_encode_artifacts ---------------------------------------------------------
# Removes the .tmp output, the sidecar .tmp files, and the stderr capture after
# a rejected encode and clears the trackers the signal handler reads. Args: tmp
# path, stderr capture path ("/dev/null" when no capture file exists).
discard_encode_artifacts() {
    local _t
    rm -f -- "$1"
    for _t in "${CURRENT_SIDECAR_TMPS[@]+"${CURRENT_SIDECAR_TMPS[@]}"}"; do
        rm -f -- "$_t"
    done
    [[ "$2" != "/dev/null" ]] && rm -f -- "$2"
    CURRENT_SIDECAR_TMPS=()
    CURRENT_TMP=""
    CURRENT_STDERR_CAPTURE=""
    return 0
}

# -- execute_encode ------------------------------------------------------------------
# Runs ffmpeg into OUTPUT_TMP, verifies the result (non-empty, SDR transfer,
# subtitle stream count), promotes it to OUTPUT, then runs -M and -A. Args 7-9
# are the names of the ffmpeg arg array, the container-flag array, and the
# sidecar "LANG TYPE PATH" line array; arg 10 is the number of subtitle streams
# the build step emitted; args 11 and 12 are the names of the sidecar ffmpeg
# output-argument array and sidecar job array (-S sidecar; empty otherwise, see
# build_sidecar_outputs). Returns 0 on success, 1 on any failure (including a
# failed -M archive).
execute_encode() {
    local INPUT="$1" OUTPUT="$2" OUTPUT_TMP="$3" OUTPUT_DIR_FOR_FILE="$4" ROOT="$5" SRC_CODEC_LABEL="$6"
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _FF="$7"
    local -n _CF="$8"
    local -n _EXTSUB="$9"
    local EXPECTED_SUBS="${10}"
    local -n _SFF="${11}"
    local -n _JOBS="${12}"

    if (( DRY_RUN )); then
        echo " [DRY RUN] Would encode -> $OUTPUT"
        return 3
    fi
    check_disk_space
    # errexit is inert in this function (process_file runs in a && || list),
    # so every step that can fail is checked explicitly.
    mkdir -p -- "$OUTPUT_DIR_FOR_FILE" || {
        echo " ERROR: could not create output directory: $OUTPUT_DIR_FOR_FILE" >&2
        log "FAILED (mkdir): $INPUT"
        return 1
    }

    echo " Running ffmpeg..."
    log "PROCESSING: $(basename "$INPUT")"
    local FILE_START
    FILE_START=$(date +%s)

    CURRENT_TMP="$OUTPUT_TMP"
    # The sidecar .tmp files are this script's private scratch like OUTPUT_TMP:
    # a leftover one is replaced without a collision policy.
    CURRENT_SIDECAR_TMPS=()
    local _job _j_strip _j_tmp _j_final
    for _job in "${_JOBS[@]+"${_JOBS[@]}"}"; do
        IFS=$'\t' read -r _j_strip _j_tmp _j_final <<< "$_job"
        CURRENT_SIDECAR_TMPS+=("$_j_tmp")
        rm -f -- "$_j_tmp"
    done

    # A leftover .tmp from a run killed hard enough to skip this script's
    # own SIGINT/SIGTERM cleanup (SIGKILL, a power loss, a container stop)
    # sits at this exact same deterministic path on the next attempt.
    # Without -y below, ffmpeg interactively prompts to overwrite it - and
    # since this runs in the background with nothing answering stdin, that
    # prompt can block indefinitely, hanging the whole batch with no error
    # printed. Removing it up front (and passing -y as defense in depth)
    # means a stale tmp is always safely replaced: it's this script's own
    # private scratch file, never the actual deliverable, so there's no
    # collision policy to apply here the way there is for the final
    # $OUTPUT path.
    if [[ -f "$OUTPUT_TMP" ]]; then
        echo " WARNING: found leftover tmp file from a previous failed/interrupted run; removing: $(basename "$OUTPUT_TMP")" >&2
        log "REMOVED STALE TMP: $OUTPUT_TMP"
        rm -f -- "$OUTPUT_TMP"
    fi

    local STDERR_CAPTURE
    if ! STDERR_CAPTURE="$(mktemp 2>/dev/null)" || [[ -z "$STDERR_CAPTURE" ]]; then
        echo " WARNING: could not create temp file for stderr capture: warnings will not be logged for this file" >&2
        STDERR_CAPTURE="/dev/null"
    fi
    CURRENT_STDERR_CAPTURE="$STDERR_CAPTURE"

    ffmpeg -y -hide_banner -loglevel warning -nostats \
            "${_FF[@]}" \
            ${_CF[@]+"${_CF[@]}"} \
            "$OUTPUT_TMP" \
            ${_SFF[@]+"${_SFF[@]}"} 2> "$STDERR_CAPTURE" &
    local FFMPEG_PID=$!
    CURRENT_FFMPEG_PID=$FFMPEG_PID

    local SPIN_IDX=0 ELAPSED=0 MINS=0 SECS=0
    local SPIN_CHARS='|/-\'
    while kill -0 "$FFMPEG_PID" 2>/dev/null; do
        MINS=$(( ELAPSED / 60 ))
        SECS=$(( ELAPSED % 60 ))
        printf "\r %s  %02d:%02d elapsed" "${SPIN_CHARS:$SPIN_IDX:1}" "$MINS" "$SECS" >&2
        SPIN_IDX=$(( (SPIN_IDX + 1) % 4 ))
        sleep 1
        ELAPSED=$(( ELAPSED + 1 ))
    done
    printf "\r%30s\r" "" >&2

    wait "$FFMPEG_PID"
    local FFMPEG_RC=$?
    CURRENT_FFMPEG_PID=""

    [[ -s "$STDERR_CAPTURE" ]] && cat "$STDERR_CAPTURE" >&2
    log_ffmpeg_warnings "$STDERR_CAPTURE" "$INPUT"

    if [[ $FFMPEG_RC -eq 0 ]]; then

        if [[ ! -s "$OUTPUT_TMP" ]]; then
            echo " ERROR: ffmpeg exited 0 but output is empty" >&2
            log "FAILED (empty output): $INPUT"
            discard_encode_artifacts "$OUTPUT_TMP" "$STDERR_CAPTURE"
            return 1
        fi

        # The probes run on the .tmp file, before the rename: a rejected file
        # never reaches OUTPUT_DIR, and -M (copy to the archive, then delete
        # the output) and -A (move the source and sidecars to the backup)
        # never act on it.
        if ! verify_sdr_output "$OUTPUT_TMP"; then
            echo " ERROR: output carries an HDR transfer function; not promoted to the output directory" >&2
            log "FAILED (HDR transfer in output): $INPUT"
            discard_encode_artifacts "$OUTPUT_TMP" "$STDERR_CAPTURE"
            return 1
        fi
        if (( OUTPUT_DOVI )); then
            echo " WARNING: output carries a Dolby Vision configuration record" >&2
            log "DOVI WARNING: $(basename "$INPUT") | output carries a Dolby Vision configuration record"
        fi
        if ! verify_subtitle_count "$OUTPUT_TMP" "$EXPECTED_SUBS"; then
            echo " ERROR: output has ${SUB_COUNT_ACTUAL:-an unreadable number of} subtitle streams, expected $EXPECTED_SUBS; not promoted, source and sidecars untouched" >&2
            log "FAILED (subtitle stream count ${SUB_COUNT_ACTUAL:-unreadable} != $EXPECTED_SUBS): $INPUT"
            discard_encode_artifacts "$OUTPUT_TMP" "$STDERR_CAPTURE"
            return 1
        fi

        if ! prepare_sidecars _JOBS; then
            log "FAILED (sidecar output): $INPUT"
            discard_encode_artifacts "$OUTPUT_TMP" "$STDERR_CAPTURE"
            return 1
        fi
        # Sidecars first, video last: an existing output video implies a
        # complete set.
        if ! promote_sidecars _JOBS; then
            log "FAILED (sidecar promote): $INPUT"
            discard_encode_artifacts "$OUTPUT_TMP" "$STDERR_CAPTURE"
            return 1
        fi
        if ! mv -- "$OUTPUT_TMP" "$OUTPUT"; then
            echo " ERROR: could not move output into place: $OUTPUT" >&2
            log "FAILED (promote): $INPUT"
            remove_sidecar_finals _JOBS
            discard_encode_artifacts "$OUTPUT_TMP" "$STDERR_CAPTURE"
            return 1
        fi
        CURRENT_TMP=""
        CURRENT_SIDECAR_TMPS=()

        local FILE_END FILE_DUR
        FILE_END=$(date +%s)
        FILE_DUR=$(( FILE_END - FILE_START ))

        # Capture file sizes for log: use MB for readability
        local SRC_BYTES OUT_BYTES SRC_MB OUT_MB
        SRC_BYTES=$(stat -c '%s' "$INPUT"  2>/dev/null || echo 0)
        OUT_BYTES=$(stat -c '%s' "$OUTPUT" 2>/dev/null || echo 0)
        SRC_MB=$(( SRC_BYTES / 1024 / 1024 ))
        OUT_MB=$(( OUT_BYTES / 1024 / 1024 ))

        # Percentage size change relative to source (sign derived from a direct
        # byte comparison, not from a truncated division: integer division
        # truncates toward zero, so a naive single division mislabels small
        # shrinkage as "+0%" growth whenever the true percentage rounds to 0
        # from below). GROWTH_PCT stays 0 unless the output is larger.
        local SIZE_DIFF="" GROWTH_PCT=0
        if (( SRC_BYTES > 0 )); then
            if (( OUT_BYTES > SRC_BYTES )); then
                GROWTH_PCT=$(( (OUT_BYTES - SRC_BYTES) * 100 / SRC_BYTES ))
                SIZE_DIFF="+${GROWTH_PCT}%"
            elif (( OUT_BYTES < SRC_BYTES )); then
                SIZE_DIFF="-$(( (SRC_BYTES - OUT_BYTES) * 100 / SRC_BYTES ))%"
            else
                SIZE_DIFF="+0%"
            fi
        fi

        echo " Done -> $OUTPUT ($(( FILE_DUR / 60 ))m $(( FILE_DUR % 60 ))s, ${OUT_MB}MB)"
        log "COMPLETED: $(basename "$INPUT") [${SRC_CODEC_LABEL}] | $(( FILE_DUR / 60 ))m $(( FILE_DUR % 60 ))s | src: ${SRC_MB}MB -> out: ${OUT_MB}MB (${SIZE_DIFF})"
        # Ignore growth under 2%: rounding noise, not a real size regression
        if (( GROWTH_PCT >= 2 )); then
            echo " WARNING: output is larger than source (${SIZE_DIFF})" >&2
            log "SIZE WARNING: $(basename "$INPUT") | output ${OUT_MB}MB exceeds source ${SRC_MB}MB (${SIZE_DIFF})"
        fi

        # The source and its sidecars move only after the output is safely in
        # place: a failed archive leaves them where they are.
        local POST_RC=0
        if [[ -n "$ARCHIVE_DIR" ]]; then
            # Sidecars first, video last, and the video only if every sidecar
            # was archived.
            for _job in "${_JOBS[@]+"${_JOBS[@]}"}"; do
                IFS=$'\t' read -r _j_strip _j_tmp _j_final <<< "$_job"
                archive_output "$_j_final" "$ROOT" "$ARCHIVE_DIR" || POST_RC=1
            done
            (( POST_RC )) || archive_output "$OUTPUT" "$ROOT" "$ARCHIVE_DIR" || POST_RC=1
        fi
        if (( POST_RC )); then
            echo " WARNING: archive failed; source and sidecars left in place, output kept at $OUTPUT" >&2
            log "BACKUP SKIPPED (archive failed): $(basename "$INPUT")"
        elif [[ -n "$BACKUP_DIR" ]]; then
            if backup_sidecar_subs "${_EXTSUB[@]+"${_EXTSUB[@]}"}" "$ROOT" "$BACKUP_DIR"; then
                backup_input "$INPUT" "$ROOT" "$BACKUP_DIR" || true
            else
                echo " WARNING: a sidecar move failed; source video left in place with its remaining sidecars" >&2
                log "BACKUP SKIPPED (sidecar move failed): $(basename "$INPUT")"
            fi
        fi

        [[ "$STDERR_CAPTURE" != "/dev/null" ]] && rm -f "$STDERR_CAPTURE"
        CURRENT_STDERR_CAPTURE=""
        return "$POST_RC"

    else
        local FILE_END FILE_DUR
        FILE_END=$(date +%s)
        FILE_DUR=$(( FILE_END - FILE_START ))
        [[ -s "$STDERR_CAPTURE" ]] && cat "$STDERR_CAPTURE" >&2
        echo " ERROR: ffmpeg exited $FFMPEG_RC" >&2
        log "FAILED: $INPUT (exit $FFMPEG_RC) | $(( FILE_DUR / 60 ))m $(( FILE_DUR % 60 ))s"
        discard_encode_artifacts "$OUTPUT_TMP" "$STDERR_CAPTURE"
        return 1
    fi
}

# -- Process one file -----------------------------------------------------------------
process_file() {
    local INPUT="$1"
    local ROOT="$2"
    local line
    SIDECAR_EXTRACT_LINES=()

    local OUTPUT
    OUTPUT="$(compute_output_path "$INPUT" "$ROOT")"
    local OUTPUT_DIR_FOR_FILE
    OUTPUT_DIR_FOR_FILE="$(dirname "$OUTPUT")"
    local OUTPUT_TMP
    OUTPUT_TMP="${OUTPUT_DIR_FOR_FILE}/.$(basename "${OUTPUT%.*}").tmp.${OUT_FORMAT}"

    FILE_NUM=$(( FILE_NUM + 1 ))
    echo ""
    echo "------------------------------------------"
    echo " [${FILE_NUM}/${#ALL_FILES[@]}] INPUT : $INPUT"
    echo " OUTPUT: $OUTPUT"
    echo "------------------------------------------"

    if [[ -f "$OUTPUT" ]] && (( SKIP_EXISTING )); then
        echo " SKIP: output already exists (-s)"
        log "SKIPPED: $(basename "$INPUT")"
        return 2
    fi

    local VID_CODEC="" VID_CODEC_LABEL="" SRC_HEIGHT=0 SRC_FPS="24/1"
    local SRC_TRANSFER="unknown" SRC_DOVI=0 SRC_PIXFMT="unknown"
    local -a AUDIO_LINES=() SUB_LINES=()
    local PROBE_ERROR=""

    while IFS= read -r line; do
        local TYPE="${line%% *}"
        case "$TYPE" in
            VIDEO)      read -r _ VID_CODEC SRC_HEIGHT SRC_FPS VID_CODEC_LABEL <<< "$line" ;;
            VIDEOFMT)   read -r _ SRC_PIXFMT <<< "$line" ;;
            VIDEOCOLOR) read -r _ SRC_TRANSFER SRC_DOVI <<< "$line" ;;
            AUDIO)      AUDIO_LINES+=("$line") ;;
            SUB)        SUB_LINES+=("$line") ;;
            ERROR)      PROBE_ERROR="${line#ERROR }" ;;
        esac
    done < <(probe_file "$INPUT")

    if [[ -n "$PROBE_ERROR" ]]; then
        echo " ERROR: probe failed ($PROBE_ERROR)" >&2
        log "FAILED (probe): $INPUT | $PROBE_ERROR"
        return 1
    fi

    if [[ -z "$VID_CODEC" ]]; then
        echo " ERROR: probe returned no video stream" >&2
        log "FAILED (no video stream): $INPUT"
        return 1
    fi

    echo " Video codec: ${VID_CODEC_LABEL:-$VID_CODEC}  |  Height: ${SRC_HEIGHT}px  |  FPS: $SRC_FPS  |  Pixel format: $SRC_PIXFMT  |  Transfer: $SRC_TRANSFER"

    # Sidecar subtitles (Movie.en.srt / Movie.en.cc.vtt / Movie.en.forced.ass, ...).
    # Raw "LANG TYPE PATH" lines, kept as-is (pointing at the ORIGINAL sidecar
    # files) for backup_sidecar_subs later - stripping happens separately,
    # below, only for the copy that gets fed to ffmpeg.
    local -a EXTSUB_LINES=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && EXTSUB_LINES+=("$line")
    done < <(discover_sidecar_subs "$INPUT")

    # Files next to the video that discovery does not embed (other formats, a
    # language outside -l, an unrecognized modifier, a shadowed .sdh.srt).
    local _unclaimed
    while IFS= read -r _unclaimed; do
        [[ -n "$_unclaimed" ]] || continue
        echo " WARNING: subtitle file not used (format, language, modifier, duplicate, or text not valid UTF-8), stays in the source directory: $(basename "$_unclaimed")" >&2
        log "SUBTITLE FILE UNCLAIMED: $_unclaimed"
    done < <(report_unclaimed_sidecars "$INPUT" "${EXTSUB_LINES[@]+"${EXTSUB_LINES[@]}"}")

    # Sidecar wins per language and type: an embedded track is dropped only
    # when a sidecar of the same primary language code and the same type
    # (target, cc, forced) exists, so the two are never both included and an
    # embedded forced or CC track survives a plain sidecar. Non-target and
    # Signs & Songs embedded tracks are left for build_subtitle_args() to skip.
    if [[ ${#EXTSUB_LINES[@]} -gt 0 ]]; then
        local -A _SIDECAR_KEYS=()
        for line in "${EXTSUB_LINES[@]}"; do
            local _es_lang _es_type _es_rest
            read -r _es_lang _es_type _es_rest <<< "$line"
            _SIDECAR_KEYS["$(subtitle_track_key "$_es_lang" "$_es_type")"]=1
        done

        local -a _FILTERED_SUB_LINES=()
        for line in "${SUB_LINES[@]+"${SUB_LINES[@]}"}"; do
            local _ _s_idx _s_codec _s_lang _s_target _s_forced _s_signs _s_cc _s_rest
            read -r _ _s_idx _s_codec _s_lang _s_target _s_forced _s_signs _s_cc _s_rest <<< "$line"
            if [[ "$_s_target" == "1" && "$_s_signs" == "0" ]]; then
                local _s_type _s_key
                _s_type="$(subtitle_track_type "$_s_forced" "$_s_cc")"
                _s_key="$(subtitle_track_key "$_s_lang" "$_s_type")"
                if [[ -n "${_SIDECAR_KEYS[$_s_key]+_}" ]]; then
                    echo " Subtitle[src:$_s_idx]: SKIP ($_s_lang/$_s_type, sidecar of the same language and type present: sidecar wins over embedded)"
                    continue
                fi
            fi
            _FILTERED_SUB_LINES+=("$line")
        done
        SUB_LINES=("${_FILTERED_SUB_LINES[@]+"${_FILTERED_SUB_LINES[@]}"}")
        unset _SIDECAR_KEYS
    fi

    local TITLE_TAG
    TITLE_TAG="$(basename "${OUTPUT%.*}")"

    # Build the input list first: main video is input 0, each sidecar
    # gets its own -i and a sequential input index for -map. On a real run,
    # each subrip sidecar is run through strip_sidecar_sub() first so ffmpeg's -i
    # points at a tag-stripped copy, never the original on-disk file - the
    # original path (in EXTSUB_LINES, above) is what backup_sidecar_subs()
    # moves later, so the stripped copy being scratch-only doesn't affect
    # the backup. On a dry run, stripping is skipped entirely (no temp
    # directory even exists - see the DRY_RUN guard around
    # init_subtitle_tag_strip, above): the printed plan shows the original
    # sidecar path with a note, rather than a real disk mutation whose
    # output is then only used to print a message.
    local -a INPUT_ARGS=(-analyzeduration "$PROBE_SIZE" -probesize "$PROBE_SIZE" -i "$INPUT")
    local -a EXTSUB_WITH_IDX=()
    local _next_input_idx=1
    for line in "${EXTSUB_LINES[@]+"${EXTSUB_LINES[@]}"}"; do
        local _e_lang _e_type _e_path _e_mux_path
        read -r _e_lang _e_type _e_path <<< "$line"

        _e_mux_path="$_e_path"
        if ! sidecar_needs_tag_strip "$_e_path"; then
            :
        elif (( DRY_RUN )); then
            echo " [DRY RUN] Would strip ASS override tags from: $(basename "$_e_path")"
        elif strip_sidecar_sub "$_e_path"; then
            _e_mux_path="$STRIPPED_SUB_PATH"
        else
            echo " WARNING: tag-strip failed for $(basename "$_e_path"); using original (may still show {\\an8}-style text on screen)" >&2
            log "SUBTITLE TAG STRIP FAILED: $_e_path (used unstripped)"
        fi

        INPUT_ARGS+=(-i "$_e_mux_path")
        EXTSUB_WITH_IDX+=("${_e_lang} ${_e_type} ${_next_input_idx} ${_e_mux_path}")
        _next_input_idx=$(( _next_input_idx + 1 ))
    done

    local -a FF_ARGS=("${INPUT_ARGS[@]}" -map_metadata -1 -metadata "title=${TITLE_TAG}")
    local -a CONTAINER_FLAGS=()
    [[ "$OUT_FORMAT" == "mp4" ]] && CONTAINER_FLAGS+=(-movflags +faststart)

    build_video_args    FF_ARGS "$VID_CODEC" "$SRC_HEIGHT" "$SRC_FPS" "$SRC_TRANSFER" "$SRC_DOVI" "$SRC_PIXFMT"
    build_audio_args    FF_ARGS "${AUDIO_LINES[@]+"${AUDIO_LINES[@]}"}"

    local SUB_OUT_IDX=0
    local -a SIDECAR_FF=() SIDECAR_JOBS=()
    build_subtitle_args          FF_ARGS SUB_OUT_IDX "${SUB_LINES[@]+"${SUB_LINES[@]}"}"
    if [[ "$SUB_MODE" == "sidecar" ]]; then
        build_sidecar_outputs "$(basename "${OUTPUT%.*}")" "$OUTPUT_DIR_FOR_FILE" SIDECAR_FF SIDECAR_JOBS \
            "${EXTSUB_WITH_IDX[@]+"${EXTSUB_WITH_IDX[@]}"}"
    else
        build_external_subtitle_args FF_ARGS SUB_OUT_IDX "${EXTSUB_WITH_IDX[@]+"${EXTSUB_WITH_IDX[@]}"}"
    fi
    [[ $SUB_OUT_IDX -eq 0 && ${#SIDECAR_JOBS[@]} -eq 0 ]] && echo " Subtitles: none matching criteria"

    echo ""
    if (( DRY_RUN )); then
        echo " [DRY RUN] ffmpeg ${FF_ARGS[*]} ${CONTAINER_FLAGS[*]:-} \"$OUTPUT_TMP\" ${SIDECAR_FF[*]:-} && mv -> \"$OUTPUT\""
        return 3
    fi

    execute_encode "$INPUT" "$OUTPUT" "$OUTPUT_TMP" "$OUTPUT_DIR_FOR_FILE" "$ROOT" "${VID_CODEC_LABEL:-$VID_CODEC}" FF_ARGS CONTAINER_FLAGS EXTSUB_LINES "$SUB_OUT_IDX" SIDECAR_FF SIDECAR_JOBS
}

# -- Main loop -------------------------------------------------------------------------
for (( i=0; i<${#ALL_FILES[@]}; i++ )); do
    process_file "${ALL_FILES[$i]}" "${ALL_ROOTS[$i]}" && _RC=0 || _RC=$?
    if [[ $_RC -eq 0 ]]; then
        ENCODE_OK=$(( ENCODE_OK + 1 ))
    elif [[ $_RC -eq 2 ]]; then
        ENCODE_SKIP=$(( ENCODE_SKIP + 1 ))
    elif [[ $_RC -eq 3 ]]; then
        ENCODE_DRYRUN=$(( ENCODE_DRYRUN + 1 ))
    else
        ENCODE_FAIL=$(( ENCODE_FAIL + 1 ))
    fi
done

# -- Summary -----------------------------------------------------------------------
SCRIPT_END=$(date +%s)
TOTAL_DUR=$(( SCRIPT_END - SCRIPT_START ))

print_summary "Batch complete" "$TOTAL_DUR"

if (( DRY_RUN )); then
    echo "Dry run: nothing was written."
elif [[ $ENCODE_FAIL -eq 0 ]]; then
    LOG_FILE_FINAL="$LOG_DIR/Log_$(date '+%Y-%m-%d_%H%M').txt"
    mv -- "$LOG_FILE_TEMP" "$LOG_FILE_FINAL"
    echo "Log saved to: $LOG_FILE_FINAL"
else
    echo "Log retained at: $LOG_FILE_TEMP (batch had failures)"
fi

[[ $ENCODE_FAIL -eq 0 ]] || exit 1
