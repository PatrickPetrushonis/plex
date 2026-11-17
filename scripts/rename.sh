#!/usr/bin/env bash
# rename.sh: Rename movie AND TV episode video/subtitle files (and
#                  optionally their containing directories) into Plex naming
#                  convention. Handles both already-Plex-formatted names and
#                  raw scene-release names — see "Name parsing" below.
#
# Usage:  ./rename.sh [OPTIONS] <target_dir>
#
# Options:
#   -n              Dry run: print decisions, do not rename; takes no lock and
#                   writes no log (default: off)
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
#                   lock file (OPDIR/.locks), never <target_dir> itself; used
#                   by real runs only.
#                   Default: this script's own directory
#   -L DIR          Log directory, overriding OPDIR/Logs specifically
#   -h              Show this help
#
# Notes:
#   • Refuses to run as root: the folders and logs it creates must belong to
#     the user who owns the library
#   • Requires bash 4.0+, a grep with PCRE support (-P; GNU grep on
#     Ubuntu/Debian has this by default), and sha256sum
#   • Exits 1 when any rename, move or deletion fails; skipped and unmatched
#     files do not change the exit status
#   • Only one run may target a given <target_dir> at a time; a second run
#     against the same directory exits immediately instead of racing on
#     shared rename targets (see "Concurrency lock" below)
#   • Requires video_exts.sh, lang_table.sh and lang_table.tsv alongside this script.
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
#   The text after SxxEyy is the episode title, with or without a hyphen
#   between them ("S03E01 - Real Title", "S03E01.Real.Title"), cut at the
#   first release tag: a resolution, source, codec, audio, HDR or streaming
#   tag from RELEASE_TAG_PATTERN in rename_parse.sh, plus any upper-case
#   language codes right before it ("Real.Title.ITA.KOR.1080p.x265-GROUP"
#   gives "Real Title"). A name with a tag straight after SxxEyy has no title
#   ("S03E01.1080p.WEB-DL.x264-GROUP"). No structural signal separates a title
#   from release tags, so the cut is a vocabulary match. Known limitation: a
#   release group with no tag before it ("S03E01.Real.Title-GROUP") stays in
#   the title.
#   Spec blocks are stripped from series and episode titles as for movies.
#   A name that already has spaces keeps the periods in its episode title
#   ("Hero Vs. Villain!"), trimming only trailing ones; a dot-delimited
#   scene name converts its dots to spaces.
#   A ".N" suffix marks a special, recap or similar extra ("S01E17.5"); it is
#   kept as written: "Series - S01E17.5 - Title.ext". Multi-episode numbering
#   (S01E01E02, S01E01-E02) is NO_MATCH, not guessed at.
#   An "NxMM" token (1-2 digit season, "x" or "X", 2-3 digit episode, bounded
#   by non-alphanumerics: "1x01", "10x105") or an SxxEyy token split by one
#   space, dot or underscore ("S01 E01", "S01.E01") is rewritten to SxxEyy
#   first ("S01E01", "S10E105") and then parsed as above. Each names its
#   season and episode outright, so it needs no sibling files. A name that
#   already has an SxxEyy token is left alone, and a resolution ("1920x1080")
#   or a one-digit episode ("1x1") is not read as one.
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
#   A title after "Episode N" is kept as for SxxEyy ("Show Episode 01 Title
#   1080p" gives "Show - S01E01 - Title"); a title after " - NN - " is dropped.
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
require sed
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

