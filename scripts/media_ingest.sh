#!/usr/bin/env bash
# media_ingest.sh: Rename finished downloads into Plex naming and move them to the
#            holding directory, stopping for a person only when something
#            needs a decision.
#
# Usage:  ./media_ingest.sh [OPTIONS] <source_dir> <holding_dir>
#
# Steps, in order, against <source_dir> (the completed-downloads directory):
#   1. Settle check: the files under <source_dir> must be unchanged across the
#      settle window (-w). A directory that is still changing ends the run with
#      exit 0; the next run tries again.
#   2. Preview: media_rename.sh -n -x on the whole directory. A skipped, unmatched or
#      to-be-deleted file stops the run with exit 2 before anything changes.
#   3. Rename: media_rename.sh -x with no input attached, so a subtitle-deletion
#      prompt is answered "no" instead of blocking an unattended run. Any
#      non-zero exit stops the run before the move.
#   4. Classify: media_classify.py names a category folder for each top-level
#      entry that holds a video file (the categories are listed in
#      media_categories.sh). An entry it cannot place stays and is listed for
#      review; an entry whose lookup could not complete stays and the next run
#      retries it.
#   5. Move: each classified entry moves to <holding_dir>/<Category>/, unless
#      the files changed during step 3. An entry with no video, or whose name
#      already exists in its category folder, stays.
#
# Options:
#   -n              Dry run: runs the settle check and the preview, then prints
#                   what a real run does; renames and moves nothing, takes no
#                   lock and writes no log (default: off)
#   -w SECONDS      Settle window in seconds; 0 skips the check (default: 60)
#   -C FILE         Category overrides for the classifier: "Title (YYYY)", a
#                   tab, a category, one per line. A missing file means no
#                   overrides (default: ../data/ingest_categories.tsv)
#   -L FILE         Library folder list for the classifier: the label stage's
#                   plex_folders.csv, which gives it the shows already in Plex
#                   (default: ../data/plex_folders.csv)
#   -O DIR          Operational directory: logs (OPDIR/Logs) and the lock file
#                   (OPDIR/.locks), never <source_dir> itself; real runs only.
#                   Default: this script's own directory
#   -h              Show this help
#
# Files written by a real run (under OPDIR/Logs):
#   Ingest.log          One line per move, hold, collision and failure
#   Ingest_review.txt   What needs a person: the preview output, or the held and
#                       colliding entries. Rewritten only when its content
#                       changes; removed when nothing needs review
#   Ingest_state        The exit code and a hash of the source and holding
#                       directories after a run that stopped non-zero; removed
#                       after a run that exits 0
#
# Exit codes:
#   0  Nothing to do, directory not settled yet, every entry moved, or entries
#      deferred to the next run because a lookup could not complete
#   1  media_rename.sh failed, a move failed, or bad usage
#   2  Something needs a person (see Ingest_review.txt)
#
# Notes:
#   • Refuses to run as root: the folders and logs it creates must belong to
#     the user who owns the library
#   • Requires bash 4.4+ (mapfile -d), GNU find (-printf), flock, sha256sum,
#     realpath, python3, ffprobe, and media_rename.sh, media_classify.py,
#     media_categories.sh and video_exts.sh alongside this script. A real run
#     needs the TMDB_API_KEY environment variable (the key plex_labels.sh uses),
#     checked before anything is renamed
#   • One run per <source_dir> at a time; a second run exits 1 immediately. The
#     lock file is named ingest_<hash>.lock, apart from media_rename.sh's
#     <hash>.lock for the same directory, so the two never block each other
#   • A run that finds both directories exactly as the last non-zero run left
#     them repeats that exit code at once, with no settle wait, rename or log
#     line. Renaming a file, or adding or removing a name in either directory,
#     starts the run over
#   • The category is chosen from the renamed names, so a dry run does not show
#     it. A lookup that cannot complete defers the entry. While an entry is
#     deferred the run records no state, so the next run retries it even when
#     another entry needs a person
#   • A top-level entry is moved whole. With a clean preview every video under
#     it is already renamed, so a folder never leaves half renamed
#   • A directory is never merged into an existing one: mv would nest it
#   • Known limitation: an entry that arrives between the settle check and the
#     preview is renamed with the rest. The change is detected after the rename
#     and the move waits for the next run, but the rename has already happened

set -euo pipefail

# Bash version guard (mapfile -d, used below, arrived in bash 4.4)
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "ERROR: bash 4.4+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

