#!/usr/bin/env bash
# rename_plex.sh: Rename movie AND TV episode video/subtitle files (and
#                  optionally their containing directories) into Plex naming
#                  convention. Handles both already-Plex-formatted names and
#                  raw scene-release names — see "Name parsing" below.
#
# Usage:  ./rename_plex.sh [OPTIONS] <target_dir>
#
# Options:
#   -n              Dry run: print decisions, do not rename (default: off)
#   -f              Force: overwrite destination if a rename target already
#                   exists (default: off — collisions are skipped and logged).
#                   Applies to files only — a directory-rename collision
#                   is always skipped regardless of -f, since mv nests a
#                   directory inside an existing target rather than
#                   replacing it; forcing that would risk silently merging
#                   or shadowing files already in the destination
#   -F              Files only: skip renaming containing directories AND
#                   skip all franchise-folder restructuring (default: off —
#                   directories are renamed alongside their matched files,
#                   and folders are created/moved as described in
#                   "Franchise-folder restructuring" below). With -F, a
#                   file is only ever renamed in place, never moved.
#   -O DIR          Operational directory: base for logs (OPDIR/Logs) and the
#                   lock file (OPDIR/.locks) — never <target_dir> itself.
#                   Default: this script's own directory. When invoked
#                   through rename.sh/rename_dry.sh, set to $OUTPUT_DIR
#                   (config.sh's shared working directory — same place
#                   encoder_params.sh already keeps its own Logs and lock)
#   -L DIR          Log directory, overriding OPDIR/Logs specifically
#   -h              Show this help
#
# Notes:
#   • Requires bash 4.0+, a grep with PCRE support (-P; GNU grep on
#     Ubuntu/Debian has this by default), and sha256sum
#   • Only one run may target a given <target_dir> at a time; a second run
#     against the same directory exits immediately instead of racing on
#     shared rename targets. Unlike encoder_params.sh, the lock file itself
#     lives in this script's own directory (hashed from <target_dir>'s
#     canonical path), not inside <target_dir> — see "Concurrency lock" note
#     near LOCK_DIR below
#   • Subtitle language tags are normalized against lang_table.sh (shared
#     with encoder_params.sh's -l flag and sidecar lookup, same directory)
#     — e.g. .eng.srt and .fre.srt become .en.srt and .fr.srt
#   • Requires lang_table.sh and lang_table.tsv alongside this script
#   • Subtitle modifiers are only ever written as cc, sdh, or forced — the
#     exact three literal forms encoder_params.sh's discover_sidecar_subs()
#     matches. Anything else (unrecognized language, unrecognized modifier)
#     is skipped rather than guessed, since a wrong guess here means the
#     encoder silently drops that subtitle later with no error of its own.
#
# Name parsing:
#   A name is split at its LAST standalone 4-digit year (1900-2099), bounded
#   on both sides by a non-alphanumeric character or string edge - so 2160p
#   (resolution) and x265 (codec) never match, but a bare year like "2015"
#   in "Movie Title 2015 1080p BluRay x265-GROUP" does. Everything before
#   the year is the title; everything after is release-tag junk (resolution,
#   source, codec, release group) and is discarded rather than parsed, since
#   discarding doesn't require knowing every tag vocabulary in use. This also
#   handles the already-Plex-formatted case ("Title (2020)") unchanged, since
#   parentheses are non-alphanumeric boundaries too.
#   Before year detection: bracketed tags anywhere (e.g. "[TRACKER]") are
#   stripped, and a leading site-announcement prefix (e.g.
#   "www.example.org    -    ") is stripped from the start of the name.
#   Known limitation: if a title itself contains a 4-digit number that looks
#   like a year (e.g. a title such as "Movie 2049"), the LAST standalone
#   year in the string wins, which is correct as long as the real release
#   year appears after the title (true for every case tested, including
#   that one - the in-title number stays in the title, the actual later
#   release year is the year used).
#   A title ending in a real year with nothing after it (e.g. a file already
#   named exactly "Movie 2049.mkv" for a movie actually titled "Movie") is
#   the one case this can't disambiguate; that's not distinguishable from a
#   correct match without an external metadata lookup, which this script
#   deliberately doesn't do.
#
#   Year-FIRST names: if nothing usable is left before the year (e.g.
#   "(2020) Movie Name" or "2020 Movie Name"), the title is taken from
#   everything AFTER the year instead. This is tried only as a fallback
#   when the year-last interpretation comes up empty, so it never competes
#   with or overrides the normal year-last case - a name like
#   "Movie Title (2020)" still parses as year-last exactly as before.
#
#   Delimited spec blocks: any COMPLETE "(...)" or "[...]" group within the
#   title portion is stripped entirely, not just trimmed - this handles
#   third-party encoders that tack on a spec block instead of (or in
#   addition to) a plain year, e.g. "Movie Name (1080p x264 AAC BluRay
#   EncoderName).mkv" or "Movie Name (1080p x264 AAC BluRay EncoderName)
#   (2020).mkv". Year detection always runs on the untouched name first, so
#   a year sitting inside such a block (e.g. "Movie Name (2020 1080p x264
#   AAC BluRay EncoderName).mkv") is still found regardless of where it
#   appears - this stripping only removes the leftover non-year text once
#   the title portion is known. Known limitation: this can't distinguish an
#   encoder's spec parentheses from parentheses that are genuinely part of
#   a title (e.g. a movie actually titled "Movie (Part Two)") - both are
#   stripped, since telling them apart would need an external metadata
#   lookup this script deliberately doesn't do.
#
# Franchise-folder restructuring (movies only):
#   Target Plex layout: <library>/Franchise Name/Movie Name (YYYY)/Movie
#   Name (YYYY).mkv. The franchise folder defaults to the bare movie title
#   (no year) and this script NEVER renames an existing franchise folder -
#   only ever creates one when none exists, so a franchise folder a user
#   has manually renamed (e.g. to an actual series name shared by several
#   movies) is never touched.
#
#   Each movie file has two independent possible sources of title/year: its
#   own name, and its immediate parent folder's name (same year-first/
#   year-last parsing as everywhere else in this script). The file's own
#   name wins whenever it has a usable year; the parent folder is only
#   consulted when the file's own name doesn't have one.
#
#   - Parent folder IS movie-shaped (has its own year): the file is renamed
#     in place, and the folder itself is renamed in place to canonical
#     form. If that folder sits directly in the scanned target directory
#     (no franchise folder above it yet), a new franchise folder is created
#     and the whole movie folder is moved into it. If the folder already
#     has any other parent, it's assumed to already be sitting inside a
#     franchise folder (default or custom-named) and nothing above it is
#     touched.
#   - Parent folder is NOT movie-shaped, but the file's own name has a
#     year: the file is relocated into a freshly created "Movie Name
#     (YYYY)" folder. If the file was sitting loose directly in the
#     scanned target directory with no per-movie folder at all, a
#     franchise folder is created too and the movie folder nests inside it.
#   - Neither the file's own name nor its parent folder has a usable year:
#     nothing is inferred or moved - same NO_MATCH as always.
#
#   This is scoped to movies only - a TV episode's SxxEyy token is always
#   on the episode file itself in every layout this script targets, and
#   show-root folders never get a franchise wrapper inserted.
#   Known limitation: a subtitle sidecar is only relocated this way if ITS
#   OWN name (after the language tag is stripped) independently carries a
#   year. A subtitle with no year in its own name, sitting loose next to a
#   correctly-named video, is not correlated with that video and is left
#   as NO_MATCH - this script doesn't cross-reference sidecar subtitles
#   against a video file's resolved title/year.
#   -F disables all of this: files are only ever renamed in place, and no
#   folders are created or moved, same as -F always disabled the plain
#   directory-rename pass.
#
# TV episodes:
#   A name is routed to episode parsing instead of movie parsing if it
#   contains a standalone SxxEyy token (S + 1-2 digit season, E + 1-3 digit
#   episode), checked BEFORE year-based movie parsing runs at all - so a
#   show whose title itself is a bare year (e.g. a show titled "1904") is
#   never misparsed as a movie. Everything before SxxEyy is the series title
#   (junk-stripped like a movie title); season/episode are zero-padded from
#   the token itself. Output: "Series - SxxEyy - Episode Title.ext", or just
#   "Series - SxxEyy.ext" with no title segment - see below for why.
#   Episode title is genuinely harder than a movie's year: there's no
#   structural anchor marking where a title ends and release-tag junk
#   begins, since scene-release TV naming almost always omits the episode
#   title entirely and goes straight from SxxEyy to quality tags. This uses
#   the presence of a literal hyphen in the separator immediately after
#   SxxEyy as that anchor: "S03E01 - Real Title" keeps everything after as
#   the title; "S03E01.1080p.WEB-DL.x264-GROUP" (no hyphen right after the
#   token) discards everything after, same as movie junk. Known limitation:
#   a raw release that includes BOTH a real episode title AND trailing
#   quality tags, hyphen-delimited from SxxEyy (e.g. "S03E01 - Title
#   1080p WEB-DL x264-GROUP"), has no way to tell where the title ends and
#   the tags begin without either enumerating tag vocabulary (which this
#   script deliberately avoids elsewhere) or an external episode-title
#   database - the whole trailing text is kept as-is in that case.
#   Both the series title and the episode title go through the same
#   delimited-spec-block stripping as movie titles (see "Delimited spec
#   blocks" above), so an encoder tag like "Show Name (1080p x264
#   EncoderName) S01E01.mkv" or "S01E01 - Real Title (1080p x264
#   EncoderName)" has that block removed rather than folded into the name.
#   Multi-episode files (S01E01E02) and absolute-numbered releases with no
#   S/E letters are not recognized; treated as NO_MATCH, not guessed at.
#   Directory handling differs from movies: an episode's own containing
#   folder is a "Season NN" folder, not the show itself, so it is never
#   touched by the directory pass. The show-root folder (one level further
#   up) is tracked instead and renamed with the same movie-style
#   title + year logic a standalone movie folder gets. Show-root folders
#   never get a franchise wrapper inserted - that's movie-only.

