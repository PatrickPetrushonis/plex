#!/usr/bin/env bash
# media_archive.sh: Move encoded files from the local archive directory to the NAS
#             archive directory, merging into the folders already there.
#
# Usage:  ./media_archive.sh -m <mount_point> [OPTIONS] <source_dir> <nas_archive_dir>
#
# Each top-level directory of <source_dir> is a category ("Series", "Movies")
# and must already exist in <nas_archive_dir>; no category is ever created.
# Files under a category keep their relative path, and existing show and movie
# folders on the NAS are merged into at file level. A top-level entry that is
# not a category folder on the NAS (a loose file, or a title folder that was
# never placed in a category) stays in <source_dir> and is reported.
#
# Per file: copy to a hidden ".<name>.tmp" beside the destination, verify the
# size (and the contents, unless -s), confirm the source did not change during
# the copy, rename into place with mv -n, then delete the source. A destination
# that already exists is never overwritten: the file stays in <source_dir> and
# is reported as a collision.
#
# Options:
#   -m DIR          Mount point of the NAS share (required). The run ends
#                   before any work when DIR is not a mount point, so an
#                   unmounted share is never mistaken for an empty one
#   -w SECONDS      A file is moved only when its modification time is at
#                   least this old; 0 disables the check (default: 60). A file
#                   that media_encode.sh -M is still copying into <source_dir> has a
#                   recent modification time
#   -s              Verify by size only; the default also compares contents
#                   with cmp before the source is deleted (default: off)
#   -n              Dry run: print the decisions, copy and delete nothing,
#                   take no lock and write no log (default: off)
#   -O DIR          Operational directory: logs (OPDIR/Logs) and the lock file
#                   (OPDIR/.locks); real runs only.
#                   Default: this script's own directory
#   -h              Show this help
#
# Notes:
#   • Refuses to run as root: the folders it creates on the NAS must belong to
#     the library's owner
#   • Requires bash 4.0+, flock, mountpoint, sha256sum, realpath and cmp, and
#     media_progress.sh alongside this script
#   • Only one run may target a given <source_dir> at a time; a second run
#     exits 1 immediately
#   • Safe while an encode runs: media_encode.sh -M copies into <source_dir>, and a
#     file still being written is skipped by the -w window. Neither script
#     takes the other's lock
#   • A source file whose delete failed after a verified copy is reported as a
#     collision (same size) by the next run, and never copied again
#   • A file whose name the share rejects fails the copy, stays in <source_dir>
#     and is reported again by every run
#   • On a terminal, listing a category, and the copy and comparison of each file, show a
#     spinner with the elapsed time and the file's place in its category. A run without a terminal
#     (a callback, cron) prints none of it
#
# Exit codes:
#   0  Nothing to do, files still inside the -w window, or every file moved
#   1  A copy, verification or delete failed, the lock is held, or bad usage
#   2  Something needs a person: a collision, a top-level entry that is not a
#      category folder on the NAS, or a loose file at the top level

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
require cmp

# The script creates folders on the NAS the library's owner must be able to use;
# under sudo they would belong to root.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates folders and logs a normal user needs to own." >&2
    exit 1
fi

# Defaults
DRY_RUN=0
VERIFY_CONTENT=1
SETTLE_SECONDS=60
MOUNT_POINT=""
OPERATIONAL_DIR=""

# Usage
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

# Arg parsing
while getopts ":m:w:O:snh" opt; do
    case $opt in
        m) MOUNT_POINT="$OPTARG" ;;
        w) SETTLE_SECONDS="$OPTARG" ;;
        O) OPERATIONAL_DIR="$OPTARG" ;;
        s) VERIFY_CONTENT=0 ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

if [[ $# -ne 2 || -z "$MOUNT_POINT" ]]; then
    echo "Usage: $0 -m <mount_point> [OPTIONS] <source_dir> <nas_archive_dir>" >&2
    echo "  Run $0 -h for full help." >&2
    exit 1
fi
[[ "$SETTLE_SECONDS" =~ ^[0-9]+$ ]] || {
    echo "ERROR: -w takes a whole number of seconds, got '$SETTLE_SECONDS'." >&2
    exit 1
}

SOURCE_DIR="${1%/}"
NAS_DIR="${2%/}"
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: Source directory '$SOURCE_DIR' does not exist." >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$OPERATIONAL_DIR" ]] && OPERATIONAL_DIR="$SCRIPT_DIR"
# Spinner, countdown and runtime helpers (media_progress.sh, alongside this script).
[[ -r "${SCRIPT_DIR}/media_progress.sh" ]] || {
    echo "ERROR: media_progress.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
# shellcheck source=./media_progress.sh
source "${SCRIPT_DIR}/media_progress.sh"

# Canonical paths, so the identity and containment checks below hold for any
# spelling of them.
SOURCE_REAL="$(realpath -- "$SOURCE_DIR")"
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
if [[ ! -d "$NAS_DIR" ]]; then
    echo "ERROR: NAS archive directory '$NAS_DIR' does not exist on the mounted share." >&2
    exit 1
fi
NAS_REAL="$(realpath -- "$NAS_DIR")"
case "$NAS_REAL/" in
    "${MOUNT_REAL%/}/"*) ;;
    *)
        echo "ERROR: $NAS_REAL is not under the mount point $MOUNT_REAL." >&2
        exit 1
        ;;