# Dependency check
require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require find
require flock
require sha256sum
require sort
require cmp
require mktemp
require sleep
require python3
require ffprobe
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
SETTLE_SECONDS=60
OPERATIONAL_DIR=""
OVERRIDES_FILE=""
FOLDERS_FILE=""

# Usage
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

# Arg parsing
while getopts ":w:C:L:O:nh" opt; do
    case $opt in
        w) SETTLE_SECONDS="$OPTARG" ;;
        C) OVERRIDES_FILE="$OPTARG" ;;
        L) FOLDERS_FILE="$OPTARG" ;;
        O) OPERATIONAL_DIR="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ $# -eq 2 ]] || {
    echo "Usage: $0 [OPTIONS] <source_dir> <holding_dir>" >&2
    echo "  Run $0 -h for full help." >&2
    exit 1
}
[[ "$SETTLE_SECONDS" =~ ^[0-9]+$ ]] || {
    echo "ERROR: -w takes a whole number of seconds, got '$SETTLE_SECONDS'." >&2
    exit 1
}
SOURCE_DIR="${1%/}"
HOLD_DIR="${2%/}"

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: Source directory '$SOURCE_DIR' does not exist." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$OPERATIONAL_DIR" ]] && OPERATIONAL_DIR="$SCRIPT_DIR"

RENAME_SH="${SCRIPT_DIR}/media_rename.sh"
[[ -x "$RENAME_SH" ]] || {
    echo "ERROR: media_rename.sh not found or not executable next to this script (${SCRIPT_DIR})" >&2
    exit 1
}

