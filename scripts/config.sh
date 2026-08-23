#!/usr/bin/env bash
# config.sh — shared by encoder_dry.sh, encoder.sh, rename_dry.sh, and
# rename.sh. Source, don't run directly.
# Override any value at call time, e.g.:
#   VIDEOS_BASE=/mnt/scratch/Videos ./encoder.sh
#   DOWNLOADS_BASE=/mnt/scratch/Downloads ./rename.sh

: "${VIDEOS_BASE:=$HOME/Videos}"
: "${DOWNLOADS_BASE:=$HOME/Downloads}"

# shellcheck disable=SC2034  # consumed by encoder.sh/encoder_dry.sh (which source this file), not used within config.sh itself
INPUT_DIR="$VIDEOS_BASE/input"
OUTPUT_DIR="$VIDEOS_BASE/output"
ARCHIVE_DIR="$VIDEOS_BASE/encoded"
BACKUP_DIR="$VIDEOS_BASE/backup"

# shellcheck disable=SC2034  # consumed by rename.sh/rename_dry.sh (which source this file), not used within config.sh itself
DOWNLOADS_INPUT_DIR="$DOWNLOADS_BASE/Complete"

CRF="${CRF:-22}"
PRESET="${PRESET:-fast}"

# shellcheck disable=SC2034  # consumed by encoder.sh/encoder_dry.sh (which source this file), not used within config.sh itself
ENCODER_ARGS=(-r -s -c "$CRF" -p "$PRESET" -o "$OUTPUT_DIR" -M "$ARCHIVE_DIR" -A "$BACKUP_DIR")