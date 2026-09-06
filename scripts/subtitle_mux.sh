#!/usr/bin/env bash
# subtitle_mux.sh: Container-aware subtitle codec selection, Plex-style
# sidecar discovery (Movie.en.srt / Movie.en.cc.srt / ...), and ffmpeg
# arg-building for muxing external subtitle files into a video.
#
# Extracted from encoder_params.sh so encoder_params.sh and
# subtitle_embed_params.sh share one definition instead of two - the
# functions here are otherwise word-for-word what encoder_params.sh used
# before this module existed.
#
# Depends on globals/functions the caller must provide before sourcing this
# file and calling into it:
#   OUT_FORMAT       "mkv" or "mp4" - read by subtitle_output_codec()
#   SUB_LANGS        comma-separated 3-letter codes - read by
#                     discover_sidecar_subs()
#   LANG_3TO2        assoc array, 3-letter -> 2-letter code - from
#                     lang_table.sh, read by discover_sidecar_subs()
#   LANG_LABEL_BASH  assoc array, code -> display label - from
#                     lang_table.sh, read by build_external_subtitle_args()
# lang_table.sh must be sourced by the caller before this module's
# functions are called; this module does not source it itself, matching
# how encoder_params.sh already keeps sourcing centralized at the call
# site rather than nested inside a shared module.
#
# Sourced by encoder_params.sh and subtitle_embed_params.sh; not intended
# to be run standalone.

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

# Looks for Movie.<lang2>.srt / Movie.<lang2>.cc.srt / Movie.<lang2>.sdh.srt /
# Movie.<lang2>.forced.srt next to INPUT, for each target language in
# SUB_LANGS. Prints "LANG3 TYPE PATH" lines (TYPE: target|cc|forced).
# Exact filename match only, no globbing, so adjacent same-prefix episodes
# (S01E1 vs S01E10) can never cross-match.
discover_sidecar_subs() {
    local INPUT="$1"
    local DIR BASENAME
    DIR="$(dirname "$INPUT")"
    BASENAME="$(basename "${INPUT%.*}")"

    local -a _TARGET_LANGS
    IFS=',' read -ra _TARGET_LANGS <<< "$SUB_LANGS"

    local lang3 lang2 f cc_f sdh_f forced_f
    for lang3 in "${_TARGET_LANGS[@]}"; do
        lang2="${LANG_3TO2[$lang3]:-}"
        [[ -z "$lang2" ]] && continue

        f="${DIR}/${BASENAME}.${lang2}.srt"
        [[ -f "$f" ]] && echo "${lang3} target ${f}"

        # Prefer .cc. over .sdh. if both exist for the same language, so we
        # never emit two CC tracks with an identical title.
        cc_f="${DIR}/${BASENAME}.${lang2}.cc.srt"
        sdh_f="${DIR}/${BASENAME}.${lang2}.sdh.srt"
        if [[ -f "$cc_f" ]]; then
            echo "${lang3} cc ${cc_f}"
        elif [[ -f "$sdh_f" ]]; then
            echo "${lang3} cc ${sdh_f}"
        fi

        forced_f="${DIR}/${BASENAME}.${lang2}.forced.srt"
        [[ -f "$forced_f" ]] && echo "${lang3} forced ${forced_f}"
    done
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
# path it's given.
build_external_subtitle_args() {
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _FF="$1"
    local -n _OUT_IDX="$2"
    shift 2
    local -a EXT_LINES=("$@")

    local line
    for line in "${EXT_LINES[@]+"${EXT_LINES[@]}"}"; do
        local LANG TYPE SIDECAR_PATH SIDECAR_INPUT_IDX
        read -r LANG TYPE SIDECAR_INPUT_IDX SIDECAR_PATH <<< "$line"

        local LANG_LABEL="${LANG_LABEL_BASH[$LANG]:-${LANG^^}}"
        local SUB_TITLE
        case "$TYPE" in
            cc)     SUB_TITLE="${LANG_LABEL} CC" ;;
            forced) SUB_TITLE="${LANG_LABEL} Forced" ;;
            *)      SUB_TITLE="${LANG_LABEL}" ;;
        esac

        local OUT_SUB_CODEC
        OUT_SUB_CODEC="$(subtitle_output_codec "subrip")"

        # Does not claim "tags stripped" here: PATH may be a stripped copy
        # or the original, unstripped file - the caller falls back to the
        # latter if strip_sidecar_sub() failed, and already prints its own
        # WARNING at that point. Claiming a strip succeeded unconditionally
        # would be wrong on exactly the failure path where it matters most.
        echo " Subtitle[external:$(basename "$SIDECAR_PATH") -> out:${_OUT_IDX}]: INCLUDE: $SUB_TITLE (srt -> $OUT_SUB_CODEC)"

        _FF+=(
            -map "${SIDECAR_INPUT_IDX}:0"
            "-c:s:${_OUT_IDX}" "$OUT_SUB_CODEC"
            "-metadata:s:s:${_OUT_IDX}" "language=${LANG}"
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
