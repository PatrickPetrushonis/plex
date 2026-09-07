#!/usr/bin/env bash
# setup_smb_mount.sh: Mounts a CIFS/SMB share (e.g. a Synology NAS) as a
# stable local mountpoint, owned by a real (non-root) user, via
# /etc/fstab - so batch tools in this project that refuse to run as root
# (encoder_params.sh, subtitle_embed_params.sh, etc) can read/write it
# directly.
#
# This is a one-time system-setup script and is the one place in this
# project that's SUPPOSED to run as root: installing a package, writing
# /etc/fstab, and mounting a filesystem all require it. That's the
# opposite check from every other script here, which refuses to run as
# root because IT creates files a normal user needs to own; this script
# creates the mount, and a normal user only interacts with what's inside
# it afterward.
#
# Usage:  sudo ./setup_smb_mount.sh [OPTIONS] <server> <share> <mountpoint>
#
# Example:
#   sudo ./setup_smb_mount.sh -p Movies synology.local plexmedia /mnt/synology/movies
#
# Options:
#   -p PATH     Subpath within the share to mount, appended to the UNC path
#               (e.g. "Movies" for //server/share/Movies). Default: none -
#               mounts the whole share.
#   -u USER     Local user who should own the mounted files (uid/gid mount
#               options). Default: $SUDO_USER if set (i.e. the user who
#               ran sudo), otherwise $USER.
#   -c FILE     Path for the SMB credentials file. Default:
#               /etc/samba/credentials/<share>.
#   -v VERS     SMB protocol version. Default: 3.0.
#   -f          Force: overwrite an existing /etc/fstab entry for this
#               mountpoint, or an existing credentials file, instead of
#               leaving it in place (default: leave it in place, skip).
#   -n          Dry run: print every step's plan, modify nothing. Does not
#               require root - a preview is safe to run as any user.
#   -h          Show this help.
#
# Notes:
#   * Requires bash 4.0+ and apt-get (Debian/Ubuntu); installs cifs-utils
#     if it isn't already present.
#   * The credentials file is always root-owned, mode 600, regardless of
#     -u: mount.cifs itself reads it as root during the mount, before any
#     uid/gid mapping happens for the files inside.
#   * /etc/fstab is backed up (timestamped, alongside the original) before
#     any write, and the fstab line itself is only ever appended or
#     replaced as a single self-contained line - nothing else in the file
#     is touched.
#   * A space in <server>/<share>/-p PATH/<mountpoint> is escaped to \040
#     automatically when building the fstab line, since fstab fields are
#     whitespace-delimited and an unescaped space silently breaks the line.
#   * Out of scope, deliberately: this is a single, short-lived
#     provisioning run, not a recurring batch job, so it doesn't take a
#     concurrency lock or register a state-restoring EXIT trap the way the
#     batch tools elsewhere in this project do - there's no long-lived
#     process state here that a concurrent run or a signal could corrupt
#     mid-way, only a handful of already-atomic, already-backed-up steps.

set -euo pipefail

# -- Bash version guard ---------------------------------------------------------
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

# -- Defaults --------------------------------------------------------------------
SUBPATH=""
TARGET_USER="${SUDO_USER:-${USER:-}}"
CRED_FILE=""
VERS="3.0"
FORCE=0
DRY_RUN=0
FSTAB_PATH="/etc/fstab"   # not exposed as a flag: overridden directly by tests, never by a real invocation

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

# -- Arg parsing -------------------------------------------------------------------
while getopts ":p:u:c:v:fnh" opt; do
    case $opt in
        p) SUBPATH="$OPTARG" ;;
        u) TARGET_USER="$OPTARG" ;;
        c) CRED_FILE="$OPTARG" ;;
        v) VERS="$OPTARG" ;;
        f) FORCE=1 ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ $# -eq 3 ]] || {
    echo "Usage: $0 [OPTIONS] <server> <share> <mountpoint>" >&2
    echo "  Run $0 -h for full help." >&2
    exit 1
}
SERVER="$1"
SHARE="$2"
MOUNTPOINT="${3%/}"

[[ -n "$TARGET_USER" ]] || {
    echo "ERROR: could not determine a target user; pass -u USER explicitly." >&2
    exit 1
}

