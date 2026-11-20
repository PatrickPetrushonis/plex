#!/usr/bin/env bash
# media_release.sh: Move entries from the holding directory to the encoder's input
#             directory. This is the one deliberate step between a held
#             download and an encode.
#
# Usage:  ./media_release.sh -S <holding_dir> -D <input_dir> [OPTIONS] [-a | ITEM...]
#
# ITEM is Category/Entry: a category folder in <holding_dir> (the categories are
# listed in media_categories.sh) and the name of one entry inside it. A bare
# category name stands for every entry held in that category. Options go before
# the items. With no ITEM and no -a, the held entries are listed and nothing
# moves.
#
# Options:
#   -S DIR          Holding directory the entries come from (required)
#   -D DIR          Input directory the entries go to (required)
#   -a              Release every entry in every category folder
#   -n              Dry run: print the moves, move nothing, take no lock and
#                   write no log (default: off)
#   -O DIR          Operational directory: logs (OPDIR/Logs) and the lock file
#                   (OPDIR/.locks); real runs only.
#                   Default: this script's own directory
#   -h              Show this help
#
# Notes:
#   • Refuses to run as root: the folders and logs it creates must belong to
#     the user who owns the library
#   • Requires bash 4.0+, GNU find (-printf), flock, sha256sum and realpath, and
#     media_progress.sh alongside this script
#   • An entry keeps its category folder, which is created in <input_dir> when
#     missing, so media_encode.sh -r carries it through to the archive
#   • An entry sitting directly in <holding_dir>, outside a category folder, is
#     listed but not released: move it into a category folder first
#   • A target that already exists in <input_dir> is skipped and logged, never
#     overwritten or merged: mv would nest a directory inside an existing one
#   • On a terminal, a move that takes more than a second (a copy, when the two
#     directories are on different filesystems) shows a spinner with the elapsed
#     time. A run without a terminal prints none of it
#   • Safe while an encode runs: media_encode.sh lists its input files once at the
#     start, so a released entry waits for the next encode
#   • Only one run may target a given <input_dir> at a time; a second run exits
#     1 immediately
#   • Exits 1 when a move fails or the lock is held; skipped and unmatched
#     items do not change the exit status

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
require sha256sum
require sort
require realpath
find / -maxdepth 0 -printf '' &>/dev/null || {
    echo "ERROR: find must support -printf (GNU findutils)" >&2
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
RELEASE_ALL=0
SOURCE_DIR=""
DEST_DIR=""
OPERATIONAL_DIR=""

# Usage
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

# Arg parsing
while getopts ":S:D:O:anh" opt; do
    case $opt in
        S) SOURCE_DIR="${OPTARG%/}" ;;
        D) DEST_DIR="${OPTARG%/}" ;;
        O) OPERATIONAL_DIR="$OPTARG" ;;
        a) RELEASE_ALL=1 ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ -n "$SOURCE_DIR" && -n "$DEST_DIR" ]] || {
    echo "Usage: $0 -S <holding_dir> -D <input_dir> [OPTIONS] [-a | ITEM...]" >&2
    echo "  Run $0 -h for full help." >&2
    exit 1
}
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: Holding directory '$SOURCE_DIR' does not exist." >&2
    exit 1
