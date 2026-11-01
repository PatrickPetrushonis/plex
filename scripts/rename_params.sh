#!/usr/bin/env bash
# rename_params.sh: Rename movie AND TV episode video/subtitle files (and
#                  optionally their containing directories) into Plex naming
#                  convention. Handles both already-Plex-formatted names and
#                  raw scene-release names — see "Name parsing" below.
#
# Usage:  ./rename_params.sh [OPTIONS] <target_dir>
#
# Options:
#   -n              Dry run: print decisions, do not rename (default: off)
#   -f              Force: overwrite destination if a rename target already
#                   exists (default: off — collisions are skipped and logged).
#                   Applies to files only: a directory-rename collision is
#                   always skipped, since mv nests a directory inside an
#                   existing target rather than replacing it. Asks for a
#                   typed "yes" on stdin before doing anything (not in a
#                   dry run); any other answer aborts the run
#   -F              Files only: rename in place; skip renaming containing
#                   directories and all franchise-folder and Season-folder
#                   restructuring (default: off — see "Franchise-folder
#                   restructuring" and "Episode folder layout" below)
#   -O DIR          Operational directory: base for logs (OPDIR/Logs) and the
#                   lock file (OPDIR/.locks), never <target_dir> itself.
#                   Default: this script's own directory
#   -L DIR          Log directory, overriding OPDIR/Logs specifically
#   -h              Show this help
#
# Notes:
#   • Refuses to run as root: the folders and logs it creates must belong to
#     the user who owns the library
#   • Requires bash 4.0+, a grep with PCRE support (-P; GNU grep on
#     Ubuntu/Debian has this by default), and sha256sum
#   • Only one run may target a given <target_dir> at a time; a second run
#     against the same directory exits immediately instead of racing on
#     shared rename targets (see "Concurrency lock" below)
#   • Requires lang_table.sh and lang_table.tsv alongside this script.
#     Subtitle language tags are normalized against them: .eng.srt and
#     .fre.srt become .en.srt and .fr.srt
#   • Subtitle modifiers are only ever written as cc, sdh, or forced, the
#     three forms the encoder's sidecar-subtitle lookup matches. Anything
#     else (unrecognized language or modifier) is skipped rather than
#     guessed, since a wrong guess makes the encoder silently drop that
#     subtitle later with no error of its own.
#
# Name parsing:
#   A name is split at its LAST standalone 4-digit year (1900-2099), bounded
#   by non-alphanumeric characters or the string edge, so 2160p and x265
#   never match but "2015" in "Movie Title 2015 1080p BluRay x265-GROUP"
#   does. Everything before the year is the title; everything after is
#   release-tag junk and is discarded unparsed, which avoids having to know
#   every tag vocabulary in use. "Title (2020)" parses the same way, since
#   parentheses are non-alphanumeric boundaries.
#
#   Cleaning order, before any year, edition or episode is read:
#   (1) "[...]" groups are read first. A group whose whole content is a year,
#   an edition marker, an SxxEyy token or an episode number is promoted into
#   the name ("[2010]" becomes "(2010)", "[Extended Cut]" becomes "(Extended
#   Cut)", "[01]" becomes " - 01"); every other group (resolution, hash,
#   release group) is dropped. (2) "(S01E01)" and "{S01E01}" are unwrapped
#   and other "{...}" groups dropped, except Plex's own "{edition-X}".
#   (3) A leading site-announcement prefix (e.g. "www.example.org    -    ")
#   is removed. (4) A release-version suffix on an episode number
#   ("S01E01v3", " - 05v2") is dropped. (5) Tabs and non-breaking spaces
#   become spaces, runs of spaces collapse, and both ends are trimmed.
#   A name with no whitespace, dots or underscores is hyphen-delimited
#   ("Movie-Name-2010-1080p") and its title hyphens are word separators; in
#   any other style hyphens stay in the title ("Hyphen-Title.2002.1080p").
#
#   Known limitation: a 4-digit number inside a title ("Movie 2049 (2017)")
#   stays in the title because the last year wins. A name that ends in such a
#   number with nothing after it ("Movie 2049.mkv") cannot be told from a
#   real year without a metadata lookup, which this script does not do.
#
#   Year-first names ("(2020) Movie Name", "2020 Movie Name") take the title
#   from the text after the year, only when nothing usable precedes it.
#
#   Delimited spec blocks: complete "(...)" groups in the title portion are
#   removed, which drops encoder spec blocks such as "(1080p x264 AAC BluRay
#   EncoderName)". The year is found first, so one inside such a block
#   ("(2020 1080p x264)") still counts. Known limitation: a title's own
#   parentheses ("Movie (Part Two)") are removed too, since telling them
#   apart needs the same metadata lookup.
#
#   Edition markers are matched as freeform keywords anywhere in the name,
#   before the year or title is touched, and written as one "{edition-X}"
#   label: "Movie Name 2010 Remastered Extended Edition" becomes "Movie Name
#   (2010) {edition-Extended Remastered}". An "{edition-X}" tag already on a
#   name takes precedence and is kept as written. EDITION_PATTERNS holds the
#   marker list, the label rules and the known limitations.
#
# Franchise-folder restructuring (movies only):
#   Target layout: <library>/Franchise Name/Movie Name (YYYY)/Movie Name
#   (YYYY).mkv. The franchise folder defaults to the bare movie title. An
#   existing franchise folder is never renamed, only created when absent, so
#   one renamed by hand (e.g. to a series name shared by several movies) is
#   safe.
#
#   A movie's title and year come from its own name, else from its immediate
#   parent folder's name. The parent is consulted only when the file's own
#   name has no year and the folder holds exactly one video, because several
#   videos would resolve to the same movie name; otherwise the file is
#   NO_MATCH.
#   - Parent folder has a year: the file and the folder are renamed in
#     place. If the folder sits directly in the scanned directory, a
#     franchise folder is created and the movie folder moved into it. With
#     any other parent, it is assumed to be in a franchise folder already and
#     nothing above it is touched.
#   - Parent folder has no year, the file's name does: the file moves into a
#     new "Movie Name (YYYY)" folder. A file loose in the scanned directory
#     also gets a new franchise folder around that.
#   - Neither has a year: NO_MATCH; nothing is inferred or moved.
#   Episodes never get a franchise wrapper. -F disables all restructuring.
#
#   Known limitations: a subtitle sidecar is relocated only if its own name
#   (after the language tag) has a year, because sidecars are not matched to
#   a video's resolved title; a year-less subtitle next to a correctly named
#   video is NO_MATCH. The scanned directory is never a rename target, but a
#   loose year-less file in a root named like a movie ("Downloads (2020)")
#   can still take its name from the root, since the file-naming fallback and
#   the directory guard are independent checks.
#
# TV episodes:
#   A name with a standalone SxxEyy token (S + 1-2 digit season, E + 1-3
#   digit episode) is parsed as an episode before any year-based movie
#   parsing, so a show titled with a bare year ("2000") is never read as a
#   movie. Everything before the token is the series title; season and
#   episode are zero-padded from the token. Output: "Series - SxxEyy -
#   Episode Title.ext", or "Series - SxxEyy.ext" with no title.
#   A hyphen in the separator right after SxxEyy marks an episode title
#   ("S03E01 - Real Title" keeps everything after it); without one,
#   everything after is discarded as junk ("S03E01.1080p.WEB-DL.x264-GROUP").
#   Known limitation: a hyphen-delimited title followed by quality tags
#   ("S03E01 - Title 1080p WEB-DL x264-GROUP") is kept whole, since telling
#   them apart needs tag vocabulary or an episode-title database.
#   Spec blocks are stripped from series and episode titles as for movies.
#   A name that already has spaces keeps the periods in its episode title
#   ("Hero Vs. Villain!"), trimming only trailing ones; a dot-delimited
#   scene name converts its dots to spaces.
#   A ".N" suffix marks a special, recap or similar extra ("S01E17.5"); it is
#   kept as written: "Series - S01E17.5 - Title.ext". Multi-episode numbering
#   (S01E01E02, S01E01-E02) is NO_MATCH, not guessed at.
#
#   Inferred episode numbering: a name with no SxxEyy token is read as an
#   episode when it contains one of the following AND at least two videos in
#   the same folder share the title before the number and the same shape
#   (the text after the number may differ):
#   - "Episode N" or "Ep N", optionally preceded by "Season N" (a year after
#     it marks a movie);
#   - " - NN", optionally followed by "(...)" groups such as "(BD 1080p)"
#     (a year there marks a movie, not an episode); NN may carry a ".N"
#     special suffix ("Show - 02.5" becomes S01E02.5);
#   - " - NN - Episode Title" (a year in the title marks a movie);
#   - a dot, underscore or hyphen plus two or three digits, in a name with
#     no whitespace ("Show.Name.01", "Show-Name-01"), optionally followed by
#     "(...)" groups ("Show_Name_01_(720p)"; a year in one marks a movie).
#   A title after "Episode N" or " - NN - " is dropped, except after a hyphen
#   following "Episode N" ("Show - Episode 01 - Title"), which is kept.
#   Siblings are counted once before any rename (build_episode_stems), so the
#   whole series stays confirmed as its files are renamed. A lone numbered
#   file is never inferred to be an episode, since a bare number is equally a
#   sequel or part number. A confirmed name is rewritten to "Title SxxEyy"
#   and parsed like any episode. Season comes from a "Season N" token, else the
#   nearest "Season NN" folder above the file, else 1. With no title before
#   the number, the show folder's name is the title.
#   Known limitations: season 1 is a guess when nothing names a season; movie
#   sequels sharing a folder ("Title - 1", "Title - 2") look like episodes; a
#   series with one unrenamed file left has too few siblings to confirm and
#   is NO_MATCH.
#
#   Show folders: a folder named "Series Name (YYYY)" (the outermost one
#   below the scanned root) that holds at least one episode, directly or in
#   Season, release or extras subfolders, is a show folder. Everything under
#   it is named from it: each episode becomes "Series Name - SxxEyy[ -
#   Title].ext" whatever series name its own file name carries, and is
#   placed in "Season XX" of that folder. The season comes from the file
#   name (SxxEyy or "Season N"), else from the nearest "Season NN" folder it
#   sits in ("Season NN - Descriptor" counts; the descriptor is dropped and
#   the files land in plain "Season NN"), else it is season 1. A season named
#   in the file name wins over the folder's. A video or subtitle under a show folder
#   with no episode number (extras, credits, trailers) is moved to "Season
#   00" with its cleaned name. A numbered file that lacks the siblings to
#   confirm it is NO_MATCH, not an extra. Folders emptied by these moves are
#   removed, innermost first.
#
#   Track-numbered subtitles: a subtitle under a show folder named only
#   "<track> <language>" ("2 English", "3_English") takes its episode from the
#   nearest ancestor folder that carries an SxxEyy token, its language from
#   lang_table.sh, and its modifier from how that folder's track subtitles of
#   the same language compare: of two, the one with more lines containing [ or
#   ] is the closed-caption one ("Series - SxxEyy.en.cc.srt") and the other the
#   plain one ("Series - SxxEyy.en.srt"); equal counts fall back to the
#   byte-order sort of the names, first plain, second cc. The track number
#   itself is ignored. A third or later track, or a language not in
#   lang_table.sh, is skipped. With no SxxEyy ancestor the file is an extra.
#
#   Subtitles below their video: a subtitle in a folder with no video of its
#   own, named only by a language ("English", "2 English", "English.forced")
#   or carrying a dot language tag, with no episode in its name or folders,
#   belongs to the nearest folder above it that directly holds exactly one
#   video. It is renamed after that video's final name plus the language tag
#   and moved beside it, in a pass after the file pass; of two tracks of one
#   language the one with more bracketed lines is ".cc" (see Track-numbered
#   subtitles). If that video was not renamed (collision or no match), or the
#   nearest folder with videos holds several, the subtitle is NO MATCH. With
#   -F these subtitles are handled as before.
#
#   Unsupported subtitles: only the languages in SUPPORTED_SUB_LANGS ("en")
#   are kept. A subtitle whose language is recognized (lang_table.tsv) and not
#   supported is deleted, not renamed: one carrying a dot tag
#   ("Name.2010.fr.srt", "Name.S01E01.fr.forced.srt") when the name outside the
#   tag has a year or an episode token, and one named only by a language word
#   of three or more letters ("3 Arabic.srt", "French.srt"). A real run asks
#   once for a typed "yes" before the first deletion; any other answer leaves
#   every such file in place. A dry run lists them as "Would delete". Folders
#   left empty are removed. A subtitle with an unrecognized language tag is
#   skipped, not deleted. Any other unsupported subtitle (a tag on a name with
#   no year or episode, a two-letter language name) is skipped, never renamed.
#   -F does not affect deletion.
#
#   Title casing: Title Case small words (a an and but by for in nor of on or
#   the to at) inside a movie, series or episode title or an extra's name are
#   lowercased, except the first and last word, a word after ": ; . ! ? ( [ -"
#   or a dash, and an all-caps word. Folders named from those titles follow.
#   Nothing is ever capitalized.
#
#   Episode folder layout outside a show folder: every episode video and
#   subtitle is placed at
#   <Series Name (YYYY)>/Season XX/<Series Name - SxxEyy>.<ext>. The season
#   folder always comes from the file's own SxxEyy token (zero-padded, so a
#   file in "Season 1" moves to "Season 01"), and a folder left empty by such
#   a move is removed. The show folder is found as follows:
#     - file in a "Season NN" folder: that folder's parent;
#     - file flat in a folder whose title matches the series: that folder;
#     - file flat in a release folder that names the series in its own
#       "(...)" group ("Native Title (Series Title) (Season 02)"): the series
#       folder beside it, so every season's release folder merges into one
#       show folder, and the release folder is removed once empty;
#     - otherwise (loose in the scanned root, a "Season NN" folder directly
#       in the root, or a folder holding unrelated things): a new
#       "Series (YYYY)" folder is created inside it ("Series" when no year
#       is known, reusing a matching series folder already there).
#   The show folder is renamed with the same title + year logic as a movie
#   folder. Its year comes from its own name, else from a year in the
#   episode's file name, which also names a new folder. With no year
#   anywhere, an existing show folder keeps its name and a new one is named
#   "Series"; either way the files move into "Season XX", and the year is
#   added to that one folder name by hand. A "Season NN" folder whose number
#   differs from the file's token is not trusted; the file moves to the
#   folder its token names.

