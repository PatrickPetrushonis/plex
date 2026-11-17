#!/usr/bin/env bash
# install_units.sh: Write the systemd user units that run `media.sh ingest` on
#                   a timer. Prints the commands that enable the timer; does
#                   not run them.
#
# Usage:  ./install_units.sh [OPTIONS]
#
# Options:
#   -i MINUTES      Minutes from the end of one ingest run to the start of the
#                   next (default: 5)
#   -f              Overwrite existing unit files instead of leaving them in
#                   place (default: off)
#   -n              Dry run: print what would be written, write nothing
#   -h              Show this help
#
# Writes, under $HOME/.config/systemd/user:
#   media_ingest.service   Runs <this directory>/media.sh ingest once
#   media_ingest.timer     Starts the service 2 minutes after the user manager
#                          starts, then -i minutes after each run ends
#
# Notes:
#   • Refuses to run as root: the units belong to the user whose files they move
#   • Takes no lock: it is a short, single provisioning run
#   • The units hold this directory's absolute path, so the scripts directory
#     is not moved afterward without running this again with -f
#   • The service exits 2 when ingest needs a decision, which systemd reports
#     as a failed unit: `systemctl --user --failed` lists it, and
#     $DOWNLOADS_BASE/Logs/Ingest_review.txt says why

set -euo pipefail

# Bash version guard
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

# The units belong to the user whose files they move; under sudo they would
# land in root's home.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, these are user units." >&2
    exit 1
fi

# Defaults
DRY_RUN=0
FORCE=0
INTERVAL_MINUTES=5

# Usage
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' || true
    exit 0
}

# Arg parsing
while getopts ":i:fnh" opt; do
    case $opt in
        i) INTERVAL_MINUTES="$OPTARG" ;;
        f) FORCE=1 ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))
[[ $# -eq 0 ]] || { echo "Usage: $0 [OPTIONS]" >&2; exit 1; }
[[ "$INTERVAL_MINUTES" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: -i takes a whole number of minutes, 1 or more, got '$INTERVAL_MINUTES'." >&2
    exit 1
}

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "${SCRIPTS_DIR}/media.sh" ]] || {
    echo "ERROR: media.sh not found or not executable in ${SCRIPTS_DIR}" >&2
    exit 1
}

# A path with whitespace, a specifier character (%), a variable character ($),
# a quote or a backslash would be split or rewritten when systemd parses the
# ExecStart line, so such a path is refused instead of written wrong.
UNSAFE_PATH_CHARS='[[:space:]%$"\\]'
if [[ "$SCRIPTS_DIR" =~ $UNSAFE_PATH_CHARS ]]; then
    printf 'ERROR: %s contains whitespace or one of %% $ " \\ ; systemd would misread it in ExecStart.\n' "'$SCRIPTS_DIR'" >&2
    exit 1
fi

UNIT_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${UNIT_DIR}/media_ingest.service"
TIMER_FILE="${UNIT_DIR}/media_ingest.timer"

# Prints the service unit. Sets nothing.
service_text() {
    cat <<EOF
[Unit]
Description=Rename completed downloads and move them to the holding directory

[Service]
Type=oneshot
ExecStart=${SCRIPTS_DIR}/media.sh ingest
EOF
}

# Prints the timer unit. OnStartupSec counts from the start of the user manager,
# OnUnitInactiveSec from the end of the previous service run. Sets nothing.
timer_text() {
    cat <<EOF
[Unit]
Description=Run media_ingest.service periodically

[Timer]
OnStartupSec=2min
OnUnitInactiveSec=${INTERVAL_MINUTES}min

[Install]
WantedBy=timers.target
EOF
}

# Writes one unit file, or previews it, applying the collision policy: an
# existing file is left in place unless -f was given. Checks the dry-run flag
# itself. Sets nothing. Arguments: path, name of the function that prints the
# text.
write_unit() {
    local path="$1" text_fn="$2"
    if [[ -e "$path" && $FORCE -eq 0 ]]; then
        echo "SKIPPING (already exists, use -f to overwrite): $path"
        return 0
    fi
    if (( DRY_RUN )); then
        echo "[DRY RUN] Would write: $path"
        "$text_fn" | sed 's/^/    /'
        return 0
    fi
    "$text_fn" > "$path"
    echo "Wrote: $path"
}

if (( DRY_RUN )); then
    echo "[DRY RUN] install_units.sh"
else
    mkdir -p -- "$UNIT_DIR"
fi
write_unit "$SERVICE_FILE" service_text
write_unit "$TIMER_FILE" timer_text

cat <<EOF

To enable (not run by this script):
  systemctl --user daemon-reload
  systemctl --user enable --now media_ingest.timer

To check:
  systemctl --user list-timers media_ingest.timer
  journalctl --user -u media_ingest.service

User timers stop when the last session ends unless lingering is enabled for the
user: sudo loginctl enable-linger "\$USER"
EOF
