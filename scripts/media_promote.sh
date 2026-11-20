#!/usr/bin/env bash
# media_promote.sh: Move finished files from the NAS archive folder into the
#             library folders beside it, merging into the folders already there.
#
# Usage:  ./media_promote.sh -m <mount_point> [OPTIONS] <nas_archive_dir> <nas_library_dir>
#
# media_archive.sh copies each encoded file into <nas_archive_dir> under a
# hidden ".<name>.tmp" name and renames it into place only after the copy is
# verified, so a file with a normal name there is complete. This script moves
# those files into <nas_library_dir> with a rename inside one mounted share,
# never a copy, so the media server's library never holds a file that is still
# being written.
#
# Each top-level directory of <nas_archive_dir> is a category ("Series",
# "Movies") and must already exist in <nas_library_dir>; no category is ever
# created. Files under a category keep their relative path, and existing show
# and movie folders in the library are merged into at file level. A top-level
# entry that is not a category folder in the library (a loose file, or a title
# folder that was never placed in a category) stays in <nas_archive_dir> and is
# reported. A destination that already exists is never overwritten: the file
# stays in <nas_archive_dir> and is reported as a collision. Hidden names are
# skipped. Folders emptied by the moves are removed; the category folders stay.
#
# Options:
#   -m DIR          Mount point of the NAS share (required). The run ends
#                   before any work when DIR is not a mount point, so an
#                   unmounted share is never mistaken for an empty one
#   -n              Dry run: print the decisions, move nothing, take no lock
#                   and write no log (default: off)
#   -O DIR          Operational directory: logs (OPDIR/Logs) and the lock file
#                   (OPDIR/.locks); real runs only.
#                   Default: this script's own directory
#   -h              Show this help
#
# Notes:
#   • Refuses to run as root: the folders it creates in the library must belong
#     to the library's owner
#   • Requires bash 4.0+, find, flock, mountpoint, sha256sum, realpath and stat,
#     and media_progress.sh alongside this script
#   • Both directories must be under <mount_point> and on one filesystem; when
#     they are not, the run ends before any work, because a move between
#     filesystems copies the file and a partly copied file would be visible in
#     the library
#   • Only one run may target a given <nas_archive_dir> at a time; a second run
#     exits 1 immediately
#   • On a terminal, listing a category and removing its emptied folders show a
#     spinner with the elapsed time. A run without a terminal (a callback, cron)
#     prints none of it
#   • Safe while media_archive.sh runs: it never takes a file that still has a
#     hidden ".tmp" name. Neither script takes the other's lock
#
# Exit codes:
#   0  Nothing to do, or every file moved
#   1  A move failed, the lock is held, or bad usage
#   2  Something needs a person: a collision, a top-level entry that is not a
#      category folder in the library, or a loose file at the top level

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
require mountpoint
require sha256sum
require sort
require realpath
require stat

# The script creates folders in the library that its owner must be able to use;
# under sudo they would belong to root.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates folders and logs a normal user needs to own." >&2
    exit 1
fi

# Defaults
DRY_RUN=0
MOUNT_POINT=""
OPERATIONAL_DIR=""

# Usage
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

# Arg parsing
while getopts ":m:O:nh" opt; do
    case $opt in
        m) MOUNT_POINT="$OPTARG" ;;
        O) OPERATIONAL_DIR="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

if [[ $# -ne 2 || -z "$MOUNT_POINT" ]]; then
    echo "Usage: $0 -m <mount_point> [OPTIONS] <nas_archive_dir> <nas_library_dir>" >&2
    echo "  Run $0 -h for full help." >&2
    exit 1
fi

ARCHIVE_DIR="${1%/}"
LIBRARY_DIR="${2%/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$OPERATIONAL_DIR" ]] && OPERATIONAL_DIR="$SCRIPT_DIR"
# Spinner, countdown and runtime helpers (media_progress.sh, alongside this script).
[[ -r "${SCRIPT_DIR}/media_progress.sh" ]] || {
    echo "ERROR: media_progress.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
# shellcheck source=./media_progress.sh
source "${SCRIPT_DIR}/media_progress.sh"

MOUNT_REAL="$(realpath -- "$MOUNT_POINT")" || {
    echo "ERROR: mount point '$MOUNT_POINT' does not exist." >&2
    exit 1
}

# The share is checked before anything on it: an unmounted mount point is an
# empty local directory.
if ! mountpoint -q -- "$MOUNT_REAL"; then
    echo "ERROR: $MOUNT_REAL is not a mount point; is the NAS share mounted?" >&2
    exit 1
fi
if [[ ! -d "$ARCHIVE_DIR" ]]; then
    echo "ERROR: NAS archive directory '$ARCHIVE_DIR' does not exist on the mounted share." >&2
    exit 1
fi
if [[ ! -d "$LIBRARY_DIR" ]]; then
    echo "ERROR: NAS library directory '$LIBRARY_DIR' does not exist on the mounted share." >&2
    exit 1
fi
ARCHIVE_REAL="$(realpath -- "$ARCHIVE_DIR")"
LIBRARY_REAL="$(realpath -- "$LIBRARY_DIR")"
for dir in "$ARCHIVE_REAL" "$LIBRARY_REAL"; do
    case "$dir/" in
        "${MOUNT_REAL%/}/"*) ;;
        *)
            echo "ERROR: $dir is not under the mount point $MOUNT_REAL." >&2
            exit 1
            ;;
    esac
