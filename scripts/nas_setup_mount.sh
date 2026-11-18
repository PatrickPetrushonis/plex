#!/usr/bin/env bash
# nas_setup_mount.sh: Mounts a CIFS/SMB share (e.g. a NAS) as a
# stable local mountpoint, owned by a real (non-root) user, via
# /etc/fstab - so batch tools in this project that refuse to run as root
# (media_archive.sh by default; the others when pointed at the share) can
# read/write it directly.
#
# This is a one-time system-setup script and is the one place in this
# project that's SUPPOSED to run as root: installing a package, writing
# /etc/fstab, and mounting a filesystem all require it. That's the
# opposite check from every other script here, which refuses to run as
# root because IT creates files a normal user needs to own; this script
# creates the mount, and a normal user only interacts with what's inside
# it afterward.
#
# Usage:  sudo ./nas_setup_mount.sh [OPTIONS] <server> <share> <mountpoint>
#
# Examples:
#   sudo ./nas_setup_mount.sh -p Movies nas.local media /mnt/nas/movies
#   sudo ./nas_setup_mount.sh nas.local plexmedia /mnt/nas/plexmedia
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
#   -o OPTS     Extra mount options, comma-separated, appended to the fstab
#               line after the fixed ones (e.g. "iocharset=utf8,mapposix").
#               No whitespace. Default: none.
#   -f          Force: overwrite an existing /etc/fstab entry for this
#               mountpoint, or an existing credentials file, instead of
#               leaving it in place (default: leave it in place, skip).
#               Asks for a typed "yes" before doing anything (not in a dry
#               run); any other answer aborts the run. A replaced credentials
#               file is backed up first, as /etc/fstab is.
#   -n          Dry run: print every step's plan, modify nothing. Does not
#               require root - a preview is safe to run as any user.
#   -h          Show this help.
#
# Notes:
#   * Requires bash 4.0+, mountpoint and runuser, and apt-get (Debian/Ubuntu);
#     installs cifs-utils if it isn't already present.
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
#   * A "#" in <server>, <share>, -p PATH or <mountpoint> is refused: how an
#     fstab field holding one is parsed is unconfirmed, so no line is written
#     for it. To use a folder whose name has a "#", mount the share root and
#     name the folder in the caller's own configuration.
#   * -o OPTS is appended to the mount options as written, after the fixed
#     ones (uid, gid, file_mode, dir_mode, vers, _netdev, nofail).
#   * A target user that resolves to root is refused: the project's batch
#     tools refuse to run as root, and a mount owned by uid 0 is not writable
#     by anyone else.
#   * <server> is resolved with getent before anything is written. A name that
#     does not resolve (for example a .local name on a machine without mDNS
#     name lookup) stops the run; pass the server's IP address instead.
#   * Run again after a failed mount: an existing fstab entry identical to the
#     line this run would write is not rewritten, and the run goes on to the
#     mount. An entry that differs is left in place, no mount is attempted, and
#     the run exits 1.
#   * Exit codes: 0 mounted (or a dry run completed); 1 any error, a failed
#     mount, or no mount because an existing entry differs.
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
MOUNT_OPTS=""
FORCE=0
DRY_RUN=0
SKIP_MOUNT=0
FSTAB_PATH="/etc/fstab"   # not exposed as a flag: overridden directly by tests, never by a real invocation

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

# -- Arg parsing -------------------------------------------------------------------
while getopts ":p:u:c:v:o:fnh" opt; do
    case $opt in
        p) SUBPATH="$OPTARG" ;;
        u) TARGET_USER="$OPTARG" ;;
        c) CRED_FILE="$OPTARG" ;;
        v) VERS="$OPTARG" ;;
        o) MOUNT_OPTS="$OPTARG" ;;
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

if [[ "$SERVER$SHARE$SUBPATH$MOUNTPOINT" == *"#"* ]]; then
    echo "ERROR: '#' in the server, share, subpath or mount point is not supported." >&2
    exit 1
fi
if [[ "$MOUNT_OPTS" == *[[:space:]]* ]]; then
    echo "ERROR: -o takes comma-separated options with no whitespace." >&2
    exit 1
fi

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

