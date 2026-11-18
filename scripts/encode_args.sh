#!/usr/bin/env bash
# encode_args.sh: The ffmpeg argument builders for encode.sh: video (copy, or x264
# re-encode with HDR-to-SDR tone-mapping), audio (copy, or aac) and the selection of
# embedded subtitle tracks. Each builder appends to the array named by its first
# argument and prints its per-stream decision to stdout; none runs ffmpeg or ffprobe,
# or creates, reads or changes a file.
#
# Sourced by encode.sh. The caller provides, before calling into this file:
#   MAX_HEIGHT, SDR_TONEMAP_CHAIN, CRF, PRESET   read by build_video_args()
#   AUDIO_COPY_CODECS, AUDIO_BITRATE             read by build_audio_args()
#   SUB_MODE                                     "embed" or "sidecar", read by
#                                                 build_subtitle_args()
#   SIDECAR_EXTRACT_LINES                        array build_subtitle_args() appends
#                                                 to in sidecar mode
#   subtitle_output_codec, subtitle_track_type, subtitle_track_key,
#   sidecar_output_spec                          functions from subtitle_mux.sh
#   canon_lang                                   function from lang_table.sh
# subtitle_mux.sh and lang_table.sh are sourced by the caller before these
# functions are called; this module does not source them itself.
#
# Not intended to be run standalone.
#
# shellcheck disable=SC2034
# File-wide: SIDECAR_EXTRACT_LINES is appended to here and read by encode.sh;
# the checker cannot see across that boundary when this file is checked
# standalone.

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
        echo " Video: COPY (already h264, transfer not PQ/HLG, 8-bit 4:2:0, within ${MAX_HEIGHT}p)"
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
# Appends the audio-stream ffmpeg args to the array named by $1: a -map, a codec
# setting and language and title metadata per stream. Args: array name, then one
# line per source audio stream "IGNORED SRC_IDX CODEC LANG TITLE", where TITLE is
# the rest of the line. A stream whose codec is in AUDIO_COPY_CODECS
# (comma-separated) is copied; any other is encoded to aac at AUDIO_BITRATE and
# its title's first word is replaced with "AAC". Prints each stream's decision;
# with no lines it prints that no streams were found and appends nothing.
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
    for c in "${_CODECS[@]+"${_CODECS[@]}"}"; do COPY_SET["$c"]=1; done

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

# -- subtitle_codec_rank -------------------------------------------------------------
# Echoes the preference rank of a source subtitle codec, lower is better: 0 for
# the text formats every Plex app renders without burn-in (subrip, mov_text,
# webvtt), 1 for ass/ssa and any other codec, 2 for bitmap formats (hdmv_pgs_subtitle,
# dvd_subtitle, dvbsub), which most Plex apps can show only by burning them into
# the video. Takes no other input and sets no state.
subtitle_codec_rank() {
    case "$1" in
        subrip|mov_text|webvtt)                    echo 0 ;;
        hdmv_pgs_subtitle|dvd_subtitle|dvbsub)     echo 2 ;;
        *)                                         echo 1 ;;
    esac
}

# -- select_subtitle_winners ---------------------------------------------------------
# Chooses one embedded track per language and type. Tracks that are in a target
# language and not Signs & Songs form a group per "<primary code3>:<type>" key
# (subtitle_track_key; type is standard, CC or forced); the track with the lowest
# subtitle_codec_rank wins, and a tie goes to the first listed. Fills the
# associative array named by the first argument with key -> SRC_IDX of the winner
# (emptied first), one entry for every group present. Args: array name, then the
# source track lines in the format build_subtitle_args() documents. Both
# build_subtitle_args() and strip_embedded_text_tracks() call this, so they
# always agree on which track survives.
select_subtitle_winners() {
    local -n _WIN="$1"
    shift
    local -A _BEST_RANK=()
    local line _ idx codec lang is_target is_forced is_signs is_cc rest key rank

    _WIN=()
    for line in "$@"; do
        read -r _ idx codec lang is_target is_forced is_signs is_cc rest <<< "$line"
        [[ "$is_target" == "1" && "$is_signs" != "1" ]] || continue
        key="$(subtitle_track_key "$lang" "$(subtitle_track_type "$is_forced" "$is_cc")")"
        rank="$(subtitle_codec_rank "$codec")"
        if [[ -z "${_BEST_RANK[$key]+_}" ]] || (( rank < _BEST_RANK[$key] )); then
            _BEST_RANK["$key"]="$rank"
            _WIN["$key"]="$idx"
        fi
    done
}

# -- build_subtitle_args -------------------------------------------------------------
# Selects embedded subtitle tracks. In -S embed mode each kept track becomes an
# embedded stream in the output. In -S sidecar mode a kept track that has a text
# sidecar form (see sidecar_output_spec) is appended to SIDECAR_EXTRACT_LINES as
# "SRC_IDX CODEC TYPE LANG3" and written as a file by build_sidecar_outputs();
# bitmap tracks stay embedded. This function does not strip ASS override tags
# (e.g. {\an8}): -S sidecar strips the extracted srt files, and in -S embed mode
# strip_embedded_text_tracks() replaces a tagged SubRip or mov_text track with a
# stripped copy before this function runs.
# One track is kept per primary language and type (standard, CC, forced), chosen
# by select_subtitle_winners(); the language is compared after alias resolution.
# Args: array name, the name of the output subtitle index counter (increased by
# one per embedded track appended), then one line per source subtitle track
# "IGNORED SRC_IDX CODEC LANG IS_TARGET IS_FORCED IS_SIGNS IS_CC LABEL", where
# LABEL is the rest of the line. Prints each track's decision.
build_subtitle_args() {
    # shellcheck disable=SC2178  # false positive: -n declares a fresh nameref scoped to this function, not a reassignment of a prior array
    local -n _FF="$1"
    local -n _OUT_IDX="$2"
    shift 2
    local -a SUB_LINES=("$@")
    local line

    local -A _WINNER=()
    select_subtitle_winners _WINNER "${SUB_LINES[@]+"${SUB_LINES[@]}"}"

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

        local SUB_TYPE _track_key
        SUB_TYPE="$(subtitle_track_type "$IS_FORCED" "$IS_CC")"
        _track_key="$(subtitle_track_key "$SUB_LANG" "$SUB_TYPE")"
        if [[ "${_WINNER[$_track_key]}" != "$SRC_IDX" ]]; then
            echo " Subtitle[src:$SRC_IDX]: DROP ($SUB_LANG, duplicate ${SUB_TYPE/target/standard} track: src:${_WINNER[$_track_key]} kept)"
            continue
        fi

        local SUB_TITLE
        case "$SUB_TYPE" in
            cc)     SUB_TITLE="${LANG_LABEL} CC" ;;
            forced) SUB_TITLE="${LANG_LABEL} Forced" ;;
            *)      SUB_TITLE="${LANG_LABEL}" ;;
        esac

        # shellcheck disable=SC2153  # SUB_MODE is the caller-provided global named in the header; SUB_CODEC is a separate local
        if [[ "$SUB_MODE" == "sidecar" ]] && sidecar_output_spec "$SUB_CODEC" >/dev/null; then
            echo " Subtitle[src:$SRC_IDX]: SIDECAR: $SUB_TITLE ($SUB_CODEC)"
            SIDECAR_EXTRACT_LINES+=("${SRC_IDX} ${SUB_CODEC} ${SUB_TYPE} ${SUB_LANG}")
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
    unset _WINNER
}