#!/usr/bin/env bash
# media_progress.sh: Spinner, elapsed time and countdown for steps that print
# nothing while they work. Sourced by the pipeline scripts; not run directly.
#
# Functions:
#   spin_until_exit PID [LABEL [DELAY]]   Spinner with elapsed time until PID exits
#   progress_run LABEL COMMAND [ARG...]   Runs COMMAND in the foreground under a spinner
#   progress_countdown SECONDS LABEL      Sleeps SECONDS with the time left shown; a key press
#                                         ends it early and sets PROGRESS_SKIPPED=1
#   format_runtime SECONDS                Prints SECONDS as "<m>m <s>s"
#
# Notes:
#   • Drawing happens only when stderr was a terminal at the moment this file
#     was sourced and /dev/tty can be written (PROGRESS_ENABLED=1). A callback,
#     a cron job or a redirected run draws nothing, so logs never hold
#     carriage returns. The frames go to /dev/tty, so a caller that redirects
#     the command's stdout and stderr to a file does not capture them
#   • Source this file before any redirection of the script's own stderr
#   • A spinner started by progress_run holds none of the lock descriptors
#     (3 to 9) the pipeline scripts use and none of the command's output pipe,
#     so a caller that captures the output with $(...) or <(...) sees it end
#     the moment the command does. It stops by itself within one second when
#     the script that started it is gone
#   • Do not wrap a command that prints to the terminal itself; its output and
#     the spinner line would overwrite each other

# 1 when frames can be drawn, 0 otherwise. Decided once, here.
PROGRESS_ENABLED=0
if [[ -t 2 ]] && { : > /dev/tty; } 2>/dev/null; then
    PROGRESS_ENABLED=1
fi

# Width of the line a frame may occupy, one less than the terminal so the
# cursor never wraps. 80 when the terminal's width is unknown.
PROGRESS_WIDTH=79
if (( PROGRESS_ENABLED )); then
    PROGRESS_COLUMNS="$(tput cols 2>/dev/null)" || PROGRESS_COLUMNS=""
    if [[ "$PROGRESS_COLUMNS" =~ ^[0-9]+$ ]] && (( PROGRESS_COLUMNS > 20 )); then
        PROGRESS_WIDTH=$(( PROGRESS_COLUMNS - 1 ))
    fi
fi

# 1 when the last progress_countdown ended on a key press, 0 when it ran its full time.
PROGRESS_SKIPPED=0

# Seconds the last progress_run command took. Set by progress_run in the
# calling shell; a call inside $(...) or a process substitution does not
# change it for the caller.
PROGRESS_ELAPSED=0

# Draws one frame: spinner character, mm:ss and an optional label, cut to the
# terminal width. Arguments: frame index (0-3), elapsed seconds, label. Writes
# to /dev/tty only.
progress_frame() {
    local frame="$1" elapsed="$2" label="${3:-}" chars='|/-\' text
    printf -v text ' %s  %02d:%02d elapsed' "${chars:frame:1}" "$(( elapsed / 60 ))" "$(( elapsed % 60 ))"
    [[ -z "$label" ]] || text+="  ${label}"
    printf '\r%s\033[K' "${text:0:PROGRESS_WIDTH}" > /dev/tty
}

# Erases the progress line. Writes to /dev/tty only.
progress_clear() {
    printf '\r\033[K' > /dev/tty
}

# Draws a spinner and the elapsed time, redrawn once a second, until the
# process PID exits, then clears the line. It neither waits for the process nor
# reads its status; the caller does both with `wait`. Nothing is drawn for the
# first DELAY seconds, so a step that finishes sooner shows nothing. Returns at
# once when PROGRESS_ENABLED is 0. Arguments: pid, optional label, optional
# delay in seconds (default 0).
spin_until_exit() {
    local pid="$1" label="${2:-}" delay="${3:-0}"
    local frame=0 start="$SECONDS" elapsed=0 drawn=0
    (( PROGRESS_ENABLED )) || return 0
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$(( SECONDS - start ))
        if (( elapsed >= delay )); then
            progress_frame "$frame" "$elapsed" "$label"
            drawn=1
        fi
        frame=$(( (frame + 1) % 4 ))
        sleep 1
    done
    (( ! drawn )) || progress_clear
}

# Runs COMMAND in the foreground, with a spinner, the elapsed time and LABEL
# drawn beside it once it has run for a second. COMMAND keeps this function's
# stdin, stdout and stderr, so a caller can redirect or capture them. Returns
# COMMAND's exit status and sets PROGRESS_ELAPSED. Safe under set -e when called
# as `progress_run ... || handler`. Arguments: label, then the command.
progress_run() {
    local label="$1" rc=0 start="$SECONDS" spinner_pid=""
    shift
    if (( PROGRESS_ENABLED )); then
        spin_until_exit "$$" "$label" 1 < /dev/null > /dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
        spinner_pid=$!
    fi
    "$@" || rc=$?
    if [[ -n "$spinner_pid" ]]; then
        kill "$spinner_pid" 2>/dev/null || true
        wait "$spinner_pid" 2>/dev/null || true
        progress_clear
    fi
    PROGRESS_ELAPSED=$(( SECONDS - start ))
    return "$rc"
}

# Sleeps SECONDS, showing the time left, LABEL and the skip hint once a second when
# PROGRESS_ENABLED is 1; a plain sleep otherwise. On a terminal any key press ends the
# wait at once and sets PROGRESS_SKIPPED=1 (0 otherwise); with no terminal nothing can
# skip it. Arguments: whole seconds, label.
progress_countdown() {
    local total="$1" label="$2" left text key rc
    PROGRESS_SKIPPED=0
    if (( ! PROGRESS_ENABLED )); then
        sleep "$total"
        return 0
    fi
    for (( left = total; left > 0; left-- )); do
        printf -v text ' %02d:%02d left  %s  (press any key to skip)' "$(( left / 60 ))" "$(( left % 60 ))" "$label"
        printf '\r%s\033[K' "${text:0:PROGRESS_WIDTH}" > /dev/tty
        # read waits up to a second for a key: status 0 is a key, above 128 is the
        # timeout, anything else means the terminal cannot be read, so sleep instead.
        rc=0
        read -rsn1 -t 1 key < /dev/tty 2> /dev/null || rc=$?
        if (( rc == 0 )); then
            PROGRESS_SKIPPED=1
            break
        elif (( rc <= 128 )); then
            sleep 1
        fi
    done
    progress_clear
}

# Prints SECONDS as "<m>m <s>s", the form media_encode.sh uses for its runtime.
# Argument: whole seconds.
format_runtime() {
    printf '%sm %ss' "$(( $1 / 60 ))" "$(( $1 % 60 ))"
}