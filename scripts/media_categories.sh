#!/usr/bin/env bash
# media_categories.sh: The category folders the holding and input directories
# are sorted into. Sourced by media_ingest.sh and media_release.sh; not run
# directly.
#
# "Anime" is shorthand for animation of any origin; the other four are live
# action.
#
# shellcheck disable=SC2034  # CATEGORIES is read by the scripts that source this file
CATEGORIES=(
    "Anime - Movies"
    "Anime - Series"
    "Anime - Series Movies"
    "Anime - Shorts"
    "Movies"
    "Series"
    "Series Movies"
    "Shorts"
)

# Returns 0 when NAME is one of CATEGORIES, 1 otherwise. Argument: name.
is_category() {
    local category
    for category in "${CATEGORIES[@]}"; do
        [[ "$category" == "$1" ]] && return 0
    done
    return 1
}
