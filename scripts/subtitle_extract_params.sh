#!/usr/bin/env bash
# subtitle_extract_params.sh: Extracts an embedded subrip/mov_text subtitle
# track from a video into a Plex-convention sidecar .srt file
# (Movie.en.srt / Movie.en.cc.srt / Movie.en.forced.srt), stripping any
# leftover ASS override tags (e.g. {\an8}) via the same subtitle_tag_strip.sh
# pipeline subtitle_embed_params.sh uses on the embedding side. This
# implements the embedded-track half of that pipeline as a standalone
# extract-first step, rather than as in-place stripping inside
# encoder_params.sh itself: run this once to turn a risky embedded track
# into a sidecar, and encoder_params.sh's existing sidecar-discovery and
# stripping picks it up on any later encode, with no changes needed there.
#
# Usage:  ./subtitle_extract_params.sh [OPTIONS] <video_input>
#
# Options:
#   -i INDEX    Absolute ffprobe stream index of the subtitle track to
#               extract. If omitted, auto-picks the first subrip/mov_text
#               track matching -l LANG, skipping any Signs/Songs track by
#               title (same skip rule encoder_params.sh's probe applies).
#   -l LANG     3-letter language code to auto-pick by (default: eng). The
#               track's own language tag is compared after alias resolution
#               (fre = fra) and an untagged track (und) counts as eng.
#               Ignored if -i is given explicitly.
#   -o DIR      Directory to write the sidecar into (default: same
#               directory as the input video)
#   -I DIR      Fallback resolution base: if <video_input> doesn't exist as
#               given, try DIR/<video_input> before failing. A path that
#               already resolves is never rewritten. Intended for a
#               wrapper to pass a shared base directory (e.g. config.sh's
#               INPUT_DIR) as an explicit value.
#   -F          Overwrite the destination sidecar if it already exists
#               (default: skip and fail rather than overwrite)
#   -n          Dry run: print the plan, write nothing
#   -h          Show this help
#
# Notes:
#   * Only subrip and mov_text source tracks are supported. A genuine
#     ass/ssa track is refused outright: {\an8} there is real positioning,
#     correctly rendered by an ASS-capable player, not a conversion
#     artifact - extracting it to plain SRT would be a lossy, incorrect
#     conversion, not a tag-strip. A bitmap track (hdmv_pgs_subtitle,
#     dvd_subtitle, dvbsub) is refused too: there is no text to extract.
#   * The destination filename follows the same convention
#     discover_sidecar_subs() (subtitle_mux.sh) already expects, so a
#     subsequent encoder_params.sh or subtitle_embed_params.sh run picks
#     it up as a normal sidecar. The file's suffix carries the track's type
#     (standard, .cc, .forced), and encoder_params.sh's rule is that a
#     sidecar replaces an embedded track of the same language and the same
#     type, so a later encode of this video prefers this sidecar over the
#     embedded track it came from.
#   * The source video is never modified; the embedded track stays exactly
#     as it was. This script only ever writes the new sidecar file.

set -euo pipefail

# -- Bash version guard ---------------------------------------------------------
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require ffmpeg
require ffprobe
require python3
require flock
require sed

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates a sidecar file a normal user needs to own." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lang_table.sh
source "$SCRIPT_DIR/lang_table.sh"
# shellcheck source=./subtitle_tag_strip.sh
source "$SCRIPT_DIR/subtitle_tag_strip.sh"

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

EXPLICIT_INDEX=""
TARGET_LANG="eng"
OUT_DIR=""
BASE_DIR=""
FORCE=0
DRY_RUN=0

while getopts ":i:l:o:I:Fnh" opt; do
    case $opt in
        i) EXPLICIT_INDEX="$OPTARG" ;;
        l) TARGET_LANG="$OPTARG" ;;
        o) OUT_DIR="$OPTARG" ;;
        I) BASE_DIR="$OPTARG" ;;
        F) FORCE=1 ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ $# -eq 1 ]] || {
    echo "Usage: $0 [OPTIONS] <video_input>" >&2
    echo "  Run $0 -h for full help." >&2
    exit 1
}
INPUT="$1"
# -I is a fallback resolution base, not a rewrite of what was given: only
# consulted if INPUT doesn't already exist as a literal path. See the same
# option in subtitle_embed_params.sh for the reasoning (config.sh's
# INPUT_DIR passed as an explicit CLI value, since "source config.sh; exec"
# does not inherit its unexported variables).
if [[ ! -f "$INPUT" && -n "$BASE_DIR" && -f "${BASE_DIR}/${INPUT}" ]]; then
    INPUT="${BASE_DIR}/${INPUT}"