[[ -z "$CRED_FILE" ]] && CRED_FILE="/etc/samba/credentials/${SHARE}"

# -- Root check (this script needs root; see header for why this is the
# opposite of every other script's own check) --------------------------------
if (( ! DRY_RUN )) && [[ $EUID -ne 0 ]]; then
    echo "ERROR: this script writes /etc/fstab and mounts a filesystem; run it with sudo." >&2
    echo "  (Dry run with -n does not require root - use that to preview first.)" >&2
    exit 1
fi

# -- Dependency check -----------------------------------------------------------
require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require id
require grep
require sed
if ! command -v mount.cifs &>/dev/null; then
    require apt-get
fi

# Builds the single fstab line for this mount. Sets FSTAB_LINE. Escapes a
# literal space in any of the four path components to \040 - fstab fields
# are whitespace-delimited, and an unescaped space silently breaks the
# line rather than erroring, so this is done unconditionally rather than
# only when a space happens to be spotted.
build_fstab_line() {
    local server="$1" share="$2" subpath="$3" mountpoint="$4" \
          cred_file="$5" uid="$6" gid="$7" vers="$8"
    local unc="//${server}/${share}"
    [[ -n "$subpath" ]] && unc="${unc}/${subpath}"
    unc="${unc// /\\040}"
    local mp_escaped="${mountpoint// /\\040}"
    FSTAB_LINE="${unc} ${mp_escaped} cifs credentials=${cred_file},uid=${uid},gid=${gid},file_mode=0664,dir_mode=0775,vers=${vers},_netdev,nofail 0 0"
}

# Tests whether FSTAB_FILE already has a non-comment entry whose mountpoint
# field (the second whitespace-delimited field) matches MOUNTPOINT_ESCAPED
# exactly. Returns 0 (found) or 1 (not found) - a plain boolean, no
# three-way state, so a bare `if fstab_has_entry ...; then` at the call
# site is the correct, safe way to use this.
fstab_has_entry() {
    local fstab_file="$1" mountpoint_escaped="$2"
    [[ -f "$fstab_file" ]] || return 1
    awk -v mp="$mountpoint_escaped" '$1 !~ /^#/ && $2 == mp { found=1 } END { exit !found }' "$fstab_file"
}

# Replaces an existing entry for MOUNTPOINT_ESCAPED in FSTAB_FILE with
# NEW_LINE (written to a temp file, then renamed over the original -
# atomic, so a failure partway never leaves a half-written fstab). Assumes
# the caller already confirmed the entry exists and a backup was already
# taken.
replace_fstab_entry() {
    local fstab_file="$1" mountpoint_escaped="$2" new_line="$3"
    local tmp
    tmp="$(mktemp)"
    awk -v mp="$mountpoint_escaped" -v newline="$new_line" \
        '$1 !~ /^#/ && $2 == mp { print newline; next } { print }' \
        "$fstab_file" > "$tmp"
    mv -- "$tmp" "$fstab_file"
}

echo "== Target user / ownership =="
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null)" || {
    echo "ERROR: no such user: $TARGET_USER" >&2
    exit 1
}
TARGET_GID="$(id -g "$TARGET_USER" 2>/dev/null)" || {
    echo "ERROR: could not resolve a primary group for: $TARGET_USER" >&2
    exit 1
}
echo "  User: $TARGET_USER (uid=$TARGET_UID, gid=$TARGET_GID)"

echo ""
echo "== Step 1/6: cifs-utils =="
if command -v mount.cifs &>/dev/null; then
    echo "  Already installed, skipping."
elif (( DRY_RUN )); then
    echo "  [DRY RUN] Would run: apt-get install -y cifs-utils"
else
    apt-get install -y cifs-utils
fi

echo ""
echo "== Step 2/6: mountpoint directory =="
if [[ -d "$MOUNTPOINT" ]]; then
    echo "  Already exists: $MOUNTPOINT"
elif (( DRY_RUN )); then
    echo "  [DRY RUN] Would create: $MOUNTPOINT"
else
    mkdir -p -- "$MOUNTPOINT"
    echo "  Created: $MOUNTPOINT"
fi

echo ""
echo "== Step 3/6: credentials file =="
if [[ -f "$CRED_FILE" ]] && (( ! FORCE )); then
    echo "  Already exists, leaving in place (use -f to overwrite): $CRED_FILE"