done

# The library is never the archive or inside it, or a move would target the
# directory it is reading from. The archive may sit inside the library.
if [[ "$LIBRARY_REAL" == "$ARCHIVE_REAL" || "$LIBRARY_REAL" == "$ARCHIVE_REAL"/* ]]; then
    echo "ERROR: the library directory is the archive directory or inside it." >&2
    exit 1
fi

# A move inside one filesystem is a rename; across filesystems it is a copy and
# delete, which would show a partly written file in the library.
if [[ "$(stat -c '%d' -- "$ARCHIVE_REAL")" != "$(stat -c '%d' -- "$LIBRARY_REAL")" ]]; then
    echo "ERROR: the archive and library directories are on different filesystems; a move would copy." >&2
    exit 1
fi

LOCK_FILE=""

# Removes the lock file on any exit.
# shellcheck disable=SC2317  # false positive: cleanup is invoked indirectly by the EXIT trap below
cleanup() {
    [[ -z "$LOCK_FILE" ]] || rm -f -- "$LOCK_FILE" 2>/dev/null || true
}

# Concurrency lock, on descriptor 7, scoped to the archive directory. A dry run
# only reads: it takes no lock and creates no directory or file.
LOG_FILE="/dev/null"
if (( ! DRY_RUN )); then
    LOCK_DIR="${OPERATIONAL_DIR}/.locks"
    mkdir -p -- "$LOCK_DIR"
    LOCK_HASH="$(printf '%s' "$ARCHIVE_REAL" | sha256sum | cut -d' ' -f1)"
    LOCK_PATH="${LOCK_DIR}/promote_${LOCK_HASH}.lock"
    exec 7>"$LOCK_PATH"
    if ! flock -n 7; then
        echo "ERROR: another promote run is already active against $ARCHIVE_DIR (lock: $LOCK_PATH)" >&2
        exit 1
    fi
    # Registered only after the lock is acquired, so a failed acquisition never
    # deletes another process's lock file.
    LOCK_FILE="$LOCK_PATH"
    trap cleanup EXIT

    LOG_DIR="${OPERATIONAL_DIR}/Logs"
    mkdir -p -- "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/Promote_$(date '+%Y-%m-%d_%H%M').txt"
fi

# Appends one timestamped line to LOG_FILE. Sets nothing.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Counters
MOVED=0
COLLIDED=0
NOT_CATEGORY=0
FAILED=0

# Reports a top-level entry left in the archive directory because it is not a
# category folder in the library: prints, logs and counts it. Arguments:
# reason, name.
report_held() {
    echo "HELD ($1): $2"
    log "HELD ($1): $2"
    NOT_CATEGORY=$(( NOT_CATEGORY + 1 ))
}

# Records a failed file: prints, logs and counts it. Arguments: reason,
# relative path. Always returns 0.
fail_file() {
    echo "  [FAILED] $1: $2" >&2
    log "FAILED ($1): $2"
    FAILED=$(( FAILED + 1 ))
    return 0
}

# Prints the files under one category folder, NUL-delimited and sorted,
# skipping names that start with a dot. Argument: category folder path.
list_category_files() {
    find "$1" -type f ! -name '.*' -print0 | sort -z
}

# Moves one file into the library, or reports why it stays: its destination
# exists. Checks the dry-run flag itself. Counts MOVED, COLLIDED or FAILED and
# always returns 0, so one bad file never ends the batch. Arguments: absolute
# source path, path relative to the archive directory.
promote_file() {
    local src="$1" rel="$2"
    local dest="${LIBRARY_REAL}/${rel}" src_size dest_size

    if [[ -e "$dest" || -L "$dest" ]]; then
        if [[ -d "$dest" ]]; then
            echo "COLLISION (a directory with this name exists in the library): $rel"
        else
            src_size="$(stat -c '%s' -- "$src" 2>/dev/null)" || src_size="unknown"
            dest_size="$(stat -c '%s' -- "$dest" 2>/dev/null)" || dest_size="unknown"
            if [[ "$dest_size" == "$src_size" ]]; then
                echo "COLLISION (same name and size already in the library; source kept): $rel"
            else
                echo "COLLISION (same name, different size in the library; source kept): $rel"
            fi
        fi
        log "COLLISION: $rel"
        COLLIDED=$(( COLLIDED + 1 ))
        return 0
    fi

    if (( DRY_RUN )); then
        echo "  [DRY RUN] Would move: $rel"
        MOVED=$(( MOVED + 1 ))
        return 0
    fi

    mkdir -p -- "$(dirname -- "$dest")" || { fail_file "mkdir" "$rel"; return 0; }

    # mv -n exits 0 without moving when the destination appeared in the
    # meantime, so a source that is still there is the failure signal.
    mv -n -- "$src" "$dest" || { fail_file "move" "$rel"; return 0; }
    if [[ -e "$src" ]]; then
        fail_file "destination appeared during the move; source kept" "$rel"
        return 0
    fi
    echo "MOVED: $rel"
    log "MOVED: $rel"
    MOVED=$(( MOVED + 1 ))
    return 0
}

echo "Starting promote: $ARCHIVE_REAL -> $LIBRARY_REAL"
echo "----------------------------------------------------------------"
log "Promote started: $ARCHIVE_REAL -> $LIBRARY_REAL"

while IFS= read -r -d '' ENTRY; do
    CATEGORY="$(basename -- "$ENTRY")"
    [[ "$CATEGORY" == .* ]] && continue

    if [[ ! -d "$ENTRY" || -L "$ENTRY" ]]; then
        report_held "loose file at the top level, not a category folder" "$CATEGORY"
        continue
    fi
    if [[ ! -d "${LIBRARY_REAL}/${CATEGORY}" ]]; then
        report_held "not a category folder in the library; none is created" "$CATEGORY"
        continue
    fi

    echo "Category: $CATEGORY"
    CATEGORY_FILES=()
    while IFS= read -r -d '' FILE; do
        CATEGORY_FILES+=("$FILE")
    done < <(progress_run "Listing $CATEGORY" list_category_files "$ENTRY")
    for FILE in ${CATEGORY_FILES[@]+"${CATEGORY_FILES[@]}"}; do
        promote_file "$FILE" "${FILE#"$ARCHIVE_REAL"/}"
    done

    # Folders emptied by the moves are removed innermost first. The category
    # folder itself stays.
    if (( ! DRY_RUN )); then
        progress_run "Removing empty folders under $CATEGORY" find "$ENTRY" -mindepth 1 -type d -empty -delete \
            || log "WARNING: could not remove every empty folder under $CATEGORY"
    fi
done < <(find "$ARCHIVE_REAL" -mindepth 1 -maxdepth 1 -print0 | sort -z)

# Summary
echo ""
echo "------------------------------------------"
echo " Promote complete"
if (( DRY_RUN )); then
    echo "  Would move: $MOVED  (dry run: nothing moved; re-run without -n to promote)"
else
    echo "  Moved:      $MOVED"
fi
echo "  Collisions: $COLLIDED  (already in the library; source kept - review manually)"
echo "  Held:       $NOT_CATEGORY  (not a category folder in the library; left in $ARCHIVE_DIR)"
echo "  Failed:     $FAILED"
echo "  Runtime:    $(format_runtime "$SECONDS")"
echo "------------------------------------------"
log "Promote complete: Moved=$MOVED Collisions=$COLLIDED Held=$NOT_CATEGORY Failed=$FAILED Runtime=$(format_runtime "$SECONDS")"
(( DRY_RUN )) || echo "Log saved to: $LOG_FILE"

(( FAILED == 0 )) || exit 1
(( COLLIDED + NOT_CATEGORY == 0 )) || exit 2
exit 0