fi
[[ -f "$INPUT" ]] || { echo "ERROR: input video not found: $INPUT" >&2; exit 1; }

if [[ -n "$EXPLICIT_INDEX" ]] && ! [[ "$EXPLICIT_INDEX" =~ ^[0-9]+$ ]]; then
    echo "ERROR: -i must be a non-negative integer stream index (got: $EXPLICIT_INDEX)" >&2
    exit 1
fi

[[ -z "$OUT_DIR" ]] && OUT_DIR="$(dirname "$INPUT")"
[[ -d "$OUT_DIR" ]] || { echo "ERROR: output directory does not exist: $OUT_DIR" >&2; exit 1; }

# Primary code3 of -l, compared against each track's canonicalized tag.
TARGET_CANON="$(canon_lang "$TARGET_LANG")"

# -- Probe subtitle streams: prints "INDEX CODEC LANG IS_FORCED IS_CC
# IS_SIGNS" one line per subtitle stream. IS_CC/IS_FORCED come from
# disposition flags or title keywords, the same signal encoder_params.sh's
# probe uses. The title itself is consulted only to derive IS_CC/IS_SIGNS
# here; it isn't reproduced in the output, so nothing downstream needs it.
probe_subtitle_streams() {
    local IN="$1"
    python3 - "$IN" << 'PYEOF'
import json, sys, subprocess

input_file = sys.argv[1]
result = subprocess.run(
    ['ffprobe', '-v', 'quiet', '-print_format', 'json', '-show_streams',
     '-select_streams', 's', input_file],
    capture_output=True, text=True
)
if result.returncode != 0:
    print(f"ERROR PROBE_FAILED:{result.stderr.strip()}")
    sys.exit(0)
try:
    streams = json.loads(result.stdout).get('streams', [])
except json.JSONDecodeError as e:
    print(f"ERROR PARSE_FAILED:{e}")
    sys.exit(0)

CC_TERMS = {'sdh', 'cc', 'hi', 'hearing impaired', 'closed caption', 'closed captions'}

for s in streams:
    idx = s.get('index', 0)
    codec = s.get('codec_name', 'unknown')
    lang = s.get('tags', {}).get('language', 'und')
    title = s.get('tags', {}).get('title', '')
    title_low = title.lower()
    disp = s.get('disposition', {})
    is_forced = int(disp.get('forced', 0) == 1)
    is_hi = int(disp.get('hearing_impaired', 0) == 1)
    is_cc = int(is_hi or any(t in title_low for t in CC_TERMS))
    is_signs = int(any(w in title_low for w in ('sign', 'song')))
    print(f"{idx} {codec} {lang} {is_forced} {is_cc} {is_signs}")
PYEOF
}

declare -a SUB_LINES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && SUB_LINES+=("$line")
done < <(probe_subtitle_streams "$INPUT")