set -euo pipefail

# Bash version guard
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

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

# The script creates folders and logs the library's owner must be able to use;
# under sudo they would belong to root.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates folders and logs a normal user needs to own." >&2
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
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
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

# -f can overwrite existing files, so it needs a typed answer at the moment of
# the run: a flag alone can be typed ahead of time and fired without re-reading
# it. Anything but "yes" (including end of input) aborts. A dry run overwrites
# nothing and is not asked.
if (( FORCE && ! DRY_RUN )); then
    CONFIRM=""
    read -r -p "-f overwrites existing files. Type 'yes' to continue: " CONFIRM || true
    [[ "$CONFIRM" == "yes" ]] || { echo "Aborted." >&2; exit 1; }
fi

# Keep the caller's stdin on descriptor 8: the file loop reads its own input
# from stdin, so a prompt inside it (delete_subtitle) reads from here instead.
exec 8<&0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR_REAL="$(cd "$TARGET_DIR" && pwd)"   # canonicalize so different relative paths to the same directory hash identically, and so folder-nesting checks below are reliable
[[ -z "$OPERATIONAL_DIR" ]] && OPERATIONAL_DIR="$SCRIPT_DIR"

# Concurrency lock: only one run may target a given TARGET_DIR at a time. The
# lock file lives under OPERATIONAL_DIR, never inside TARGET_DIR, so a library
# holds no operational files. Its name is a hash of TARGET_DIR's canonical
# path, so any spelling of the same directory collides and different
# directories do not.
LOCK_DIR="${OPERATIONAL_DIR}/.locks"
mkdir -p -- "$LOCK_DIR"
LOCK_HASH="$(printf '%s' "$TARGET_DIR_REAL" | sha256sum | cut -d' ' -f1)"
LOCK_FILE="${LOCK_DIR}/${LOCK_HASH}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another run is already active against $TARGET_DIR (lock: $LOCK_FILE)" >&2
    exit 1
fi
# Registered only after the lock is acquired, so a failed acquisition never
# deletes another process's lock file. Removes the lock file on any exit,
# including SIGINT and SIGTERM (EXIT traps run on both; SIGKILL skips them).
# Accepted race: a process that locks this path between the last real work
# and this trap can have the file unlinked from under it; for a single-user
# batch tool that window is negligible.
trap 'rm -f -- "$LOCK_FILE" 2>/dev/null || true' EXIT

# Extensions
VIDEO_EXTS="mkv|mp4|avi|mov|m4v"
SUB_EXTS="srt|vtt|ass|idx|sub"
ALL_EXTS="${VIDEO_EXTS}|${SUB_EXTS}"

# Subtitle languages kept: space-separated 2-letter codes, each a code2 in
# lang_table.tsv. A subtitle in any other recognized language is deleted. To
# keep another language, add its code here (SUPPORTED_SUB_LANGS="en fr").
SUPPORTED_SUB_LANGS="en"

# Language alias table (lang_table.sh, alongside this script).
# shellcheck source=./lang_table.sh
[[ -r "${SCRIPT_DIR}/lang_table.sh" ]] || {
    echo "ERROR: lang_table.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
source "${SCRIPT_DIR}/lang_table.sh"

# Prints the canonical language code for a raw subtitle language tag, or
# nothing when the tag isn't in LANG_ALIASES (lang_table.sh).
normalize_lang() {
    local raw="${1,,}"
    echo "${LANG_ALIASES[$raw]:-}"
}

# Returns 0 when CODE (a 2-letter language code) is in SUPPORTED_SUB_LANGS.
is_supported_lang() { [[ " $SUPPORTED_SUB_LANGS " == *" $1 "* ]]; }

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

# Returns 0 when TEXT is, in its entirety, one recognized edition marker
# ("Extended Cut", "Director's Cut", "25th Anniversary Edition"), so a bracket
# group holding only that is an edition and not release-tag noise. Uses
# extract_known_edition, so it clobbers EDITION_LABEL and EDITION_RAW.
is_whole_edition() {
    extract_known_edition "$1"
    [[ -n "$EDITION_LABEL" && -z "$(clean_fragment "$EDITION_RAW")" ]]
}

# Returns 0 when NAME is delimited by hyphens alone: no whitespace, dots or
# underscores, at least one hyphen ("Movie-Name-2010-1080p"). In that style
# the hyphens are word separators. In any other style a hyphen is part of a
# title ("Hyphen-Title.2002.1080p") and is left alone.
hyphen_delimited() {
    [[ "$1" != *[[:space:]._]* && "$1" == *-* ]]
}

# Reads the information carried by "[...]" groups before they are discarded.
# A group is read only when its WHOLE content is one recognized token, so
# resolution, codec, hash and release-group tags ("[1080p]", "[ABCD1234]",
# "[Grp]") stay noise:
#   [2010]            a year; becomes "(2010)", the form the parser already reads
#   [Extended Cut]    an edition marker; becomes "(Extended Cut)"
#   [S01E01]          an episode token; becomes a bare " S01E01 "
#   [01]              an episode number; becomes " - 01 " (see below)
# Any other "[...]" group is dropped. An episode number is promoted only when
# it is the one numeric group in the name, nothing else in the name already
# carries an episode number, text precedes it, and no year follows it, so
# "Movie [2] (2010)" is never turned into an episode. Prints the result.
promote_bracket_tokens() {
    local rest="$1" out="" head content before after plain num
    local mark=$'\x01' endmark=$'\x02' nums=0
    local group_re='^([^][]*)\[([^][]*)\](.*)$'

    while [[ "$rest" =~ $group_re ]]; do
        head="${BASH_REMATCH[1]}"; content="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
        content="${content#"${content%%[![:space:]]*}"}"
        content="${content%"${content##*[![:space:]]}"}"
        if [[ "$content" =~ ^(19|20)[0-9]{2}$ ]]; then
            out+="$head ($content) "
        elif [[ "$content" =~ ^[Ss][0-9]{1,2}[Ee][0-9]{1,3}(\.[0-9]{1,2})?$ ]]; then
            out+="$head $content "
        elif [[ "$content" =~ ^[0-9]{1,3}$ ]]; then
            nums=$(( nums + 1 ))
            out+="$head $mark$content$endmark "
        elif [[ -n "$content" ]] && is_whole_edition "$content"; then
            out+="$head ($content) "
        else
            out+="$head "
        fi
    done
    out+="$rest"

    if [[ "$out" == *"$mark"* ]]; then
        before="${out%%"$mark"*}"
        num="${out#*"$mark"}"; num="${num%%"$endmark"*}"
        after="${out#*"$endmark"}"
        plain="$before $after"
        if (( nums == 1 )) && [[ "$before" =~ [[:alnum:]] ]] && ! is_episode_shaped "$plain"; then
            abs_locate "$plain"
            find_last_year "$after"
            if (( ! ABS_FOUND )) && [[ -z "$YEAR_MATCH" ]]; then
                out="$before - $num $after"
            else
                out="$plain"
            fi
        else
            out="$plain"
            while [[ "$out" == *"$mark"* ]]; do
                out="${out%%"$mark"*} ${out#*"$endmark"}"
            done
        fi
    fi
    printf '%s' "$out"
}

# Shared preprocessing for both parse_media_name and parse_episode_name,
# applied in this order:
#   1. promote_bracket_tokens reads the whole-content tokens out of "[...]"
#      groups (year, edition, episode); every other "[...]" group is dropped.
#   2. Episode tokens wrapped in "(...)" or "{...}" are unwrapped, and every
#      other "{...}" group is dropped, except Plex's own "{edition-X}".
#   3. A leading site-announcement prefix (e.g. "www.example.org    -    ")
#      is removed; it requires a domain-like token followed by
#      whitespace-hyphen-whitespace, so a legitimate title that starts with
#      a hyphenated phrase is untouched.
#   4. A release-version suffix on an episode number ("S01E01v3", " - 05v2",
#      " - 05 v2", "S01E01 v2") is dropped.
#   5. Whitespace is normalized: tabs and non-breaking spaces become spaces,
#      runs collapse to one space, and both ends are trimmed.
# Run once by the caller before branching on movie vs. episode, so the
# episode-detection check itself also sees the cleaned name, not just
# whichever parser runs after it.
strip_junk_prefixes() {
    local s="$1"
    s="$(promote_bracket_tokens "$s")"
    s="$(sed -E 's/[({][[:space:]]*([Ss][0-9]{1,2}[Ee][0-9]{1,3}(\.[0-9]{1,2})?)[[:space:]]*[)}]/ \1 /g' <<< "$s")"
    s="$(sed -E 's/([Ss][0-9]{1,2}[Ee][0-9]{1,3}(\.[0-9]{1,2})?)[ ._]?[Vv][0-9]{1,2}\b/\1/g; s/([ ._-]-[ ._-]*[0-9]{1,3})[ ._]?[Vv][0-9]{1,2}\b/\1/g' <<< "$s")"
    s="$(sed -E 's/\{edition-/\x03/g; s/\{[^}]*\}//g; s/\x03/{edition-/g' <<< "$s")"
    s="$(sed -E 's/^(www\.)?[A-Za-z0-9-]+\.[A-Za-z]{2,}[[:space:]]*-[[:space:]]*//' <<< "$s")"
    s="${s//$'\t'/ }"
    s="${s//$'\xc2\xa0'/ }"
    s="$(sed -E 's/ +/ /g; s/^[ _]+//; s/[ _]+$//' <<< "$s")"
    printf '%s\n' "$s"
}

# Converts a byte offset (as grep -b reports) into a character offset for
# bash substring expansion. In a UTF-8 locale ${s:0:N} counts characters,
# not bytes, so grep's byte offset used directly on a name with accented or
# other multi-byte characters before the match slices too far - for
# "Café Show (2016)" the title would end "(2" instead of "Café Show". The
# prefix is cut by bytes (LC_ALL=C in a subshell), then measured in the
# caller's locale. Offsets always land on an ASCII match start, so the cut
# never splits a character. Prints the character offset.
byte_to_char_offset() {
    local s="$1" bytes="$2" prefix
    prefix="$(LC_ALL=C; printf '%s' "${s:0:$bytes}")"
    printf '%s' "${#prefix}"
}

# Finds the LAST standalone 4-digit year (1900-2099) in a string: not
# immediately preceded or followed by another alphanumeric character, so
# "2160p" and "x265" never match. Sets YEAR_MATCH and YEAR_OFFSET (character
# offset within the input); both are empty when there is none. `|| true`
# keeps grep's exit 1 on no match from tripping set -e/pipefail. Shared by
# the movie parser, the episode parser and the bare-number episode check.
find_last_year() {
    local raw="$1"
    YEAR_MATCH=""; YEAR_OFFSET=""
    YEAR_MATCH="$(grep -oP '(?<![0-9A-Za-z])(19[0-9]{2}|20[0-9]{2})(?![0-9A-Za-z])' <<< "$raw" | tail -1)" || true
    [[ -z "$YEAR_MATCH" ]] && return
    local off
    off="$(grep -boP '(?<![0-9A-Za-z])'"$YEAR_MATCH"'(?![0-9A-Za-z])' <<< "$raw" | tail -1)" || true
    [[ -z "$off" ]] && { YEAR_MATCH=""; return; }
    YEAR_OFFSET="$(byte_to_char_offset "$raw" "${off%%:*}")"
}

# Cleans a title fragment: dots, underscores and slashes become spaces, runs
# of whitespace collapse, and leading/trailing whitespace and hyphens are
# trimmed. Slashes are replaced because titles become directory and file name
# components, where a literal "/" would be read as a path separator.
clean_fragment() {
    local s
    s="$(tr '._/' '   ' <<< "$1" | tr -s ' ')"
    sed -E 's/^[[:space:]-]+//; s/[[:space:]-]+$//' <<< "$s"
}

# Removes every complete (...) or [...] group, which drops encoder spec
# blocks like "(1080p x264 AAC BluRay EncoderName)" from a title. A lone
# "(" or ")" left by splitting at a year is untouched here; see
# parse_media_name.
strip_delimited_groups() {
    sed -E 's/\([^()]*\)//g; s/\[[^][]*\]//g' <<< "$1"
}

# Runs strip_delimited_groups then clean_fragment, the pairing used wherever a
# title fragment is finalized. TRIM_CHAR and TRIM_SIDE ("leading" or
# "trailing") optionally remove one character in between: the lone "(" or ")"
# left when a movie title is split right at an already-parenthesized year.
strip_and_clean() {
    local s="$1" trim_char="${2:-}" trim_side="${3:-}"
    s="$(strip_delimited_groups "$s")"
    case "$trim_side" in
        trailing) s="${s%$trim_char}" ;;
        leading)  s="${s#$trim_char}" ;;
    esac
    clean_fragment "$s"
}