# -f overwrites existing configuration, so it needs a typed answer at the moment
# of the run: a flag alone can be typed ahead of time and fired without
# re-reading it. Anything but "yes" (including end of input) aborts. A dry run
# overwrites nothing and is not asked.
if (( FORCE && ! DRY_RUN )); then
    CONFIRM=""
    read -r -p "-f overwrites the existing credentials file and fstab entry for this mount. Type 'yes' to continue: " CONFIRM || true
    [[ "$CONFIRM" == "yes" ]] || { echo "Aborted." >&2; exit 1; }
fi

# -- Dependency check -----------------------------------------------------------
require() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }; }
require id
require getent
require grep
require sed
require awk
require mountpoint
require runuser
if ! command -v mount.cifs &>/dev/null; then
    require apt-get
fi

# Builds the single fstab line for this mount. Sets FSTAB_LINE. Escapes a
# literal space in any of the four path components to \040 - fstab fields
# are whitespace-delimited, and an unescaped space silently breaks the
# line rather than erroring, so this is done unconditionally rather than
# only when a space happens to be spotted. EXTRA_OPTS, when non-empty, is
# appended to the mount options as written.
build_fstab_line() {
    local server="$1" share="$2" subpath="$3" mountpoint="$4" \
          cred_file="$5" uid="$6" gid="$7" vers="$8" extra_opts="$9"
    local unc="//${server}/${share}"
    [[ -n "$subpath" ]] && unc="${unc}/${subpath}"
    unc="${unc// /\\040}"
    local mp_escaped="${mountpoint// /\\040}"
    FSTAB_LINE="${unc} ${mp_escaped} cifs credentials=${cred_file},uid=${uid},gid=${gid},file_mode=0664,dir_mode=0775,vers=${vers},_netdev,nofail${extra_opts:+,${extra_opts}} 0 0"
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

# Tests whether FSTAB_FILE has a non-comment entry for MOUNTPOINT_ESCAPED whose
# fields, joined by single spaces, equal WANT_LINE's. Returns 0 (identical) or
# 1 (absent or different); a plain boolean, safe in a bare `if`.
fstab_entry_matches() {
    local fstab_file="$1" mountpoint_escaped="$2" want_line="$3"
    [[ -f "$fstab_file" ]] || return 1
    awk -v mp="$mountpoint_escaped" -v want="$want_line" '
        BEGIN { n = split(want, w, " "); joined = w[1]; for (i = 2; i <= n; i++) joined = joined " " w[i] }
        $1 !~ /^#/ && $2 == mp {
            line = $1; for (i = 2; i <= NF; i++) line = line " " $i
            if (line == joined) found = 1
        }
        END { exit !found }' "$fstab_file"
}

# Reloads systemd so it re-reads the fstab just written; mount prints a hint
# when it is missing. Does nothing when systemctl is absent. A failed reload is
# reported, not fatal: the mount step reports its own result.
reload_systemd() {
    command -v systemctl &>/dev/null || return 0
    if systemctl daemon-reload; then
        echo "  Reloaded systemd."
    else
        echo "  WARNING: systemctl daemon-reload failed; run it before mounting." >&2
    fi
}