if [[ ${#SUB_LINES[@]} -eq 0 ]]; then
    echo "ERROR: no subtitle streams found in: $INPUT" >&2
    exit 1
fi
if [[ "${SUB_LINES[0]}" == ERROR* ]]; then
    echo "ERROR: probe failed: ${SUB_LINES[0]#ERROR }" >&2
    exit 1
fi

# -- Pick the stream: explicit -i, or auto-pick by language/codec -----------
SRC_INDEX="" SRC_CODEC="" SRC_LANG="" IS_FORCED=0 IS_CC=0

if [[ -n "$EXPLICIT_INDEX" ]]; then
    for LINE in "${SUB_LINES[@]}"; do
        read -r LINE_IDX LINE_CODEC LINE_LANG LINE_FORCED LINE_CC LINE_SIGNS <<< "$LINE"
        if [[ "$LINE_IDX" == "$EXPLICIT_INDEX" ]]; then
            SRC_INDEX="$LINE_IDX" SRC_CODEC="$LINE_CODEC" SRC_LANG="$LINE_LANG" IS_FORCED="$LINE_FORCED" IS_CC="$LINE_CC"
            break
        fi
    done
    [[ -z "$SRC_INDEX" ]] && { echo "ERROR: no subtitle stream at index $EXPLICIT_INDEX in: $INPUT" >&2; exit 1; }
else
    # Two-pass by priority: a plain target track outranks CC or forced when
    # picking automatically, matching encoder_params.sh's own distinction
    # between target/cc/forced (see build_subtitle_args()) - the first pass
    # only considers plain tracks; CC/forced are only picked if no plain
    # target track exists for this language. Without this, auto-pick would
    # just take whichever matching-language track happens to be listed
    # first in the container, which is not a reliable signal of intent.
    for PASS in target fallback; do
        [[ -n "$SRC_INDEX" ]] && break
        for LINE in "${SUB_LINES[@]}"; do
            read -r LINE_IDX LINE_CODEC LINE_LANG LINE_FORCED LINE_CC LINE_SIGNS <<< "$LINE"
            [[ "$(canon_lang "$LINE_LANG")" != "$TARGET_CANON" ]] && continue
            [[ "$LINE_SIGNS" == "1" ]] && continue
            case "$LINE_CODEC" in
                subrip|mov_text) ;;
                *) continue ;;
            esac
            if [[ "$PASS" == "target" ]]; then
                [[ "$LINE_FORCED" == "1" || "$LINE_CC" == "1" ]] && continue
            fi
            SRC_INDEX="$LINE_IDX" SRC_CODEC="$LINE_CODEC" SRC_LANG="$LINE_LANG" IS_FORCED="$LINE_FORCED" IS_CC="$LINE_CC"
            break
        done
    done
    [[ -z "$SRC_INDEX" ]] && {
        echo "ERROR: no subrip/mov_text subtitle track found for language '$TARGET_LANG' (excluding Signs/Songs) in: $INPUT" >&2
        exit 1
    }
fi

case "$SRC_CODEC" in
    subrip|mov_text) ;;
    ass|ssa)
        echo "ERROR: stream $SRC_INDEX is $SRC_CODEC (genuine ASS/SSA) - refusing to extract: its override tags are real positioning, not a conversion artifact to strip" >&2
        exit 1
        ;;
    hdmv_pgs_subtitle|dvd_subtitle|dvbsub)
        echo "ERROR: stream $SRC_INDEX is $SRC_CODEC (bitmap subtitle) - no text to extract" >&2
        exit 1
        ;;
    *)
        echo "ERROR: stream $SRC_INDEX has unsupported codec '$SRC_CODEC' for extraction" >&2
        exit 1
        ;;
esac

# Resolves via LANG_ALIASES, not LANG_3TO2: SRC_LANG comes from the file's
# own embedded metadata tag, not user input, and commonly carries a
# bibliographic ISO 639-2/B code (e.g. "fre", "ger", "chi") rather than the
# primary code3 lang_table.tsv uses as its key ("fra", "deu", "zho").
# LANG_3TO2 is keyed by primary code3 only and would miss those; LANG_ALIASES
# is a superset (every primary code3, every code2, and every listed alias,
# all -> code2) built specifically to resolve exactly this. This is
# unrelated to -l/TARGET_LANG above, which stays restricted to primary
# code3 per lang_table.tsv's own stated design ("aliases ... NOT valid
# values for -l") - that restriction is about what a user may type, not
# about what a file's own tag may already contain.
LANG2="${LANG_ALIASES[$SRC_LANG]:-}"
if [[ -z "$LANG2" ]]; then
    echo "ERROR: language '$SRC_LANG' on stream $SRC_INDEX has no known 2-letter code in lang_table.sh - cannot name the sidecar file" >&2
    exit 1
fi

BASENAME="$(basename "${INPUT%.*}")"
if (( IS_FORCED )); then
    SUFFIX="forced"
elif (( IS_CC )); then
    SUFFIX="cc"
else
    SUFFIX=""
fi
if [[ -n "$SUFFIX" ]]; then
    DEST="${OUT_DIR}/${BASENAME}.${LANG2}.${SUFFIX}.srt"
else
    DEST="${OUT_DIR}/${BASENAME}.${LANG2}.srt"
fi

if [[ -f "$DEST" ]] && (( ! FORCE )); then
    echo "ERROR: destination sidecar already exists (use -F to overwrite): $DEST" >&2
    exit 1
fi