esac

# The two directories are never the same or nested in each other: a move would
# then target the directory it is reading from, or the reverse.
if [[ "$NAS_REAL" == "$SOURCE_REAL" || "$NAS_REAL" == "$SOURCE_REAL"/* || "$SOURCE_REAL" == "$NAS_REAL"/* ]]; then
    echo "ERROR: the source and NAS directories are the same or nested in each other." >&2
    exit 1
fi

LOCK_FILE=""
CURRENT_TMP=""

# Removes the lock file and an in-flight partial copy on any exit.
# shellcheck disable=SC2317  # false positive: cleanup is invoked indirectly by the EXIT trap below
cleanup() {
    [[ -z "$CURRENT_TMP" ]] || rm -f -- "$CURRENT_TMP" 2>/dev/null || true
    [[ -z "$LOCK_FILE" ]] || rm -f -- "$LOCK_FILE" 2>/dev/null || true
}

# Concurrency lock, on descriptor 7, scoped to the source directory. A dry run
# only reads: it takes no lock and creates no directory or file.
LOG_FILE="/dev/null"
if (( ! DRY_RUN )); then
    LOCK_DIR="${OPERATIONAL_DIR}/.locks"
    mkdir -p -- "$LOCK_DIR"
    LOCK_HASH="$(printf '%s' "$SOURCE_REAL" | sha256sum | cut -d' ' -f1)"
    LOCK_PATH="${LOCK_DIR}/archive_${LOCK_HASH}.lock"
    exec 7>"$LOCK_PATH"
    if ! flock -n 7; then
        echo "ERROR: another archive run is already active against $SOURCE_DIR (lock: $LOCK_PATH)" >&2
        exit 1
    fi
    # Registered only after the lock is acquired, so a failed acquisition never
    # deletes another process's lock file, and before any step that could fail.
    LOCK_FILE="$LOCK_PATH"
    trap cleanup EXIT

    LOG_DIR="${OPERATIONAL_DIR}/Logs"
    mkdir -p -- "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/Archive_$(date '+%Y-%m-%d_%H%M').txt"
fi

# Appends one timestamped line to LOG_FILE. Sets nothing.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Counters
MOVED=0
WAITING=0
COLLIDED=0
NOT_CATEGORY=0
FAILED=0
FILE_NUM=0
FILE_TOTAL=0

# Reports a top-level entry left in the source directory because it is not a
# category folder on the NAS: prints, logs and counts it. Arguments: reason,
# name.
report_held() {
    echo "HELD ($1): $2"
    log "HELD ($1): $2"
    NOT_CATEGORY=$(( NOT_CATEGORY + 1 ))
}

# Records a failed file: prints, logs and counts it, removes its partial copy
# and clears CURRENT_TMP. Arguments: reason, relative path.
fail_file() {
    echo "  [FAILED] $1: $2" >&2
    log "FAILED ($1): $2"
    FAILED=$(( FAILED + 1 ))
    if [[ -n "$CURRENT_TMP" ]]; then
        rm -f -- "$CURRENT_TMP"
        CURRENT_TMP=""
    fi
    return 0
}

# Prints the files under one category folder, NUL-delimited and sorted,
# skipping names that start with a dot. Argument: category folder path.
list_category_files() {
    find "$1" -type f ! -name '.*' -print0 | sort -z
}

# Moves one file to the NAS, or reports why it stays: still inside the settle
# window, or its destination exists. Checks the dry-run flag itself. Counts
# MOVED, WAITING, COLLIDED or FAILED and always returns 0, so one bad file
# never ends the batch. Reads FILE_NUM and FILE_TOTAL for the progress labels.
# Arguments: absolute source path, path relative to the source directory.
archive_file() {
    local src="$1" rel="$2"
    local dest="${NAS_REAL}/${rel}" dest_dir base before after now mtime dest_size
    local place="[${FILE_NUM}/${FILE_TOTAL}]" copy_started

    before="$(stat -c '%s %Y' -- "$src")" || { fail_file "source vanished" "$rel"; return 0; }
    mtime="${before#* }"
    now="$(date +%s)"
    if (( now - mtime < SETTLE_SECONDS )); then
        echo "WAITING (modified within ${SETTLE_SECONDS}s): $rel"
        log "WAITING: $rel"
        WAITING=$(( WAITING + 1 ))
        return 0
    fi

    if [[ -e "$dest" || -L "$dest" ]]; then
        if [[ -d "$dest" ]]; then
            echo "COLLISION (a directory with this name exists on the NAS): $rel"
        else
            dest_size="$(stat -c '%s' -- "$dest" 2>/dev/null)" || dest_size="unknown"
            if [[ "$dest_size" == "${before%% *}" ]]; then
                echo "COLLISION (same name and size already on the NAS; source kept): $rel"
            else
                echo "COLLISION (same name, different size on the NAS; source kept): $rel"
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

    dest_dir="$(dirname -- "$dest")"
    base="$(basename -- "$dest")"
    mkdir -p -- "$dest_dir" || { fail_file "mkdir" "$rel"; return 0; }

    CURRENT_TMP="${dest_dir}/.${base}.tmp"
    copy_started="$SECONDS"
    progress_run "Copying ${place} ${rel}" cp --preserve=timestamps -- "$src" "$CURRENT_TMP" || { fail_file "copy; the share may reject a character in this name" "$rel"; return 0; }

    [[ "$(stat -c '%s' -- "$CURRENT_TMP" 2>/dev/null)" == "${before%% *}" ]] \
        || { fail_file "size mismatch after copy" "$rel"; return 0; }
    if (( VERIFY_CONTENT )); then
        progress_run "Comparing ${place} ${rel}" cmp -s -- "$src" "$CURRENT_TMP" || { fail_file "content mismatch after copy" "$rel"; return 0; }
    fi

    after="$(stat -c '%s %Y' -- "$src")" || { fail_file "source vanished during copy" "$rel"; return 0; }
    [[ "$after" == "$before" ]] || { fail_file "source changed during copy" "$rel"; return 0; }

    # mv -n exits 0 without moving when the destination appeared in the
    # meantime, so a partial file left behind is the failure signal.
    mv -n -- "$CURRENT_TMP" "$dest" || { fail_file "rename into place" "$rel"; return 0; }
    if [[ -e "$CURRENT_TMP" ]]; then
        fail_file "destination appeared during copy" "$rel"
        return 0
    fi
    CURRENT_TMP=""

    if rm -- "$src"; then
        echo "MOVED: $rel ($(format_runtime "$(( SECONDS - copy_started ))"))"
        log "MOVED: $rel ($(format_runtime "$(( SECONDS - copy_started ))"))"
        MOVED=$(( MOVED + 1 ))
    else
        echo "  [FAILED] copied and verified, source not deleted: $rel" >&2
        log "FAILED (rm, copy verified): $rel"
        FAILED=$(( FAILED + 1 ))
    fi
    return 0
}

echo "Starting archive: $SOURCE_REAL -> $NAS_REAL"
echo "----------------------------------------------------------------"
log "Archive started: $SOURCE_REAL -> $NAS_REAL"

while IFS= read -r -d '' ENTRY; do
    CATEGORY="$(basename -- "$ENTRY")"
    [[ "$CATEGORY" == .* ]] && continue

    if [[ ! -d "$ENTRY" || -L "$ENTRY" ]]; then
        report_held "loose file at the top level, not a category folder" "$CATEGORY"
        continue
    fi
    if [[ ! -d "${NAS_REAL}/${CATEGORY}" ]]; then
        report_held "not a category folder on the NAS; none is created" "$CATEGORY"
        continue
    fi

    echo "Category: $CATEGORY"
    CATEGORY_FILES=()
    while IFS= read -r -d '' FILE; do
        CATEGORY_FILES+=("$FILE")
    done < <(progress_run "Listing $CATEGORY" list_category_files "$ENTRY")
    FILE_TOTAL=${#CATEGORY_FILES[@]}
    FILE_NUM=0
    for FILE in ${CATEGORY_FILES[@]+"${CATEGORY_FILES[@]}"}; do
        FILE_NUM=$(( FILE_NUM + 1 ))
        archive_file "$FILE" "${FILE#"$SOURCE_REAL"/}"
    done

    # Folders emptied by the moves are removed innermost first. The category
    # folder itself stays, as in media_encode.sh's own cleanup.
    if (( ! DRY_RUN )); then
        progress_run "Removing empty folders under $CATEGORY" find "$ENTRY" -mindepth 1 -type d -empty -delete \
            || log "WARNING: could not remove every empty folder under $CATEGORY"
    fi
done < <(find "$SOURCE_REAL" -mindepth 1 -maxdepth 1 -print0 | sort -z)

# Summary
echo ""
echo "------------------------------------------"
echo " Archive complete"
if (( DRY_RUN )); then
    echo "  Would move: $MOVED  (dry run: nothing copied or deleted; re-run without -n to archive)"
else
    echo "  Moved:      $MOVED"
fi
echo "  Waiting:    $WAITING  (modified within the last ${SETTLE_SECONDS}s; the next run retries)"
echo "  Collisions: $COLLIDED  (already on the NAS; source kept - review manually)"
echo "  Held:       $NOT_CATEGORY  (not a category folder on the NAS; left in $SOURCE_DIR)"
echo "  Failed:     $FAILED"
echo "  Runtime:    $(format_runtime "$SECONDS")"
echo "------------------------------------------"
log "Archive complete: Moved=$MOVED Waiting=$WAITING Collisions=$COLLIDED Held=$NOT_CATEGORY Failed=$FAILED Runtime=$(format_runtime "$SECONDS")"
(( DRY_RUN )) || echo "Log saved to: $LOG_FILE"

(( FAILED == 0 )) || exit 1
(( COLLIDED + NOT_CATEGORY == 0 )) || exit 2
exit 0
