#!/usr/bin/env bash
# subtitle_mux.sh: Container-aware subtitle codec selection, Plex-style
# sidecar discovery (Movie.en.srt / Movie.en.cc.vtt / Movie.en.forced.ass / ...), embedded/sidecar
# track matching, output stream-count verification, and ffmpeg arg-building
# for muxing external subtitle files into a video.
#
# Shared by encoder_params.sh and subtitle_embed_params.sh.
#
# The caller provides, before sourcing this file and calling into it:
#   OUT_FORMAT       "mkv" or "mp4" - read by subtitle_output_codec()
#   SUB_LANGS        comma-separated 3-letter codes - read by
#                     discover_sidecar_subs()
#   LANG_3TO2        assoc array, 3-letter -> 2-letter code - from
#                     lang_table.sh, read by discover_sidecar_subs()
#   LANG_LABEL_BASH  assoc array, code -> display label - from
#                     lang_table.sh, read by build_external_subtitle_args()
#   canon_lang       function from lang_table.sh, read by
#                     subtitle_track_key()
# lang_table.sh is sourced by the caller before this module's functions are
# called; this module does not source it itself, so sourcing stays at the
# call site.
#
# Not intended to be run standalone.

# -- Container-aware subtitle codec ------------------------------------------------
# Given a source subtitle codec name, echoes the codec to mux it as in the
# output container (subtitle_output_codec "subrip" -> "copy", "srt",
# "mov_text", or "DROP" for a bitmap codec MP4 can't carry). Reads
# $OUT_FORMAT (a caller-provided global, see the module header above);
# takes no other input and sets no other state.
subtitle_output_codec() {
    local SRC_CODEC="$1"
    if [[ "$OUT_FORMAT" == "mp4" ]]; then
        case "$SRC_CODEC" in
            hdmv_pgs_subtitle|dvd_subtitle|dvbsub)
                echo "DROP"
                ;;
            *)
                echo "mov_text"
                ;;
        esac
    else
        case "$SRC_CODEC" in
            mov_text)
                # mov_text is an MP4/MOV-only binary subtitle codec; Matroska
                # has no muxer support for it at all ("Subtitle codec 94213 is
                # not supported" / "Could not write header ... Function not
                # implemented"). Convert to plain-text SRT instead of copying.
                echo "srt"
                ;;
            *)
                echo "copy"
                ;;
        esac
    fi
}

# -- Track identity ------------------------------------------------------------------
# Echoes the type of an embedded track from its disposition flags:
# forced, cc, or target. Forced outranks cc, matching the sidecar file
# suffix subtitle_extract_params.sh writes for the same flags.
subtitle_track_type() {
    local IS_FORCED="$1" IS_CC="$2"
    if [[ "$IS_FORCED" == "1" ]]; then
        echo "forced"
    elif [[ "$IS_CC" == "1" ]]; then
        echo "cc"
    else
        echo "target"
    fi
}

# Echoes the identity key "<primary code3>:<type>" for a track or sidecar,
# so an embedded track (tagged with whatever code the file carries) and a
# sidecar (tagged with the -l code) compare equal exactly when they are the
# same language and the same type.
subtitle_track_key() {
    echo "$(canon_lang "$1"):$2"
}

# -- Sidecar formats -----------------------------------------------------------------
# Extensions tried for a sidecar, in precedence order, and the probed codecs
# that are muxed. A file is claimed only if its extension is listed and
# ffprobe reports one of the listed codecs, so a bitmap or unreadable .sub is
# never claimed.
SUBTITLE_MUX_EXTS="srt vtt ass ssa sub"
SUBTITLE_MUX_CODECS="subrip webvtt ass microdvd"

# Echoes the codec name of the first stream in FILE. Returns 1 with nothing
# echoed if ffprobe fails.
probe_sidecar_codec() {
    local OUT
    OUT="$(ffprobe -v error -select_streams s:0 -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null)" || return 1
    echo "${OUT%%$'\n'*}"
}

# Given a probed sidecar codec, echoes the codec to mux it as. In Matroska,
# webvtt and microdvd convert to srt; every other codec follows
# subtitle_output_codec().
sidecar_output_codec() {
    local SRC_CODEC="$1"
    if [[ "$OUT_FORMAT" == "mkv" ]]; then
        case "$SRC_CODEC" in
            webvtt|microdvd) echo "srt"; return 0 ;;
        esac
    fi
    subtitle_output_codec "$SRC_CODEC"
}

# Returns 0 if FILE is a subrip-codec sidecar, the only kind that can carry
# leftover ASS override tags as literal text. A real ASS/SSA track keeps its
# tags: they are positioning.
sidecar_needs_tag_strip() {
    [[ "$(probe_sidecar_codec "$1")" == "subrip" ]]
}