# Replaces an existing entry for MOUNTPOINT_ESCAPED in FSTAB_FILE with
# NEW_LINE (written to a temp file in the same directory, given the original's
# mode and owner, then renamed over it - atomic, so a failure partway never
# leaves a half-written fstab). Assumes
# the caller already confirmed the entry exists and a backup was already
# taken.
replace_fstab_entry() {
    local fstab_file="$1" mountpoint_escaped="$2" new_line="$3"
    local tmp
    # Created beside the target: rename(2) is atomic only within one
    # filesystem, and mktemp's default 0600 mode would replace the mode and
    # owner of the original.
    tmp="$(mktemp "${fstab_file}.XXXXXX")"
    awk -v mp="$mountpoint_escaped" -v newline="$new_line" \
        '$1 !~ /^#/ && $2 == mp { print newline; next } { print }' \
        "$fstab_file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod --reference="$fstab_file" -- "$tmp"
    chown --reference="$fstab_file" -- "$tmp"
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
if (( TARGET_UID == 0 )); then
    echo "ERROR: the target user resolves to root; the project's batch tools refuse to run as root and could not write to the mount. Pass -u USER." >&2
    exit 1
fi
echo "  User: $TARGET_USER (uid=$TARGET_UID, gid=$TARGET_GID)"

echo ""
echo "== Check: server name =="
if getent hosts "$SERVER" >/dev/null; then
    echo "  Resolves: $SERVER"
elif (( DRY_RUN )); then
    echo "  [DRY RUN] WARNING: $SERVER does not resolve; a real run stops here."
else
    echo "ERROR: $SERVER does not resolve, so mount.cifs would fail with 'could not resolve address'." >&2
    echo "  Pass the server's IP address, or fix name lookup (a .local name needs mDNS)." >&2
    exit 1
fi

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
    if [[ -f "$CRED_FILE" ]]; then
        CRED_BACKUP="${CRED_FILE}.bak.$(date '+%Y%m%d_%H%M%S')"
        cp -- "$CRED_FILE" "$CRED_BACKUP"
        echo "  Backed up to: $CRED_BACKUP"
    fi
    read -r -p "  SMB username for //${SERVER}/${SHARE}: " SMB_USERNAME
    read -r -s -p "  SMB password: " SMB_PASSWORD
    echo ""
    CRED_DIR="$(dirname "$CRED_FILE")"
    mkdir -p -- "$CRED_DIR"
    # Created beside the target, as in replace_fstab_entry: a mv across
    # filesystems is a copy and delete, not an atomic rename.
    CRED_TMP="$(mktemp "${CRED_FILE}.XXXXXX")"
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
build_fstab_line "$SERVER" "$SHARE" "$SUBPATH" "$MOUNTPOINT" "$CRED_FILE" "$TARGET_UID" "$TARGET_GID" "$VERS" "$MOUNT_OPTS"
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
            reload_systemd
        fi
    elif fstab_entry_matches "$FSTAB_PATH" "$MOUNTPOINT_ESCAPED" "$FSTAB_LINE"; then
        echo "  An identical entry for $MOUNTPOINT already exists; no write needed."
    else
        echo "  An entry for $MOUNTPOINT already exists and differs from this run's line (use -f to overwrite)."
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
        reload_systemd
    fi
fi

echo ""
echo "== Step 5/6: mount =="
if (( SKIP_MOUNT )); then
    echo "  Skipped (see above) - run manually once you've reconciled the existing fstab entry: mount \"$MOUNTPOINT\""
elif (( DRY_RUN )); then
    echo "  [DRY RUN] Would run: mount \"$MOUNTPOINT\""
elif mountpoint -q -- "$MOUNTPOINT"; then
    echo "  Already mounted."
else
    if ! mount "$MOUNTPOINT"; then
        echo "  ERROR: mount failed. The credentials file and fstab entry are in place." >&2
        echo "  Fix the cause shown above, then run this script again or: mount \"$MOUNTPOINT\"" >&2
        exit 1
    fi
    echo "  Mounted."
fi

echo ""
echo "== Step 6/6: confirm =="
if (( DRY_RUN )); then
    echo "  [DRY RUN] Would check: mountpoint -q \"$MOUNTPOINT\"; write access for $TARGET_USER; ls -la \"$MOUNTPOINT\""
elif (( SKIP_MOUNT )); then
    echo "  Skipped (mount step skipped above)."
else
    mountpoint -q -- "$MOUNTPOINT" || {
        echo "  WARNING: mount succeeded but $MOUNTPOINT is not a mount point - check manually." >&2
        exit 1
    }
    runuser -u "$TARGET_USER" -- test -w "$MOUNTPOINT" || {
        echo "  WARNING: $TARGET_USER cannot write to $MOUNTPOINT - check the SMB account's permissions on the share." >&2
        exit 1
    }
    echo ""
    ls -la "$MOUNTPOINT"
fi

if (( SKIP_MOUNT )); then
    echo ""
    echo "Not mounted: reconcile the existing fstab entry for $MOUNTPOINT (or rerun with -f), then run this script again." >&2
    exit 1
fi

echo ""
echo "Done. Set NAS_MOUNT to $MOUNTPOINT (environment or config.sh) for media.sh archive."