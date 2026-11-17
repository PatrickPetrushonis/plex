#!/usr/bin/env bash
# config.sh: Paths and settings for media.sh. Source, don't run directly.
# VIDEOS_BASE, DOWNLOADS_BASE, CRF, PRESET and INGEST_SETTLE_SECONDS take overrides at call time, e.g.:
#   VIDEOS_BASE=/mnt/scratch/Videos ./media.sh encode
#   DOWNLOADS_BASE=/mnt/scratch/Downloads ./media.sh rename
#   CRF=18 PRESET=slow ./media.sh encode
#   INGEST_SETTLE_SECONDS=0 ./media.sh ingest -n
# The directories below derive from the two base variables; a direct override is ignored.
#
# shellcheck disable=SC2034
# File-wide: INPUT_DIR, UNENCODED_DIR, DOWNLOADS_INPUT_DIR, INGEST_SETTLE_SECONDS and
# ENCODER_ARGS are written here and read by media.sh; shellcheck cannot see across that
# boundary standalone.

: "${VIDEOS_BASE:=$HOME/Videos}"
: "${DOWNLOADS_BASE:=$HOME/Downloads}"

INPUT_DIR="$VIDEOS_BASE/input"
OUTPUT_DIR="$VIDEOS_BASE/output"
ARCHIVE_DIR="$VIDEOS_BASE/encoded"
BACKUP_DIR="$VIDEOS_BASE/backup"
UNENCODED_DIR="$VIDEOS_BASE/unencoded"

DOWNLOADS_INPUT_DIR="$DOWNLOADS_BASE/Complete"

CRF="${CRF:-22}"
PRESET="${PRESET:-fast}"

# Seconds the completed-downloads directory must stay unchanged before ingest
# touches it; 0 skips the check.
INGEST_SETTLE_SECONDS="${INGEST_SETTLE_SECONDS:-60}"

ENCODER_ARGS=(-r -s -c "$CRF" -p "$PRESET" -o "$OUTPUT_DIR" -M "$ARCHIVE_DIR" -A "$BACKUP_DIR")