# Given a probed subtitle codec, echoes "EXT CODEC FORMAT" for writing it as a
# standalone sidecar: the file extension, the ffmpeg -c:s value, and the ffmpeg
# -f muxer. SubRip, ASS/SSA and WebVTT are copied (ASS keeps its styling);
# mov_text and MicroDVD are converted to srt. Returns 1 with nothing echoed for
# a codec with no text sidecar form (the bitmap codecs).
sidecar_output_spec() {
    case "$1" in
        subrip)            echo "srt copy srt" ;;
        mov_text|microdvd) echo "srt srt srt" ;;
        webvtt)            echo "vtt copy webvtt" ;;
        ass|ssa)           echo "ass copy ass" ;;
        *)                 return 1 ;;
    esac
}

# Echoes the sidecar file name (no directory) "<BASE>.<lang2>[.cc|.forced].<EXT>"
# for a track of language LANG3 and TYPE (target|cc|forced); the suffixes match
# subtitle_extract_params.sh. Returns 1 with nothing echoed if LANG3 has no
# 2-letter code in the language table.
sidecar_file_name() {
    local BASE="$1" LANG3="$2" TYPE="$3" EXT="$4"
    local LANG2 SUFFIX=""
    LANG2="${LANG_3TO2[$(canon_lang "$LANG3")]:-}"
    [[ -n "$LANG2" ]] || return 1
    case "$TYPE" in
        cc)     SUFFIX=".cc" ;;
        forced) SUFFIX=".forced" ;;
    esac
    echo "${BASE}.${LANG2}${SUFFIX}.${EXT}"
}

# Echoes the first existing file named "<PREFIX>.<ext>" for ext in
# SUBTITLE_MUX_EXTS whose probed codec is in SUBTITLE_MUX_CODECS and whose
# bytes are valid UTF-8 (Plex expects UTF-8; a file in another encoding stays
# unclaimed and report_unclaimed_sidecars() reports it). Returns 1 if none
# qualifies. Exact name match only, no globbing. Needs iconv.
find_sidecar_file() {
    local PREFIX="$1" ext f codec
    for ext in $SUBTITLE_MUX_EXTS; do
        f="${PREFIX}.${ext}"
        [[ -f "$f" ]] || continue
        codec="$(probe_sidecar_codec "$f")" || continue
        [[ " $SUBTITLE_MUX_CODECS " == *" $codec "* ]] || continue
        iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1 || continue
        echo "$f"
        return 0
    done
    return 1
}

# -- Sidecar discovery ---------------------------------------------------------------
# Looks for Movie.<lang2>.<ext> / Movie.<lang2>.cc.<ext> / Movie.<lang2>.sdh.<ext> /
# Movie.<lang2>.forced.<ext> next to INPUT, for each target language in
# SUB_LANGS and each ext in SUBTITLE_MUX_EXTS (see find_sidecar_file for
# which one wins). Prints "LANG3 TYPE PATH" lines (TYPE: target|cc|forced).
# Exact filename match only, no globbing, so adjacent same-prefix episodes
# (S01E1 vs S01E10) can never cross-match.
discover_sidecar_subs() {
    local INPUT="$1"
    local DIR BASENAME
    DIR="$(dirname "$INPUT")"
    BASENAME="$(basename "${INPUT%.*}")"

    local -a _TARGET_LANGS
    IFS=',' read -ra _TARGET_LANGS <<< "$SUB_LANGS"

    local lang3 lang2 f
    for lang3 in "${_TARGET_LANGS[@]}"; do
        lang2="${LANG_3TO2[$lang3]:-}"
        [[ -z "$lang2" ]] && continue

        if f="$(find_sidecar_file "${DIR}/${BASENAME}.${lang2}")"; then
            echo "${lang3} target ${f}"
        fi

        # Prefer .cc. over .sdh. if both exist for the same language, in any
        # format, so we never emit two CC tracks with an identical title.
        if f="$(find_sidecar_file "${DIR}/${BASENAME}.${lang2}.cc")"; then
            echo "${lang3} cc ${f}"
        elif f="$(find_sidecar_file "${DIR}/${BASENAME}.${lang2}.sdh")"; then
            echo "${lang3} cc ${f}"
        fi

        if f="$(find_sidecar_file "${DIR}/${BASENAME}.${lang2}.forced")"; then
            echo "${lang3} forced ${f}"
        fi
    done
}

SUBTITLE_SIDECAR_EXTS="srt sub idx ass ssa vtt sup smi"

