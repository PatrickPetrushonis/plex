#!/usr/bin/env bash
# subtitle_tag_strip.sh: Strips leftover ASS/SSA override tags (e.g. {\an8},
# {\pos(400,300)}, {\c&HFF0000&}) from plain-text subtitle files. These tags
# are valid ASS/SSA syntax but are not part of the SRT spec; when a subtitle
# service does an ASS→SRT conversion that keeps the tags, they end up as
# literal text instead of being interpreted, and a player that does not parse
# them renders "{\an8}" on screen rather than positioning the line.
#
# Scope: sidecar files whose probed codec is subrip. The caller gates on
# sidecar_needs_tag_strip() in subtitle_mux.sh and only hands this module
# such a path; ASS/SSA, WebVTT and MicroDVD sidecars never reach it.
#
# Embedded subtitle tracks are handled by the caller, encoder_params.sh, in
# -S embed mode: it extracts a SubRip or mov_text track to a temp .srt (ffmpeg
# -map 0:IDX), and when that file carries override tags calls
# strip_sidecar_sub() below on it exactly as on any other sidecar. A real
# embedded ASS/SSA track must never be run through that pipeline: \an8 there
# is genuine positioning, correctly rendered by an ASS-capable player, not a
# leftover conversion artifact - the caller gates on source codec
# (subrip/mov_text only).
#
# Sourced by encoder_params.sh; not intended to be run standalone.

# Directory holding this run's stripped-copy temp files. Set by
# init_subtitle_tag_strip(); every temp file this module creates lives
# here, so cleanup sweeps one directory instead of tracking paths one by
# one.
STRIPPED_TMP_DIR=""

# Structural match: any "{\" ... "}" span, regardless of which specific
# override tag it is. SRT text has no legitimate use for that bracket
# syntax, so this doesn't need a keyword list of every tag name that could
# appear (an8, an7, pos, c, fad, ...) - it just needs to know the tags are
# always wrapped in {\...}. Extended-regex form for `sed -E`.
TAG_STRIP_PATTERN='\{\\[^}]*\}'

# Known limitation: only strips the bracketed {\...} form used by SRT files
# carrying over ASS override syntax. A source using some other, unbracketed
# convention is not covered; not observed in sidecar .srt files pulled from
# subtitle services, which is the only input this module currently sees.

# Creates a fresh temp directory for this run and resets the temp-file
# registry. Sets STRIPPED_TMP_DIR. Call once, after the concurrency lock is
# held, before any sidecar subtitle is processed.
init_subtitle_tag_strip() {
    STRIPPED_TMP_DIR="$(mktemp -d 2>/dev/null)" || {
        echo "ERROR: could not create temp directory for subtitle tag stripping" >&2
        return 1
    }
}

# Removes every temp file this module created this run, and the temp
# directory itself. Safe to call with STRIPPED_TMP_DIR unset (a run that
# never reached init_subtitle_tag_strip, or already cleaned up). Intended
# to be wired into the caller's own EXIT trap alongside its existing
# lock-file cleanup, so an interrupted run doesn't leave stripped copies
# behind - the same reasoning Linux_Script_Style_Guide.md section 5 applies
# to restoring any state on exit, not just locks.
cleanup_stripped_subs() {
    [[ -n "$STRIPPED_TMP_DIR" && -d "$STRIPPED_TMP_DIR" ]] || return 0
    rm -rf -- "$STRIPPED_TMP_DIR" 2>/dev/null || true
    STRIPPED_TMP_DIR=""
}

# Reads SRC (a plain sidecar .srt file), strips every {\...} override tag
# from it, and writes the result to a new file under STRIPPED_TMP_DIR. Sets
# STRIPPED_SUB_PATH to that new file's path. SRC itself is never modified -
# the caller's original sidecar file (and its later backup move) is
# unaffected by this function.
#
# Returns 1 (STRIPPED_SUB_PATH left empty) if init_subtitle_tag_strip
# hasn't been called, SRC doesn't exist, or the strip itself fails; the
# caller decides whether to fall back to muxing the unstripped original or
# to skip the track.
strip_sidecar_sub() {
    local SRC="$1"
    STRIPPED_SUB_PATH=""

    if [[ -z "$STRIPPED_TMP_DIR" ]]; then
        echo "ERROR: strip_sidecar_sub called before init_subtitle_tag_strip" >&2
        return 1
    fi
    if [[ ! -f "$SRC" ]]; then
        echo "ERROR: strip_sidecar_sub: source not found: $SRC" >&2
        return 1
    fi

    local DEST
    DEST="${STRIPPED_TMP_DIR}/$(basename "$SRC")"
    # Two sidecars from different source directories can share a basename
    # (e.g. two different shows both shipping a plain "en.srt"); disambiguate
    # rather than let the second strip silently overwrite the first inside
    # the shared temp dir.
    if [[ -e "$DEST" ]]; then
        DEST="${STRIPPED_TMP_DIR}/$(basename "$SRC").$$.${RANDOM}"
    fi

    if ! sed -E "s/${TAG_STRIP_PATTERN}//g" -- "$SRC" > "$DEST" 2>/dev/null; then
        echo "ERROR: failed to strip override tags from: $SRC" >&2
        rm -f -- "$DEST"
        return 1
    fi

    STRIPPED_SUB_PATH="$DEST"
}