set -euo pipefail

# Bash version guard
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

# Defaults
DRY_RUN=0
FORCE=0
RENAME_DIRS=1
LOG_DIR=""
OPERATIONAL_DIR=""

# Usage
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//'
    exit 0
}

# Arg parsing
while getopts ":L:O:nfFh" opt; do
    case $opt in
        L) LOG_DIR="$OPTARG" ;;
        O) OPERATIONAL_DIR="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        f) FORCE=1 ;;
        F) RENAME_DIRS=0 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ $# -eq 1 ]] || {
    echo "Usage: $0 [OPTIONS] <target_dir>" >&2
    echo "  Run $0 -h for full help." >&2
    exit 1
}
TARGET_DIR="${1%/}"

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "ERROR: Target directory '$TARGET_DIR' does not exist." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR_REAL="$(cd "$TARGET_DIR" && pwd)"   # canonicalize so different relative paths to the same directory hash identically, and so folder-nesting checks below are reliable
[[ -z "$OPERATIONAL_DIR" ]] && OPERATIONAL_DIR="$SCRIPT_DIR"

# Dependency check
require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require find
require flock
require grep
require sha256sum
grep -oP 'x' <<< 'x' &>/dev/null || {
    echo "ERROR: grep must support -P (PCRE); GNU grep on Ubuntu/Debian has this by default" >&2
    exit 1
}

# Concurrency lock: only one run may target a given TARGET_DIR at a time.
# The lock file itself lives under OPERATIONAL_DIR (default: this script's
# own directory; -O to route it elsewhere, e.g. $OUTPUT_DIR when invoked
# through rename.sh/rename_dry.sh), never inside TARGET_DIR — a movie
# library shouldn't have operational files (lock, logs) scattered into it.
# The lock is still correctly scoped per-target: its filename is a hash of
# TARGET_DIR's canonical path, so two runs against the same directory (from
# anywhere, any relative path) still collide, and runs against different
# directories don't.
LOCK_DIR="${OPERATIONAL_DIR}/.locks"
mkdir -p "$LOCK_DIR"
LOCK_HASH="$(printf '%s' "$TARGET_DIR_REAL" | sha256sum | cut -d' ' -f1)"
LOCK_FILE="${LOCK_DIR}/${LOCK_HASH}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another run is already active against $TARGET_DIR (lock: $LOCK_FILE)" >&2
    exit 1