# Language alias table (lang_table.sh, alongside this script).
[[ -r "${SCRIPT_DIR}/lang_table.sh" ]] || {
    echo "ERROR: lang_table.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
# shellcheck source=./lang_table.sh
source "${SCRIPT_DIR}/lang_table.sh"

# Video extensions (video_exts.sh, alongside this script).
[[ -r "${SCRIPT_DIR}/video_exts.sh" ]] || {
    echo "ERROR: video_exts.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
# shellcheck source=./video_exts.sh
source "${SCRIPT_DIR}/video_exts.sh"

# Name parsing (rename_parse.sh, alongside this script): the functions that turn
# a raw name into a Plex name. It reads LANG_ALIASES, SUPPORTED_SUB_LANGS and
# TARGET_DIR, all set before any of its functions run.
[[ -r "${SCRIPT_DIR}/rename_parse.sh" ]] || {
    echo "ERROR: rename_parse.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
# shellcheck source=./rename_parse.sh
source "${SCRIPT_DIR}/rename_parse.sh"

# Concurrency lock: only one run may target a given TARGET_DIR at a time. The
# lock file lives under OPERATIONAL_DIR, never inside TARGET_DIR, so a library
# holds no operational files. Its name is a hash of TARGET_DIR's canonical
# path, so any spelling of the same directory collides and different
# directories do not.
# A dry run only reads: it takes no lock and creates no directory or file.
if (( ! DRY_RUN )); then
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
fi

# Extensions
SUB_EXTS="srt|vtt|ass|idx|sub"
ALL_EXTS="${VIDEO_EXTS}|${SUB_EXTS}"

# Subtitle languages kept: space-separated 2-letter codes, each a code2 in
# lang_table.tsv. A subtitle in any other recognized language is deleted. To
# keep another language, add its code here (SUPPORTED_SUB_LANGS="en fr").
SUPPORTED_SUB_LANGS="en"


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
# A dry run writes no log, as in encode.sh: every log() call goes to
# /dev/null.
if (( DRY_RUN )); then
    LOG_FILE="/dev/null"
else
    [[ -z "$LOG_DIR" ]] && LOG_DIR="${OPERATIONAL_DIR}/Logs"
    mkdir -p -- "$LOG_DIR"
    LOG_FILE="$LOG_DIR/Rename_$(date '+%Y-%m-%d_%H%M').txt"
fi
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

# Prints the files under DIR whose extension is one of EXTS (a "|"-separated
# list such as VIDEO_EXTS), NUL-delimited and sorted, so callers can read the
# complete list before any rename changes the tree. MAXDEPTH, when given,
# limits the search ("1" is DIR's own files). Sets nothing.
list_ext_files() {
    local exts="$1" dir="$2" maxdepth="${3:-}"
    local -a depth=()
    [[ -z "$maxdepth" ]] || depth=(-maxdepth "$maxdepth")
    find "$dir" ${depth[@]+"${depth[@]}"} -type f -regextype posix-extended \
        -iregex ".*\.(${exts})$" -print0 | sort -z
}

# Counts the video files directly inside DIR (not recursive). Sets nothing;
# prints the count. Used to decide whether a folder name can stand in for a
# year-less file's own name: only a folder holding exactly one video can.
count_videos_in() {
    list_ext_files "$VIDEO_EXTS" "$1" 1 | tr -cd '\0' | wc -c
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
    done < <(list_ext_files "$VIDEO_EXTS" "$dir")
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

# Reads the episode token from the nearest folder name between DIR (inclusive)
# and STOP (exclusive), in any form normalize_episode_token accepts (SxxEyy,
# NxMM, a split "S01 E01"). Sets ANC_TOKEN to e.g. "S01E07", zero-padded to
# two digits, or "" when no folder in that range carries one. Clobbers
# EPISODE_TOKEN_NAME and PCRE_*. Always returns 0.
ancestor_episode_token() {
    local d="$1" stop="$2" base
    ANC_TOKEN=""
    while [[ "$d" != "$stop" && "$d" != "/" && "$d" != "." ]]; do
        base="$(basename -- "$d")"
        normalize_episode_token "$base"
        pcre_locate "${EPISODE_TOKEN_PATTERN}(?![0-9A-Za-z])" "$EPISODE_TOKEN_NAME"
        if [[ "$PCRE_MATCH" =~ ^[Ss]([0-9]{1,2})[Ee]([0-9]{1,3}) ]]; then
            printf -v ANC_TOKEN 'S%02dE%02d' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))"
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
        mapfile -d '' vids < <(list_ext_files "$VIDEO_EXTS" "$d" 1)
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
# NUL-delimited and sorted (see list_ext_files).
list_media_files() { list_ext_files "$ALL_EXTS" "$TARGET_DIR"; }
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
        # title that happens to end in a language code ("Some.Title.It") is never
        # taken for a tagged subtitle.
        if [[ -n "$SUB_LANG_CODE" ]] && ! is_supported_lang "$SUB_LANG_CODE"; then
            find_last_year "$SUB_TAG_STRIPPED_NAME"
            normalize_episode_token "$(strip_junk_prefixes "$SUB_TAG_STRIPPED_NAME")"
            if [[ -n "$YEAR_MATCH" ]] || is_episode_shaped "$EPISODE_TOKEN_NAME"; then
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
    # "1x01" and "S01 E01" name their season and episode outright, so both
    # become "S01E01" here, before any check below asks whether the name is an
    # episode.
    normalize_episode_token "$WORKING_NAME_STRIPPED"
    WORKING_NAME_STRIPPED="$EPISODE_TOKEN_NAME"
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
echo "  Skipped:    $SKIPPED  (collisions, unconfirmed deletions, unrecognized or surplus subtitle tracks - review manually)"
echo "  No match:   $NO_MATCH  (no usable year found, or no confirmed series; left untouched)"
echo "  Failed:     $FAILED"
echo "------------------------------------------"
log "Batch complete: Renamed=$RENAMED Deleted=$DELETED DeletePreviewed=$DELETE_PREVIEWED Previewed=$PREVIEWED Skipped=$SKIPPED NoMatch=$NO_MATCH Failed=$FAILED"
(( DRY_RUN )) || echo "Log saved to: $LOG_FILE"
(( FAILED == 0 )) || exit 1

[[ $FAILED -eq 0 ]] || exit 1