#!/usr/bin/env bash
# rename_parse.sh: Name parsing for rename.sh: turns a raw file or folder name
# into a Plex-convention movie or episode name, and reads language, modifier and
# edition tags. The functions work on their arguments and report through the
# globals documented above each one; none reads or writes the filesystem.
#
# Sourced by rename.sh. The caller provides, before calling into this file:
#   LANG_ALIASES         assoc array from lang_table.sh, read by normalize_lang()
#   SUPPORTED_SUB_LANGS  space-separated 2-letter codes, read by is_supported_lang()
#   TARGET_DIR           the directory being processed, read by season_folder_above()
#
# Not intended to be run standalone.
#
# shellcheck disable=SC2034
# File-wide: the PARSED_* results and the other globals set here are read by
# rename.sh; shellcheck cannot see across that boundary standalone.

# Include guard: safe to source twice.
[[ -n "${RENAME_PARSE_LOADED:-}" ]] && return 0
RENAME_PARSE_LOADED=1

# Prints the canonical language code for a raw subtitle language tag, or
# nothing when the tag isn't in LANG_ALIASES (lang_table.sh).
normalize_lang() {
    local raw="${1,,}"
    echo "${LANG_ALIASES[$raw]:-}"
}

# Returns 0 when CODE (a 2-letter language code) is in SUPPORTED_SUB_LANGS.
is_supported_lang() { [[ " $SUPPORTED_SUB_LANGS " == *" $1 "* ]]; }

# Only cc, sdh, and forced are meaningful to encode.sh's sidecar
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
# basename). See "Name parsing" in rename.sh's header comment for the heuristic.
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
# begin, so this is a heuristic (see the hyphen-delimited title limitation in
# rename.sh's header comment).
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