fi
# Registered only after successfully acquiring the lock (a failed acquisition
# above exits before this line, so it never deletes another process's active
# lock file). Removes the now-empty .lock file on any exit - normal, error,
# or signal (bash runs EXIT traps even on SIGINT/SIGTERM; only SIGKILL skips
# them, which nothing here can protect against anyway). Releasing the fd
# alone (which happens automatically at process exit regardless) frees the
# advisory lock; this additionally deletes the file itself so .locks/ doesn't
# accumulate a permanent empty file per target directory ever rename-batched.
# Small accepted race: if another process opens+locks this exact path in the
# instant between this process's last real work and this trap firing, the
# unlink here would remove the path out from under it, and a third process
# could then create a fresh file at the same path and lock that too. For a
# single-user batch tool where runs are seconds apart at minimum, this window
# is negligible - the same tradeoff most lock-file cleanup implementations
# accept in exchange for not leaving permanent clutter behind.
trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT

# Extensions
VIDEO_EXTS="mkv|mp4|avi|mov|m4v"
SUB_EXTS="srt|vtt|ass|idx|sub"
ALL_EXTS="${VIDEO_EXTS}|${SUB_EXTS}"

# Language alias table - shared with encoder_params.sh, same directory.
# shellcheck source=./lang_table.sh
source "$(dirname "${BASH_SOURCE[0]}")/lang_table.sh"

normalize_lang() {
    local raw="${1,,}"
    echo "${LANG_ALIASES[$raw]:-}"
}

# Only cc, sdh, and forced are meaningful to encoder_params.sh's sidecar
# lookup. Anything else comes back empty and the caller treats it as unknown
# rather than writing a modifier the encoder will never match.
normalize_modifier() {
    local raw="${1,,}"
    case "$raw" in
        cc|sdh|forced) echo "$raw" ;;
        *) echo "" ;;
    esac
}

# Shared preprocessing for both parse_media_name and parse_episode_name.
# Strips bracketed release-tracker tags anywhere (e.g. "[TRACKER]" -
# movie/show titles essentially never contain literal square brackets, so
# this is safe unconditionally) and a leading site-announcement prefix (e.g.
# "www.example.org    -    " - requires a domain-like token followed by
# whitespace-hyphen-whitespace, so it won't eat a legitimate title that
# happens to start with a hyphenated phrase). Run once by the caller before
# branching on movie vs. episode, so the episode-detection check itself
# also sees the cleaned name, not just whichever parser runs after it.
strip_junk_prefixes() {
    local s="$1"
    s="$(sed -E 's/\[[^][]*\]//g' <<< "$s")"
    s="$(sed -E 's/^(www\.)?[A-Za-z0-9-]+\.[A-Za-z]{2,}[[:space:]]*-[[:space:]]*//' <<< "$s")"
    echo "$s"
}

# Finds the LAST standalone 4-digit year (1900-2099) in a string, per the
# boundary rule in "Name parsing" above: not immediately preceded or
# followed by another alphanumeric character, so "2160p" and "x265" never
# match. Sets YEAR_MATCH and YEAR_OFFSET (byte offset of the match within
# the input); both empty if no standalone year is present. grep exits 1 on
# no match; `|| true` stops that from tripping set -e/pipefail (same class
# of issue encoder_params.sh's own Design Notes document covers for its
# main-loop return-code handling). Shared by parse_media_name and
# parse_episode_name's redundant-year stripping - both want the same "last
# standalone year" detection, just applied to different substrings.
find_last_year() {
    local raw="$1"
    YEAR_MATCH=""; YEAR_OFFSET=""
    YEAR_MATCH="$(grep -oP '(?<![0-9A-Za-z])(19[0-9]{2}|20[0-9]{2})(?![0-9A-Za-z])' <<< "$raw" | tail -1)" || true
    [[ -z "$YEAR_MATCH" ]] && return
    local off
    off="$(grep -boP '(?<![0-9A-Za-z])'"$YEAR_MATCH"'(?![0-9A-Za-z])' <<< "$raw" | tail -1)" || true
    [[ -z "$off" ]] && { YEAR_MATCH=""; return; }
    YEAR_OFFSET="${off%%:*}"
}

# Cleans a raw title/series-title fragment: dots, underscores, and slashes
# become spaces, runs of whitespace collapse to one space, and
# leading/trailing whitespace or hyphens are trimmed. The slash handling
# specifically guards every title this script produces (PARSED_TITLE,
# PARSED_SERIES, PARSED_EPTITLE) against ever containing a literal "/" -
# titles are used directly as directory and file name components
# (franchise folders, movie-year folders, filenames), and a stray "/"
# there would otherwise be silently read as an extra path separator by
# mkdir/mv rather than as part of the name. Shared by every title-shaped
# fragment this script produces (movie titles both year-last and
# year-first, series titles, episode titles) so the same cleanup rule
# applies everywhere.
clean_fragment() {
    local s
    s="$(tr '._/' '   ' <<< "$1" | tr -s ' ')"
    sed -E 's/^[[:space:]-]+//; s/[[:space:]-]+$//' <<< "$s"
}

# Removes every COMPLETE (...) or [...] group from a string (both
# delimiters present in the input; a lone unmatched "(" or ")" left behind
# by splitting a string at a year is untouched here - that's handled
# separately, see parse_media_name). Used to strip third-party-encoder spec
# blocks like "(1080p x264 AAC BluRay EncoderName)" out of a title before
# it's used, so they never end up as part of a movie's parsed name.
strip_delimited_groups() {
    sed -E 's/\([^()]*\)//g; s/\[[^][]*\]//g' <<< "$1"
}