fi
if (( RELEASE_ALL && $# > 0 )); then
    echo "ERROR: -a releases everything; do not also name items." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$OPERATIONAL_DIR" ]] && OPERATIONAL_DIR="$SCRIPT_DIR"

# Category names (media_categories.sh, alongside this script): the same list
# media_ingest.sh reads.
[[ -r "${SCRIPT_DIR}/media_categories.sh" ]] || {
    echo "ERROR: media_categories.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
# shellcheck source=./media_categories.sh
source "${SCRIPT_DIR}/media_categories.sh"
# Spinner, countdown and runtime helpers (media_progress.sh, alongside this script).
[[ -r "${SCRIPT_DIR}/media_progress.sh" ]] || {
    echo "ERROR: media_progress.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
# shellcheck source=./media_progress.sh
source "${SCRIPT_DIR}/media_progress.sh"

# Canonical paths, so the identity check below holds for any spelling of them.
SOURCE_REAL="$(realpath -- "$SOURCE_DIR")"
DEST_REAL="$(realpath -m -- "$DEST_DIR")"

# The two directories are never the same or nested in each other: a move would
# then target the directory it is reading from, or the reverse.
if [[ "$DEST_REAL" == "$SOURCE_REAL" || "$DEST_REAL" == "$SOURCE_REAL"/* || "$SOURCE_REAL" == "$DEST_REAL"/* ]]; then
    echo "ERROR: the holding and input directories are the same or nested in each other." >&2
    exit 1
fi

# Prints the releasable entries of the holding directory as Category/Entry, one
# per line, sorted. Only the folders named in media_categories.sh are read.
# Prints nothing when none is held.
list_held() {
    local category name
    for category in "${CATEGORIES[@]}"; do
        [[ -d "${SOURCE_DIR}/${category}" ]] || continue
        while IFS= read -r name; do
            printf '%s/%s\n' "$category" "$name"
        done < <(find "${SOURCE_DIR}/${category}" -mindepth 1 -maxdepth 1 -printf '%f\n')
    done | LC_ALL=C sort
}

# Prints the top-level names in the holding directory that are not category
# folders, one per line, sorted. These are not releasable until moved into one.
list_uncategorized() {
    local name
    while IFS= read -r name; do
        is_category "$name" || printf '%s\n' "$name"
    done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
}

# Listing mode: no item and no -a.
if (( ! RELEASE_ALL && $# == 0 )); then
    HELD_LIST="$(list_held)"
    UNCATEGORIZED_LIST="$(list_uncategorized)"
    if [[ -z "$HELD_LIST" && -z "$UNCATEGORIZED_LIST" ]]; then
        echo "Nothing is held in $SOURCE_DIR."
    fi
    if [[ -n "$HELD_LIST" ]]; then
        echo "Held in $SOURCE_DIR:"
        while IFS= read -r HELD_NAME; do echo "  $HELD_NAME"; done <<< "$HELD_LIST"
        echo "Name the entries (Category/Entry) to release, or pass -a for all of them."
    fi
    if [[ -n "$UNCATEGORIZED_LIST" ]]; then
        echo "Not in a category folder (move each into one before releasing):"
        while IFS= read -r HELD_NAME; do echo "  $HELD_NAME"; done <<< "$UNCATEGORIZED_LIST"
    fi
    exit 0
fi

LOCK_FILE=""

# Concurrency lock, on descriptor 7, scoped to the input directory. A dry run
# only reads: it takes no lock and creates no directory or file.
LOG_FILE="/dev/null"
if (( ! DRY_RUN )); then
    LOCK_DIR="${OPERATIONAL_DIR}/.locks"
    mkdir -p -- "$LOCK_DIR"
    LOCK_HASH="$(printf '%s' "$DEST_REAL" | sha256sum | cut -d' ' -f1)"
    LOCK_PATH="${LOCK_DIR}/release_${LOCK_HASH}.lock"
    exec 7>"$LOCK_PATH"
    if ! flock -n 7; then
        echo "ERROR: another release is already running against $DEST_DIR (lock: $LOCK_PATH)" >&2
        exit 1
    fi
    # Registered only after the lock is acquired, so a failed acquisition never
    # deletes another process's lock file, and before any step that could fail.
    LOCK_FILE="$LOCK_PATH"
    # Removes the lock file on any exit, including SIGINT and SIGTERM (SIGKILL
    # skips EXIT traps).
    trap 'rm -f -- "$LOCK_FILE" 2>/dev/null || true' EXIT

    mkdir -p -- "$DEST_DIR"
    LOG_DIR="${OPERATIONAL_DIR}/Logs"
    mkdir -p -- "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/Release_$(date '+%Y-%m-%d_%H%M').txt"
fi

# Appends one timestamped line to LOG_FILE. Sets nothing.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Counters
RELEASED=0
PREVIEWED=0
SKIPPED=0
NO_MATCH=0
FAILED=0

# Reports an item left in place on purpose: prints, logs and counts it.
# Arguments: reason, name.
report_skip() {
    echo "SKIPPING ($1): $2"
    log "SKIPPED ($1): $2"
    SKIPPED=$(( SKIPPED + 1 ))
}

# Reports a requested item that is not a releasable entry: prints, logs and
# counts it. Arguments: reason, name.
report_no_match() {
    echo "NO MATCH ($1): $2"
    log "NO MATCH ($1): $2"
    NO_MATCH=$(( NO_MATCH + 1 ))
}

# Moves one entry from its category folder in the holding directory to the same
# category folder in the input directory, checking the dry-run flag itself.
# Counts RELEASED, PREVIEWED, SKIPPED or FAILED. Sets nothing else. Argument:
# item, as Category/Entry.
release_entry() {
    local name="$1" src dest
    src="${SOURCE_DIR}/${name}"
    dest="${DEST_DIR}/${name}"
    if [[ -e "$dest" || -L "$dest" ]]; then
        if [[ -d "$dest" ]]; then
            report_skip "target directory already exists, merge manually" "$name"
        else
            report_skip "target already exists" "$name"
        fi
        return 0
    fi
    echo "RELEASE: $name"
    if (( DRY_RUN )); then
        echo "  [DRY RUN] Would move to: $dest"
        log "PREVIEWED: $src -> $dest"
        PREVIEWED=$(( PREVIEWED + 1 ))
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dest")" || {
        echo "  [FAILED] mkdir error" >&2
        log "FAILED (mkdir): $dest"
        FAILED=$(( FAILED + 1 ))
        return 0
    }
    # -T keeps mv from nesting the entry inside a directory that appeared at
    # the target after the check above; -n keeps it from overwriting a file that did.
    if progress_run "Moving $name" mv -nT -- "$src" "$dest" && [[ ! -e "$src" && -e "$dest" ]]; then
        echo "  [SUCCESS] Moved."
        log "RELEASED: $src -> $dest"
        RELEASED=$(( RELEASED + 1 ))
    else
        echo "  [FAILED] mv error" >&2
        log "FAILED (mv): $src -> $dest"
        FAILED=$(( FAILED + 1 ))
    fi
}

log "Release started: $SOURCE_DIR -> $DEST_DIR"

declare -a NAMES=()
if (( RELEASE_ALL )); then
    mapfile -t NAMES < <(list_held)
    while IFS= read -r NAME; do
        [[ -z "$NAME" ]] || report_no_match "not in a category folder; move it into one first" "$NAME"
    done < <(list_uncategorized)
else
    # An item that is just a category name stands for every entry held in it.
    for ITEM in "$@"; do
        if [[ "$ITEM" != */* ]] && is_category "$ITEM"; then
            COUNT_BEFORE=${#NAMES[@]}
            while IFS= read -r NAME; do
                [[ "$NAME" == "${ITEM}/"* ]] && NAMES+=("$NAME")
            done < <(list_held)
            (( ${#NAMES[@]} > COUNT_BEFORE )) || report_no_match "nothing held in this category" "$ITEM"
        else
            NAMES+=("$ITEM")
        fi
    done
fi

for NAME in ${NAMES[@]+"${NAMES[@]}"}; do
    # An item is Category/Entry: a listed category folder and one entry name.
    # Any other path would reach outside the holding directory, so it is
    # refused before any filesystem check.
    if [[ "$NAME" != */* ]]; then
        report_no_match "not a Category/Entry item; an entry outside a category folder must be moved into one first" "$NAME"
        continue
    fi
    ITEM_CATEGORY="${NAME%%/*}"
    ITEM_ENTRY="${NAME#*/}"
    if ! is_category "$ITEM_CATEGORY" || [[ -z "$ITEM_ENTRY" || "$ITEM_ENTRY" == */* || "$ITEM_ENTRY" == "." || "$ITEM_ENTRY" == ".." ]]; then
        report_no_match "not a Category/Entry item with a listed category" "$NAME"
        continue
    fi
    if [[ ! -e "${SOURCE_DIR}/${NAME}" && ! -L "${SOURCE_DIR}/${NAME}" ]]; then
        report_no_match "not held in $SOURCE_DIR" "$NAME"
        continue
    fi
    release_entry "$NAME"
done

# Summary
echo ""
echo "------------------------------------------"
echo " Release complete"
echo "  Released:   $RELEASED"
(( DRY_RUN )) && echo "  Previewed:  $PREVIEWED  (dry run: nothing moved; re-run without -n to release)"
echo "  Skipped:    $SKIPPED  (name already exists in $DEST_DIR - review manually)"
echo "  No match:   $NO_MATCH  (not held, or not a Category/Entry item)"
echo "  Failed:     $FAILED"
echo "  Runtime:    $(format_runtime "$SECONDS")"
echo "------------------------------------------"
log "Release complete: Released=$RELEASED Previewed=$PREVIEWED Skipped=$SKIPPED NoMatch=$NO_MATCH Failed=$FAILED Runtime=$(format_runtime "$SECONDS")"
(( DRY_RUN )) || echo "Log saved to: $LOG_FILE"
(( FAILED == 0 )) || exit 1
exit 0