echo "Input:  $INPUT"
echo "Stream: $SRC_INDEX ($SRC_CODEC, $SRC_LANG$( (( IS_FORCED )) && echo ', forced')$( (( IS_CC )) && echo ', cc'))"
echo "Dest:   $DEST"

# -- Concurrency lock, scoped to the destination sidecar path, not the
# source video: two runs extracting DIFFERENT tracks from the same video to
# different destinations should not block each other; two runs racing on
# the same destination should. Acquired unconditionally, dry-run or not -
# matching encoder_params.sh/rename_params.sh's own convention of always
# locking regardless of -n, since a dry-run's preview is still reading live
# filesystem state a concurrent mutating run could otherwise invalidate. ---
DEST_REAL="$(cd "$OUT_DIR" && pwd)/$(basename "$DEST")"
LOCK_DIR="${TMPDIR:-/tmp}/subtitle_extract_locks"
mkdir -p -- "$LOCK_DIR"
LOCK_HASH="$(printf '%s' "$DEST_REAL" | sha256sum | cut -d' ' -f1)"
LOCK_FILE="${LOCK_DIR}/${LOCK_HASH}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another extract run is already active against $DEST" >&2
    exit 1
fi
trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT

if (( DRY_RUN )); then
    echo ""
    echo "[DRY RUN] ffmpeg -i \"$INPUT\" -map 0:${SRC_INDEX} -c:s srt <extract_tmp>.srt"
    echo "[DRY RUN] then strip ASS override tags and write to: $DEST"
    exit 0
fi

init_subtitle_tag_strip || exit 1
trap 'rm -f "$LOCK_FILE" 2>/dev/null || true; cleanup_stripped_subs' EXIT

CURRENT_TMP=""
# SIGINT/SIGTERM handler. Removes the in-progress .tmp output named by
# CURRENT_TMP, then exits 1 (the EXIT trap removes the lock and the
# stripped-subtitle scratch directory). SIG is the signal name in the message.
cleanup() {
    local SIG="$1"
    echo "" >&2
    echo "subtitle_extract_params.sh: caught $SIG, aborting." >&2
    [[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]] && rm -f -- "$CURRENT_TMP"
    exit 1
}
trap 'cleanup SIGINT'  INT
trap 'cleanup SIGTERM' TERM

RAW_EXTRACT="$(mktemp --suffix=.srt 2>/dev/null)" || {
    echo "ERROR: could not create temp file for raw extraction" >&2
    exit 1
}
# Deliberately outside STRIPPED_TMP_DIR: strip_sidecar_sub() names its
# output "STRIPPED_TMP_DIR/$(basename SRC)", which would collide with SRC
# itself if SRC already lived inside STRIPPED_TMP_DIR. Keeping the raw
# extract in its own mktemp file outside that directory avoids the
# ambiguity entirely instead of relying on strip_sidecar_sub's same-name
# collision handling to save us from a self-referential SRC==DEST.
CURRENT_TMP="$RAW_EXTRACT"
echo ""
echo "Extracting stream $SRC_INDEX..."
if ! ffmpeg -hide_banner -loglevel warning -nostats -y -i "$INPUT" -map "0:${SRC_INDEX}" -c:s srt "$RAW_EXTRACT"; then
    echo "ERROR: ffmpeg failed to extract stream $SRC_INDEX" >&2
    rm -f -- "$RAW_EXTRACT"
    CURRENT_TMP=""
    exit 1
fi
if [[ ! -s "$RAW_EXTRACT" ]]; then
    echo "ERROR: ffmpeg produced an empty extract for stream $SRC_INDEX" >&2
    rm -f -- "$RAW_EXTRACT"
    CURRENT_TMP=""
    exit 1
fi

echo "Stripping ASS override tags..."
if ! strip_sidecar_sub "$RAW_EXTRACT"; then
    echo "ERROR: tag-strip failed on the extracted subtitle" >&2
    rm -f -- "$RAW_EXTRACT"
    CURRENT_TMP=""
    exit 1
fi
rm -f -- "$RAW_EXTRACT"
CURRENT_TMP=""

DEST_TMP="${OUT_DIR}/.$(basename "$DEST").tmp"
CURRENT_TMP="$DEST_TMP"
cp -- "$STRIPPED_SUB_PATH" "$DEST_TMP"
mv -- "$DEST_TMP" "$DEST"
CURRENT_TMP=""

echo "Done -> $DEST"