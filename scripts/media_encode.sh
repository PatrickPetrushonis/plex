#!/usr/bin/env bash
# media_encode.sh: Batch video encoder with stream-aware copy/transcode decisions
#
# Usage:  ./media_encode.sh [OPTIONS] <input_file|dir|glob> [<input2> ...]
#
# Options:
#   -o DIR          Output directory (default: <script directory>/encoded)
#   -c INT          CRF quality, 0-51, lower = better (default: 18)
#   -p PRESET       x264 preset: ultrafast..veryslow (default: slow)
#   -T TUNE         x264 tune, passed to ffmpeg as -tune, e.g. animation or film (default: none)
#   -K KBPS         Copy h264 video only when the file's overall bitrate is at most KBPS kb/s;
#                   a higher bitrate is re-encoded. 0 always copies (default: 8000)
#   -b BITRATE      Audio fallback encode bitrate (default: 192k)
#   -H HEIGHT       Max output height in px; taller sources are scaled down (default: 1080)
#   -f FORMAT       Output container: mkv or mp4 (default: mkv)
#   -l LANGS        Comma-separated subtitle languages to keep, as primary 3-letter
#                   codes from lang_table.tsv (default: eng)
#   -a CODECS       Comma-separated audio codecs to copy without re-encode
#                   (default: aac,ac3,eac3,dts,truehd,flac,opus)
#   -e EXTS         Comma-separated input extensions to scan (default: VIDEO_EXTS in video_exts.sh)
#   -L DIR          Log directory (default: OUTPUT_DIR/Logs)
#   -r              Recurse into subdirectories, mirroring folder structure in output
#   -F              Flat output: do not mirror directory structure (default when
#                   input is a file or glob; ignored for directory inputs unless set)
#   -J              Do not merge multi-part sets: encode each CD1/CD2 file on its own
#                   (default: a complete, compatible set in one folder is one output)
#   -n              Dry run: print decisions, do not encode
#   -s              Skip if output file already exists (default: overwrite)
#   -M PATH         After encode: cp output to this path (a local staging directory or a NAS/SMB mount), verify size, remove original
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
#     ffprobe, python3, flock, find, grep, sed, awk, iconv, and media_progress.sh
#     subtitle_join.py and subtitle_ocr.py alongside this script. VobSub subtitles
#     (.idx and .sub) also need tesseract with the language data for each target
#     language, and Pillow for python3; without them the VobSub files are reported
#     and left alone, and the encode goes on
#   * The spinner and elapsed time show on a terminal only; a run without one
#     (a callback, cron) prints none of it
#   * Video is copied if already h264, 8-bit 4:2:0, SDR (colour transfer not PQ or
#     HLG), within MAX_HEIGHT, and at an overall bitrate of at most -K kb/s (container
#     size over duration, which includes audio; unreadable means copy); otherwise
#     re-encoded to x264
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
#   * Embedded subtitles: one track per language and type (standard, CC, forced); the
#     best codec wins (subrip, mov_text and webvtt, then ass and ssa, then bitmap) and
#     a tie goes to the first listed track
#   * Subtitle codec is container-aware: srt/ass in MKV; mov_text in MP4 (subtitle_mux.sh)
#   * Sidecar subtitle files (<name>.<lang2>[.cc|.sdh|.forced].<ext>, ext in
#     srt vtt ass ssa sub, claimed by probed codec subrip/webvtt/ass/microdvd;
#     first ext in that order wins per language and type) are muxed. In MKV,
#     webvtt and microdvd convert to srt and ass is copied; in MP4 all become
#     mov_text. Subrip sidecars have leftover ASS override tags (e.g. {\an8})
#     stripped before muxing (subtitle_strip_tags.py); ass is left untouched.
#     A sidecar replaces an embedded track of the same
#     language and the same type (standard, CC, forced); language codes are
#     compared after alias resolution and an untagged track counts as eng
#   * VobSub sidecars (<name>.<lang2>[.cc|.sdh|.forced].idx with its .sub beside it) are
#     bitmap subtitles. For each target language the first track of that language in
#     the .idx is read by OCR (subtitle_ocr.py, tesseract) into SubRip, which is muxed
#     like any other sidecar, so merged sets, -S sidecar and the tag-stripping all
#     apply. A text sidecar of the same language and type wins over a VobSub one; the
#     VobSub pair is not read, is named in a message, and -A moves it with the video. OCR
#     takes about 0.1 s per cue, so a feature film takes a minute or two per part; the
#     spinner shows while it runs. Text recognised by OCR can hold errors, and a cue it
#     cannot read is skipped. A dry run does not run OCR. -A moves the .idx and the .sub
#     together. A VobSub pair is reported and left alone when OCR is unavailable, the
#     language data is not installed, the .idx has no track in the language, or the
#     OCR fails. Embedded bitmap tracks (a VobSub or PGS track inside the video) and
#     .sup files are not read by OCR
#   * Subtitle-extension files next to a video that discovery does not embed
#     (.sup, .smi, a bitmap .sub with no .idx, a lower-precedence duplicate format,
#     a language outside -l, an unrecognized modifier, or a VobSub pair that could
#     not be read as above) are reported as warnings, are not embedded, and stay
#     where they are
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
#   * -S embed: an embedded SubRip or mov_text track that carries ASS override tags
#     (e.g. {\an8}) is extracted to a scratch file, tag-stripped, and muxed from the
#     stripped copy; a track without tags is muxed from the source as is. A dry run
#     does not inspect embedded tracks
#   * Multi-part movies: video files in one folder whose names match once a part token
#     is removed (cd, disc, disk, dvd, part or pt, then a number: "Title CD1 (YYYY).avi",
#     "Title - part2.mkv") and whose numbers run 1..N without a gap are encoded as one
#     output named without the token. ffmpeg's concat demuxer joins the parts inside the
#     single encode, so the video is encoded once. A set is merged only when every part
#     has the same stream layout (codec, size, frame rate, sample rate, channels); an
#     incomplete or mismatched set is encoded as separate files with a warning, and -J
#     turns merging off. Episode names (SxxEyy, NxNN) are never merged. Known limitation:
#     two separate movies named "Title Part 1 (YYYY)" and "Title Part 2 (YYYY)" in one
#     folder look like one set and are merged; use -J to encode them separately
#   * Merged sets and subtitles: the sidecar files of one language and type are converted
#     to SubRip, shifted by the summed durations of the parts before them
#     (subtitle_join.py) and muxed as one track; ASS styling in a joined sidecar is
#     dropped. Embedded tracks are joined with the video and are not checked for ASS
#     override tags. An output whose duration differs from the parts' total by more than
#     the larger of 1% and 3 s is rejected. -A moves every part and its sidecars, and
#     moves none when the backup destination of any part already exists
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
TUNE=""
MAX_COPY_KBPS=8000
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
MERGE_PARTS=1       # -J sets 0: do not merge multi-part sets
# A merged output's duration must be within the larger of MERGE_TOLERANCE_PCT percent and
# MERGE_TOLERANCE_MIN_SECONDS seconds of the parts' summed durations.
MERGE_TOLERANCE_PCT=1
MERGE_TOLERANCE_MIN_SECONDS=3

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
while getopts ":o:c:p:T:K:b:H:f:l:a:e:L:M:A:S:d:P:rFJnsh" opt; do
    case $opt in
        o) OUTPUT_DIR="$OPTARG" ;;
        c) CRF="$OPTARG" ;;
        p) PRESET="$OPTARG" ;;
        T) TUNE="$OPTARG" ;;
        K) MAX_COPY_KBPS="$OPTARG" ;;
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
        J) MERGE_PARTS=0 ;;
        n) DRY_RUN=1 ;;
        s) SKIP_EXISTING=1 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ $# -lt 1 ]] && {
    echo "Usage: $0 [OPTIONS] <input_file|dir|glob> ..." >&2
    echo "  Run $0 -h for full help." >&2
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

    if ! [[ "$MAX_COPY_KBPS" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Copy limit (-K) must be a non-negative integer in kb/s (got: $MAX_COPY_KBPS)" >&2
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
require find
require grep
require awk

# Loaded before the lock and log exist, so a missing or mismatched file leaves
# nothing behind.
# -- Sidecar subtitle support (Plex-style Movie.en.srt / Movie.en.cc.vtt) ----------
# LANG_TABLE, LANG_3TO2, LANG_LABEL_BASH, LANG_ALIASES, LANG_CANON and
# canon_lang() come from the shared lang_table.sh / lang_table.tsv (same
# directory), also the source probe_streams.py reads for track labels.
PROBE_PY="$(dirname "${BASH_SOURCE[0]}")/probe_streams.py"
[[ -r "$PROBE_PY" ]] || { echo "ERROR: probe_streams.py not found next to this script ($PROBE_PY)" >&2; exit 1; }
STRIP_PY="$(dirname "${BASH_SOURCE[0]}")/subtitle_strip_tags.py"
[[ -r "$STRIP_PY" ]] || { echo "ERROR: subtitle_strip_tags.py not found next to this script ($STRIP_PY)" >&2; exit 1; }
JOIN_PY="$(dirname "${BASH_SOURCE[0]}")/subtitle_join.py"
[[ -r "$JOIN_PY" ]] || { echo "ERROR: subtitle_join.py not found next to this script ($JOIN_PY)" >&2; exit 1; }
# Optional: only VobSub sidecars need it (see ocr_ready).
OCR_PY="$(dirname "${BASH_SOURCE[0]}")/subtitle_ocr.py"
# shellcheck source=./video_exts.sh
source "$(dirname "${BASH_SOURCE[0]}")/video_exts.sh"
PROGRESS_SH="$(dirname "${BASH_SOURCE[0]}")/media_progress.sh"
[[ -r "$PROGRESS_SH" ]] || { echo "ERROR: media_progress.sh not found next to this script ($PROGRESS_SH)" >&2; exit 1; }
# shellcheck source=./media_progress.sh
source "$PROGRESS_SH"
# shellcheck source=./lang_table.sh
source "$(dirname "${BASH_SOURCE[0]}")/lang_table.sh"
declare -F canon_lang >/dev/null || {
    echo "ERROR: canon_lang is not defined; lang_table.sh is not the version this script requires" >&2
    exit 1
}

# subtitle_output_codec(), sidecar_output_codec(), probe_sidecar_codec(),
# sidecar_needs_tag_strip(), find_sidecar_file(), discover_sidecar_subs(),
# report_unclaimed_sidecars(), subtitle_track_type(), subtitle_track_key(),
# verify_subtitle_count() and build_external_subtitle_args() come from
# subtitle_mux.sh (same directory).
# shellcheck source=./subtitle_mux.sh
source "$(dirname "${BASH_SOURCE[0]}")/subtitle_mux.sh"

# is_hdr_transfer, build_video_args, build_audio_args and build_subtitle_args come
# from media_encode_args.sh (same directory). They read the settings defined below when
# they run.
# shellcheck source=./media_encode_args.sh
source "$(dirname "${BASH_SOURCE[0]}")/media_encode_args.sh"

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
# Re-registered below, right after the subtitle scratch directory is created,
# so each trap is added immediately after the state it undoes.
trap 'rm -f -- "$LOCK_FILE" 2>/dev/null || true' EXIT

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
    echo "media_encode.sh Batch Processing Log: $(date)"
    echo "Output:  $OUTPUT_DIR"
    echo "Logs:    $LOG_DIR"
    [[ -n "$ARCHIVE_DIR" ]] && echo "Archive: $ARCHIVE_DIR"
    [[ -n "$BACKUP_DIR"  ]] && echo "Backup:  $BACKUP_DIR"
    printf 'Args:    %s\n' "$*"
    echo "------------------------------------------"
    echo " Settings"
    echo "  CRF:          $CRF"
    echo "  Preset:       $PRESET"
    echo "  Tune:         ${TUNE:-none}"
    echo "  Copy limit:   ${MAX_COPY_KBPS} kb/s"
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
# The video files of the job in progress: the input alone, or every part of a merged
# multi-part set in part order. Set by process_file(), read by execute_encode() and
# finish_outputs().
declare -a CURRENT_PARTS=()
# The parts' summed durations in seconds for a merged set; empty for a single file. Set
# by process_file(), read by execute_encode().
CURRENT_EXPECTED_SECONDS=""

# SIGINT/SIGTERM handler. Stops the running ffmpeg, removes the partial .tmp
# output and the stderr capture, prints the summary labelled ABORTED, and exits
# 1 (which fires the EXIT trap that removes the lock and the stripped-subtitle
# scratch directory). SIG is the signal name used in the messages.
cleanup() {
    local SIG="$1"
    echo "" >&2
    echo "media_encode.sh: caught $SIG, aborting." >&2
    if [[ -n "$CURRENT_FFMPEG_PID" ]]; then
        kill "$CURRENT_FFMPEG_PID" 2>/dev/null
        wait "$CURRENT_FFMPEG_PID" 2>/dev/null
        CURRENT_FFMPEG_PID=""
    fi
    if [[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]]; then
        echo "  Removing partial output: $CURRENT_TMP" >&2
        rm -f -- "$CURRENT_TMP"
    fi
    local _t
    for _t in "${CURRENT_SIDECAR_TMPS[@]+"${CURRENT_SIDECAR_TMPS[@]}"}"; do
        rm -f -- "$_t"
    done
    [[ -n "$CURRENT_STDERR_CAPTURE" && -f "$CURRENT_STDERR_CAPTURE" ]] && rm -f -- "$CURRENT_STDERR_CAPTURE"
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
    VIDEO_EXT_REGEX="$VIDEO_EXTS"
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

# -- Multi-part sets -------------------------------------------------------------------
# A movie split across files ("Title CD1 (YYYY).avi", "Title CD2 (YYYY).avi") is one
# job: ffmpeg joins the parts with the concat demuxer inside the single encode. These
# functions find the sets in ALL_FILES before the batch starts.

# Parses NAME (a file name without directory or extension) for a part token: cd, disc,
# disk, dvd, part or pt, an optional gap of spaces, dots, underscores or hyphens, a one
# or two digit number and an optional "of N", with a non-alphanumeric character or the
# edge of the name on both sides. A name with an episode marker (SxxEyy or NxNN) never
# matches. Sets MP_OK (1 when matched), MP_NUM (the part number) and MP_STEM (NAME with
# the token and the separators around it removed, the rest joined by one space:
# "Title CD1 (YYYY)" gives "Title (YYYY)"). MP_NUM is 0 and MP_STEM empty when MP_OK is 0.
multipart_parse() {
    local NAME="$1" PRE="" POST="" NC=0
    local EPISODE_RE='(^|[^[:alnum:]])(s[0-9]{1,2}e[0-9]{1,3}|[0-9]{1,2}x[0-9]{2,3})([^[:alnum:]]|$)'
    local TOKEN_RE='^(.*[^[:alnum:]])?(cd|disc|disk|dvd|part|pt)[[:space:]._-]*([0-9]{1,2})([[:space:]._-]+of[[:space:]._-]+[0-9]{1,2})?([^[:alnum:]].*)?$'
    MP_OK=0; MP_NUM=0; MP_STEM=""

    shopt -q nocasematch && NC=1
    shopt -s nocasematch
    if [[ ! "$NAME" =~ $EPISODE_RE ]] && [[ "$NAME" =~ $TOKEN_RE ]]; then
        PRE="${BASH_REMATCH[1]}"
        MP_NUM=$(( 10#${BASH_REMATCH[3]} ))
        POST="${BASH_REMATCH[5]}"
        MP_OK=1
    fi
    (( NC )) || shopt -u nocasematch
    (( MP_OK )) || return 0

    # A token wrapped in its own brackets, "Title (CD1)", leaves the pair empty.
    if [[ "$PRE" == *"(" && "$POST" == ")"* ]] || [[ "$PRE" == *"[" && "$POST" == "]"* ]]; then
        PRE="${PRE%?}"
        POST="${POST#?}"
    fi
    PRE="${PRE%"${PRE##*[![:space:]._-]}"}"
    POST="${POST#"${POST%%[![:space:]._-]*}"}"
    if [[ -n "$PRE" && -n "$POST" ]]; then
        MP_STEM="$PRE $POST"
    else
        MP_STEM="${PRE}${POST}"
    fi
    if [[ -z "$MP_STEM" ]]; then
        MP_OK=0
        MP_NUM=0
    fi
}

# Echoes one line per stream of FILE with the properties the concat demuxer needs
# identical across parts: type, codec, size, pixel format, frame rate, sample rate and
# channels. Returns 1 when ffprobe fails.
stream_signature() {
    ffprobe -v error \
        -show_entries stream=codec_type,codec_name,width,height,pix_fmt,r_frame_rate,sample_rate,channels \
        -of csv=p=0 "$1" 2>/dev/null
}

# Echoes the container duration of FILE in seconds. Returns 1 with nothing echoed when
# ffprobe fails or reports no positive duration.
probe_duration() {
    local OUT
    OUT="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null)" || return 1
    awk -v d="$OUT" 'BEGIN { if (d + 0 > 0) { print d; exit 0 } exit 1 }'
}

# Echoes the sum of the decimal second counts in the arguments, to three decimals.
sum_seconds() {
    printf '%s\n' "$@" | awk '{ s += $1 } END { printf "%.3f\n", s }'
}

# Returns 0 when the files given (the parts of one set) can be joined: ffprobe reads
# each, each has a duration, and each has the stream layout of the first. Otherwise
# returns 1 with MERGE_REASON naming the first part that fails and why.
check_part_set() {
    local FIRST_SIG="" SIG p
    MERGE_REASON=""
    for p in "$@"; do
        if ! SIG="$(stream_signature "$p")" || [[ -z "$SIG" ]]; then
            MERGE_REASON="cannot read the streams of $(basename -- "$p")"
            return 1
        fi
        if ! probe_duration "$p" >/dev/null; then
            MERGE_REASON="cannot read the duration of $(basename -- "$p")"
            return 1
        fi
        if [[ -z "$FIRST_SIG" ]]; then
            FIRST_SIG="$SIG"
        elif [[ "$SIG" != "$FIRST_SIG" ]]; then
            MERGE_REASON="$(basename -- "$p") has a different stream layout than $(basename -- "$1") (codec, size, frame rate, sample rate or channels)"
            return 1
        fi
    done
    return 0
}

# Maps the path of part 1 of each merged set to the paths of all its parts in part
# order, one per line. Filled by group_multipart_files().
declare -A GROUP_PARTS=()

# Collapses each complete, compatible multi-part set in ALL_FILES into one job: the
# entry for part 1 stays and the other parts leave ALL_FILES and ALL_ROOTS, and
# GROUP_PARTS records the set. A set is the files that share a folder, a scan root and
# a stem (multipart_parse) and numbered 1..N with no gap or repeat; every part must
# pass check_part_set. A set that fails either test stays as separate files, with a
# warning. A path that contains a newline is never part of a set. Does nothing under -J.
group_multipart_files() {
    (( MERGE_PARTS )) || return 0
    local -A MEMBERS=() DROP=()
    local -a KEYS=() ROWS=() PARTS=() PARTS_IDX=() NEW_FILES=() NEW_ROOTS=()
    local i f key row num idx k ok SET_STEM NUMS
    for (( i=0; i<${#ALL_FILES[@]}; i++ )); do
        f="${ALL_FILES[$i]}"
        [[ "$f" == *$'\n'* ]] && continue
        multipart_parse "$(basename -- "${f%.*}")"
        (( MP_OK )) || continue
        key="${ALL_ROOTS[$i]}"$'\x1f'"$(dirname -- "$f")"$'\x1f'"$MP_STEM"
        [[ -n "${MEMBERS[$key]+_}" ]] || KEYS+=("$key")
        MEMBERS["$key"]+="${MP_NUM} ${i}"$'\n'
    done

    for key in "${KEYS[@]+"${KEYS[@]}"}"; do
        SET_STEM="${key##*$'\x1f'}"
        mapfile -t ROWS < <(printf '%s' "${MEMBERS[$key]}" | sort -n -k1,1)
        (( ${#ROWS[@]} >= 2 )) || continue
        PARTS=(); PARTS_IDX=(); k=0; ok=1; NUMS=""
        for row in "${ROWS[@]}"; do
            read -r num idx <<< "$row"
            k=$(( k + 1 ))
            (( num == k )) || ok=0
            NUMS+="${NUMS:+,}${num}"
            PARTS_IDX+=("$idx")
            PARTS+=("${ALL_FILES[$idx]}")
        done
        if (( ! ok )); then
            echo "WARNING: \"$SET_STEM\" not merged: its part numbers are $NUMS, a set needs 1..${#ROWS[@]} with no gap or repeat" >&2
            log "MERGE SKIPPED (part numbers $NUMS): $SET_STEM"
            continue
        fi
        if ! check_part_set "${PARTS[@]}"; then
            echo "WARNING: \"$SET_STEM\" not merged: $MERGE_REASON" >&2
            log "MERGE SKIPPED ($MERGE_REASON): $SET_STEM"
            continue
        fi
        GROUP_PARTS["${PARTS[0]}"]="$(printf '%s\n' "${PARTS[@]}")"
        for idx in "${PARTS_IDX[@]:1}"; do
            DROP["$idx"]=1
        done
        echo "Multi-part: \"$SET_STEM\" (${#PARTS[@]} parts) will be encoded as one output"
        log "MERGE: $SET_STEM (${#PARTS[@]} parts)"
    done

    for (( i=0; i<${#ALL_FILES[@]}; i++ )); do
        [[ -n "${DROP[$i]+_}" ]] && continue
        NEW_FILES+=("${ALL_FILES[$i]}")
        NEW_ROOTS+=("${ALL_ROOTS[$i]}")
    done
    ALL_FILES=("${NEW_FILES[@]+"${NEW_FILES[@]}"}")
    ALL_ROOTS=("${NEW_ROOTS[@]+"${NEW_ROOTS[@]}"}")
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

group_multipart_files

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
# Echoes the output path for INPUT under OUTPUT_DIR: mirrored by its folder below ROOT,
# or flat when ROOT is empty or -F is set. STEM, when given, replaces INPUT's file name
# without extension (a merged set's name without the part token).
compute_output_path() {
    local INPUT="$1"
    local ROOT="$2"
    local BASENAME="${3:-}"
    [[ -n "$BASENAME" ]] || BASENAME="$(basename "${INPUT%.*}")"

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
# Runs probe_streams.py, which prints one line per stream group for the caller to parse:
#   VIDEO <codec> <height> <fps> <label>
#   VIDEOFMT <pix_fmt>                       ("unknown" when the probe reports none)
#   VIDEOCOLOR <color_transfer> <has_dovi>   (transfer is "unknown" when untagged;
#                                             has_dovi is 1 if the video stream
#                                             carries a Dolby Vision configuration record)
#   AUDIO ... / SUB ...
#   ERROR <message>   (on probe failure)
probe_file() {
    python3 "$PROBE_PY" encode "$1" "$SUB_LANGS" "$LANG_TABLE_TSV"
}

# Echoes the overall bitrate of FILE in kb/s as an integer, from the container's
# size and duration. Audio and subtitle streams are included, so it is an upper
# bound on the video bitrate; the video stream's own value is not used because
# ffprobe reports none for many Matroska files. Returns 1 with nothing echoed
# when ffprobe fails or reports no usable size or duration.
probe_overall_kbps() {
    local OUT key val SIZE="" DURATION=""
    OUT="$(ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 "$1" 2>/dev/null)" || return 1
    while IFS='=' read -r key val; do
        case "$key" in
            duration) DURATION="$val" ;;
            size)     SIZE="$val" ;;
        esac
    done <<< "$OUT"
    awk -v s="$SIZE" -v d="$DURATION" 'BEGIN { if (s + 0 > 0 && d + 0 > 0) printf "%d\n", s * 8 / 1000 / d; else exit 1 }'
}

# Scratch directory: the tag-stripped copies of sidecar and embedded subtitle tracks,
# the temporary .srt extracted from each embedded track to check it for override tags,
# and, for a merged multi-part set, the concat list and the joined subtitle files.
# Created once, after the concurrency lock above is held, and only for a real run (see
# the guard below).
SUB_TMP_DIR=""

# Removes SUB_TMP_DIR and everything under it. Safe to call when it was never
# created or is already gone, so the EXIT trap can call it unconditionally.
# Wired into that trap alongside the lock-file removal, so an interrupted run
# doesn't leave stripped copies behind - the same reasoning
# Linux_Script_Style_Guide.md section 5 applies to restoring any state on exit,
# not just locks.
cleanup_sub_tmp() {
    [[ -n "$SUB_TMP_DIR" && -d "$SUB_TMP_DIR" ]] || return 0
    rm -rf -- "$SUB_TMP_DIR" 2>/dev/null || true
    SUB_TMP_DIR=""
}

# Reads SRC (a plain sidecar .srt file), strips every {\...} override tag from
# it with subtitle_strip_tags.py, and writes the result to a new file under
# SUB_TMP_DIR. Sets STRIPPED_SUB_PATH to that new file's path. SRC itself is
# never modified - the caller's original sidecar file (and its later backup
# move) is unaffected by this function.
#
# Returns 1 (STRIPPED_SUB_PATH left empty) if SUB_TMP_DIR has not been created,
# SRC doesn't exist, or the strip itself fails; the caller decides whether to
# fall back to muxing the unstripped original or to skip the track.
strip_sidecar_sub() {
    local SRC="$1"
    STRIPPED_SUB_PATH=""

    if [[ -z "$SUB_TMP_DIR" ]]; then
        echo "ERROR: strip_sidecar_sub called before the subtitle temp directory was created" >&2
        return 1
    fi
    if [[ ! -f "$SRC" ]]; then
        echo "ERROR: strip_sidecar_sub: source not found: $SRC" >&2
        return 1
    fi

    local DEST
    DEST="${SUB_TMP_DIR}/$(basename "$SRC")"
    # Two sidecars from different source directories can share a basename
    # (e.g. two different shows both shipping a plain "en.srt"); disambiguate
    # rather than let the second strip silently overwrite the first inside
    # the shared temp dir.
    if [[ -e "$DEST" ]]; then
        DEST="${SUB_TMP_DIR}/$(basename "$SRC").$$.${RANDOM}"
    fi

    if ! python3 "$STRIP_PY" strip "$SRC" "$DEST" 2>/dev/null; then
        echo "ERROR: failed to strip override tags from: $SRC" >&2
        rm -f -- "$DEST"
        return 1
    fi

    STRIPPED_SUB_PATH="$DEST"
}

# Creates SUB_TMP_DIR, only for a real run: a dry run prints decisions and
# touches nothing, so it must not create even a scratch temp directory. A
# failure here aborts the run the same way a missing dependency does
# (require()) rather than falling back to muxing unstripped sidecars silently.
if (( ! DRY_RUN )); then
    SUB_TMP_DIR="$(mktemp -d 2>/dev/null)" || {
        echo "ERROR: could not create temp directory for subtitle tag stripping" >&2
        exit 1
    }
    # Re-registers the EXIT trap now that the temp directory exists (see the
    # lock's trap above).
    trap 'rm -f -- "$LOCK_FILE" 2>/dev/null || true; cleanup_sub_tmp' EXIT
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
        rmdir -- "$DIR" 2>/dev/null || break
        DIR="$(dirname "$DIR")"
    done
}

# Copies SRC (an encoded output) to the same relative path under DEST_BASE,
# verifies the copy by byte size, then removes SRC. ROOT is accepted for call
# symmetry with backup_input() and is unused: the relative path is taken from
# OUTPUT_DIR. A destination that already exists is never overwritten. Returns
# 0 on success; returns 1 with SRC kept in place on any failure, including an
# existing destination. In a dry run it prints the plan without touching disk.
archive_output() {
    local SRC="$1"
    local ROOT="$2"
    local DEST_BASE="$3"

    local REL="${SRC#"${OUTPUT_DIR}"/}"
    local DEST="${DEST_BASE}/${REL}"
    local DEST_DIR
    DEST_DIR="$(dirname "$DEST")"

    if [[ -e "$DEST" ]]; then
        echo " WARNING: archive destination already exists, not overwriting: $DEST" >&2
        log "ARCHIVE FAILED (destination exists): $SRC"
        return 1
    fi
    if (( DRY_RUN )); then
        echo " [DRY RUN] Would archive: $SRC -> $DEST"
        return 0
    fi

    echo " Archive -> $DEST"
    mkdir -p -- "$DEST_DIR" || {
        echo " WARNING: could not create archive directory: $DEST_DIR" >&2
        log "ARCHIVE FAILED (mkdir): $SRC"
        return 1
    }

    progress_run "Archiving $(basename -- "$SRC")" cp -- "$SRC" "$DEST" || {
        echo " WARNING: cp failed: $SRC -> $DEST" >&2
        log "ARCHIVE FAILED (cp): $SRC"
        rm -f -- "$DEST"
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
        rm -f -- "$DEST"
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

# Echoes where SRC goes under DEST_BASE: its path relative to ROOT, or its file name
# alone when ROOT is empty.
backup_dest_path() {
    local SRC="$1" ROOT="$2" DEST_BASE="$3" REL
    if [[ -n "$ROOT" ]]; then
        REL="${SRC#"${ROOT}"/}"
    else
        REL="$(basename "$SRC")"
    fi
    echo "${DEST_BASE}/${REL}"
}

# Moves SRC under DEST_BASE, mirroring its path relative to ROOT (flat by file
# name when ROOT is empty). Refuses to overwrite an existing destination.
# LABEL ("" or " (sidecar)") is appended to messages. Returns 0 on success, 1
# on any failure; every failure is logged.
move_into_backup() {
    local SRC="$1" ROOT="$2" DEST_BASE="$3" LABEL="$4"
    local DEST DEST_DIR

    DEST="$(backup_dest_path "$SRC" "$ROOT" "$DEST_BASE")"
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
    (( DRY_RUN )) || cleanup_empty_dirs "$SRC" "$ROOT"
}

# Moves each sidecar subtitle file that was muxed into the output to BACKUP_DIR,
# mirrored relative to ROOT the same way backup_input() moves the source
# video, so the backup tree keeps a video and its sidecar subs together.
# Moves the ORIGINAL sidecar file, not the stripped mux copy used to feed
# ffmpeg (that copy lives under SUB_TMP_DIR and is swept by cleanup_sub_tmp,
# not backed up).
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
        # A VobSub .idx travels with the .sub beside it.
        if [[ "$SIDECAR_SRC" == *.idx ]]; then
            move_into_backup "${SIDECAR_SRC%.idx}.sub" "$ROOT" "$DEST_BASE" " (sidecar)" || FAILED=1
        fi
    done
    return "$FAILED"
}

# -- extract_embedded_srt -------------------------------------------------------------
# Extracts the embedded text tracks with the given source indexes to scratch files
# "${SUB_TMP_DIR}/raw/e<index>.srt" in a single ffmpeg run. Extracting even one
# track reads the whole input file, so a run per file costs one read of it and a
# run per track costs one read each. Args: input video, then the source indexes.
# Shows the spinner while it runs and registers the process in CURRENT_FFMPEG_PID
# so the SIGINT/SIGTERM handler stops it. Returns ffmpeg's exit status; after a
# failure the files may be missing or partial.
extract_embedded_srt() {
    local INPUT="$1"
    shift
    local -a MAPS=()
    local idx RC=0
    mkdir -p -- "${SUB_TMP_DIR}/raw"
    for idx in "$@"; do
        MAPS+=(-map "0:${idx}" -c:s srt "${SUB_TMP_DIR}/raw/e${idx}.srt")
    done
    ffmpeg -nostdin -v error -y -analyzeduration "$PROBE_SIZE" -probesize "$PROBE_SIZE" \
        -i "$INPUT" "${MAPS[@]}" 2>/dev/null &
    CURRENT_FFMPEG_PID=$!
    spin_until_exit "$CURRENT_FFMPEG_PID"
    wait "$CURRENT_FFMPEG_PID" || RC=$?
    CURRENT_FFMPEG_PID=""
    return "$RC"
}

# -- strip_embedded_text_tracks -------------------------------------------------------
# -S embed mode, real runs only. Extracts every embedded SubRip or mov_text track
# that build_subtitle_args() would keep to a scratch .srt file, all in one pass over
# the input (extract_embedded_srt). A track whose text carries ASS override tags
# (e.g. {\an8}) is removed from the SUB_LINES array and replaced by a tag-stripped
# copy, which the caller muxes as an external input; a track without tags, or one
# that cannot be extracted (warning), stays in SUB_LINES and is muxed from the
# source. Args: input video, the name of the SUB_LINES array, the name of the
# output array. Appends to the output array one "LANG3 TYPE PATH" line per replaced
# track, LANG3 being the primary code. A track that loses its language-and-type
# group in select_subtitle_winners(), the choice build_subtitle_args() also makes,
# is dropped here, so a dropped duplicate is never extracted and removing a
# replaced track cannot promote a duplicate behind it.
strip_embedded_text_tracks() {
    local INPUT="$1"
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _SL="$2"
    local -n _REPL="$3"
    local -a kept=() plan=() cands=()
    local -A winner=() extracted=()
    local line entry idx raw type key list

    select_subtitle_winners winner "${_SL[@]+"${_SL[@]}"}"

    # Pass 1: drop the losers, set aside everything that needs no check, and
    # collect the SubRip and mov_text winners. plan keeps source order, each entry
    # prefixed "K " (keep as is) or "C " (check for override tags).
    for line in "${_SL[@]+"${_SL[@]}"}"; do
        local _ codec lang is_target is_forced is_signs is_cc rest
        read -r _ idx codec lang is_target is_forced is_signs is_cc rest <<< "$line"

        if [[ "$is_target" != "1" || "$is_signs" == "1" \
              || "$(subtitle_output_codec "$codec")" == "DROP" ]]; then
            plan+=("K $line")
            continue
        fi

        type="$(subtitle_track_type "$is_forced" "$is_cc")"
        key="$(subtitle_track_key "$lang" "$type")"
        if [[ "${winner[$key]}" != "$idx" ]]; then
            echo " Subtitle[src:$idx]: DROP ($lang, duplicate ${type/target/standard} track: src:${winner[$key]} kept)"
            continue
        fi

        if [[ "$codec" != "subrip" && "$codec" != "mov_text" ]]; then
            plan+=("K $line")
            continue
        fi

        plan+=("C $line")
        cands+=("$idx")
    done

    if (( ${#cands[@]} > 0 )); then
        list=""
        for idx in "${cands[@]}"; do list+="${list:+, }src:${idx}"; done
        echo " Subtitles: checking ${list} for ASS override tags (reads the whole file once)"

        if ! extract_embedded_srt "$INPUT" "${cands[@]}"; then
            # A track ffmpeg cannot convert fails the whole run. Discard what it
            # wrote and retry each track alone, so only the unreadable one goes
            # unchecked.
            rm -f -- "${SUB_TMP_DIR}"/raw/e*.srt
            if (( ${#cands[@]} > 1 )); then
                for idx in "${cands[@]}"; do
                    extract_embedded_srt "$INPUT" "$idx" || rm -f -- "${SUB_TMP_DIR}/raw/e${idx}.srt"
                done
            fi
        fi
        for idx in "${cands[@]}"; do
            [[ -s "${SUB_TMP_DIR}/raw/e${idx}.srt" ]] && extracted["$idx"]=1
        done
    fi

    # Pass 2: resolve each candidate in source order, so the kept tracks keep
    # their output order.
    for entry in "${plan[@]+"${plan[@]}"}"; do
        line="${entry:2}"
        if [[ "${entry:0:1}" == "K" ]]; then
            kept+=("$line")
            continue
        fi

        local _ codec lang is_target is_forced is_signs is_cc rest
        read -r _ idx codec lang is_target is_forced is_signs is_cc rest <<< "$line"
        raw="${SUB_TMP_DIR}/raw/e${idx}.srt"

        if [[ -z "${extracted[$idx]+_}" ]]; then
            echo " WARNING: could not read embedded subtitle src:$idx to check it for override tags; muxing it unchecked" >&2
            log "SUBTITLE TAG CHECK FAILED: $INPUT src:$idx (muxed unchecked)"
            kept+=("$line")
            continue
        fi

        if ! python3 "$STRIP_PY" has "$raw"; then
            kept+=("$line")
            continue
        fi

        type="$(subtitle_track_type "$is_forced" "$is_cc")"
        if strip_sidecar_sub "$raw"; then
            echo " Subtitle[src:$idx]: ASS override tags found, muxing a tag-stripped copy"
            _REPL+=("$(canon_lang "$lang") ${type} ${STRIPPED_SUB_PATH}")
        else
            printf ' WARNING: tag-strip failed for embedded subtitle src:%s; muxing the original (may still show {\\an8}-style text on screen)\n' "$idx" >&2
            log "SUBTITLE TAG STRIP FAILED: $INPUT src:$idx (muxed unstripped)"
            kept+=("$line")
        fi
    done
    rm -f -- "${SUB_TMP_DIR}"/raw/e*.srt

    _SL=("${kept[@]+"${kept[@]}"}")
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
    local job m_tmp m_final
    local -a moved=()
    for job in "${_MJOBS[@]+"${_MJOBS[@]}"}"; do
        IFS=$'\t' read -r _ m_tmp m_final <<< "$job"
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
    local job r_final
    for job in "${_RJOBS[@]+"${_RJOBS[@]}"}"; do
        IFS=$'\t' read -r _ _ r_final <<< "$job"
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

# -- verify_merged_duration -----------------------------------------------------------
# Sets MERGED_DURATION_ACTUAL to the duration of FILE in seconds (empty when it cannot
# be read). Returns 0 when it is within the merge tolerance of EXPECTED seconds, 1
# otherwise or when it cannot be read. Call on the .tmp output of a merged set.
MERGED_DURATION_ACTUAL=""
verify_merged_duration() {
    local FILE="$1" EXPECTED="$2"
    MERGED_DURATION_ACTUAL=""
    MERGED_DURATION_ACTUAL="$(probe_duration "$FILE")" || return 1
    awk -v a="$MERGED_DURATION_ACTUAL" -v e="$EXPECTED" \
        -v pct="$MERGE_TOLERANCE_PCT" -v min="$MERGE_TOLERANCE_MIN_SECONDS" \
        'BEGIN { tol = e * pct / 100; if (tol < min) tol = min; d = a - e; if (d < 0) d = -d; exit (d <= tol) ? 0 : 1 }'
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

# -- finish_outputs ------------------------------------------------------------------
# Runs -M and then -A for one encoded file. With -M set, archives each sidecar
# output and then the video to ARCHIVE_DIR, the video only if every sidecar was
# archived. With -A set and no archive failure, moves the muxed sidecar
# subtitles and then the source video, or every part of a merged set, into
# BACKUP_DIR; a merged set moves nothing when the backup destination of any part
# already exists. Args: input video (part 1 of a merged set),
# output video, scan root (empty for a file or glob input), then the names of
# the sidecar job array ("STRIP<TAB>TMP<TAB>FINAL" lines) and the sidecar
# "LANG TYPE PATH" line array. In a dry run it prints the planned moves and
# touches nothing. Returns 0 when every requested step succeeded, 1 otherwise;
# every failure is logged.
finish_outputs() {
    local INPUT="$1" OUTPUT="$2" ROOT="$3"
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _FO_JOBS="$4"
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _FO_EXTSUB="$5"
    local POST_RC=0 _job _j_strip _j_tmp _j_final

    if [[ -n "$ARCHIVE_DIR" ]]; then
        # Sidecars first, video last, and the video only if every sidecar
        # was archived.
        for _job in "${_FO_JOBS[@]+"${_FO_JOBS[@]}"}"; do
            IFS=$'\t' read -r _j_strip _j_tmp _j_final <<< "$_job"
            archive_output "$_j_final" "$ROOT" "$ARCHIVE_DIR" || POST_RC=1
        done
        (( POST_RC )) || archive_output "$OUTPUT" "$ROOT" "$ARCHIVE_DIR" || POST_RC=1
    fi
    if (( POST_RC )); then
        echo " WARNING: archive failed; source and sidecars left in place, output kept at $OUTPUT" >&2
        log "BACKUP SKIPPED (archive failed): $(basename "$INPUT")"
    elif [[ -n "$BACKUP_DIR" ]]; then
        local _part _taken=""
        if (( ${#CURRENT_PARTS[@]} > 1 )); then
            for _part in "${CURRENT_PARTS[@]}"; do
                [[ -e "$(backup_dest_path "$_part" "$ROOT" "$BACKUP_DIR")" ]] && _taken="$_part"
            done
        fi
        if [[ -n "$_taken" ]]; then
            echo " WARNING: backup destination already exists for $(basename -- "$_taken"); no part or sidecar moved" >&2
            log "BACKUP SKIPPED (destination exists): $(basename "$_taken")"
        elif backup_sidecar_subs "${_FO_EXTSUB[@]+"${_FO_EXTSUB[@]}"}" "$ROOT" "$BACKUP_DIR"; then
            for _part in "${CURRENT_PARTS[@]}"; do
                backup_input "$_part" "$ROOT" "$BACKUP_DIR" || true
            done
        else
            echo " WARNING: a sidecar move failed; source video left in place with its remaining sidecars" >&2
            log "BACKUP SKIPPED (sidecar move failed): $(basename "$INPUT")"
        fi
    fi
    return "$POST_RC"
}

# -- execute_encode ------------------------------------------------------------------
# Runs ffmpeg into OUTPUT_TMP, verifies the result (non-empty, SDR transfer,
# subtitle stream count), promotes it to OUTPUT, then runs finish_outputs() for
# -M and -A. Args 7-9
# are the names of the ffmpeg arg array, the container-flag array, and the
# sidecar "LANG TYPE PATH" line array (the files -A moves, including a VobSub pair a text
# sidecar made redundant); arg 10 is the number of subtitle streams
# the build step emitted; args 11 and 12 are the names of the sidecar ffmpeg
# output-argument array and sidecar job array (-S sidecar; empty otherwise, see
# build_sidecar_outputs). Returns 0 on success, 1 on any failure (including a
# failed -M archive).
execute_encode() {
    local INPUT="$1" OUTPUT="$2" OUTPUT_TMP="$3" OUTPUT_DIR_FOR_FILE="$4" ROOT="$5" SRC_CODEC_LABEL="$6"
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _FF="$7"
    local -n _CF="$8"
    local EXTSUB_NAME="$9"
    local EXPECTED_SUBS="${10}"
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _SFF="${11}"
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
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

    local JOB_LABEL
    JOB_LABEL="$(basename "$INPUT")"
    if (( ${#CURRENT_PARTS[@]} > 1 )); then
        JOB_LABEL+=" (+$(( ${#CURRENT_PARTS[@]} - 1 )) more parts)"
    fi

    echo " Running ffmpeg..."
    log "PROCESSING: $JOB_LABEL"
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

    spin_until_exit "$FFMPEG_PID"

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

        if [[ -n "$CURRENT_EXPECTED_SECONDS" ]] && ! verify_merged_duration "$OUTPUT_TMP" "$CURRENT_EXPECTED_SECONDS"; then
            echo " ERROR: merged output runs ${MERGED_DURATION_ACTUAL:-an unreadable number of} s, expected ${CURRENT_EXPECTED_SECONDS} s (the parts' total); not promoted, sources untouched" >&2
            log "FAILED (merged duration ${MERGED_DURATION_ACTUAL:-unreadable} != ${CURRENT_EXPECTED_SECONDS}): $INPUT"
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
        local SRC_BYTES=0 OUT_BYTES SRC_MB OUT_MB _part _part_bytes
        for _part in "${CURRENT_PARTS[@]}"; do
            _part_bytes=$(stat -c '%s' "$_part" 2>/dev/null || echo 0)
            SRC_BYTES=$(( SRC_BYTES + _part_bytes ))
        done
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
        log "COMPLETED: $JOB_LABEL [${SRC_CODEC_LABEL}] | $(( FILE_DUR / 60 ))m $(( FILE_DUR % 60 ))s | src: ${SRC_MB}MB -> out: ${OUT_MB}MB (${SIZE_DIFF})"
        # Ignore growth under 2%: rounding noise, not a real size regression
        if (( GROWTH_PCT >= 2 )); then
            echo " WARNING: output is larger than source (${SIZE_DIFF})" >&2
            log "SIZE WARNING: $JOB_LABEL | output ${OUT_MB}MB exceeds source ${SRC_MB}MB (${SIZE_DIFF})"
        fi

        # The source and its sidecars move only after the output is safely in
        # place: a failed archive leaves them where they are.
        local POST_RC=0
        finish_outputs "$INPUT" "$OUTPUT" "$ROOT" _JOBS "$EXTSUB_NAME" || POST_RC=1

        [[ "$STDERR_CAPTURE" != "/dev/null" ]] && rm -f -- "$STDERR_CAPTURE"
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

# -- write_concat_list ---------------------------------------------------------------
# Writes the concat demuxer list LIST for the part files that follow it: one
# "file '<absolute path>'" line per part, in order. A single quote inside a path is
# written as '\'' (close the quote, an escaped quote, reopen the quote). Writes nothing
# in a dry run. Returns 1 when LIST cannot be written.
write_concat_list() {
    local LIST="$1" p
    local QUOTE_ESCAPE="'\\''"
    shift
    (( DRY_RUN )) && return 0
    : > "$LIST" || return 1
    for p in "$@"; do
        [[ "$p" == /* ]] || p="$PWD/$p"
        printf "file '%s'\n" "${p//\'/$QUOTE_ESCAPE}" >> "$LIST" || return 1
    done
}

# -- VobSub sidecars (.idx + .sub) -----------------------------------------------------
# State of the VobSub OCR check: "" until ocr_ready() has run, then 1 (usable) or 0.
OCR_READY=""
# The tesseract languages installed, space separated with a space at each end. Set by
# ocr_ready().
OCR_LANGS=""

# Checks once per run that VobSub OCR can run: subtitle_ocr.py beside this script,
# tesseract on the PATH, Pillow for python3. Prints one warning naming the first thing
# missing and returns 1 when OCR cannot run. Called from the main shell, never from a
# command substitution, so the result is kept.
ocr_ready() {
    if [[ -n "$OCR_READY" ]]; then
        [[ "$OCR_READY" == 1 ]]
        return
    fi
    OCR_READY=0
    if [[ ! -r "$OCR_PY" ]]; then
        echo " WARNING: VobSub subtitles found but subtitle_ocr.py is missing next to this script; they are not used" >&2
    elif ! command -v tesseract >/dev/null 2>&1; then
        echo " WARNING: VobSub subtitles found but tesseract is not installed; they are not used" >&2
    elif ! python3 -I -c 'import PIL' 2>/dev/null; then
        echo " WARNING: VobSub subtitles found but python3 lacks Pillow; they are not used" >&2
    else
        OCR_LANGS=" $(tesseract --list-langs 2>/dev/null | tail -n +2 | tr '\n' ' ')"
        OCR_READY=1
    fi
    [[ "$OCR_READY" == 1 ]]
}

# Echoes the tesseract language name for the 3-letter language code LANG3 (tesseract
# names its data after the ISO 639-2 terminology codes, where bibliographic codes such
# as fre and ger differ from them).
tesseract_lang() {
    case "$1" in
        fre|fra) echo fra ;;
        ger|deu) echo deu ;;
        dut|nld) echo nld ;;
        cze|ces) echo ces ;;
        gre|ell) echo ell ;;
        per|fas) echo fas ;;
        wel|cym) echo cym ;;
        baq|eus) echo eus ;;
        mac|mkd) echo mkd ;;
        may|msa) echo msa ;;
        bur|mya) echo mya ;;
        chi|zho) echo chi_sim ;;
        *)       echo "$1" ;;
    esac
}

# Finds the VobSub sidecars next to INPUT: for each target language in SUB_LANGS and
# each of <base>.<lang2>.idx, <base>.<lang2>.cc.idx (or .sdh.idx, after .cc) and
# <base>.<lang2>.forced.idx, an .idx with its .sub beside it and a track of that
# language in the .idx. Appends one "LANG3 TYPE IDX_PATH" line per find to the array
# named by arg 2; the remaining args are the already claimed "LANG3 TYPE PATH" lines.
# A pair whose language and type already has a claimed text sidecar is not read; it is
# appended to the global VOBSUB_SHADOWED instead (same line form), which each call
# resets, so the caller can say why it is unused and back it up with the video. An .idx
# that cannot be used for any other reason is in neither array, so it is reported as
# unclaimed. Runs in the calling shell (no command substitution) so the one-time OCR
# warning is kept.
VOBSUB_SHADOWED=()
discover_vobsub_sidecars() {
    local INPUT="$1"
    VOBSUB_SHADOWED=()
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function
    local -n _VOUT="$2"
    shift 2
    local DIR BASE
    DIR="$(dirname "$INPUT")"
    BASE="$(basename "${INPUT%.*}")"

    local -A TAKEN=() TEXT_TAKEN=()
    local line _l _t _p
    for line in "$@"; do
        read -r _l _t _p <<< "$line"
        TAKEN["${_l} ${_t}"]=1
        TEXT_TAKEN["${_l} ${_t}"]=1
    done

    local -a TARGET_LANGS=()
    IFS=',' read -ra TARGET_LANGS <<< "$SUB_LANGS"
    local lang3 lang2 cand type suffix f tl
    for lang3 in "${TARGET_LANGS[@]+"${TARGET_LANGS[@]}"}"; do
        lang2="${LANG_3TO2[$lang3]:-}"
        [[ -n "$lang2" ]] || continue
        for cand in "target:" "cc:.cc" "cc:.sdh" "forced:.forced"; do
            type="${cand%%:*}"
            suffix="${cand#*:}"
            f="${DIR}/${BASE}.${lang2}${suffix}.idx"
            [[ -f "$f" && -f "${f%.idx}.sub" ]] || continue
            if [[ -n "${TEXT_TAKEN[${lang3} ${type}]+_}" ]]; then
                VOBSUB_SHADOWED+=("${lang3} ${type} ${f}")
                continue
            fi
            [[ -z "${TAKEN[${lang3} ${type}]+_}" ]] || continue
            ocr_ready || continue
            tl="$(tesseract_lang "$lang3")"
            if [[ "$OCR_LANGS" != *" ${tl} "* ]]; then
                echo " WARNING: tesseract has no '${tl}' language data installed; not using $(basename "$f")" >&2
                continue
            fi
            if ! python3 -I "$OCR_PY" tracks "$f" 2>/dev/null | awk -v l="$lang2" '$1 == l { found = 1 } END { exit !found }'; then
                echo " WARNING: $(basename "$f") has no '${lang2}' track; not using it" >&2
                continue
            fi
            TAKEN["${lang3} ${type}"]=1
            _VOUT+=("${lang3} ${type} ${f}")
        done
    done
}

# Reads the first track of language LANG3 in the VobSub IDX by OCR and writes it to OUT
# as SubRip. The spinner shows while it runs, and the process is registered in
# CURRENT_FFMPEG_PID so the SIGINT/SIGTERM handler stops it. Prints the cue count on
# success. Returns 1 on a failure, after printing why.
ocr_vobsub() {
    local IDX="$1" LANG3="$2" OUT="$3"
    local lang2 track RC=0 msg
    lang2="${LANG_3TO2[$LANG3]:-}"
    track="$(python3 -I "$OCR_PY" tracks "$IDX" 2>/dev/null | awk -v l="$lang2" '$1 == l { print $2; exit }')"
    [[ -n "$track" ]] || { echo " WARNING: $(basename "$IDX") has no '${lang2}' track" >&2; return 1; }
    mkdir -p -- "${OUT%/*}" || return 1
    python3 -I "$OCR_PY" ocr "$IDX" "$track" "$OUT" "$(tesseract_lang "$LANG3")" >"${OUT}.out" 2>"${OUT}.err" &
    CURRENT_FFMPEG_PID=$!
    spin_until_exit "$CURRENT_FFMPEG_PID" "OCR $(basename "$IDX")"
    wait "$CURRENT_FFMPEG_PID" || RC=$?
    CURRENT_FFMPEG_PID=""
    if (( RC != 0 )) || [[ ! -s "$OUT" ]]; then
        msg="$(head -n 1 "${OUT}.err" 2>/dev/null)"
        echo " WARNING: OCR of $(basename "$IDX") failed${msg:+: $msg}" >&2
        return 1
    fi
    echo " Subtitles: OCR of $(basename "$IDX") ($LANG3, track $track): $(< "${OUT}.out")"
}

# -- join_part_sidecars --------------------------------------------------------------
# Joins the sidecar subtitles of each language and type across the parts of a merged
# set into one SubRip file under SUB_TMP_DIR/join, so the subtitles follow the joined video:
# ffmpeg converts each part's file to SubRip, and subtitle_join.py shifts it by the
# summed durations of the parts before it and writes the joined file. Args: the name of
# the output array, the name of the array of part durations in seconds, then one
# "PART_INDEX LANG TYPE PATH" line per sidecar (PART_INDEX counts from 0). Appends to
# the output array one "LANG TYPE PATH" line per language and type, in the order first
# seen, PATH being the joined file. A language and type missing from some parts is
# joined from the parts that have it, with a warning. In a dry run it prints the plan,
# writes nothing and appends the first file of each language and type. Returns 1 on the
# first file that cannot be converted or joined, with the file named.
join_part_sidecars() {
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _JOUT="$1"
    local -n _JDURS="$2"
    shift 2
    local -a ORDER=() OFFSETS=() JOIN_ARGS=()
    local -A FILES=()
    local line idx lang type path key d acc=0 first n conv joined lang_type

    if (( ! DRY_RUN )) && ! mkdir -p -- "${SUB_TMP_DIR}/join"; then
        echo " ERROR: could not create the subtitle join directory under $SUB_TMP_DIR" >&2
        return 1
    fi
    for d in "${_JDURS[@]}"; do
        OFFSETS+=("$acc")
        acc="$(awk -v a="$acc" -v b="$d" 'BEGIN { printf "%.3f", a + b }')"
    done
    for line in "$@"; do
        read -r idx lang type path <<< "$line"
        key="${lang} ${type}"
        [[ -n "${FILES[$key]+_}" ]] || ORDER+=("$key")
        FILES["$key"]+="${idx} ${path}"$'\n'
    done

    for key in "${ORDER[@]+"${ORDER[@]}"}"; do
        read -r lang type <<< "$key"
        lang_type="${lang}_${type}"
        JOIN_ARGS=(); n=0; first=""
        while IFS=' ' read -r idx path; do
            [[ -n "$idx" ]] || continue
            n=$(( n + 1 ))
            [[ -n "$first" ]] || first="$path"
            (( DRY_RUN )) && continue
            conv="${SUB_TMP_DIR}/join/part_${FILE_NUM}_${idx}_${lang_type}.srt"
            if ! ffmpeg -nostdin -v error -y -i "$path" -c:s srt "$conv" 2>/dev/null || [[ ! -s "$conv" ]]; then
                echo " ERROR: could not convert subtitle file to SubRip: $path" >&2
                return 1
            fi
            JOIN_ARGS+=("${OFFSETS[$idx]}" "$conv")
        done <<< "${FILES[$key]}"

        if (( n < ${#_JDURS[@]} )); then
            echo " WARNING: $lang/$type subtitles exist for $n of ${#_JDURS[@]} parts; the other parts have none" >&2
            log "SUBTITLE PARTS MISSING: $lang/$type has $n of ${#_JDURS[@]} parts"
        fi
        if (( DRY_RUN )); then
            echo " [DRY RUN] Would join $n $lang/$type subtitle file(s), each shifted by the parts before it"
            _JOUT+=("${lang} ${type} ${first}")
            continue
        fi
        joined="${SUB_TMP_DIR}/join/joined_${FILE_NUM}_${lang_type}.srt"
        if ! python3 "$JOIN_PY" join "$joined" "${JOIN_ARGS[@]}"; then
            echo " ERROR: could not join the $lang/$type subtitle files" >&2
            return 1
        fi
        echo " Subtitles: joined $n $lang/$type file(s), each shifted by the parts before it"
        _JOUT+=("${lang} ${type} ${joined}")
    done
}

# -- Process one job -------------------------------------------------------------------
# Encodes one job: a single video file, or the parts of a merged multi-part set (INPUT
# is part 1; GROUP_PARTS holds the rest). Sets CURRENT_PARTS and CURRENT_EXPECTED_SECONDS
# for execute_encode() and finish_outputs(). Returns 0 on success, 1 on failure, 2 when
# skipped (-s), 3 for a dry run.
process_file() {
    local INPUT="$1"
    local ROOT="$2"
    local line
    SIDECAR_EXTRACT_LINES=()
    CURRENT_PARTS=("$INPUT")
    CURRENT_EXPECTED_SECONDS=""

    local IS_GROUP=0 OUT_STEM=""
    if [[ -n "${GROUP_PARTS[$INPUT]+_}" ]]; then
        IS_GROUP=1
        mapfile -t CURRENT_PARTS <<< "${GROUP_PARTS[$INPUT]}"
        multipart_parse "$(basename -- "${INPUT%.*}")"
        OUT_STEM="$MP_STEM"
    fi

    local OUTPUT
    OUTPUT="$(compute_output_path "$INPUT" "$ROOT" "$OUT_STEM")"
    local OUTPUT_DIR_FOR_FILE
    OUTPUT_DIR_FOR_FILE="$(dirname "$OUTPUT")"
    local OUTPUT_TMP
    OUTPUT_TMP="${OUTPUT_DIR_FOR_FILE}/.$(basename "${OUTPUT%.*}").tmp.${OUT_FORMAT}"

    FILE_NUM=$(( FILE_NUM + 1 ))
    echo ""
    echo "------------------------------------------"
    echo " [${FILE_NUM}/${#ALL_FILES[@]}] INPUT : $INPUT"
    local _pn
    for (( _pn=1; _pn<${#CURRENT_PARTS[@]}; _pn++ )); do
        echo "          + part $(( _pn + 1 )): ${CURRENT_PARTS[$_pn]}"
    done
    echo " OUTPUT: $OUTPUT"
    echo "------------------------------------------"

    if [[ -f "$OUTPUT" ]] && (( SKIP_EXISTING )); then
        echo " SKIP: output already exists (-s)"
        log "SKIPPED: $(basename "$INPUT")"
        return 2
    fi

    local -a PART_DURS=()
    if (( IS_GROUP )); then
        local _p _pd
        for _p in "${CURRENT_PARTS[@]}"; do
            if ! _pd="$(probe_duration "$_p")"; then
                echo " ERROR: could not read the duration of $_p" >&2
                log "FAILED (part duration): $_p"
                return 1
            fi
            PART_DURS+=("$_pd")
        done
        CURRENT_EXPECTED_SECONDS="$(sum_seconds "${PART_DURS[@]}")"
        echo " Parts: ${#CURRENT_PARTS[@]} joined, $(format_runtime "${CURRENT_EXPECTED_SECONDS%.*}") in total"
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
    # PART_SUB_LINES carries the same lines prefixed with the index of the part they
    # belong to, for join_part_sidecars().
    local -a EXTSUB_LINES=() PART_SUB_LINES=() _part_lines=() _report_lines=() _vob_lines=()
    # EXTSUB_LINES plus the VobSub pairs a text sidecar made redundant: what -A moves
    local -a BACKUP_LINES=() SHADOWED_LINES=()
    # VobSub .idx path -> the SubRip file its OCR wrote, for the sidecars muxed below
    local -A OCR_SRT=()
    local _unclaimed _pi _vl _vt _vp _vsrt
    for (( _pi=0; _pi<${#CURRENT_PARTS[@]}; _pi++ )); do
        _part_lines=()
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            _part_lines+=("$line")
            EXTSUB_LINES+=("$line")
            PART_SUB_LINES+=("${_pi} ${line}")
        done < <(discover_sidecar_subs "${CURRENT_PARTS[$_pi]}")

        # VobSub pairs for the languages and types the text sidecars did not cover.
        # Each is read by OCR into a SubRip file under SUB_TMP_DIR; EXTSUB_LINES keeps
        # the .idx path, which is what -A moves later.
        _report_lines=("${_part_lines[@]+"${_part_lines[@]}"}")
        _vob_lines=()
        discover_vobsub_sidecars "${CURRENT_PARTS[$_pi]}" _vob_lines "${_part_lines[@]+"${_part_lines[@]}"}"
        # A pair a text sidecar of the same language and type made redundant is not read.
        # It belongs to this video, so -A moves it with the rest.
        for line in "${VOBSUB_SHADOWED[@]+"${VOBSUB_SHADOWED[@]}"}"; do
            read -r _vl _vt _vp <<< "$line"
            echo " Subtitles: $(basename "$_vp") not used, the text sidecar of the same language and type ($_vl/$_vt) is used instead"
            SHADOWED_LINES+=("$line")
            _report_lines+=("$line" "${_vl} ${_vt} ${_vp%.idx}.sub")
        done
        for line in "${_vob_lines[@]+"${_vob_lines[@]}"}"; do
            read -r _vl _vt _vp <<< "$line"
            if (( DRY_RUN )); then
                echo " [DRY RUN] Would read $(basename "$_vp") by OCR ($_vl/$_vt) into SubRip"
            else
                _vsrt="${SUB_TMP_DIR}/ocr/p${FILE_NUM}_${_pi}_${_vl}_${_vt}.srt"
                if ! ocr_vobsub "$_vp" "$_vl" "$_vsrt"; then
                    log "VOBSUB OCR FAILED: $_vp"
                    continue
                fi
                OCR_SRT["$_vp"]="$_vsrt"
            fi
            _part_lines+=("$line")
            _report_lines+=("$line" "${_vl} ${_vt} ${_vp%.idx}.sub")
            EXTSUB_LINES+=("$line")
            PART_SUB_LINES+=("${_pi} ${line}")
        done

        # Files next to the video that discovery does not embed (other formats, a
        # language outside -l, an unrecognized modifier, a shadowed .sdh.srt).
        while IFS= read -r _unclaimed; do
            [[ -n "$_unclaimed" ]] || continue
            echo " WARNING: subtitle file not used (format, language, modifier, duplicate, text not valid UTF-8, or VobSub that could not be read), stays in the source directory: $(basename "$_unclaimed")" >&2
            log "SUBTITLE FILE UNCLAIMED: $_unclaimed"
        done < <(report_unclaimed_sidecars "${CURRENT_PARTS[$_pi]}" "${_report_lines[@]+"${_report_lines[@]}"}")
    done

    BACKUP_LINES=("${EXTSUB_LINES[@]+"${EXTSUB_LINES[@]}"}" "${SHADOWED_LINES[@]+"${SHADOWED_LINES[@]}"}")

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

    # -S embed: an embedded SubRip or mov_text track that carries ASS override
    # tags is replaced by a tag-stripped copy, muxed below as an extra input.
    # Not in EXTSUB_LINES: these copies are scratch files, never backed up.
    local -a EMBED_STRIPPED_LINES=()
    if (( IS_GROUP )); then
        if [[ "$SUB_MODE" == "embed" ]] && (( ${#SUB_LINES[@]} > 0 )); then
            echo " Subtitles: embedded tracks of a merged set are joined with the video, not checked for ASS override tags"
        fi
    elif [[ "$SUB_MODE" == "embed" ]] && (( ! DRY_RUN )); then
        strip_embedded_text_tracks "$INPUT" SUB_LINES EMBED_STRIPPED_LINES
    fi

    local TITLE_TAG
    TITLE_TAG="$(basename "${OUTPUT%.*}")"

    # The sidecars ffmpeg opens: each one as found for a single file; one joined file
    # per language and type for a merged set.
    # A VobSub .idx is replaced by the SubRip file its OCR wrote.
    local -a MUX_SRC_LINES=() MUX_PART_LINES=()
    local _mi _ml _mt _mp
    for line in "${EXTSUB_LINES[@]+"${EXTSUB_LINES[@]}"}"; do
        read -r _ml _mt _mp <<< "$line"
        MUX_SRC_LINES+=("${_ml} ${_mt} ${OCR_SRT[$_mp]:-$_mp}")
    done
    for line in "${PART_SUB_LINES[@]+"${PART_SUB_LINES[@]}"}"; do
        read -r _mi _ml _mt _mp <<< "$line"
        MUX_PART_LINES+=("${_mi} ${_ml} ${_mt} ${OCR_SRT[$_mp]:-$_mp}")
    done
    if (( IS_GROUP && ${#EXTSUB_LINES[@]} > 0 )); then
        MUX_SRC_LINES=()
        if ! join_part_sidecars MUX_SRC_LINES PART_DURS "${MUX_PART_LINES[@]}"; then
            log "FAILED (sidecar join): $INPUT"
            return 1
        fi
    fi

    # Build the input list first: main video is input 0, each sidecar
    # gets its own -i and a sequential input index for -map. On a real run,
    # each subrip sidecar is run through strip_sidecar_sub() first so ffmpeg's -i
    # points at a tag-stripped copy, never the original on-disk file - the
    # original path (in EXTSUB_LINES, above) is what backup_sidecar_subs()
    # moves later, so the stripped copy being scratch-only doesn't affect
    # the backup. On a dry run, stripping is skipped entirely (no temp
    # directory even exists - see the DRY_RUN guard around
    # SUB_TMP_DIR's creation, above): the printed plan shows the original
    # sidecar path with a note, rather than a real disk mutation whose
    # output is then only used to print a message.
    local -a INPUT_ARGS=(-analyzeduration "$PROBE_SIZE" -probesize "$PROBE_SIZE" -i "$INPUT")
    if (( IS_GROUP )); then
        local CONCAT_LIST="${SUB_TMP_DIR:-${TMPDIR:-/tmp}}/concat_${FILE_NUM}.txt"
        (( DRY_RUN )) && echo " [DRY RUN] Would join ${#CURRENT_PARTS[@]} parts with the concat demuxer (list file: $CONCAT_LIST)"
        if ! write_concat_list "$CONCAT_LIST" "${CURRENT_PARTS[@]}"; then
            echo " ERROR: could not write the concat list: $CONCAT_LIST" >&2
            log "FAILED (concat list): $INPUT"
            return 1
        fi
        INPUT_ARGS=(-analyzeduration "$PROBE_SIZE" -probesize "$PROBE_SIZE" -f concat -safe 0 -i "$CONCAT_LIST")
    fi
    local -a EXTSUB_WITH_IDX=()
    local _next_input_idx=1
    for line in "${MUX_SRC_LINES[@]+"${MUX_SRC_LINES[@]}"}"; do
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
            printf ' WARNING: tag-strip failed for %s; using original (may still show {\\an8}-style text on screen)\n' "$(basename "$_e_path")" >&2
            log "SUBTITLE TAG STRIP FAILED: $_e_path (used unstripped)"
        fi

        INPUT_ARGS+=(-i "$_e_mux_path")
        EXTSUB_WITH_IDX+=("${_e_lang} ${_e_type} ${_next_input_idx} ${_e_mux_path}")
        _next_input_idx=$(( _next_input_idx + 1 ))
    done

    for line in "${EMBED_STRIPPED_LINES[@]+"${EMBED_STRIPPED_LINES[@]}"}"; do
        local _m_lang _m_type _m_path
        read -r _m_lang _m_type _m_path <<< "$line"
        INPUT_ARGS+=(-i "$_m_path")
        EXTSUB_WITH_IDX+=("${_m_lang} ${_m_type} ${_next_input_idx} ${_m_path}")
        _next_input_idx=$(( _next_input_idx + 1 ))
    done

    local -a FF_ARGS=("${INPUT_ARGS[@]}" -map_metadata -1 -metadata "title=${TITLE_TAG}")
    local -a CONTAINER_FLAGS=()
    [[ "$OUT_FORMAT" == "mp4" ]] && CONTAINER_FLAGS+=(-movflags +faststart)

    local SRC_KBPS
    SRC_KBPS="$(probe_overall_kbps "$INPUT")" || SRC_KBPS=""
    build_video_args    FF_ARGS "$VID_CODEC" "$SRC_HEIGHT" "$SRC_FPS" "$SRC_TRANSFER" "$SRC_DOVI" "$SRC_PIXFMT" "$SRC_KBPS"
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
        local DRY_CMD
        printf -v DRY_CMD '%q ' ffmpeg "${FF_ARGS[@]}" "${CONTAINER_FLAGS[@]+"${CONTAINER_FLAGS[@]}"}" \
            "$OUTPUT_TMP" "${SIDECAR_FF[@]+"${SIDECAR_FF[@]}"}"
        echo " [DRY RUN] ${DRY_CMD}&& mv -- $(printf '%q %q' "$OUTPUT_TMP" "$OUTPUT")"
        finish_outputs "$INPUT" "$OUTPUT" "$ROOT" SIDECAR_JOBS BACKUP_LINES || true
        return 3
    fi

    execute_encode "$INPUT" "$OUTPUT" "$OUTPUT_TMP" "$OUTPUT_DIR_FOR_FILE" "$ROOT" "${VID_CODEC_LABEL:-$VID_CODEC}" FF_ARGS CONTAINER_FLAGS BACKUP_LINES "$SUB_OUT_IDX" SIDECAR_FF SIDECAR_JOBS
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
    # Two runs finishing in one minute must not overwrite each other's log.
    [[ -e "$LOG_FILE_FINAL" ]] && LOG_FILE_FINAL="$LOG_DIR/Log_$(date '+%Y-%m-%d_%H%M%S').txt"
    mv -- "$LOG_FILE_TEMP" "$LOG_FILE_FINAL"
    echo "Log saved to: $LOG_FILE_FINAL"
else
    echo "Log retained at: $LOG_FILE_TEMP (batch had failures)"
fi

[[ $ENCODE_FAIL -eq 0 ]] || exit 1