# strip_and_clean for a title taken from a name that already has spaces
# ("Hero Vs. Villain!"): its periods are punctuation, not delimiters, so
# they are kept and only a trailing run of them is trimmed. A dot-delimited
# scene name still goes through strip_and_clean.
clean_spaced_title() {
    local s
    s="$(strip_delimited_groups "$1" | tr '_/' '  ' | tr -s ' ')"
    sed -E 's/^[[:space:]-]+//; s/[[:space:].-]+$//' <<< "$s"
}

# Words lowercased when they appear mid-title in Title Case.
SMALL_WORDS=" a an and but by for in nor of on or the to at "
CLAUSE_END='[:;.!?([–—-]$'

# Prints TITLE with every Title Case small word lowercased unless it is the
# first or last word, follows a clause break, or carries punctuation. All-caps
# and already-lowercase words are left alone, and nothing is ever capitalized.
# Sets nothing.
fix_small_word_case() {
    local s="$1" out="" w lw prev="" i n
    local -a words
    read -ra words <<< "$s"
    n=${#words[@]}
    for i in "${!words[@]}"; do
        w="${words[$i]}"; lw="${w,,}"
        if (( i > 0 && i < n - 1 )) && [[ "$w" =~ ^[[:alpha:]]+$ ]] \
            && [[ "$SMALL_WORDS" == *" $lw "* && "$w" == "${w^}" && "$w" != "$lw" && "${w:1}" == "${lw:1}" ]] \
            && [[ ! "$prev" =~ $CLAUSE_END ]]; then
            w="$lw"
        fi
        out+="${out:+ }$w"
        prev="${words[$i]}"
    done
    printf '%s' "$out"
}

# Recognized edition/cut markers, matched as freeform text anywhere in a name
# (the "{edition-X}" syntax is Plex's own and is not on a file before this
# script runs). Each entry is "<PCRE>::<label>", matched case-insensitively,
# one entry per label with every spelling of that marker folded into its
# pattern.
#   - Labels omit "Edition", "Cut" and "Version" ("Extended Cut" and
#     "Extended Edition" are both "Extended"), except possessive names, which
#     keep theirs: "Director's Cut", "Collector's Edition". A marker that can
#     be followed by one of those words swallows it as an optional suffix, or
#     the word would stay behind in the title.
#   - Several markers in a name are all kept, joined alphabetically
#     (case-insensitive) with Remastered last; a label found twice ("DC" and
#     "Director's Cut") is kept once.
#   - "[ ._-]" between words accepts spaces and scene-style dot, underscore
#     or hyphen separators.
#   - Ordinal anniversary editions ("25th Anniversary Edition") are handled
#     in check_anniversary_edition, since the number is reproduced in the
#     label.
#   - Entries are alphabetical by label, except "Ultimate Extended Edition",
#     which contains the "Extended" marker: extract_known_edition removes each
#     match before running the next entry, so it must come first or
#     "Extended" would claim part of it and "Ultimate" would be lost. Nothing
#     else is a fragment of another entry; check that before adding one.
# Known limitations: the bare words (Extended, Theatrical, DC) also match
# inside a related but distinct label with no entry of its own ("Extended
# Dance Mix"), which is recorded under the shorter label; and a title word
# that is one of these keywords ("Redux") is pulled into the edition.
EDITION_PATTERNS=(
    "ultimate[ ._-]extended(?:[ ._-](?:cut|edition))?::Ultimate Extended"   # pinned first, see above

    "anniversary[ ._-](?:edition|collection)::Anniversary"
    "assembly[ ._-]cut::Assembly"
    "collector'?s[ ._-]edition::Collector's Edition"
    "criterion(?:[ ._-](?:collection|edition))?::Criterion"
    "definitive[ ._-](?:cut|edition)::Definitive"
    "diamond[ ._-]edition::Diamond"
    "(?:director'?s[ ._-]cut|(?<![0-9A-Za-z])dc(?![0-9A-Za-z]))::Director's Cut"
    "extended(?:[ ._-](?:cut|edition|version))?::Extended"
    "final[ ._-]cut::Final"
    "international[ ._-](?:cut|edition|version)::International"
    "(?:open[ ._-]matte|(?<![0-9A-Za-z])imax(?![0-9A-Za-z]))(?:[ ._-](?:edition|version))?::Open Matte"
    "platinum[ ._-](?:edition|series)::Platinum"
    "redux(?:[ ._-](?:cut|edition|version))?::Redux"
    "remaster(?:ed)?(?:[ ._-](?:edition|version))?::Remastered"
    "special[ ._-]edition::Special"
    "theatrical(?:[ ._-](?:cut|edition|release|version))?::Theatrical"
    "ultimate[ ._-]edition::Ultimate"
    "uncensored(?:[ ._-](?:edition|version))?::Uncensored"
    "uncut(?:[ ._-](?:edition|version))?::Uncut"
    "unrated(?:[ ._-](?:cut|edition|version))?::Unrated"
)

# Matches an ordinal anniversary edition ("25th Anniversary Edition", "40th
# Anniversary Collector's Edition") and reproduces the ordinal in the label as
# "<N><suffix> Anniversary"; a trailing Edition/Collection word is removed
# with the match but not reproduced. Ordinals can't be enumerated as
# EDITION_PATTERNS entries, so this runs before the static list. Sets
# EDITION_LABEL (empty without a match) and EDITION_RAW.
check_anniversary_edition() {
    local raw="$1" match
    EDITION_LABEL=""
    match="$(grep -ioP '[0-9]+(?:st|nd|rd|th)[ ._-]anniversary(?:[ ._-](?:edition|collection))?' <<< "$raw" | head -1)" || true
    if [[ -n "$match" ]] && [[ "$match" =~ ^([0-9]+)(st|nd|rd|th) ]]; then
        EDITION_LABEL="${BASH_REMATCH[1]}${BASH_REMATCH[2]} Anniversary"
        raw="${raw/$match/}"
    fi
    EDITION_RAW="$raw"
}

# Joins edition labels (arguments) into one string: duplicates removed,
# sorted alphabetically case-insensitively (C locale, so the sort doesn't
# depend on the host's collation), with "Remastered" always last. Prints
# nothing for no arguments.
join_editions() {
    local label out="" remastered=0
    (( $# )) || return 0
    while IFS= read -r label; do
        [[ -z "$label" ]] && continue
        if [[ "${label,,}" == "remastered" ]]; then
            remastered=1
        else
            out="${out:+$out }$label"
        fi
    done < <(printf '%s\n' "$@" | LC_ALL=C sort -fu)
    (( remastered )) && out="${out:+$out }Remastered"
    printf '%s' "$out"
}

# Scans RAW for every recognized edition marker: an ordinal anniversary
# edition first, then each EDITION_PATTERNS entry in order. Each match is
# removed before the next entry runs, so a specific phrase claims its words,
# and every occurrence of a marker is removed, so a repeated marker leaves
# nothing behind. Matches are combined by join_editions. Sets EDITION_LABEL
# (empty if nothing matched) and EDITION_RAW (the input minus the matched
# text). Called before year detection or title stripping in both parsers, so
# a marker is found wherever it sits and never ends up in a title.
extract_known_edition() {
    local raw="$1" entry pattern label match
    local -a found=()

    check_anniversary_edition "$raw"
    [[ -n "$EDITION_LABEL" ]] && found+=("$EDITION_LABEL")
    raw="$EDITION_RAW"

    for entry in "${EDITION_PATTERNS[@]}"; do
        pattern="${entry%%::*}"
        label="${entry#*::}"
        # Strip every occurrence, not just the first: with one entry per
        # label, a name that repeats a marker ("Extended Cut ... Extended
        # Edition") must not leave the second one behind in the title.
        while :; do
            match="$(grep -ioP "$pattern" <<< "$raw" | head -1)" || true
            [[ -n "$match" ]] || break
            found+=("$label")
            raw="${raw/"$match"/}"
        done
    done

    EDITION_LABEL=""
    if (( ${#found[@]} )); then
        EDITION_LABEL="$(join_editions "${found[@]}")"
    fi
    EDITION_RAW="$raw"
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

    # An explicit "{edition-X}" tag wins and is kept as written; otherwise
    # freeform markers are matched (see EDITION_PATTERNS).
    if [[ "$raw" =~ \{edition-([^}]+)\} ]]; then
        PARSED_EDITION="${BASH_REMATCH[1]}"
        raw="${raw/${BASH_REMATCH[0]}/}"
    else
        extract_known_edition "$raw"
        PARSED_EDITION="$EDITION_LABEL"
        raw="$EDITION_RAW"
    fi

    # Year detection runs with groups intact, so a year inside an encoder spec
    # block ("Movie Name (2020 1080p x264)") is found. Non-year text inside
    # groups is discarded once the title is known.
    find_last_year "$raw"
    [[ -z "$YEAR_MATCH" ]] && return
    local year_match="$YEAR_MATCH" offset="$YEAR_OFFSET"

    local hyphens=0 title_part="${raw:0:$offset}"
    hyphen_delimited "$raw" && hyphens=1
    (( hyphens )) && title_part="${title_part//-/ }"
    title_part="$(strip_and_clean "$title_part" "(" trailing)"   # drop a wrapping "(" left by an already-parenthesized year

    if [[ -z "$title_part" ]]; then
        # Nothing usable before the year: take the title from the text after
        # it ("(2020) Movie Name"). Only reached when year-last came up
        # empty, so "Movie Title (2020)" always parses year-last.
        local after_offset=$(( offset + ${#year_match} ))
        title_part="${raw:$after_offset}"
        (( hyphens )) && title_part="${title_part//-/ }"
        title_part="$(strip_and_clean "$title_part" ")" leading)"
    fi

    [[ -z "$title_part" ]] && return

    PARSED_TITLE="$(fix_small_word_case "$title_part")"
    PARSED_YEAR="$year_match"
    PARSED_OK=1
}

# PCRE for a standalone SxxEyy token without its trailing boundary check
# (callers append what may follow it): S + 1-2 digit season, E + 1-3 digit
# episode, optionally a ".N" / ".NN" special-episode suffix ("S01E17.5"), not
# preceded by an alphanumeric character.
EPISODE_TOKEN_PATTERN='(?<![0-9A-Za-z])[Ss][0-9]{1,2}[Ee][0-9]{1,3}(?:\.[0-9]{1,2})?'

# Zero-pads a number to at least two digits, forcing base 10 so "08" and
# "09" aren't read as invalid octal. Prints the result.
pad2() { printf '%02d' "$((10#$1))"; }

# Returns 0 when NAME (a folder's basename) is a "Season NN" folder -
# "Season", an optional separator, then digits ("Season 1", "Season.02"),
# optionally followed by a hyphen and a descriptor ("Season 02 - Descriptor"),
# which is dropped. Sets SEASON_FOLDER_NUMBER to the digits, empty when it
# isn't one.
is_season_folder_name() {
    SEASON_FOLDER_NUMBER=""
    [[ "$1" =~ ^[Ss]eason[\ ._-]*([0-9]+)([\ ._]*-[\ ._-]*[^\ ._-].*)?$ ]] || return 1
    SEASON_FOLDER_NUMBER="${BASH_REMATCH[1]}"
}

# Returns 0 when DIR or a folder above it, up to but excluding the scanned
# root, is a "Season NN" folder; the nearest one wins. Sets
# SEASON_FOLDER_NUMBER (empty when there is none).
season_folder_above() {
    local d="$1"
    SEASON_FOLDER_NUMBER=""
    while [[ "$d" != "$TARGET_DIR" && "$d" != "/" && "$d" != "." ]]; do
        is_season_folder_name "$(basename "$d")" && return 0
        d="$(dirname "$d")"
    done
    return 1
}

# Detects whether an already-prefix-stripped name is TV-episode-shaped:
# looks for a standalone SxxEyy token (S, 1-2 digit season, E, 1-3 digit
# episode; bounded by non-alphanumeric the same way the movie parser
# bounds years, so "S03E01" matches but nothing inside a longer alnum run
# does). Checked BEFORE year-based movie parsing runs at all, not as a
# fallback after it - so a show whose title happens to be a bare year
# (e.g. a show titled "2000") is still routed to the episode parser, never
# misparsed as a movie. Multi-episode files (S01E01E02) are NOT recognized -
# deliberately, consistent with this script's "skip rather than guess"
# philosophy elsewhere: treated as NO_MATCH, not force-fit. Episode numbering
# without an SxxEyy token is handled one step earlier, by
# normalize_absolute_episode, which rewrites it into SxxEyy form first.
is_episode_shaped() {
    grep -qP "${EPISODE_TOKEN_PATTERN}(?![0-9A-Za-z])" <<< "$1"
}

# Detects an SxxEyy token immediately followed by a hyphen-joined range
# ("S01E01-E02"). The plain SxxEyy match above accepts it because "-" is a
# non-alphanumeric boundary, but it then sees only the first number and the
# remainder fails the episode-title anchor, so the file would be renamed to
# the wrong episode with its title dropped. These are NO_MATCH, consistent
# with multi-episode files (S01E01E02): the script can't know which number
# the file should take. A ".N" special ("S01E17.5") is part of the token and
# is supported.
is_unsupported_episode_numbering() {
    grep -qP "${EPISODE_TOKEN_PATTERN}-[Ee][0-9]{1,3}(?![0-9A-Za-z])" <<< "$1"
}

# PCRE for an inferred episode token: "Episode N" or "Ep N", optionally
# preceded by "Season N". Used only by abs_locate.
ABS_EP_PATTERN='(?<![0-9A-Za-z])(?:season[ ._-]*[0-9]{1,2}[ ._-]*)?(?:episode|ep)[ ._-]*[0-9]{1,3}(?![0-9A-Za-z])'

# Bare trailing episode number: "<title> - NN", then optionally any
# whitespace and "(...)" groups ("Title - 01 (BD 1080p)") - the "[...]"
# groups were already read or removed by strip_junk_prefixes (a "[01]" group
# arrives here as " - 01"), which leaves the space that preceded them.
# The number may carry a ".N" special suffix ("Title - 02.5").
# Captures: 1 = title, 2 = number, 3 = ".N" suffix or empty, 4 = the trailing
# text. Underscores may separate the groups ("Title_-_01_(720p)_(Group)").
ABS_BARE_PATTERN='^(.*[^ ._-])[ ._-]+-[ ._-]*([0-9]{1,3})(\.[0-9]{1,2})?(([[:space:]_]*[(][^()]*[)])*[[:space:]_]*)$'

# Numbered episode with a title after it: "<title> - NN - <episode title>".
# Both hyphens are required, so a number inside a title is not read as one.
# Captures: 1 = title, 2 = number, 3 = ".N" suffix or empty, 4 = episode title.
ABS_TITLED_PATTERN='^(.*[^ ._-])[ ._-]+-[ ._-]*([0-9]{1,3})(\.[0-9]{1,2})?[ ._]+-[ ._]+(.+)$'

# Delimiter-only trailing episode number, for a name with no whitespace at
# all: "<title><delim><NN>" where the delimiter is a dot, underscore or
# hyphen ("Show.Name.01", "Show_Name_01", "Show-Name-01"). Two or three digits
# only: a single digit is too often a sequel number, and four digits is a
# year. Trailing "(...)" groups may follow the number ("Show_Name_01_(720p)");
# a year in one marks a movie. Captures: 1 = title, 2 = number, 3 = the
# trailing groups.
ABS_DELIM_PATTERN='^([^[:space:]]*[A-Za-z][^[:space:]]*[^[:space:]._-])[._-]([0-9]{2,3})(([._-]?[(][^()]*[)])*)$'

# Locates an inferred episode token in NAME: "Episode N" / "Ep N"
# (optionally preceded by "Season N"), a trailing " - NN" that may be
# followed by "(...)" groups, " - NN - Episode Title", or, for a name with no
# whitespace, a trailing delimiter plus two or three digits. Sets ABS_FOUND
# (0/1), ABS_PRE (text before the token), ABS_REST (text after the token, for
# the "Episode N" form), ABS_TAIL (the trailing "(...)" groups, for the " - NN"
# form), ABS_EP (episode number, with its ".N" suffix for a special),
# ABS_FORM (the shape that matched: token, bare, titled or delim) and
# ABS_SEASON (empty when no "Season N" token is present). Siblings are matched
# on ABS_PRE and ABS_FORM alone, so episodes with different titles or tags
# still share a stem. Clobbers YEAR_MATCH and YEAR_OFFSET. Always returns 0,
# so it is safe to call as a bare statement under set -e.
abs_locate() {
    local name="$1" hit off match trailing
    ABS_FOUND=0; ABS_PRE=""; ABS_REST=""; ABS_TAIL=""; ABS_EP=""; ABS_SEASON=""; ABS_FORM=""
    hit="$(grep -boiP "$ABS_EP_PATTERN" <<< "$name" | head -1)" || true
    if [[ -n "$hit" ]]; then
        off="$(byte_to_char_offset "$name" "${hit%%:*}")"; match="${hit#*:}"
        [[ "$match" =~ ([0-9]{1,3})$ ]] || return 0
        ABS_EP="${BASH_REMATCH[1]}"
        if [[ "$match" =~ ^[Ss][Ee][Aa][Ss][Oo][Nn][\ ._-]*([0-9]{1,2}) ]]; then
            ABS_SEASON="${BASH_REMATCH[1]}"
        fi
        ABS_PRE="${name:0:$off}"
        ABS_REST="${name:$(( off + ${#match} ))}"
        # A year after the token marks a movie ("Title Episode 4 (1977)").
        find_last_year "$ABS_REST"
        if [[ -z "$YEAR_MATCH" ]]; then
            ABS_FORM="token"
            ABS_FOUND=1
        fi
    elif [[ "$name" =~ $ABS_BARE_PATTERN ]]; then
        ABS_PRE="${BASH_REMATCH[1]}"
        ABS_EP="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
        trailing="${BASH_REMATCH[4]}"
        # A year in the trailing group ("Title - 2 (2010)") marks a movie,
        # not an episode.
        find_last_year "$trailing"
        if [[ -z "$YEAR_MATCH" ]]; then
            [[ -n "$(tr -d '[:space:]_' <<< "$trailing")" ]] && ABS_TAIL="$trailing"
            ABS_FORM="bare"
            ABS_FOUND=1
        fi
    elif [[ "$name" =~ $ABS_TITLED_PATTERN ]]; then
        # The episode title is not carried over; only a year in it is checked,
        # since a year marks a movie ("Title - 2 - Return (2010)").
        ABS_PRE="${BASH_REMATCH[1]}"
        ABS_EP="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
        find_last_year "${BASH_REMATCH[4]}"
        if [[ -z "$YEAR_MATCH" ]]; then
            ABS_FORM="titled"
            ABS_FOUND=1
        fi
    elif [[ "$name" != *[[:space:]]* && "$name" =~ $ABS_DELIM_PATTERN ]]; then
        ABS_PRE="${BASH_REMATCH[1]}"
        ABS_EP="${BASH_REMATCH[2]}"
        # A year in a trailing "(...)" group marks a movie, as for " - NN".
        find_last_year "${BASH_REMATCH[3]}"
        if [[ -z "$YEAR_MATCH" ]]; then
            [[ "$ABS_PRE" != *[._]* ]] && ABS_PRE="${ABS_PRE//-/ }"
            ABS_FORM="delim"
            ABS_FOUND=1
        fi
    fi
    return 0
}

# Counts, per folder, the videos that carry an inferred episode token and
# share a stem (the name minus the token), into EPISODE_STEMS keyed
# "<dir>|<pre>|<rest>". A bare number alone is not evidence of a series - it
# is equally a sequel or part number in a movie title - so two or more videos
# with the same stem in one folder is what confirms it. Built once from the
# full file list BEFORE any rename, because each rename removes a sibling
# from the folder: counting live would stop confirming the last files of a
# series partway through the batch. Takes the NUL-delimited file list on
# stdin. A second count per episode number (key suffix "|ABS_EP") lets
# normalize_absolute_episode leave two files with one number alone: they are
# copies, not a series. Clobbers ABS_*.
declare -A EPISODE_STEMS=()
build_episode_stems() {
    local f base dir
    while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        [[ "${base##*.}" =~ ^(${VIDEO_EXTS})$ ]] || continue
        dir="$(dirname "$f")"
        base="${base%.*}"
        abs_locate "$(strip_junk_prefixes "$base")"
        (( ABS_FOUND )) || continue
        EPISODE_STEMS["$dir|$ABS_PRE|$ABS_FORM"]=$(( ${EPISODE_STEMS["$dir|$ABS_PRE|$ABS_FORM"]:-0} + 1 ))
        EPISODE_STEMS["$dir|$ABS_PRE|$ABS_FORM|$ABS_EP"]=$(( ${EPISODE_STEMS["$dir|$ABS_PRE|$ABS_FORM|$ABS_EP"]:-0} + 1 ))
    done
}

# Splits a season marker off the end of an inferred title: "Show S2",
# "Show Season 2" or "Show 2nd Season". Sets TITLE_BASE (the title without the
# marker) and TITLE_SEASON (the season number) and returns 0, or returns 1 and
# sets both empty when the title carries no marker or nothing would be left.
split_title_season() {
    local t="$1"
    TITLE_BASE=""; TITLE_SEASON=""
    if [[ "$t" =~ ^(.*[^\ ._-])[\ ._-]+([Ss]|[Ss]eason[\ ._-]*)([0-9]{1,2})$ ]]; then
        TITLE_BASE="${BASH_REMATCH[1]}"; TITLE_SEASON="${BASH_REMATCH[3]}"
    elif [[ "$t" =~ ^(.*[^\ ._-])[\ ._-]+([0-9]{1,2})(st|nd|rd|th)[\ ._-]+[Ss]eason$ ]]; then
        TITLE_BASE="${BASH_REMATCH[1]}"; TITLE_SEASON="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    return 0
}

# Rewrites an inferred-episode name into "Title SxxEyy<rest>" so the normal
# episode parser handles it, but only when EPISODE_STEMS (built by
# build_episode_stems) confirms a series. Season: "Season N" in the name,
# else a season marker ending the title ("Show S2", "Show Season 2", "Show
# 2nd Season"), else the nearest "Season NN" folder above the file, else 1.
# The sibling stem keeps the marker, so "Show S1 - 01" and "Show S2 - 01" in
# one folder are two series, not copies of one episode. When nothing
# precedes the token, the title is the show folder's name (the parent of a
# "Season NN" folder, otherwise the folder itself).
# Sets ABS_NAME; unchanged from the input when the name already has an
# SxxEyy token, carries no inferred token, or has no confirming siblings.
# Clobbers ABS_* and PARSED_*.
normalize_absolute_episode() {
    local name="$1" dir="$2"
    local pre rest trailing ep season show_dir ep_int ep_frac
    ABS_NAME="$name"
    is_episode_shaped "$name" && return 0
    abs_locate "$name"
    (( ABS_FOUND )) || return 0
    pre="$ABS_PRE"; rest="$ABS_REST"; trailing="$ABS_TAIL"; ep="$ABS_EP"; season="$ABS_SEASON"
    (( ${EPISODE_STEMS["$dir|$pre|$ABS_FORM"]:-0} >= 2 )) || return 0
    # Two files for the same episode number are copies, not a series; renaming
    # one would leave the other to be read as a movie on the next run.
    (( ${EPISODE_STEMS["$dir|$pre|$ABS_FORM|$ep"]:-0} < 2 )) || return 0
    if [[ -z "$season" ]] && split_title_season "$pre"; then
        pre="$TITLE_BASE"; season="$TITLE_SEASON"
    fi
    if [[ -z "$season" ]] && season_folder_above "$dir"; then
        season="$SEASON_FOLDER_NUMBER"
    fi
    [[ -z "$season" ]] && season=1
    if [[ -z "$(clean_fragment "$(strip_delimited_groups "$pre")")" ]]; then
        show_dir="$dir"
        is_season_folder_name "$(basename "$dir")" && show_dir="$(dirname "$dir")"
        parse_media_name "$(strip_junk_prefixes "$(basename "$show_dir")")"
        if (( PARSED_OK )); then
            pre="$PARSED_TITLE"
        else
            pre="$(basename "$show_dir")"
        fi
    fi
    ep_int="${ep%%.*}"; ep_frac="${ep#"$ep_int"}"
    ABS_NAME="$pre S$(pad2 "$season")E$(pad2 "$ep_int")${ep_frac}${rest}${trailing}"
}

# Core name parser for TV EPISODES. Sets PARSED_OK, PARSED_SERIES,
# PARSED_SEASON, PARSED_EPISODE, PARSED_EPTITLE, PARSED_EDITION and
# PARSED_YEAR from a cleaned name with no extension. Call only after
# is_episode_shaped has confirmed an SxxEyy token.
# The series title is everything before the token, cleaned like a movie
# title, minus a redundant year (Plex episode names never carry one; a guard
# below keeps a show titled with a year). Season and episode are zero-padded;
# the 10# prefix forces base 10 so "08" and "09" are not read as octal.
# The episode title is whatever follows a separator run containing a literal
# hyphen; without one, everything after the token is discarded as junk.
# SxxEyy gives no structural signal for where a title ends and release tags
# begin, so this is a heuristic (see the header's known limitation).
parse_episode_name() {
    local raw="$1"
    PARSED_OK=0; PARSED_SERIES=""; PARSED_SEASON=""; PARSED_EPISODE=""
    PARSED_EPTITLE=""; PARSED_EDITION=""; PARSED_YEAR=""

    # Edition markers on either side of SxxEyy ("Show Name Director's Cut
    # S01E01", "Show Name S01E01 - Uncut") are captured here; a literal
    # "{edition-X}" in the episode title is read further below.
    extract_known_edition "$raw"
    PARSED_EDITION="$EDITION_LABEL"
    raw="$EDITION_RAW"

    local match offset
    match="$(grep -oP "${EPISODE_TOKEN_PATTERN}(?![0-9A-Za-z])" <<< "$raw" | head -1)" || true
    [[ -z "$match" ]] && return

    offset="$(grep -boP '(?<![0-9A-Za-z])'"${match//./\\.}"'(?![0-9A-Za-z])' <<< "$raw" | head -1)" || true
    [[ -z "$offset" ]] && return
    offset="$(byte_to_char_offset "$raw" "${offset%%:*}")"

    [[ "$match" =~ ^[Ss]([0-9]{1,2})[Ee]([0-9]{1,3})(\.[0-9]{1,2})?$ ]] || return
    local season="${BASH_REMATCH[1]}" episode="${BASH_REMATCH[2]}" special="${BASH_REMATCH[3]}"

    local series_raw="${raw:0:$offset}"
    hyphen_delimited "$raw" && series_raw="${series_raw//-/ }"

    # Strip a redundant year from the series title ("Show Title (2019) S03E13"):
    # only the show folder carries the year. Discarded when nothing meaningful
    # would remain, which keeps a show titled with a year ("2000") intact.
    find_last_year "$series_raw"
    if [[ -n "$YEAR_MATCH" ]]; then
        local candidate="${series_raw:0:$YEAR_OFFSET}"
        candidate="${candidate%(}"
        if [[ -n "$(tr -d '[:space:]._-' <<< "$candidate")" ]]; then
            series_raw="$candidate"
            PARSED_YEAR="$YEAR_MATCH"   # kept so the show folder can be named "Series (YYYY)" when no folder carries the year
        fi
    fi

    local series_part
    series_part="$(strip_and_clean "$series_raw")"
    [[ -z "$series_part" ]] && return

    local rest_part="${raw:$(( offset + ${#match} ))}"
    if [[ "$rest_part" =~ ^[[:space:]._]*-[[:space:]._]*(.+)$ ]]; then
        local ep_title="${BASH_REMATCH[1]}"
        if [[ "$ep_title" =~ \{edition-([^}]+)\} ]]; then
            PARSED_EDITION="${BASH_REMATCH[1]}"
            ep_title="${ep_title/${BASH_REMATCH[0]}/}"
        fi
        if [[ "$raw" == *[[:space:]]* ]]; then
            PARSED_EPTITLE="$(fix_small_word_case "$(clean_spaced_title "$ep_title")")"
        else
            PARSED_EPTITLE="$(fix_small_word_case "$(strip_and_clean "$ep_title")")"
        fi
    fi

    PARSED_SERIES="$(fix_small_word_case "$series_part")"
    PARSED_SEASON="$(pad2 "$season")"
    PARSED_EPISODE="$(pad2 "$episode")${special}"
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
# and a fourth, SUB_LANG_CODE: the 2-letter code of a recognized language,
# also set when its modifier is unrecognized, "" otherwise.
extract_sub_lang_tag() {
    local name="$1"
    SUB_LANG_CODE=""
    SUB_LANG_TAG=""
    SUB_TAG_STRIPPED_NAME="$name"
    SUB_TAG_UNRECOGNIZED=""

    if [[ "$name" =~ ^(.*)\.([A-Za-z]{2,3})\.([A-Za-z]+)$ ]]; then
        local base="${BASH_REMATCH[1]}" raw_lang="${BASH_REMATCH[2]}" raw_mod="${BASH_REMATCH[3]}"
        local norm_lang norm_mod
        norm_lang="$(normalize_lang "$raw_lang")"
        norm_mod="$(normalize_modifier "$raw_mod")"
        SUB_LANG_CODE="$norm_lang"
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
            SUB_LANG_CODE="$norm_lang"
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
DELETED=0
DELETE_PREVIEWED=0
DELETE_STATE=""

# Log setup. The log is written directly to its final path: a rename pass is
# idempotent (already-correct names are left alone on a re-run), so an
# interrupted batch has no partial state worth keeping apart from the log.
[[ -z "$LOG_DIR" ]] && LOG_DIR="${OPERATIONAL_DIR}/Logs"
mkdir -p -- "$LOG_DIR"
LOG_FILE="$LOG_DIR/Rename_$(date '+%Y-%m-%d_%H%M').txt"
# Appends one timestamped line to LOG_FILE. Sets nothing.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Reports a file that was left untouched because no name could be derived
# for it: prints and logs the reason, and counts it. Centralized so every
# NO_MATCH outcome is recorded identically. Arguments: reason, file name.
report_no_match() {
    echo "NO MATCH ($1): $2"
    log "NO MATCH ($1): $2"
    NO_MATCH=$(( NO_MATCH + 1 ))
}

# Reports a file that was left untouched on purpose rather than failed: prints
# and logs the reason, and counts it. Arguments: reason, file name.
report_skip() {
    echo "SKIPPING ($1): $2"
    log "SKIPPED ($1): $2"
    SKIPPED=$(( SKIPPED + 1 ))
}

# Deletes a subtitle in an unsupported language (not in SUPPORTED_SUB_LANGS):
# it is removed instead of renamed. Checks the
# dry-run flag itself. A real run asks once, before the first deletion, for a
# typed "yes"; any other answer, or no input, leaves every such file in place
# for the rest of the run. Counts DELETED (DELETE_PREVIEWED in a dry run),
# SKIPPED when not confirmed and FAILED when rm fails, and queues the file's
# folder for pruning. Sets DELETE_STATE ("", "yes" or "no"). Argument: path.
delete_subtitle() {
    local file="$1" confirm=""
    echo "MATCH FOUND (Subtitle, unsupported language):"
    echo "  Current path:  $file"
    if (( DRY_RUN )); then
        echo "  [DRY RUN] Would delete: $file"
        log "PREVIEWED (delete): $file"
        DELETE_PREVIEWED=$(( DELETE_PREVIEWED + 1 ))
        echo "----------------------------------------------------------------"
        return 0
    fi
    if [[ -z "$DELETE_STATE" ]]; then
        read -r -u 8 -p "Subtitle files in unsupported languages are deleted, not renamed. Type 'yes' to allow deletions in this run: " confirm || true
        if [[ "$confirm" == "yes" ]]; then DELETE_STATE="yes"; else DELETE_STATE="no"; fi
    fi
    if [[ "$DELETE_STATE" != "yes" ]]; then
        echo "  [SKIPPED] deletion not confirmed."
        log "SKIPPED (deletion not confirmed): $file"
        SKIPPED=$(( SKIPPED + 1 ))
    elif rm -- "$file"; then
        echo "  [SUCCESS] Deleted."
        log "DELETED: $file"
        DELETED=$(( DELETED + 1 ))
        queue_prune "$(dirname -- "$file")" "$TARGET_DIR"
    else
        echo "  [FAILED] rm error" >&2
        log "FAILED (rm): $file"
        FAILED=$(( FAILED + 1 ))
    fi
    echo "----------------------------------------------------------------"
    return 0
}

# Rename executor shared by every call site: sets ATTEMPT_OK to 1 when the
# path was already right or the move succeeded or was previewed, and to 0 on a
# collision or failure. Handles the unchanged-path no-op,
# collision check, dry-run preview, mv and counters in one place. The no-op
# check compares full paths, since a target can share a basename with its
# source while moving to a different directory.
attempt_rename() {
    local old="$1" new="$2" label="$3"
    local old_base new_base
    old_base="$(basename "$old")"
    new_base="$(basename "$new")"

    ATTEMPT_OK=0
    [[ "$old" == "$new" ]] && { ATTEMPT_OK=1; return 0; }

    # The two collision outcomes below differ in message, log tag and the
    # path shown, so they stay separate rather than sharing a helper whose
    # signature would be longer than either block.
    if [[ -e "$new" ]]; then
        if [[ -d "$new" ]]; then
            # mv onto an existing directory nests the source inside it
            # (new/old/...) instead of replacing it, so this is never forced,
            # whatever -f says or the source type.
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
        ATTEMPT_OK=1
    else
        if mv -- "$old" "$new"; then
            ATTEMPT_OK=1
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

# Builds the canonical Plex-format movie name - "Title (Year)" or "Title
# (Year) {edition-X}" when an edition is present - used identically for
# both the file name (main loop) and the containing folder name (directory
# pass).
build_movie_name() {
    local title="$1" year="$2" edition="$3"
    if [[ -n "$edition" ]]; then
        echo "$title ($year) {edition-$edition}"
    else
        echo "$title ($year)"
    fi
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

# Tests whether DIR's canonical path is exactly the scanned target root, to
# decide whether a movie needs a new franchise wrapper (it sits in the root)
# or already has one (it sits anywhere else). Exit status: 0 = DIR is the
# root, 1 = DIR exists and is not the root, 2 = DIR could not be statted
# (removed or made inaccessible since the scan began). Callers handle 2 as a
# per-item failure and call this with `|| rc=$?`, never as a bare statement,
# which set -e would turn into an abort.
is_target_root() {
    local real
    real="$(cd "$1" 2>/dev/null && pwd)" || return 2
    [[ "$real" == "$TARGET_DIR_REAL" ]]
}

# Wraps is_target_root with the "can't stat it" handling every call site
# needs: prints/logs and counts a FAILED, the same way ensure_dir's own
# mkdir-failure path does, so that bookkeeping exists in exactly one place.
# Returns the same three-way status as is_target_root (0/1/2) - callers
# still branch on it themselves, but don't need their own copy of the
# failure handling.
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

# Counts the video files directly inside DIR (not recursive). Sets nothing;
# prints the count. Used to decide whether a folder name can stand in for a
# year-less file's own name: only a folder holding exactly one video can.
count_videos_in() {
    find "$1" -maxdepth 1 -type f -regextype posix-extended \
        -iregex ".*\.(${VIDEO_EXTS})$" | wc -l
}

# Reduces a title to lowercase alphanumerics, for comparing a folder's title
# with an episode's series title regardless of punctuation or spacing.
norm_title() { tr -cd '[:alnum:]' <<< "${1,,}"; }

# Returns 0 when one of BASE's own "(...)" groups is the series title, the
# alternate-title convention of release folders ("Native Title (Series Title)
# (Season 02)"). Such a folder holds one season of the series but is not the
# show folder: its files move to the series folder beside it.
folder_names_series() {
    local base="$1" series="$2" want group
    want="$(norm_title "$series")"
    [[ -n "$want" ]] || return 1
    while IFS= read -r group; do
        [[ "$(norm_title "$group")" == "$want" ]] && return 0
    done < <(strip_junk_prefixes "$base" | grep -oP '(?<=\()[^()]*(?=\))' || true)
    return 1
}

# Prints the first folder directly inside PARENT whose title matches SERIES
# (a "Series" or "Series (YYYY)" folder, never a "Season NN" folder), or
# nothing when there is none. Used when no year is known, so a new season
# joins the series folder that already exists instead of creating a second
# one beside it.
find_series_dir() {
    local parent="$1" series="$2" want dir base title
    want="$(norm_title "$series")"
    [[ -n "$want" ]] || return 0
    while IFS= read -r -d '' dir; do
        base="$(basename "$dir")"
        is_season_folder_name "$base" && continue
        parse_media_name "$(strip_junk_prefixes "$base")"
        if (( PARSED_OK )); then
            title="$PARSED_TITLE"
        else
            title="$(clean_fragment "$(strip_delimited_groups "$(strip_junk_prefixes "$base")")")"
        fi
        if [[ "$(norm_title "$title")" == "$want" ]]; then
            printf '%s' "$dir"
            return 0
        fi
    done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    return 0
}

# Returns 0 when any video under DIR is an episode: it carries an SxxEyy
# token or is a confirmed inferred episode (see normalize_absolute_episode).
# Clobbers ABS_* and PARSED_*.
folder_has_episodes() {
    local dir="$1" f base
    while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        normalize_absolute_episode "$(strip_junk_prefixes "${base%.*}")" "$(dirname "$f")"
        is_episode_shaped "$ABS_NAME" && return 0
    done < <(find "$dir" -type f -regextype posix-extended -iregex ".*\.(${VIDEO_EXTS})$" -print0 | sort -z)
    return 1
}

# Finds the show folder for a file in DIR: the outermost folder between the
# scanned root (excluded) and DIR (included) that is named "Title (YYYY)" and
# holds at least one episode. Sets SHOW_DIR and SHOW_TITLE, both empty when
# there is none. Answers are cached per folder in SHOW_FOLDER_TITLE, since
# every file in a show asks about the same few folders. Clobbers ABS_* and
# PARSED_*. Always returns 0.
declare -A SHOW_FOLDER_TITLE=()
find_show_folder() {
    local dir="$1" d base
    local -a chain=()
    SHOW_DIR=""; SHOW_TITLE=""
    d="$dir"
    while [[ "$d" != "$TARGET_DIR" && "$d" != "/" && "$d" != "." ]]; do
        chain+=("$d")
        d="$(dirname "$d")"
    done
    local i
    for (( i = ${#chain[@]} - 1; i >= 0; i-- )); do
        d="${chain[i]}"
        if [[ -z "${SHOW_FOLDER_TITLE[$d]+set}" ]]; then
            SHOW_FOLDER_TITLE["$d"]=""
            base="$(basename "$d")"
            if ! is_season_folder_name "$base"; then
                parse_media_name "$(strip_junk_prefixes "$base")"
                if (( PARSED_OK )) && [[ -n "$PARSED_YEAR" ]]; then
                    local title="$PARSED_TITLE"
                    folder_has_episodes "$d" && SHOW_FOLDER_TITLE["$d"]="$title"
                fi
            fi
        fi
        if [[ -n "${SHOW_FOLDER_TITLE[$d]}" ]]; then
            SHOW_DIR="$d"; SHOW_TITLE="${SHOW_FOLDER_TITLE[$d]}"
            return 0
        fi
    done
    return 0
}

# Cleans the name of a file under a show folder that has no episode number
# (an extra): spec groups are dropped except a year, and separators are
# cleaned as for an episode title. Prints the result, empty when nothing
# usable is left.
clean_extra_name() {
    local s="$1" mark=$'\x01' endmark=$'\x02'
    s="$(sed -E "s/\(((19|20)[0-9]{2})\)/${mark}\1${endmark}/g" <<< "$s")"
    if [[ "$s" == *[[:space:]]* ]]; then
        s="$(clean_spaced_title "$s")"
    else
        s="$(strip_and_clean "$s")"
    fi
    s="${s//$mark/(}"; s="${s//$endmark/)}"
    printf '%s' "$(fix_small_word_case "$s")"
}

# Reads the SxxEyy token from the nearest folder name between DIR (inclusive)
# and STOP (exclusive). Sets ANC_TOKEN to e.g. "S01E07", zero-padded to two
# digits, or "" when no folder in that range carries one. Always returns 0.
ancestor_episode_token() {
    local d="$1" stop="$2" base
    ANC_TOKEN=""
    while [[ "$d" != "$stop" && "$d" != "/" && "$d" != "." ]]; do
        base="$(basename -- "$d")"
        if [[ "$base" =~ (^|[^0-9A-Za-z])[Ss]([0-9]{1,2})[Ee]([0-9]{1,3})([^0-9A-Za-z]|$) ]]; then
            printf -v ANC_TOKEN 'S%02dE%02d' "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
            return 0
        fi
        d="$(dirname -- "$d")"
    done
    return 0
}

# Counts the lines of FILE that contain a square bracket, the mark of a
# closed-caption track's sound descriptions. Prints the count, 0 for an
# unreadable file. Sets nothing.
count_bracket_lines() {
    local n
    n="$(LC_ALL=C grep -a -c '[][]' -- "$1" 2>/dev/null)" || true
    printf '%s' "${n:-0}"
}

# Fills TRACK_RANK for every track subtitle in DIR, keyed by full path: the
# position (0, 1, ...) of the file among DIR's track subtitles of the same
# language and extension. Two tracks are told apart by content: the one with
# more bracketed lines (count_bracket_lines) is rank 1, the closed-caption
# track. Equal counts, or any other number of tracks, fall back to the
# byte-order sort of the file names. Run once per folder and extension before
# its first file moves, so a later file is still ranked against the files that
# were there at the start. Arguments: directory. Reads FILE_EXT_LOWER.
rank_track_subtitles() {
    local dir="$1" f sib lang group i n
    local -A members=()
    local -a list=()
    TRACK_RANKED["$dir|$FILE_EXT_LOWER"]=1
    while IFS= read -r -d '' f; do
        sib="$(strip_junk_prefixes "${f##*/}")"
        sib="${sib%.*}"
        [[ "$sib" =~ ^([0-9]{1,2}[\ ._-]+)?([A-Za-z]+)$ ]] || continue
        lang="$(normalize_lang "${BASH_REMATCH[2]}")"
        [[ -n "$lang" ]] || continue
        members["$lang"]+="${f}"$'\x1f'
    done < <(find "$dir" -maxdepth 1 -type f -iname "*.${FILE_EXT_LOWER}" -print0 | LC_ALL=C sort -z)
    for lang in "${!members[@]}"; do
        group="${members[$lang]}"
        list=()
        while [[ -n "$group" ]]; do
            list+=("${group%%$'\x1f'*}")
            group="${group#*$'\x1f'}"
        done
        for i in "${!list[@]}"; do TRACK_RANK["${list[$i]}"]="$i"; done
        if (( ${#list[@]} == 2 )); then
            n=$(( $(count_bracket_lines "${list[0]}") - $(count_bracket_lines "${list[1]}") ))
            if (( n > 0 )); then
                TRACK_RANK["${list[0]}"]=1; TRACK_RANK["${list[1]}"]=0
            fi
        fi
    done
    return 0
}

# Plans a subtitle named only "<track> <language>" (for example "2 English")
# that sits under a show folder: the episode comes from the nearest ancestor
# folder (ancestor_episode_token) and the language from lang_table.sh. The
# track number itself is ignored; the file's rank (rank_track_subtitles) sets
# the modifier: rank 0 is plain, rank 1 is cc, a third or later is skipped.
# Sets TRACK_STATUS to "none" (the name has another shape, or no ancestor
# carries an episode, so the file is handled as before), "ok" (SUB_LANG_TAG
# and TRACK_NAME are set) or "skip" (TRACK_REASON says why). Arguments:
# stripped name, directory. Reads FILE_PATH.
plan_track_subtitle() {
    local name="$1" dir="$2" word lang mod rank
    TRACK_STATUS="none"; TRACK_NAME=""; TRACK_REASON=""
    [[ "$name" =~ ^[0-9]{1,2}[\ ._-]+([A-Za-z]+)$ ]] || return 0
    word="${BASH_REMATCH[1]}"
    ancestor_episode_token "$dir" "$SHOW_DIR"
    [[ -n "$ANC_TOKEN" ]] || return 0
    lang="$(normalize_lang "$word")"
    if [[ -z "$lang" ]]; then
        TRACK_STATUS="skip"; TRACK_REASON="unrecognized subtitle language '${word}'"
        return 0
    fi
    [[ -n "${TRACK_RANKED[$dir|$FILE_EXT_LOWER]:-}" ]] || rank_track_subtitles "$dir"
    rank="${TRACK_RANK[$FILE_PATH]:-0}"
    case "$rank" in
        0) mod="" ;;
        1) mod=".cc" ;;
        *) TRACK_STATUS="skip"; TRACK_REASON="more than two '${word}' subtitle tracks for one episode"; return 0 ;;
    esac
    TRACK_STATUS="ok"; TRACK_NAME="$ANC_TOKEN"; SUB_LANG_TAG=".${lang}${mod}"
    return 0
}

# Finds the video a subtitle in DIR belongs to: the nearest folder from DIR up
# to the scanned root (excluded) that directly holds videos, when it holds
# exactly one. Sets COMPANION_VIDEO to its path, or "" when no such folder has
# videos or the nearest one has several. Always returns 0.
find_companion_video() {
    local d="$1"
    local -a vids
    COMPANION_VIDEO=""
    while [[ "$d" != "$TARGET_DIR" && "$d" != "/" && "$d" != "." ]]; do
        mapfile -d '' vids < <(find "$d" -maxdepth 1 -type f -regextype posix-extended \
            -iregex ".*\.(${VIDEO_EXTS})$" -print0)
        if (( ${#vids[@]} )); then
            (( ${#vids[@]} == 1 )) && COMPANION_VIDEO="${vids[0]}"
            return 0
        fi
        d="$(dirname -- "$d")"
    done
    return 0
}

# Returns 0 when NAME (a subtitle name without extension, junk stripped) is
# only a language: "English", "2 English" or "English.forced", the language
# being in lang_table.tsv. Sets TRACK_WORD (the language word), TRACK_LANG (its
# code) and TRACK_MOD (".cc", ".sdh" or ".forced" when the name carries one,
# else ""). Returns 1 and sets all three empty otherwise.
subtitle_is_language_name() {
    TRACK_WORD=""; TRACK_LANG=""; TRACK_MOD=""
    [[ "$1" =~ ^([0-9]{1,2}[\ ._-]+)?([A-Za-z]+)(\.(cc|sdh|forced))?$ ]] || return 1
    TRACK_LANG="$(normalize_lang "${BASH_REMATCH[2]}")"
    [[ -n "$TRACK_LANG" ]] || return 1
    TRACK_WORD="${BASH_REMATCH[2]}"
    [[ -n "${BASH_REMATCH[4]}" ]] && TRACK_MOD=".${BASH_REMATCH[4],,}"
    return 0
}

# Adds DIR and each folder above it, up to but excluding STOP, to PRUNE_DIRS,
# so the folders an episode was moved out of are removed once empty.
queue_prune() {
    local d="$1" stop="$2"
    while [[ "$d" != "$stop" && "$d" != "/" && "$d" != "." ]]; do
        PRUNE_DIRS["$d"]=1
        d="$(dirname "$d")"
    done
}

# Plans where an episode file belongs: <show folder>/Season XX/ (the rules are
# in the header's "Episode folder layout"). Sets EP_DEST_DIR (empty = rename in
# place), EP_TRACK_DIR (the show folder for the directory pass, or empty) and
# EP_SHOW_NAME (the "Series (YYYY)" name for a show folder whose own name has
# no year). Arguments: the file's directory, series title, zero-padded season,
# and the year from the file's own name (may be empty). With no show folder
# and no year, the new show folder is named without a year. Returns 2
# if a folder can't be statted, else 0. Clobbers PARSED_OK, PARSED_TITLE and
# PARSED_YEAR; plan_episode_destination below restores the episode fields.
_plan_episode_destination() {
    local fdir="$1" series="$2" season="$3" file_year="$4"
    local base parent show_dir="" container="" rc=0 ftitle
    EP_DEST_DIR=""; EP_TRACK_DIR=""; EP_SHOW_NAME=""
    base="$(basename "$fdir")"

    check_root "$fdir" || rc=$?
    [[ $rc -eq 2 ]] && return 2
    if [[ $rc -eq 0 ]]; then
        container="$fdir"
    elif is_season_folder_name "$base"; then
        parent="$(dirname "$fdir")"; rc=0
        check_root "$parent" || rc=$?
        [[ $rc -eq 2 ]] && return 2
        if [[ $rc -eq 0 ]]; then container="$parent"; else show_dir="$parent"; fi
    else
        parse_media_name "$(strip_junk_prefixes "$base")"
        if (( PARSED_OK )); then
            ftitle="$PARSED_TITLE"
        else
            ftitle="$(clean_fragment "$(strip_delimited_groups "$(strip_junk_prefixes "$base")")")"
        fi
        if [[ "$(norm_title "$ftitle")" == "$(norm_title "$series")" ]]; then
            show_dir="$fdir"
        elif folder_names_series "$base" "$series"; then
            container="$(dirname "$fdir")"
        else
            container="$fdir"
        fi
    fi

    if [[ -n "$show_dir" ]]; then
        parse_media_name "$(strip_junk_prefixes "$(basename "$show_dir")")"
        if (( ! PARSED_OK )) && [[ -n "$file_year" ]]; then
            EP_SHOW_NAME="$series ($file_year)"
        fi
        EP_DEST_DIR="${show_dir}/Season ${season}"
        EP_TRACK_DIR="$show_dir"
    else
        local series_dir=""
        [[ -z "$file_year" ]] && series_dir="$(find_series_dir "$container" "$series")"
        : "${series_dir:=${container}/${series}${file_year:+ (${file_year})}}"
        EP_DEST_DIR="${series_dir}/Season ${season}"
    fi
    return 0
}
# Calls _plan_episode_destination with the same arguments and return status,
# but restores PARSED_EDITION afterward, since the helper's folder-name
# parsing overwrites it and the caller still needs the episode's own
# edition. Sets the same EP_* outputs.
plan_episode_destination() {
    local saved_edition="$PARSED_EDITION" rc=0
    _plan_episode_destination "$@" || rc=$?
    PARSED_EDITION="$saved_edition"
    return $rc
}

# Removes DIR if it is empty and leaves it alone otherwise (rmdir only ever
# removes an empty folder). Never removes the scanned root. Checks the
# dry-run flag itself, so nothing is removed in dry-run. Always returns 0: a
# folder that still holds files is the expected, silent outcome, not a
# failure.
prune_empty_dir() {
    local dir="$1"
    (( DRY_RUN )) && return 0
    [[ -d "$dir" && ! "$dir" -ef "$TARGET_DIR_REAL" ]] || return 0
    if rmdir -- "$dir" 2>/dev/null; then
        echo "Removed empty folder: $dir"
        log "REMOVED (empty folder): $dir"
    fi
    return 0
}

echo "Starting Plex library scan (Videos & Subtitles)..."
(( DRY_RUN )) && echo "=== RUNNING IN DRY-RUN MODE (No changes will be made) ==="
(( RENAME_DIRS )) || echo "=== Files only (-F): no directories will be renamed, created, or moved ==="
echo "----------------------------------------------------------------"
log "Rename pass started: $TARGET_DIR"

# Prints every video and subtitle file under the target directory,
# NUL-delimited and sorted, so callers can read the complete list before
# any rename changes the tree.
list_media_files() { find "$TARGET_DIR" -type f -regextype posix-extended -iregex ".*\.(${ALL_EXTS})$" -print0 | sort -z; }
build_episode_stems < <(list_media_files)

declare -A SHOW_FALLBACK_NAME=()   # show folder -> "Series (YYYY)" to rename it to when its own name has no year but an episode's file name did
declare -A TRACK_RANK=()           # track subtitle path -> its rank among the folder's same-language track subtitles (rank_track_subtitles)
declare -A TRACK_RANKED=()         # "folder|extension" -> 1 once that folder has been ranked
declare -a DEFERRED_SUBS=()        # subtitles set aside to be named after their companion video
declare -A DEFERRED_VIDEO=()       # deferred subtitle path -> its companion video's path
declare -A DEFERRED_TAG=()         # deferred subtitle path -> its dot language tag, or ""
declare -A DEFERRED_STEM=()        # deferred subtitle path -> its name stem, junk stripped
declare -A FINAL_VIDEO_PATH=()     # video path -> its final path, recorded when its rename succeeded
declare -A PRUNE_DIRS=()           # folders an episode was moved out of; removed after the file loop if now empty
declare -A MATCHED_DIRS=()   # unique ancestor dirs of successfully-parsed movie/show files, for the directory pass. Value is "movie" or "show" - only "movie" entries are ever eligible for franchise-wrapper insertion.

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

    # Reset per-iteration state so a stale value from a previous iteration
    # can never leak into this one's decisions.
    IS_EPISODE=0; IS_EXTRA=0; EP_YEAR=""; EXTRA_NAME=""
    OWN_OK=0; DIR_OK=0; MOVIE_OK=0; USED_PARENT_FALLBACK=0; AMBIGUOUS_PARENT=0; UNSUPPORTED_EP=0
    ITEM_OK=0

    # 1. SUBTITLE LANGUAGE TAG (decoupled from title/year parsing - see
    #    extract_sub_lang_tag's own comment for why).
    SUB_LANG_TAG=""
    WORKING_NAME="$FILE_BASE"
    if (( IS_SUBTITLE )); then
        extract_sub_lang_tag "$FILE_BASE"
        # A recognized language outside SUPPORTED_SUB_LANGS is deleted, not renamed,
        # when the name outside the tag has a year or an episode token, so a
        # title that happens to end in a language code ("Dr.No") is never
        # taken for a tagged subtitle.
        if [[ -n "$SUB_LANG_CODE" ]] && ! is_supported_lang "$SUB_LANG_CODE"; then
            find_last_year "$SUB_TAG_STRIPPED_NAME"
            if [[ -n "$YEAR_MATCH" ]] || is_episode_shaped "$(strip_junk_prefixes "$SUB_TAG_STRIPPED_NAME")"; then
                delete_subtitle "$FILE_PATH"
            else
                report_skip "unsupported-language subtitle with no year or episode in its name; not renamed or deleted" "$FILE_NAME"
            fi
            continue
        fi
        if [[ -n "$SUB_TAG_UNRECOGNIZED" ]]; then
            SKIP_KIND="${SUB_TAG_UNRECOGNIZED%%:*}"
            [[ "$SKIP_KIND" == "lang" ]] && SKIP_KIND="language"
            report_skip "unrecognized subtitle ${SKIP_KIND} '${SUB_TAG_UNRECOGNIZED#*:}'" "$FILE_NAME"
            continue
        fi
        WORKING_NAME="$SUB_TAG_STRIPPED_NAME"
    fi

    # 2. STRIP SHARED JUNK (brackets, site-prefix), INFER EPISODE NUMBERING
    #    FROM SIBLINGS, THEN BRANCH: episode detection runs first and
    #    unconditionally, so a title containing a bare year is never
    #    misrouted into movie parsing (see is_episode_shaped's own comment).
    WORKING_NAME_STRIPPED="$(strip_junk_prefixes "$WORKING_NAME")"
    # A subtitle named only by an unsupported language ("3 Arabic", "French") is
    # deleted when the language word has three or more letters; a two-letter
    # name ("no", "it") is too often an ordinary word, so it is left as it is.
    if (( IS_SUBTITLE )) && [[ -z "$SUB_LANG_TAG" ]] \
        && subtitle_is_language_name "$WORKING_NAME_STRIPPED" && ! is_supported_lang "$TRACK_LANG"; then
        if (( ${#TRACK_WORD} >= 3 )); then
            delete_subtitle "$FILE_PATH"
        else
            report_skip "unsupported-language subtitle named by a two-letter code; not renamed or deleted" "$FILE_NAME"
        fi
        continue
    fi
    find_show_folder "$FILE_DIR"
    # A subtitle named only "<track> <language>" carries its episode in an
    # ancestor folder; plan_track_subtitle supplies the SxxEyy and the tag, and
    # the file then follows the ordinary episode path.
    TRACK_STATUS="none"
    if (( IS_SUBTITLE )) && [[ -z "$SUB_LANG_TAG" && -n "$SHOW_DIR" ]]; then
        plan_track_subtitle "$WORKING_NAME_STRIPPED" "$FILE_DIR"
        if [[ "$TRACK_STATUS" == "skip" ]]; then
            report_skip "$TRACK_REASON" "${FILE_DIR##*/}/$FILE_NAME"
            continue
        fi
        [[ "$TRACK_STATUS" == "ok" ]] && WORKING_NAME_STRIPPED="$TRACK_NAME"
    fi
    # A subtitle in a folder with no video, whose name is a language or a
    # language tag and carries no episode, belongs to the video nearest above
    # it. It is set aside and renamed after that video once the video's final
    # name is known (the deferred subtitle pass). Not with -F, which moves
    # nothing.
    if (( IS_SUBTITLE && RENAME_DIRS )) && [[ "$TRACK_STATUS" != "ok" ]] \
        && (( $(count_videos_in "$FILE_DIR") == 0 )) \
        && ! is_episode_shaped "$WORKING_NAME_STRIPPED"; then
        if [[ -n "$SUB_LANG_TAG" ]] || subtitle_is_language_name "$WORKING_NAME_STRIPPED"; then
            find_companion_video "$FILE_DIR"
            if [[ -n "$COMPANION_VIDEO" ]]; then
                DEFERRED_SUBS+=("$FILE_PATH")
                DEFERRED_VIDEO["$FILE_PATH"]="$COMPANION_VIDEO"
                DEFERRED_TAG["$FILE_PATH"]="$SUB_LANG_TAG"
                DEFERRED_STEM["$FILE_PATH"]="$WORKING_NAME_STRIPPED"
                continue
            fi
            if [[ -n "$SHOW_DIR" && -z "$SUB_LANG_TAG" ]]; then
                report_no_match "subtitle folder has no single video or episode to attach to" "${FILE_DIR##*/}/$FILE_NAME"
                continue
            fi
        fi
    fi
    normalize_absolute_episode "$WORKING_NAME_STRIPPED" "$FILE_DIR"
    WORKING_NAME_STRIPPED="$ABS_NAME"

    if is_unsupported_episode_numbering "$WORKING_NAME_STRIPPED"; then
        UNSUPPORTED_EP=1
        ITEM_OK=0
    elif is_episode_shaped "$WORKING_NAME_STRIPPED"; then
        IS_EPISODE=1
        parse_episode_name "$WORKING_NAME_STRIPPED"
        if [[ -n "$SHOW_DIR" ]]; then
            # The show folder names the series, whatever the file's own name
            # says; a name that starts at the SxxEyy token has no series part
            # of its own, so the folder's title is supplied.
            (( PARSED_OK )) || parse_episode_name "$SHOW_TITLE $WORKING_NAME_STRIPPED"
            (( PARSED_OK )) && PARSED_SERIES="$SHOW_TITLE"
        fi
        ITEM_OK=$PARSED_OK
        EP_YEAR="$PARSED_YEAR"
    elif [[ -n "$SHOW_DIR" ]]; then
        # Under a show folder, a file with no episode number is an extra,
        # unless it is numbered like an episode and only lacks the siblings
        # to confirm it, which stays unrenamed.
        abs_locate "$WORKING_NAME_STRIPPED"
        if (( ! ABS_FOUND )); then
            IS_EXTRA=1
            EXTRA_NAME="$(clean_extra_name "$WORKING_NAME_STRIPPED")"
            [[ -n "$EXTRA_NAME" ]] && ITEM_OK=1
        fi
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
            # The parent folder's name can only stand in for a file's own
            # name when the folder holds a single video; several videos
            # would all resolve to the same target name and collide.
            if (( $(count_videos_in "$FILE_DIR") > 1 )); then
                AMBIGUOUS_PARENT=1
                MOVIE_OK=0
            else
                FINAL_TITLE="$DIR_TITLE"; FINAL_YEAR="$DIR_YEAR"; FINAL_EDITION="$DIR_EDITION"
                MOVIE_OK=1
                USED_PARENT_FALLBACK=1
            fi
        else
            MOVIE_OK=0
        fi
        ITEM_OK=$MOVIE_OK
    fi

    if [[ $ITEM_OK -ne 1 ]]; then
        if (( UNSUPPORTED_EP )); then
            report_no_match "episode range or multi-episode number; not renamed" "$FILE_NAME"
        elif (( IS_EPISODE )); then
            report_no_match "episode-shaped but unparseable" "$FILE_NAME"
        elif (( IS_EXTRA )); then
            report_no_match "no usable name left after cleaning" "$FILE_NAME"
        elif [[ -n "$SHOW_DIR" ]]; then
            report_no_match "numbered like an episode but no matching siblings confirm it" "$FILE_NAME"
        elif (( AMBIGUOUS_PARENT )); then
            report_no_match "parent folder has multiple videos; its name can't name them all" "$FILE_NAME"
        else
            report_no_match "no valid year found in file name or parent folder" "$FILE_NAME"
        fi
        continue
    fi

    # A movie's own directory holds just that movie, but only when it's
    # itself movie-shaped (i.e. DIR_OK, computed above) - when it isn't, the
    # file instead relocates into a freshly created subfolder below, and
    # this plain (non-year) folder is deliberately left out of MATCHED_DIRS
    # so the directory pass never tries to rename it into a match for the
    # movie itself. An episode's show folder is tracked instead, once its
    # destination is planned below.
    if (( ! IS_EPISODE && DIR_OK )); then
        MATCHED_DIRS["$FILE_DIR"]="movie"
    fi

    # 3. REBUILD
    if (( IS_EPISODE )); then
        CLEAN_PLEX_NAME="$PARSED_SERIES - S${PARSED_SEASON}E${PARSED_EPISODE}"
        [[ -n "$PARSED_EPTITLE" ]] && CLEAN_PLEX_NAME="$CLEAN_PLEX_NAME - $PARSED_EPTITLE"
        [[ -n "$PARSED_EDITION" ]] && CLEAN_PLEX_NAME="$CLEAN_PLEX_NAME {edition-$PARSED_EDITION}"
    elif (( IS_EXTRA )); then
        CLEAN_PLEX_NAME="$EXTRA_NAME"
    else
        CLEAN_PLEX_NAME="$(build_movie_name "$FINAL_TITLE" "$FINAL_YEAR" "$FINAL_EDITION")"
    fi
    NEW_FILE_NAME="${CLEAN_PLEX_NAME}${SUB_LANG_TAG}.${FILE_EXT_LOWER}"

    # Destination directory. Movies whose immediate parent folder is NOT
    # movie-shaped (DIR_OK=0) relocate into a freshly created folder
    # instead of staying in place - everything else renames in place.
    # Gated on RENAME_DIRS (-F): with -F, nothing is ever created or
    # moved, only renamed in place.
    RESTRUCTURED=0
    if (( IS_EPISODE || IS_EXTRA )) && (( RENAME_DIRS )); then
        # Episodes go to <show folder>/Season XX/, extras to Season 00. Under
        # a show folder (find_show_folder) the folder is already known;
        # otherwise _plan_episode_destination finds or creates it.
        if [[ -n "$SHOW_DIR" ]]; then
            EP_TRACK_DIR="$SHOW_DIR"; EP_SHOW_NAME=""
            EP_DEST_DIR="${SHOW_DIR}/Season ${PARSED_SEASON:-00}"
            (( IS_EXTRA )) && EP_DEST_DIR="${SHOW_DIR}/Season 00"
        else
            PLAN_RC=0
            plan_episode_destination "$FILE_DIR" "$PARSED_SERIES" "$PARSED_SEASON" "$EP_YEAR" || PLAN_RC=$?
            [[ $PLAN_RC -eq 2 ]] && continue
        fi
        [[ -n "$EP_TRACK_DIR" ]] && MATCHED_DIRS["$EP_TRACK_DIR"]="show"
        [[ -n "$EP_TRACK_DIR" && -n "$EP_SHOW_NAME" ]] && SHOW_FALLBACK_NAME["$EP_TRACK_DIR"]="$EP_SHOW_NAME"
        if [[ -n "$EP_DEST_DIR" && "$EP_DEST_DIR" != "$FILE_DIR" ]]; then
            NEW_FILE_DIR="$EP_DEST_DIR"
            ensure_dir "$NEW_FILE_DIR" || continue
            RESTRUCTURED=1
            queue_prune "$FILE_DIR" "${SHOW_DIR:-$TARGET_DIR}"
        else
            NEW_FILE_DIR="$FILE_DIR"
        fi
        NEW_FILE_PATH="${NEW_FILE_DIR}/${NEW_FILE_NAME}"
    elif [[ $IS_EPISODE -eq 0 && $IS_EXTRA -eq 0 && $DIR_OK -eq 0 ]] && (( RENAME_DIRS )); then
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

    if [[ "$FILE_PATH" == "$NEW_FILE_PATH" ]]; then
        (( IS_SUBTITLE )) || FINAL_VIDEO_PATH["$FILE_PATH"]="$NEW_FILE_PATH"
        continue
    fi

    if (( IS_EPISODE || IS_EXTRA )); then
        if (( IS_EXTRA )); then
            echo "  Cached Data:   Extra: '$EXTRA_NAME' | Lang: '$SUB_LANG_TAG'"
        else
            echo "  Cached Data:   Series: '$PARSED_SERIES' | S${PARSED_SEASON}E${PARSED_EPISODE} | Title: '$PARSED_EPTITLE' | Edition: '$PARSED_EDITION' | Lang: '$SUB_LANG_TAG'"
        fi
        if (( RESTRUCTURED )); then
            echo "  Restructure:   moving into '${NEW_FILE_DIR#"$TARGET_DIR_REAL"/}/'"
            log "RESTRUCTURED: $FILE_NAME -> $NEW_FILE_DIR"
        fi
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
    (( IS_SUBTITLE || ! ATTEMPT_OK )) || FINAL_VIDEO_PATH["$FILE_PATH"]="$NEW_FILE_PATH"

done < <(list_media_files)

# Deferred subtitle pass: each set-aside subtitle takes its companion video's
# final name plus its language tag and moves beside it. A tag comes from the
# subtitle's own dot tag or its language name; a name with no modifier is told
# from a second track of the same language by rank_track_subtitles (first
# plain, second ".cc", a third is skipped). A companion whose rename did not
# succeed leaves its subtitle NO MATCH.
for FILE_PATH in "${DEFERRED_SUBS[@]}"; do
    FILE_NAME="$(basename "$FILE_PATH")"
    FILE_DIR="$(dirname "$FILE_PATH")"
    FILE_EXT_LOWER="$(tr 'A-Z' 'a-z' <<< "${FILE_NAME##*.}")"
    VIDEO_FINAL="${FINAL_VIDEO_PATH[${DEFERRED_VIDEO[$FILE_PATH]}]:-}"
    if [[ -z "$VIDEO_FINAL" ]]; then
        report_no_match "companion video was not renamed" "${FILE_DIR##*/}/$FILE_NAME"
        continue
    fi
    SUB_LANG_TAG="${DEFERRED_TAG[$FILE_PATH]}"
    if [[ -z "$SUB_LANG_TAG" ]]; then
        subtitle_is_language_name "${DEFERRED_STEM[$FILE_PATH]}" || continue
        if [[ -n "$TRACK_MOD" ]]; then
            SUB_LANG_TAG=".${TRACK_LANG}${TRACK_MOD}"
        else
            [[ -n "${TRACK_RANKED[$FILE_DIR|$FILE_EXT_LOWER]:-}" ]] || rank_track_subtitles "$FILE_DIR"
            case "${TRACK_RANK[$FILE_PATH]:-0}" in
                0) SUB_LANG_TAG=".${TRACK_LANG}" ;;
                1) SUB_LANG_TAG=".${TRACK_LANG}.cc" ;;
                *)
                    report_skip "more than two '${TRACK_WORD}' subtitle tracks for one video" "${FILE_DIR##*/}/$FILE_NAME"
                    continue
                    ;;
            esac
        fi
    fi
    NEW_FILE_PATH="${VIDEO_FINAL%.*}${SUB_LANG_TAG}.${FILE_EXT_LOWER}"
    queue_prune "$FILE_DIR" "$TARGET_DIR"
    attempt_rename "$FILE_PATH" "$NEW_FILE_PATH" "Subtitle"
done

# Prune pass: remove folders an episode was moved out of (e.g. "Season 1"
# after its files move to "Season 01") if that left them empty.
if (( RENAME_DIRS && ${#PRUNE_DIRS[@]} > 0 )); then
    # Reverse order lists a folder's subfolders before it, so a chain of
    # emptied folders is removed from the inside out.
    while IFS= read -r -d '' PRUNE_PATH; do
        prune_empty_dir "$PRUNE_PATH"
    done < <(printf '%s\0' "${!PRUNE_DIRS[@]}" | sort -rz)
fi

# Directory pass. Runs after all file renames, over the directories that are
# the title/year-shaped ancestor of a parsed file: a movie's own folder (when
# already movie-shaped; see MATCHED_DIRS in the main loop) or a show's root
# folder. "Season NN" folders are never touched. Names are parsed as
# movie/show-style (title + year), never episode-style, including year-first
# names.
if (( RENAME_DIRS )) && [[ ${#MATCHED_DIRS[@]} -gt 0 ]]; then
    echo ""
    echo "=== Directory pass ==="
    for DIR_PATH in "${!MATCHED_DIRS[@]}"; do
        DIR_TYPE="${MATCHED_DIRS[$DIR_PATH]}"

        # The scanned directory is never a rename target, even if a loose
        # year-less file's fallback put it in MATCHED_DIRS (a root named like
        # "Downloads (2020)"): renaming it mid-run would be far more
        # disruptive than leaving one derived name as-is.
        ROOT_CHECK=0
        check_root "$DIR_PATH" || ROOT_CHECK=$?
        [[ $ROOT_CHECK -eq 0 ]] && continue

        DIR_BASE="$(basename "$DIR_PATH")"
        DIR_PARENT="$(dirname "$DIR_PATH")"

        parse_media_name "$(strip_junk_prefixes "$DIR_BASE")"
        if [[ $PARSED_OK -eq 1 ]]; then
            NEW_DIR_NAME="$(build_movie_name "$PARSED_TITLE" "$PARSED_YEAR" "$PARSED_EDITION")"
        elif [[ "$DIR_TYPE" == "show" && -n "${SHOW_FALLBACK_NAME[$DIR_PATH]:-}" ]]; then
            # The folder's own name has no year, but an episode file's did.
            NEW_DIR_NAME="${SHOW_FALLBACK_NAME[$DIR_PATH]}"
            PARSED_TITLE="$NEW_DIR_NAME"
        else
            continue
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
echo "  Deleted:    $DELETED  (subtitles in unsupported languages)"
(( DRY_RUN )) && echo "  Would delete: $DELETE_PREVIEWED"
(( DRY_RUN )) && echo "  Previewed:  $PREVIEWED  (dry run: nothing written; re-run without -n to rename)"
echo "  Skipped:    $SKIPPED  (collisions or unrecognized language/modifier - review manually)"
echo "  No match:   $NO_MATCH  (no usable year found, or no confirmed series; left untouched)"
echo "  Failed:     $FAILED"
echo "------------------------------------------"
log "Batch complete: Renamed=$RENAMED Deleted=$DELETED DeletePreviewed=$DELETE_PREVIEWED Previewed=$PREVIEWED Skipped=$SKIPPED NoMatch=$NO_MATCH Failed=$FAILED"
echo "Log saved to: $LOG_FILE"

[[ $FAILED -eq 0 ]] || exit 1