# Prints the path of every subtitle-extension file named "<video basename>.*"
# next to INPUT that is not among the claimed "LANG TYPE PATH" lines passed as
# the remaining arguments (the output of discover_sidecar_subs). These are the
# files discovery does not embed: formats outside SUBTITLE_MUX_EXTS (.idx,
# .sup, .smi), a file whose probed codec is not muxed (a bitmap .sub) or whose
# text is not valid UTF-8, a
# language outside SUB_LANGS, an unrecognized modifier (.en.hi.srt), a lower
# precedence format of a claimed language and type (.en.ass beside .en.srt),
# and an .sdh file shadowed by a .cc file. Matching is by string prefix, never by glob,
# so brackets in a filename are literal and S01E1 never matches S01E10.
report_unclaimed_sidecars() {
    local INPUT="$1"
    shift
    local DIR BASENAME f ext line
    DIR="$(dirname "$INPUT")"
    BASENAME="$(basename "${INPUT%.*}")"

    local -A CLAIMED=()
    local _lang _type _path
    for line in "$@"; do
        read -r _lang _type _path <<< "$line"
        CLAIMED["$_path"]=1
    done

    for f in "$DIR"/*; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$DIR/$BASENAME".* ]] || continue
        ext="${f##*.}"
        [[ " $SUBTITLE_SIDECAR_EXTS " == *" ${ext,,} "* ]] || continue
        [[ -n "${CLAIMED[$f]+_}" ]] || echo "$f"
    done
}

# -- Output verification ---------------------------------------------------------------
# Echoes the number of subtitle streams in FILE. Returns 1 with nothing
# echoed if ffprobe fails.
count_subtitle_streams() {
    local OUT
    OUT="$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null)" || return 1
    if [[ -z "$OUT" ]]; then
        echo 0
    else
        grep -c . <<< "$OUT"
    fi
}

# Sets SUB_COUNT_ACTUAL to the probed subtitle stream count of FILE (empty if
# the probe failed). Returns 0 if the count equals EXPECTED, 1 otherwise or on
# probe failure. Call on the .tmp output, before it is promoted and before any
# source file is moved.
SUB_COUNT_ACTUAL=""
verify_subtitle_count() {
    local FILE="$1" EXPECTED="$2"
    SUB_COUNT_ACTUAL=""
    SUB_COUNT_ACTUAL="$(count_subtitle_streams "$FILE")" || return 1
    (( SUB_COUNT_ACTUAL == EXPECTED ))
}

# -- build_external_subtitle_args -----------------------------------------------------
# Builds ffmpeg -map/-c:s/-metadata/-disposition args for one or more
# external subtitle files already opened as ffmpeg inputs. Shares the
# _OUT_IDX counter with any other subtitle-arg builder the caller runs
# first (e.g. encoder_params.sh's build_subtitle_args() for embedded
# tracks), so external and embedded tracks are numbered continuously and
# indistinguishable in the output.
# Takes: ff_ref idx_ref, then "LANG TYPE INPUT_IDX PATH" lines, where PATH
# is expected to already be whatever copy the caller wants muxed (a
# tag-stripped copy, or the original file) -- this function itself does
# not strip anything or open any -i, it only maps whatever input index and
# path it's given. Every line it receives is muxed; it has no drop path.
build_external_subtitle_args() {
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _FF="$1"
    local -n _OUT_IDX="$2"
    shift 2
    local -a EXT_LINES=("$@")

    local line
    for line in "${EXT_LINES[@]+"${EXT_LINES[@]}"}"; do
        local SUB_LANG TYPE SIDECAR_PATH SIDECAR_INPUT_IDX
        read -r SUB_LANG TYPE SIDECAR_INPUT_IDX SIDECAR_PATH <<< "$line"

        local LANG_LABEL="${LANG_LABEL_BASH[$SUB_LANG]:-${SUB_LANG^^}}"
        local SUB_TITLE
        case "$TYPE" in
            cc)     SUB_TITLE="${LANG_LABEL} CC" ;;
            forced) SUB_TITLE="${LANG_LABEL} Forced" ;;
            *)      SUB_TITLE="${LANG_LABEL}" ;;
        esac

        local SRC_CODEC OUT_SUB_CODEC
        SRC_CODEC="$(probe_sidecar_codec "$SIDECAR_PATH")" || SRC_CODEC=""
        if [[ -z "$SRC_CODEC" ]]; then
            echo "ERROR: cannot probe subtitle codec of: $SIDECAR_PATH" >&2
            return 1
        fi
        OUT_SUB_CODEC="$(sidecar_output_codec "$SRC_CODEC")"

        # PATH may be a stripped copy or the original, unstripped file: the
        # caller falls back to the latter if strip_sidecar_sub() failed and
        # prints its own WARNING at that point, so this line makes no claim
        # about stripping.
        echo " Subtitle[external:$(basename "$SIDECAR_PATH") -> out:${_OUT_IDX}]: INCLUDE: $SUB_TITLE ($SRC_CODEC -> $OUT_SUB_CODEC)"

        _FF+=(
            -map "${SIDECAR_INPUT_IDX}:0"
            "-c:s:${_OUT_IDX}" "$OUT_SUB_CODEC"
            "-metadata:s:s:${_OUT_IDX}" "language=${SUB_LANG}"
            "-metadata:s:s:${_OUT_IDX}" "title=${SUB_TITLE}"
        )

        case "$TYPE" in
            forced) _FF+=("-disposition:s:${_OUT_IDX}" forced) ;;
            cc)     _FF+=("-disposition:s:${_OUT_IDX}" hearing_impaired) ;;
            *)      _FF+=("-disposition:s:${_OUT_IDX}" 0) ;;
        esac

        _OUT_IDX=$(( _OUT_IDX + 1 ))
    done
}