elif (( DRY_RUN )); then
    echo "  [DRY RUN] Would prompt for a username/password and write: $CRED_FILE (mode 600, root-owned)"
else
    read -r -p "  SMB username for //${SERVER}/${SHARE}: " SMB_USERNAME
    read -r -s -p "  SMB password: " SMB_PASSWORD
    echo ""
    CRED_DIR="$(dirname "$CRED_FILE")"
    mkdir -p -- "$CRED_DIR"
    CRED_TMP="$(mktemp)"
    {
        printf 'username=%s\n' "$SMB_USERNAME"
        printf 'password=%s\n' "$SMB_PASSWORD"
    } > "$CRED_TMP"
    chmod 600 "$CRED_TMP"
    mv -- "$CRED_TMP" "$CRED_FILE"
    chown root:root "$CRED_FILE"
    unset SMB_USERNAME SMB_PASSWORD
    echo "  Written: $CRED_FILE (mode 600, root-owned)"
fi

echo ""
echo "== Step 4/6: /etc/fstab entry =="
build_fstab_line "$SERVER" "$SHARE" "$SUBPATH" "$MOUNTPOINT" "$CRED_FILE" "$TARGET_UID" "$TARGET_GID" "$VERS"
MOUNTPOINT_ESCAPED="${MOUNTPOINT// /\\040}"

if fstab_has_entry "$FSTAB_PATH" "$MOUNTPOINT_ESCAPED"; then
    if (( FORCE )); then
        if (( DRY_RUN )); then
            echo "  [DRY RUN] Would back up $FSTAB_PATH and replace the existing entry for $MOUNTPOINT with:"
            echo "    $FSTAB_LINE"
        else
            FSTAB_BACKUP="${FSTAB_PATH}.bak.$(date '+%Y%m%d_%H%M%S')"
            cp -- "$FSTAB_PATH" "$FSTAB_BACKUP"
            replace_fstab_entry "$FSTAB_PATH" "$MOUNTPOINT_ESCAPED" "$FSTAB_LINE"
            echo "  Backed up to: $FSTAB_BACKUP"
            echo "  Replaced existing entry for $MOUNTPOINT."
        fi
    else
        echo "  An entry for $MOUNTPOINT already exists, leaving it in place (use -f to overwrite)."
        echo "  Not touching $FSTAB_PATH; skipping mount below to avoid mounting against a stale definition."
        SKIP_MOUNT=1
    fi
else
    if (( DRY_RUN )); then
        echo "  [DRY RUN] Would back up $FSTAB_PATH and append:"
        echo "    $FSTAB_LINE"
    else
        FSTAB_BACKUP="${FSTAB_PATH}.bak.$(date '+%Y%m%d_%H%M%S')"
        cp -- "$FSTAB_PATH" "$FSTAB_BACKUP"
        printf '%s\n' "$FSTAB_LINE" >> "$FSTAB_PATH"
        echo "  Backed up to: $FSTAB_BACKUP"
        echo "  Appended entry for $MOUNTPOINT."
    fi
fi

echo ""
echo "== Step 5/6: mount =="
if [[ "${SKIP_MOUNT:-0}" == "1" ]]; then
    echo "  Skipped (see above) - run manually once you've reconciled the existing fstab entry: mount \"$MOUNTPOINT\""
elif (( DRY_RUN )); then
    echo "  [DRY RUN] Would run: mount \"$MOUNTPOINT\""
else
    mount "$MOUNTPOINT"
    echo "  Mounted."
fi

echo ""
echo "== Step 6/6: confirm =="
if (( DRY_RUN )); then
    echo "  [DRY RUN] Would run: mount | grep -F \"$MOUNTPOINT\"; ls -la \"$MOUNTPOINT\""
elif [[ "${SKIP_MOUNT:-0}" == "1" ]]; then
    echo "  Skipped (mount step skipped above)."
else
    mount | grep -F "$MOUNTPOINT" || {
        echo "  WARNING: mount succeeded but was not found in the mount table - check manually." >&2
        exit 1
    }
    echo ""
    ls -la "$MOUNTPOINT"
fi

echo ""
echo "Done. Point this project's scripts at: $MOUNTPOINT"