# Core name parser for MOVIES. Sets PARSED_OK, PARSED_TITLE, PARSED_YEAR,
# PARSED_EDITION from an already-prefix-stripped name with no extension (a
# file basename with its extension already stripped, or a directory
# basename). See "Name parsing" in the header comment for the heuristic.
# PARSED_OK=0 means no usable year was found; the other PARSED_* vars are
# meaningless in that case.
parse_media_name() {
    local raw="$1"
    PARSED_OK=0; PARSED_TITLE=""; PARSED_YEAR=""; PARSED_EDITION=""

    # Extract {edition-X} wherever it appears (rare outside already-Plex-
    # formatted names, but scanned unconditionally rather than assumed
    # absent), removing it from the working string.
    if [[ "$raw" =~ \{edition-([^}]+)\} ]]; then
        PARSED_EDITION="${BASH_REMATCH[1]}"
        raw="${raw/${BASH_REMATCH[0]}/}"
    fi

    # Year detection always runs on the untouched string, BEFORE any
    # delimiter stripping below - so a year is found no matter where it
    # sits, including inside a third-party encoder's spec block (e.g.
    # "Movie Name (2020 1080p x264 AAC BluRay EncoderName).mkv"). Only the
    # leftover non-year text within delimiters is discarded, once the
    # title portion is known - see below.
    find_last_year "$raw"
    [[ -z "$YEAR_MATCH" ]] && return
    local year_match="$YEAR_MATCH" offset="$YEAR_OFFSET"

    local title_part="${raw:0:$offset}"
    title_part="$(strip_delimited_groups "$title_part")"
    title_part="${title_part%(}"   # drop a wrapping "(" left by an already-parenthesized year
    title_part="$(clean_fragment "$title_part")"

    if [[ -z "$title_part" ]]; then
        # Nothing usable before the year - try year-FIRST instead of
        # year-last: "(2020) Movie Name" / "2020 Movie Name", the shape a
        # raw download's own folder is sometimes named. Title becomes
        # everything AFTER the year instead of before it. A trailing ")"
        # left by an already-parenthesized year is dropped the same way a
        # leading "(" is dropped above. This only ever runs when the
        # year-last interpretation came up empty, so a normal
        # "Movie Title (2020)" name is unaffected and still parses year-last.
        local after_offset=$(( offset + ${#year_match} ))
        title_part="${raw:$after_offset}"
        title_part="$(strip_delimited_groups "$title_part")"
        title_part="${title_part#)}"
        title_part="$(clean_fragment "$title_part")"
    fi

    [[ -z "$title_part" ]] && return

    PARSED_TITLE="$title_part"
    PARSED_YEAR="$year_match"
    PARSED_OK=1
}

# Detects whether an already-prefix-stripped name is TV-episode-shaped:
# looks for a standalone SxxEyy token (S, 1-2 digit season, E, 1-3 digit
# episode; bounded by non-alphanumeric the same way the movie parser
# bounds years, so "S03E01" matches but nothing inside a longer alnum run
# does). Checked BEFORE year-based movie parsing runs at all, not as a
# fallback after it - so a show whose title happens to be a bare year
# (e.g. a show titled "1904") is still routed to the episode parser, never
# misparsed as a movie. Multi-episode files (S01E01E02) and absolute-
# numbered releases with no S/E letters (common in some long-running
# anime) are NOT recognized - deliberately, consistent with this script's
# "skip rather than guess" philosophy elsewhere: treated as NO_MATCH, not
# force-fit.
is_episode_shaped() {
    grep -qP '(?<![0-9A-Za-z])[Ss][0-9]{1,2}[Ee][0-9]{1,3}(?![0-9A-Za-z])' <<< "$1"
}

# Core name parser for TV EPISODES. Sets PARSED_OK, PARSED_SERIES,
# PARSED_SEASON, PARSED_EPISODE, PARSED_EPTITLE, PARSED_EDITION from an
# already-prefix-stripped name with no extension. Only call this after
# is_episode_shaped has confirmed an SxxEyy token is present.
#
# Series title = everything before the SxxEyy token (junk-stripped the same
# way movie titles are, plus a redundant trailing year stripped out - Plex
# episode filenames never carry the year, unlike movie filenames; see the
# guard against stripping a show that's actually just named after a year,
# e.g. a show titled "1904", in the code below). Season/episode = the
# digits inside the token, zero-padded to at least 2 digits each (avoiding
# bash's octal trap on inputs like "08"/"09" via the 10# base-10 forcing
# prefix).
#
# Episode title is the hard part: unlike a movie's year, SxxEyy has no
# structural signal marking where a real trailing episode title ends and
# release-tag junk (resolution/source/codec/group) begins - scene-release
# TV naming almost always omits the episode title entirely and goes
# straight from SxxEyy to quality tags, while an already-Plex-formatted
# name puts " - Episode Title" right after it with nothing further. This
# uses that distinction as its own anchor: if what immediately follows
# SxxEyy is a run of separators (space/dot/underscore) THAT INCLUDES A
# LITERAL HYPHEN, everything after is treated as the episode title;
# otherwise everything after is discarded as junk, same as a movie's
# trailing tags. This mirrors the movie parser's approach of using a
# structural anchor instead of enumerating junk vocabulary, but it is a
# heuristic, not a guarantee - see the known limitation this creates,
# noted in the header comment.
parse_episode_name() {
    local raw="$1"
    PARSED_OK=0; PARSED_SERIES=""; PARSED_SEASON=""; PARSED_EPISODE=""
    PARSED_EPTITLE=""; PARSED_EDITION=""

    local match offset
    match="$(grep -oP '(?<![0-9A-Za-z])[Ss][0-9]{1,2}[Ee][0-9]{1,3}(?![0-9A-Za-z])' <<< "$raw" | head -1)" || true
    [[ -z "$match" ]] && return

    offset="$(grep -boP '(?<![0-9A-Za-z])'"$match"'(?![0-9A-Za-z])' <<< "$raw" | head -1)" || true
    [[ -z "$offset" ]] && return
    offset="${offset%%:*}"

    [[ "$match" =~ ^[Ss]([0-9]{1,2})[Ee]([0-9]{1,3})$ ]] || return
    local season="${BASH_REMATCH[1]}" episode="${BASH_REMATCH[2]}"

    local series_raw="${raw:0:$offset}"

    # Strip a redundant year from the series-title segment: Plex episode
    # filenames don't carry the year (only the show-root folder does), but
    # raw releases commonly repeat it right before SxxEyy anyway (e.g.
    # "Show Title (2019) S03E13..." or "Show.Title.2019.S03E13...").
    # Uses the same last-standalone-year detection as the movie parser.
    # Guarded: if stripping would leave nothing meaningful behind, the
    # strip is discarded and the year stays in the title - this is what
    # keeps a show actually named after a year (e.g. a show titled "1904")
    # intact, since there the "year" IS the whole title, not a redundant
    # repeat.
    find_last_year "$series_raw"
    if [[ -n "$YEAR_MATCH" ]]; then
        local candidate="${series_raw:0:$YEAR_OFFSET}"
        candidate="${candidate%(}"
        if [[ -n "$(tr -d '[:space:]._-' <<< "$candidate")" ]]; then
            series_raw="$candidate"
        fi
    fi

    local series_part
    series_raw="$(strip_delimited_groups "$series_raw")"
    series_part="$(clean_fragment "$series_raw")"
    [[ -z "$series_part" ]] && return

    local rest_part="${raw:$(( offset + ${#match} ))}"
    if [[ "$rest_part" =~ ^[[:space:]._]*-[[:space:]._]*(.+)$ ]]; then
        local ep_title="${BASH_REMATCH[1]}"
        if [[ "$ep_title" =~ \{edition-([^}]+)\} ]]; then
            PARSED_EDITION="${BASH_REMATCH[1]}"
            ep_title="${ep_title/${BASH_REMATCH[0]}/}"
        fi
        ep_title="$(strip_delimited_groups "$ep_title")"
        PARSED_EPTITLE="$(clean_fragment "$ep_title")"
    fi

    PARSED_SERIES="$series_part"
    PARSED_SEASON="$(printf '%02d' "$((10#$season))")"
    PARSED_EPISODE="$(printf '%02d' "$((10#$episode))")"
    PARSED_OK=1
}


# Subtitle language/modifier extraction. Decoupled from parse_media_name
# entirely: operates on the raw name's trailing dot-segments before the
# extension, independent of where (or whether, in Plex-parenthesized form)
# the year appears. This also means a subtitle from a raw scene-release name
# (no parentheses at all) still gets its language tag recognized and
# stripped before the name reaches parse_media_name, regardless of whether
# a year appears anywhere in the filename.
# Sets three globals (does not return a value via echo/command substitution
# - that forks a subshell, which would silently discard these same
# assignments, exactly as parse_media_name's globals are set by direct call
# elsewhere in this script):
#   SUB_LANG_TAG           e.g. ".en", ".en.forced", or "" if no tag found
#   SUB_TAG_STRIPPED_NAME  name with the tag removed (unchanged if none found)
#   SUB_TAG_UNRECOGNIZED   "lang:X" or "modifier:X" if a tag was present but
#                          not recognized; "" otherwise
extract_sub_lang_tag() {
    local name="$1"
    SUB_LANG_TAG=""
    SUB_TAG_STRIPPED_NAME="$name"
    SUB_TAG_UNRECOGNIZED=""

    if [[ "$name" =~ ^(.*)\.([A-Za-z]{2,3})\.([A-Za-z]+)$ ]]; then
        local base="${BASH_REMATCH[1]}" raw_lang="${BASH_REMATCH[2]}" raw_mod="${BASH_REMATCH[3]}"
        local norm_lang norm_mod
        norm_lang="$(normalize_lang "$raw_lang")"
        norm_mod="$(normalize_modifier "$raw_mod")"
        if [[ -n "$norm_lang" && -n "$norm_mod" ]]; then
            SUB_LANG_TAG=".${norm_lang}.${norm_mod}"
            SUB_TAG_STRIPPED_NAME="$base"
            return
        elif [[ -n "$norm_lang" ]]; then
            SUB_TAG_UNRECOGNIZED="modifier:$raw_mod"
            return
        fi
        # Neither segment recognized as lang+modifier - fall through and
        # try the lang-only pattern below.
    fi

    if [[ "$name" =~ ^(.*)\.([A-Za-z]{2,3})$ ]]; then
        local base="${BASH_REMATCH[1]}" raw_lang="${BASH_REMATCH[2]}"
        local norm_lang
        norm_lang="$(normalize_lang "$raw_lang")"
        if [[ -n "$norm_lang" ]]; then
            SUB_LANG_TAG=".${norm_lang}"
            SUB_TAG_STRIPPED_NAME="$base"
            return
        fi
        SUB_TAG_UNRECOGNIZED="lang:$raw_lang"
        return
    fi
}

# Counters
RENAMED=0
PREVIEWED=0
SKIPPED=0
NO_MATCH=0
FAILED=0

# Log setup. Unlike encoder_params.sh's Log_InProgress.txt -> finalize-on-
# success dance, this writes directly to its final path: a rename pass is
# seconds long and fully idempotent (already-correct names are simply left
# alone on a re-run), so there's no meaningful "interrupted mid-batch" state
# worth preserving separately.
[[ -z "$LOG_DIR" ]] && LOG_DIR="${OPERATIONAL_DIR}/Logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/Rename_$(date '+%Y-%m-%d_%H%M').txt"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Rename executor, shared by every call site (file loop, directory pass,
# franchise-wrapper moves): handles the unchanged-path no-op, collision
# check, dry-run preview, mv, and counters uniformly so every call site
# stays in sync. The no-op check compares full PATHS, not just basenames,
# since a rename target can legitimately share a basename with its source
# while still needing to move to a different directory (franchise-folder
# restructuring) - a basename-only comparison would wrongly treat that as
# "nothing to do".
attempt_rename() {
    local old="$1" new="$2" label="$3"
    local old_base new_base
    old_base="$(basename "$old")"
    new_base="$(basename "$new")"

    [[ "$old" == "$new" ]] && return 0

    if [[ -e "$new" ]]; then
        if [[ -d "$new" && -d "$old" ]]; then
            # mv on an existing directory target nests the source inside it
            # (new/old/...) rather than replacing or merging it - never safe
            # to force automatically, since it could silently orphan or
            # shadow files already in the destination. Always skipped,
            # regardless of -f.
            echo "SKIPPING (rename target directory already exists — merge manually): $new_base"
            log "SKIPPED (directory collision): $old_base -> $new_base"
            SKIPPED=$(( SKIPPED + 1 ))
            return 0
        fi
        if (( ! FORCE )); then
            echo "SKIPPING (rename target already exists, use -f to overwrite): $new_base"
            log "SKIPPED (collision): $old_base -> $new_base"
            SKIPPED=$(( SKIPPED + 1 ))
            return 0
        fi
    fi

    echo "MATCH FOUND (${label}):"
    echo "  Current path:  $old"
    echo "  New path:      $new"

    if (( DRY_RUN )); then
        echo "  [DRY RUN] Would rename/move to: $new"
        log "PREVIEWED: $old -> $new"
        PREVIEWED=$(( PREVIEWED + 1 ))
    else
        if mv -- "$old" "$new"; then
            echo "  [SUCCESS] Renamed."
            log "RENAMED: $old -> $new"
            RENAMED=$(( RENAMED + 1 ))
        else
            echo "  [FAILED] mv error" >&2
            log "FAILED (mv): $old -> $new"
            FAILED=$(( FAILED + 1 ))
        fi
    fi
    echo "----------------------------------------------------------------"
}

# Creates DIR (and any missing parents) unless in dry-run, where nothing on
# disk is touched - consistent with attempt_rename's own dry-run philosophy
# of previewing without mutating. On a real failure, prints/logs it and
# counts a FAILED the same way attempt_rename's own mv-failure path does.
# Shared by both franchise-folder restructuring call sites: the new
# movie-year folder in the file loop, and the new franchise wrapper in the
# directory pass.
ensure_dir() {
    local dir="$1"
    (( DRY_RUN )) && return 0
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        echo "  [FAILED] could not create folder: $dir" >&2
        log "FAILED (mkdir): $dir"
        FAILED=$(( FAILED + 1 ))
        return 1
    fi
    return 0
}

# Tests whether DIR's canonical path is exactly the scanned target root.
# Used to decide whether a movie needs a brand-new franchise wrapper
# (sitting directly in the root, nothing above it) or already has one in
# place (sitting anywhere else) - see "Franchise-folder restructuring" in
# the header comment.
# Exit status distinguishes three outcomes, not just true/false: 0 = DIR is
# the target root, 1 = DIR exists and is not the target root, 2 = DIR could
# not be statted at all (removed or made inaccessible by something else
# since this batch started scanning). Callers must check for 2 separately
# and treat it as a per-item failure (skip + log), not fall through to
# either the true or false branch - and must never call this as a bare
# statement, since under `set -e` any non-zero return from a bare command
# (as opposed to one used in a conditional) would abort the whole script.
# The `|| result=$?` pattern at each call site keeps this safe.
is_target_root() {
    local real
    real="$(cd "$1" 2>/dev/null && pwd)" || return 2
    [[ "$real" == "$TARGET_DIR_REAL" ]]
}

# Wraps is_target_root with the "can't stat it" handling every call site
# needs: prints/logs and counts a FAILED, the same way ensure_dir's own
# mkdir-failure path does, so that bookkeeping exists in exactly one place.
# Returns the same three-way status as is_target_root (0/1/2) - callers
# still branch on it themselves, but no longer repeat the failure handling.
check_root() {
    local dir="$1" rc=0
    is_target_root "$dir" || rc=$?
    if [[ $rc -eq 2 ]]; then
        echo "  [FAILED] could not stat folder: $dir (removed or inaccessible during this run?)" >&2
        log "FAILED (stat): $dir"
        FAILED=$(( FAILED + 1 ))
    fi
    return $rc
}

echo "Starting Plex library scan (Videos & Subtitles)..."
(( DRY_RUN )) && echo "=== RUNNING IN DRY-RUN MODE (No changes will be made) ==="
(( RENAME_DIRS )) || echo "=== Files only (-F): no directories will be renamed, created, or moved ==="
echo "----------------------------------------------------------------"
log "Rename pass started: $TARGET_DIR"

declare -A MATCHED_DIRS=()   # unique parent dirs of successfully-parsed movie/show files, for the directory pass. Value is "movie" or "show" - only "movie" entries are ever eligible for franchise-wrapper insertion.

# Main loop. Null-delimited find + process substitution (not a pipe) so
# counters set inside the loop are visible after it ends - a
# `find ... | while read` loop runs the loop body in a subshell and
# silently discards them.
while IFS= read -r -d '' FILE_PATH; do

    FILE_NAME="$(basename "$FILE_PATH")"
    FILE_DIR="$(dirname "$FILE_PATH")"
    FILE_EXT="${FILE_NAME##*.}"
    FILE_EXT_LOWER="${FILE_EXT,,}"
    FILE_BASE="${FILE_NAME%.*}"

    IS_SUBTITLE=0
    [[ "$FILE_EXT_LOWER" =~ ^(${SUB_EXTS})$ ]] && IS_SUBTITLE=1

    # Reset per-iteration movie-path state so a stale value from a previous
    # (possibly episode) iteration can never leak into this one's decisions.
    IS_EPISODE=0
    OWN_OK=0; DIR_OK=0; MOVIE_OK=0; USED_PARENT_FALLBACK=0
    ITEM_OK=0

    # 1. SUBTITLE LANGUAGE TAG (decoupled from title/year parsing - see
    #    extract_sub_lang_tag's own comment for why).
    SUB_LANG_TAG=""
    WORKING_NAME="$FILE_BASE"
    if (( IS_SUBTITLE )); then
        extract_sub_lang_tag "$FILE_BASE"
        if [[ -n "$SUB_TAG_UNRECOGNIZED" ]]; then
            case "$SUB_TAG_UNRECOGNIZED" in
                lang:*)
                    echo "SKIPPING (unrecognized subtitle language '${SUB_TAG_UNRECOGNIZED#lang:}'): $FILE_NAME"
                    log "SKIPPED (unrecognized language '${SUB_TAG_UNRECOGNIZED#lang:}'): $FILE_NAME"
                    ;;
                modifier:*)
                    echo "SKIPPING (unrecognized subtitle modifier '${SUB_TAG_UNRECOGNIZED#modifier:}'): $FILE_NAME"
                    log "SKIPPED (unrecognized modifier '${SUB_TAG_UNRECOGNIZED#modifier:}'): $FILE_NAME"
                    ;;
            esac
            SKIPPED=$(( SKIPPED + 1 ))
            continue
        fi
        WORKING_NAME="$SUB_TAG_STRIPPED_NAME"
    fi

    # 2. STRIP SHARED JUNK (brackets, site-prefix), THEN BRANCH: episode
    #    detection runs first and unconditionally, so a title containing a
    #    bare year is never misrouted into movie parsing (see
    #    is_episode_shaped's own comment).
    WORKING_NAME_STRIPPED="$(strip_junk_prefixes "$WORKING_NAME")"

    if is_episode_shaped "$WORKING_NAME_STRIPPED"; then
        IS_EPISODE=1
        parse_episode_name "$WORKING_NAME_STRIPPED"
        ITEM_OK=$PARSED_OK
    else
        # MOVIE path: try the file's own name, then (independently) its
        # immediate parent folder's name. Both attempts are made - not just
        # one short-circuited fallback - because which one succeeds also
        # decides how the file gets relocated below; see
        # "Franchise-folder restructuring" in the header comment.
        parse_media_name "$WORKING_NAME_STRIPPED"
        OWN_OK=$PARSED_OK; OWN_TITLE="$PARSED_TITLE"; OWN_YEAR="$PARSED_YEAR"; OWN_EDITION="$PARSED_EDITION"

        PARENT_NAME="$(basename "$FILE_DIR")"
        parse_media_name "$(strip_junk_prefixes "$PARENT_NAME")"
        DIR_OK=$PARSED_OK; DIR_TITLE="$PARSED_TITLE"; DIR_YEAR="$PARSED_YEAR"; DIR_EDITION="$PARSED_EDITION"

        if (( OWN_OK )); then
            FINAL_TITLE="$OWN_TITLE"; FINAL_YEAR="$OWN_YEAR"; FINAL_EDITION="$OWN_EDITION"
            MOVIE_OK=1
        elif (( DIR_OK )); then
            FINAL_TITLE="$DIR_TITLE"; FINAL_YEAR="$DIR_YEAR"; FINAL_EDITION="$DIR_EDITION"
            MOVIE_OK=1
            USED_PARENT_FALLBACK=1
        else
            MOVIE_OK=0
        fi
        ITEM_OK=$MOVIE_OK
    fi

    if [[ $ITEM_OK -ne 1 ]]; then
        if (( IS_EPISODE )); then
            echo "NO MATCH (episode-shaped but unparseable): $FILE_NAME"
            log "NO MATCH: $FILE_NAME"
        else
            echo "NO MATCH (no valid year found in file name or parent folder): $FILE_NAME"
            log "NO MATCH: $FILE_NAME"
        fi
        NO_MATCH=$(( NO_MATCH + 1 ))
        continue
    fi

    # A movie's own directory holds just that movie (only when it's itself
    # movie-shaped - see Case B below for when it isn't); an episode's own
    # directory is a "Season NN" folder, not the show - the show-root
    # folder is one level further up. Track whichever is the actual
    # title/year-shaped ancestor, so the directory pass never runs against
    # "Season NN" itself, and never runs against a plain (non-year) folder
    # that a Case B move will create a NEW correctly-named subfolder inside
    # of rather than renaming.
    if (( IS_EPISODE )); then
        MATCHED_DIRS["$(dirname "$FILE_DIR")"]="show"
    elif (( DIR_OK )); then
        MATCHED_DIRS["$FILE_DIR"]="movie"
    fi

    # 3. REBUILD
    if (( IS_EPISODE )); then
        CLEAN_PLEX_NAME="$PARSED_SERIES - S${PARSED_SEASON}E${PARSED_EPISODE}"
        [[ -n "$PARSED_EPTITLE" ]] && CLEAN_PLEX_NAME="$CLEAN_PLEX_NAME - $PARSED_EPTITLE"
        [[ -n "$PARSED_EDITION" ]] && CLEAN_PLEX_NAME="$CLEAN_PLEX_NAME {edition-$PARSED_EDITION}"
    else
        if [[ -n "$FINAL_EDITION" ]]; then
            CLEAN_PLEX_NAME="$FINAL_TITLE ($FINAL_YEAR) {edition-$FINAL_EDITION}"
        else
            CLEAN_PLEX_NAME="$FINAL_TITLE ($FINAL_YEAR)"
        fi
    fi
    NEW_FILE_NAME="${CLEAN_PLEX_NAME}${SUB_LANG_TAG}.${FILE_EXT_LOWER}"

    # Destination directory. Movies whose immediate parent folder is NOT
    # movie-shaped (Case B) relocate into a freshly created folder instead
    # of staying in place - everything else renames in place, exactly as
    # before. Gated on RENAME_DIRS (-F): with -F, nothing is ever created
    # or moved, only renamed in place.
    RESTRUCTURED=0
    if [[ $IS_EPISODE -eq 0 && $DIR_OK -eq 0 ]] && (( RENAME_DIRS )); then
        ROOT_CHECK=0
        check_root "$FILE_DIR" || ROOT_CHECK=$?
        if [[ $ROOT_CHECK -eq 2 ]]; then
            continue
        elif [[ $ROOT_CHECK -eq 0 ]]; then
            # File is sitting loose directly in the scanned root with no
            # per-movie folder at all - create both the franchise folder
            # and the movie-year folder.
            NEW_FILE_DIR="${FILE_DIR}/${FINAL_TITLE}/${CLEAN_PLEX_NAME}"
        else
            # File is inside some existing non-year-shaped folder, which
            # is treated as the franchise folder already in place (default
            # or custom-named) - only the movie-year folder is created.
            NEW_FILE_DIR="${FILE_DIR}/${CLEAN_PLEX_NAME}"
        fi
        ensure_dir "$NEW_FILE_DIR" || continue
        NEW_FILE_PATH="${NEW_FILE_DIR}/${NEW_FILE_NAME}"
        RESTRUCTURED=1
    else
        NEW_FILE_PATH="${FILE_DIR}/${NEW_FILE_NAME}"
    fi

    [[ "$FILE_PATH" == "$NEW_FILE_PATH" ]] && continue

    if (( IS_EPISODE )); then
        echo "  Cached Data:   Series: '$PARSED_SERIES' | S${PARSED_SEASON}E${PARSED_EPISODE} | Title: '$PARSED_EPTITLE' | Edition: '$PARSED_EDITION' | Lang: '$SUB_LANG_TAG'"
    else
        echo "  Cached Data:   Name: '$FINAL_TITLE' | Year: '$FINAL_YEAR' | Edition: '$FINAL_EDITION' | Lang: '$SUB_LANG_TAG'"
        if (( USED_PARENT_FALLBACK )); then
            echo "  Source:        title/year taken from parent folder name (file's own name had none)"
            log "PARENT FALLBACK USED: $FILE_NAME <- $PARENT_NAME"
        fi
        if (( RESTRUCTURED )); then
            echo "  Restructure:   moving into '${NEW_FILE_DIR#"$TARGET_DIR_REAL"/}/' (no movie folder existed here yet)"
            log "RESTRUCTURED: $FILE_NAME -> $NEW_FILE_DIR"
        fi
    fi
    TYPE_LABEL="Video"
    (( IS_SUBTITLE )) && TYPE_LABEL="Subtitle"

    # 4. EXECUTE
    attempt_rename "$FILE_PATH" "$NEW_FILE_PATH" "$TYPE_LABEL"

done < <(find "$TARGET_DIR" -type f -regextype posix-extended -iregex ".*\.(${ALL_EXTS})$" -print0 | sort -z)

# Directory pass. Runs after all file renames complete, over the set of
# directories that are the title/year-shaped ancestor of at least one
# successfully-parsed file: a movie's own folder (only when that folder was
# already movie-shaped going in - see Case B above for when it wasn't), or
# a show's root folder (one level above "Season NN" for episodes). "Season
# NN" folders themselves are never in this set and are never touched.
# Always parsed as movie/show-style (title + year), never as episode-style
# - a directory basename has no extension and isn't itself an episode
# file. Year-first names (e.g. a raw download's "(2020) Movie Name"
# folder) are handled the same way here as everywhere else, via
# parse_media_name's year-first fallback.
if (( RENAME_DIRS )) && [[ ${#MATCHED_DIRS[@]} -gt 0 ]]; then
    echo ""
    echo "=== Directory pass ==="
    for DIR_PATH in "${!MATCHED_DIRS[@]}"; do
        DIR_TYPE="${MATCHED_DIRS[$DIR_PATH]}"
        DIR_BASE="$(basename "$DIR_PATH")"
        DIR_PARENT="$(dirname "$DIR_PATH")"

        parse_media_name "$(strip_junk_prefixes "$DIR_BASE")"
        if [[ $PARSED_OK -ne 1 ]]; then
            continue
        fi

        if [[ -n "$PARSED_EDITION" ]]; then
            NEW_DIR_NAME="$PARSED_TITLE ($PARSED_YEAR) {edition-$PARSED_EDITION}"
        else
            NEW_DIR_NAME="$PARSED_TITLE ($PARSED_YEAR)"
        fi
        NEW_DIR_PATH="${DIR_PARENT}/${NEW_DIR_NAME}"

        SKIPPED_BEFORE=$SKIPPED
        attempt_rename "$DIR_PATH" "$NEW_DIR_PATH" "Directory"
        # A collision here means we couldn't safely rename this folder at
        # all - don't attempt a franchise-wrapper move on top of that.
        [[ $SKIPPED -gt $SKIPPED_BEFORE ]] && continue

        [[ "$DIR_TYPE" == "movie" ]] || continue   # show-root folders never get a franchise wrapper

        # Franchise-wrapper insertion: only when this movie folder sits
        # directly in the scanned root with nothing above it - see
        # "Franchise-folder restructuring" in the header comment. A movie
        # folder that already has any other parent is assumed to already
        # be inside a franchise folder (default-named or a user's custom
        # one) and is left exactly where it is - this script never renames
        # an existing franchise folder.
        ROOT_CHECK=0
        check_root "$DIR_PARENT" || ROOT_CHECK=$?
        [[ $ROOT_CHECK -eq 0 ]] || continue

        CURRENT_DIR_PATH="${DIR_PARENT}/${NEW_DIR_NAME}"
        WRAPPER_DIR="${TARGET_DIR_REAL}/${PARSED_TITLE}"

        ensure_dir "$WRAPPER_DIR" || continue
        attempt_rename "$CURRENT_DIR_PATH" "${WRAPPER_DIR}/${NEW_DIR_NAME}" "Directory (franchise wrapper)"
    done
fi

# Summary
echo ""
echo "------------------------------------------"
echo " Batch complete"
echo "  Renamed:    $RENAMED"
(( DRY_RUN )) && echo "  Previewed:  $PREVIEWED  (dry run: nothing written; re-run without -n to rename)"
echo "  Skipped:    $SKIPPED  (collisions or unrecognized language/modifier - review manually)"
echo "  No match:   $NO_MATCH  (no usable year found; left untouched)"
echo "  Failed:     $FAILED"
echo "------------------------------------------"
log "Batch complete: Renamed=$RENAMED Previewed=$PREVIEWED Skipped=$SKIPPED NoMatch=$NO_MATCH Failed=$FAILED"
echo "Log saved to: $LOG_FILE"

[[ $FAILED -eq 0 ]] || exit 1