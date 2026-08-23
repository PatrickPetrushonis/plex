#!/usr/bin/env bash
# lang_table.sh: Loads video-encoder/scripts/lang_table.tsv into the
# associative arrays encoder_params.sh and rename_plex.sh both need. Source,
# don't run directly. Resolves the tsv relative to THIS file's location
# (not the sourcing script's), so it works regardless of caller cwd.
#
# Populates:
#   LANG_TABLE      code3 -> "code2:Label"   (encoder_params.sh's own format)
#   LANG_3TO2       code3 -> code2           (sidecar filename lookups)
#   LANG_LABEL_BASH code3 -> Label           (embedded/sidecar track titles)
#   LANG_ALIASES    any lowercase code (2-letter, 3-letter, or listed alias)
#                   -> code2                 (rename_plex.sh normalization)
#
# shellcheck disable=SC2034
# File-wide: every array here is written in this file and read only by
# encoder_params.sh and rename_plex.sh, which source this file — shellcheck
# can't see across that boundary when checking this file standalone (-x/
# follow-sources only traces what a file itself sources, not who sources it
# back). LANG_TABLE specifically is the one exception actually unread by
# name anywhere, kept intentionally as the pre-centralization "code2:Label"
# format for any future consumer that wants the combined form.

# Include guard: safe to source twice (e.g. a future single-entry-point
# script sourcing both encoder_params.sh and rename_plex.sh in one process).
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

while IFS=$'\t' read -r _code3 _code2 _label _aliases; do
    [[ -z "$_code3" || "$_code3" == \#* ]] && continue

    LANG_TABLE["$_code3"]="${_code2}:${_label}"
    LANG_3TO2["$_code3"]="$_code2"
    LANG_LABEL_BASH["$_code3"]="$_label"

    LANG_ALIASES["$_code3"]="$_code2"
    LANG_ALIASES["$_code2"]="$_code2"
    if [[ "$_aliases" != "-" && -n "$_aliases" ]]; then
        IFS=',' read -ra _alias_list <<< "$_aliases"
        for _a in "${_alias_list[@]}"; do
            LANG_ALIASES["$_a"]="$_code2"
        done
    fi
done < "$LANG_TABLE_TSV"
unset _code3 _code2 _label _aliases _alias_list _a