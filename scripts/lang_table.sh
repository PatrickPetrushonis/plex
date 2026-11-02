#!/usr/bin/env bash
# lang_table.sh: Loads lang_table.tsv (same directory as this file) into the
# associative arrays the plex scripts share, and defines canon_lang(). Source,
# don't run directly. Resolves the tsv relative to THIS file's location
# (not the sourcing script's), so it works regardless of caller cwd.
#
# Populates:
#   LANG_TABLE      code3 -> "code2:Label"
#   LANG_3TO2       code3 -> code2           (sidecar filename lookups)
#   LANG_LABEL_BASH code3 -> Label           (embedded/sidecar track titles)
#   LANG_ALIASES    any lowercase code (2-letter, 3-letter, or listed alias)
#                   or lowercase label -> code2
#                                            (rename_params.sh normalization)
#   LANG_CANON      any lowercase code3, code2, or listed alias -> primary
#                   code3. The "und" row contributes only its own code3: its
#                   code2 ("en") belongs to "eng".
#
# shellcheck disable=SC2034
# File-wide: every array here is written in this file and read by the scripts
# that source it; shellcheck cannot see across that boundary when checking
# this file standalone. LANG_TABLE has no reader by name and keeps the
# combined "code2:Label" form available to any consumer that wants it.

# Include guard: safe to source twice (e.g. a future single-entry-point
# script sourcing several consumers in one process).
[[ -n "${LANG_TABLE_LOADED:-}" ]] && return 0
LANG_TABLE_LOADED=1

LANG_TABLE_TSV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lang_table.tsv"

if [[ ! -f "$LANG_TABLE_TSV" ]]; then
    echo "ERROR: lang_table.tsv not found at $LANG_TABLE_TSV" >&2
    exit 1
fi

declare -A LANG_TABLE=()
declare -A LANG_3TO2=()
declare -A LANG_LABEL_BASH=()
declare -A LANG_ALIASES=()
declare -A LANG_CANON=()

# The "|| [[ -n ... ]]" keeps a final row that has no trailing newline (read
# returns non-zero for it), and the "%$'\r'" trims drop the carriage return of
# a CRLF file, which would otherwise stay in the last field.
while IFS=$'\t' read -r _code3 _code2 _label _aliases || [[ -n "$_code3" ]]; do
    _label="${_label%$'\r'}"; _aliases="${_aliases%$'\r'}"
    [[ -z "$_code3" || "$_code3" == \#* ]] && continue

    LANG_TABLE["$_code3"]="${_code2}:${_label}"
    LANG_3TO2["$_code3"]="$_code2"
    LANG_LABEL_BASH["$_code3"]="$_label"

    LANG_ALIASES["$_code3"]="$_code2"
    LANG_ALIASES["$_code2"]="$_code2"
    LANG_ALIASES["${_label,,}"]="$_code2"

    LANG_CANON["$_code3"]="$_code3"
    [[ "$_code3" != "und" ]] && LANG_CANON["$_code2"]="$_code3"

    if [[ "$_aliases" != "-" && -n "$_aliases" ]]; then
        IFS=',' read -ra _alias_list <<< "$_aliases"
        for _a in "${_alias_list[@]}"; do
            LANG_ALIASES["$_a"]="$_code2"
            LANG_CANON["$_a"]="$_code3"
        done
    fi
done < "$LANG_TABLE_TSV"
unset _code3 _code2 _label _aliases _alias_list _a

# Echoes the primary code3 for any code3, code2, or listed alias, so a file's
# own language tag (commonly a bibliographic code such as "fre") compares
# equal to a code typed for -l ("fra"). An untagged track ("und") resolves to
# "eng", matching the probe step's treatment of untagged tracks. A code absent
# from the table is echoed unchanged.
canon_lang() {
    local code="${1,,}"
    if [[ "$code" == "und" ]]; then
        echo "eng"
        return 0
    fi
    echo "${LANG_CANON[$code]:-$code}"
}