# Video extensions (video_exts.sh, alongside this script): the same list
# media_rename.sh and media_encode.sh read.
[[ -r "${SCRIPT_DIR}/video_exts.sh" ]] || {
    echo "ERROR: video_exts.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
# shellcheck source=./video_exts.sh
source "${SCRIPT_DIR}/video_exts.sh"

# The classifier and the category list (media_categories.sh, which
# media_release.sh also reads), alongside this script.
CLASSIFY_PY="${SCRIPT_DIR}/media_classify.py"
[[ -r "$CLASSIFY_PY" ]] || {
    echo "ERROR: media_classify.py not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
[[ -r "${SCRIPT_DIR}/media_categories.sh" ]] || {
    echo "ERROR: media_categories.sh not found next to this script (${SCRIPT_DIR})" >&2
    exit 1
}
# shellcheck source=./media_categories.sh
source "${SCRIPT_DIR}/media_categories.sh"
[[ -n "$OVERRIDES_FILE" ]] || OVERRIDES_FILE="${SCRIPT_DIR}/../data/ingest_categories.tsv"
[[ -n "$FOLDERS_FILE" ]] || FOLDERS_FILE="${SCRIPT_DIR}/../data/plex_folders.csv"
# The classifier looks up every entry on TMDB. Checked here, before the rename,
# so a missing key never leaves renamed entries that cannot be sorted.
if (( ! DRY_RUN )) && [[ -z "${TMDB_API_KEY:-}" ]]; then
    echo "ERROR: TMDB_API_KEY is not set; put it in ~/.config/plex_env (template: plex_env.example), a TMDB v3 API key that media_classify.py needs" >&2
    exit 1
fi
# Without the library list the classifier cannot tell a series movie from a
# movie, so say so once here instead of once per entry.
if [[ ! -f "$FOLDERS_FILE" ]]; then
    echo "WARNING: library list not found: $FOLDERS_FILE; series movies are not detected" >&2
    FOLDERS_FILE=""
fi

# Canonical paths, so the nesting check below holds for any spelling of them.
SOURCE_REAL="$(realpath -- "$SOURCE_DIR")"
HOLD_REAL="$(realpath -m -- "$HOLD_DIR")"

# The holding directory is never the source or inside it: a move would then
# target the directory it is reading from.
if [[ "$HOLD_REAL" == "$SOURCE_REAL" || "$HOLD_REAL" == "$SOURCE_REAL"/* ]]; then
    echo "ERROR: holding directory '$HOLD_DIR' is the source directory or inside it." >&2
    exit 1
fi

# Set once this run holds the lock and has made its scratch directory; the EXIT
# trap below removes each, only when this run created it.
LOCK_FILE=""
WORK_DIR=""

# Concurrency lock, on descriptor 7 (media_rename.sh uses 8 and 9, and runs as a
# child of this script). A dry run only reads: it takes no lock and creates no
# directory or file.
LOG_FILE="/dev/null"
REVIEW_FILE=""
STATE_FILE=""
if (( ! DRY_RUN )); then
    LOCK_DIR="${OPERATIONAL_DIR}/.locks"
    mkdir -p -- "$LOCK_DIR"
    LOCK_HASH="$(printf '%s' "$SOURCE_REAL" | sha256sum | cut -d' ' -f1)"
    LOCK_PATH="${LOCK_DIR}/ingest_${LOCK_HASH}.lock"
    exec 7>"$LOCK_PATH"
    if ! flock -n 7; then
        echo "ERROR: another ingest is already running against $SOURCE_DIR (lock: $LOCK_PATH)" >&2
        exit 1
    fi
    # Registered only after the lock is acquired, so a failed acquisition never
    # deletes another process's lock file, and before any step that could fail.
    LOCK_FILE="$LOCK_PATH"
    # Removes the lock file on any exit, including SIGINT and SIGTERM (SIGKILL
    # skips EXIT traps). WORK_DIR is removed too once it exists.
    trap '[[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR" 2>/dev/null || true; rm -f -- "$LOCK_FILE" 2>/dev/null || true' EXIT

    WORK_DIR="$(mktemp -d)"
    LOG_DIR="${OPERATIONAL_DIR}/Logs"
    mkdir -p -- "$LOG_DIR" "$HOLD_DIR"
    LOG_FILE="${LOG_DIR}/Ingest.log"
    REVIEW_FILE="${LOG_DIR}/Ingest_review.txt"
    STATE_FILE="${LOG_DIR}/Ingest_state"
fi

# Appends one timestamped line to LOG_FILE. Sets nothing.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Counters
PROMOTED=0
HELD=0
UNCLASSIFIED=0
DEFERRED_LOOKUP=0
COLLIDED=0
FAILED=0
REVIEW_TEXT=""
CLASS_CATEGORY=""
CLASS_REASON=""

# Appends one line to REVIEW_TEXT, the text a person must read. Argument: line.
add_review() { REVIEW_TEXT+="$1"$'\n'; }

# Reports an entry left in the source directory because it holds no video file:
# prints, logs and counts it, and adds it to the review text. Argument: name.
report_held() {
    echo "HELD (no video file inside; left in place): $1"
    log "HELD (no video file): $1"
    add_review "HELD (no video file inside; left in $SOURCE_DIR): $1"
    HELD=$(( HELD + 1 ))
}

# Reports an entry left in the source directory because its name already exists
# in its category folder in the holding directory. A directory is never merged:
# mv would nest it. Prints, logs and counts it, and adds it to the review text.
# Arguments: name, category folder.
report_collision() {
    echo "COLLISION (name already exists in $2; merge manually): $1"
    log "COLLISION: $2/$1"
    add_review "COLLISION (name already exists in $2; merge manually): $1"
    COLLIDED=$(( COLLIDED + 1 ))
}

# Reports an entry left in the source directory because the classifier needs a
# person to place it: prints, logs and counts it, and adds it to the review
# text. Arguments: name, reason.
report_unclassified() {
    echo "NEEDS A DECISION ($2; left in place): $1"
    log "UNCLASSIFIED ($2): $1"
    add_review "NEEDS A DECISION ($2; left in $SOURCE_DIR): $1. Name its category in $OVERRIDES_FILE, or move it into a category folder under $HOLD_DIR by hand."
    UNCLASSIFIED=$(( UNCLASSIFIED + 1 ))
}

# Reports an entry left in the source directory because a lookup could not
# complete: prints, logs and counts it. It is not added to the review text; the
# next run retries it. Arguments: name, reason.
report_deferred() {
    echo "DEFERRED ($2; the next run retries): $1"
    log "DEFERRED ($2): $1"
    DEFERRED_LOOKUP=$(( DEFERRED_LOOKUP + 1 ))
}

# Reports a move that did not complete: prints, logs and counts it. Argument:
# name, with the reason when it is not a failed mv.
report_failure() {
    echo "  [FAILED] move: $1" >&2
    log "FAILED (move): $1"
    FAILED=$(( FAILED + 1 ))
}

# Publishes REVIEW_TEXT as REVIEW_FILE only when it differs from the file's
# current content, so a problem that persists across runs is logged once, and
# removes REVIEW_FILE when nothing needs review. Real runs only. Sets nothing.
finish_review() {
    (( DRY_RUN )) && return 0
    if [[ -z "$REVIEW_TEXT" ]]; then
        rm -f -- "$REVIEW_FILE"
        return 0
    fi
    if [[ ! -f "$REVIEW_FILE" ]] || ! printf '%s' "$REVIEW_TEXT" | cmp -s - "$REVIEW_FILE"; then
        printf '%s' "$REVIEW_TEXT" > "$REVIEW_FILE"
        log "NEEDS REVIEW: $REVIEW_FILE"
        echo "Review file written: $REVIEW_FILE"
    fi
    return 0
}

# Prints one hash of the size and modification time of every file under DIR. It
# changes when a file is added, removed, grown or rewritten, and not when files
# are renamed or moved, so it can be compared across the rename. Argument: dir.
tree_signature() {
    find "$1" -type f -printf '%s\t%T@\n' | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

# Prints one hash of every path under the source directory with its type, size
# and modification time, plus the top-level names in the holding directory.
# Unlike tree_signature it changes when a file is renamed, a held name appears or
# disappears (in a category folder too), or the overrides file changes, so a
# person's fix makes the next run start over.
state_signature() {
    {
        find "$SOURCE_DIR" -mindepth 1 -printf '%P\t%y\t%s\t%T@\n'
        find "$HOLD_DIR" -mindepth 1 -maxdepth 2 -printf 'held\t%P\n'
        if [[ -f "$OVERRIDES_FILE" ]]; then
            printf 'overrides\t%s\n' "$(sha256sum < "$OVERRIDES_FILE")"
        fi
    } | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

# Records RC and the current state_signature in STATE_FILE, so the next run that
# finds nothing changed repeats RC without redoing the work, or removes
# STATE_FILE when RC is 0 or an entry was deferred, so a deferred lookup is
# retried by the next run. Real runs only. Argument: exit code.
record_state() {
    (( DRY_RUN )) && return 0
    if (( $1 == 0 || DEFERRED_LOOKUP > 0 )); then
        rm -f -- "$STATE_FILE"
    else
        printf '%s %s\n' "$1" "$(state_signature)" > "$STATE_FILE"
    fi
    return 0
}

# Ends the run: publishes the review text, records the state and exits with RC.
# Real runs only reach it with a non-zero RC, apart from the nothing-to-ingest
# and clean-finish exits. Argument: exit code.
stop_run() {
    finish_review
    record_state "$1"
    exit "$1"
}

# Ends the run for a person to look at: the review text is DESCRIPTION followed
# by the captured output in FILE. Real runs only. Arguments: exit code,
# description, output file.
stop_for_review() {
    local rc="$1" description="$2" output_file="$3"
    add_review "$description"
    REVIEW_TEXT+="$(<"$output_file")"$'\n'
    stop_run "$rc"
}

# Prints the top-level entries of the source directory, NUL-delimited and sorted.
list_entries() {
    find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z
}

# Returns 0 when the path is a video file or a directory holding one, by the
# extension list in video_exts.sh. Argument: path.
entry_has_video() {
    local found
    found="$(find "$1" -type f -regextype posix-extended -iregex ".*\.(${VIDEO_EXTS})$" -print -quit)" || true
    [[ -n "$found" ]]
}

# Asks media_classify.py for the category of one entry. Sets CLASS_CATEGORY and
# CLASS_REASON. The classifier prints "<first field><TAB><reason>" and exits 0
# for a chosen category, 2 when it needs a person (HOLD), 3 when a lookup could
# not complete (DEFER) and 1 on an error (ERROR). Returns 0 for a chosen
# category that is listed in media_categories.sh, 2 or 3 as the classifier did,
# and 1 for any other exit or an unlisted category. Argument: entry path.
classify_entry() {
    local entry="$1" out="" rc=0
    local -a args=(-E "$VIDEO_EXTS" -C "$OVERRIDES_FILE")
    CLASS_CATEGORY=""
    CLASS_REASON=""
    [[ -z "$FOLDERS_FILE" ]] || args+=(-L "$FOLDERS_FILE")
    out="$(python3 "$CLASSIFY_PY" "${args[@]}" -- "$entry")" || rc=$?
    IFS=$'\t' read -r CLASS_CATEGORY CLASS_REASON <<< "$out"
    case "$rc" in
        0)
            if is_category "$CLASS_CATEGORY"; then
                return 0
            fi
            CLASS_REASON="unlisted category '${CLASS_CATEGORY}'"
            return 1
            ;;
        2|3) return "$rc" ;;
        *)
            CLASS_REASON="${CLASS_REASON:-exit $rc}"
            return 1
            ;;
    esac
}

# Moves one top-level entry to its category folder in the holding directory, or
# reports why it stays: gone since the listing (a failure), no video inside
# (held), no category chosen (a decision, or deferred to the next run), or its
# name already in the category folder (a collision). Checks the dry-run flag
# itself. Counts PROMOTED, HELD, UNCLASSIFIED, DEFERRED_LOOKUP, COLLIDED or
# FAILED. Sets nothing else. Argument: entry path.
ingest_entry() {
    local entry="$1" name dest class_rc=0
    name="$(basename -- "$entry")"
    if [[ ! -e "$entry" && ! -L "$entry" ]]; then
        report_failure "$name (gone since the listing)"
        return 0
    fi
    if ! entry_has_video "$entry"; then
        report_held "$name"
        return 0
    fi
    classify_entry "$entry" || class_rc=$?
    case "$class_rc" in
        0) ;;
        2) report_unclassified "$name" "$CLASS_REASON"; return 0 ;;
        3) report_deferred "$name" "$CLASS_REASON"; return 0 ;;
        *) report_failure "$name (classifier: $CLASS_REASON)"; return 0 ;;
    esac
    dest="${HOLD_DIR}/${CLASS_CATEGORY}/${name}"
    if [[ -e "$dest" || -L "$dest" ]]; then
        report_collision "$name" "${HOLD_DIR}/${CLASS_CATEGORY}"
        return 0
    fi
    if (( DRY_RUN )); then
        echo "  [DRY RUN] Would move: $name -> $dest ($CLASS_REASON)"
        return 0
    fi
    mkdir -p -- "${HOLD_DIR}/${CLASS_CATEGORY}" || {
        report_failure "$name (mkdir ${CLASS_CATEGORY})"
        return 0
    }
    # -T keeps mv from nesting the entry inside a directory that appeared at
    # DEST after the check above; -n keeps it from overwriting a file that did.
    if mv -nT -- "$entry" "$dest" && [[ ! -e "$entry" && -e "$dest" ]]; then
        echo "MOVED: $name -> $CLASS_CATEGORY ($CLASS_REASON)"
        log "MOVED: $entry -> $dest ($CLASS_REASON)"
        PROMOTED=$(( PROMOTED + 1 ))
    else
        report_failure "$name (mv error)"
    fi
}

declare -a ENTRIES=()
mapfile -d '' ENTRIES < <(list_entries)
if (( ${#ENTRIES[@]} == 0 )); then
    echo "Nothing to ingest in $SOURCE_DIR."
    stop_run 0
fi

# A real run that finds both directories as the last non-zero run left them has
# nothing new to decide: it repeats that exit code before any wait or rename.
if (( ! DRY_RUN )) && [[ -f "$STATE_FILE" ]]; then
    STATE_RC=""; STATE_HASH=""
    read -r STATE_RC STATE_HASH < "$STATE_FILE" || true
    if [[ "$STATE_HASH" == "$(state_signature)" && "$STATE_RC" =~ ^[0-9]+$ ]]; then
        echo "UNCHANGED since the last run, which stopped with exit $STATE_RC; nothing done. Details: $REVIEW_FILE"
        exit "$STATE_RC"
    fi
fi

echo "Starting ingest: $SOURCE_DIR -> $HOLD_DIR"
echo "----------------------------------------------------------------"

# 1. SETTLE CHECK
SIG_SETTLED="$(tree_signature "$SOURCE_DIR")"
if (( SETTLE_SECONDS > 0 )); then
    echo "Waiting ${SETTLE_SECONDS}s to confirm $SOURCE_DIR has stopped changing..."
    sleep "$SETTLE_SECONDS"
    SIG_AFTER_WAIT="$(tree_signature "$SOURCE_DIR")"
    if [[ "$SIG_AFTER_WAIT" != "$SIG_SETTLED" ]]; then
        echo "NOT SETTLED: files under $SOURCE_DIR changed during the ${SETTLE_SECONDS}s window; nothing done, the next run retries."
        log "NOT SETTLED: $SOURCE_DIR changed during the ${SETTLE_SECONDS}s window"
        exit 0
    fi
else
    echo "Settle check skipped (-w 0)."
fi

# 2. PREVIEW
echo "=== Preview: media_rename.sh -n -x ==="
PREVIEW_RC=0
if (( DRY_RUN )); then
    "$RENAME_SH" -n -x -O "$OPERATIONAL_DIR" "$SOURCE_DIR" || PREVIEW_RC=$?
else
    PREVIEW_FILE="${WORK_DIR}/preview.txt"
    "$RENAME_SH" -n -x -O "$OPERATIONAL_DIR" "$SOURCE_DIR" > "$PREVIEW_FILE" 2>&1 || PREVIEW_RC=$?
    cat -- "$PREVIEW_FILE"
fi
if (( PREVIEW_RC != 0 )); then
    if (( PREVIEW_RC == 2 )); then
        echo "NEEDS A DECISION: the preview skipped, left unmatched or would delete files; nothing was changed."
    else
        echo "FAILED: the preview exited $PREVIEW_RC; nothing was changed." >&2
    fi
    (( DRY_RUN )) && exit "$PREVIEW_RC"
    log "PREVIEW exit $PREVIEW_RC: $SOURCE_DIR"
    stop_for_review "$PREVIEW_RC" \
        "media_rename.sh -n -x exited $PREVIEW_RC on $SOURCE_DIR. Resolve the items below, or run media_rename.sh -n on it to see them again." \
        "$PREVIEW_FILE"
fi
if (( DRY_RUN )); then
    echo "[DRY RUN] The preview is clean. A real run renames, then sorts every entry of $SOURCE_DIR that holds a video into a category folder under $HOLD_DIR. Categories are chosen from the renamed names, so they are not previewed."
    exit 0
fi

# 3. RENAME
echo "=== Rename: media_rename.sh -x ==="
log "Rename started: $SOURCE_DIR"
RENAME_RC=0
RENAME_FILE="${WORK_DIR}/rename.txt"
"$RENAME_SH" -x -O "$OPERATIONAL_DIR" "$SOURCE_DIR" < /dev/null > "$RENAME_FILE" 2>&1 || RENAME_RC=$?
cat -- "$RENAME_FILE"
if (( RENAME_RC != 0 )); then
    echo "STOPPED: media_rename.sh exited $RENAME_RC; nothing was moved." >&2
    log "RENAME exit $RENAME_RC: $SOURCE_DIR"
    stop_for_review "$RENAME_RC" \
        "media_rename.sh -x exited $RENAME_RC on $SOURCE_DIR after a clean preview. Nothing was moved." \
        "$RENAME_FILE"
fi

# The rename moves files without changing their size or modification time, so a
# different signature means something arrived or changed while it ran.
if [[ "$(tree_signature "$SOURCE_DIR")" != "$SIG_SETTLED" ]]; then
    echo "DEFERRED: files under $SOURCE_DIR changed during the rename; nothing was moved, the next run retries."
    log "DEFERRED: $SOURCE_DIR changed during the rename"
    exit 0
fi

# 4. CLASSIFY AND MOVE
echo "=== Classify and move to $HOLD_DIR ==="
mapfile -d '' ENTRIES < <(list_entries)
for ENTRY in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
    ingest_entry "$ENTRY"
done

# Summary
echo ""
echo "------------------------------------------"
echo " Ingest complete"
echo "  Moved:      $PROMOTED"
echo "  Held:       $HELD  (no video file inside; left in $SOURCE_DIR)"
echo "  Unplaced:   $UNCLASSIFIED  (no category chosen; left in $SOURCE_DIR, see the review file)"
echo "  Deferred:   $DEFERRED_LOOKUP  (a lookup could not complete; the next run retries)"
echo "  Collisions: $COLLIDED  (name already exists in its category folder; merge manually)"
echo "  Failed:     $FAILED"
echo "------------------------------------------"
log "Ingest complete: Moved=$PROMOTED Held=$HELD Unplaced=$UNCLASSIFIED Deferred=$DEFERRED_LOOKUP Collisions=$COLLIDED Failed=$FAILED"
echo "Log saved to: $LOG_FILE"
FINAL_RC=0
if (( FAILED > 0 )); then
    FINAL_RC=1
elif [[ -n "$REVIEW_TEXT" ]]; then
    FINAL_RC=2
fi
stop_run "$FINAL_RC"
