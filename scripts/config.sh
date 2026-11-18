#!/usr/bin/env bash
# config.sh: Paths and settings for media.sh. Source, don't run directly.
# VIDEOS_BASE, DOWNLOADS_BASE, NAS_MOUNT, CRF, PRESET, TUNE, MAX_COPY_KBPS,
# INGEST_SETTLE_SECONDS and ARCHIVE_SETTLE_SECONDS take overrides at call time, e.g.:
#   VIDEOS_BASE=/mnt/scratch/Videos ./media.sh encode
#   DOWNLOADS_BASE=/mnt/scratch/Downloads ./media.sh rename
#   NAS_MOUNT=/mnt/other/plexmedia ./media.sh archive -n
#   CRF=18 PRESET=slow ./media.sh encode
#   TUNE=animation MAX_COPY_KBPS=0 ./media.sh encode
#   INGEST_SETTLE_SECONDS=0 ./media.sh ingest -n
# The directories below derive from the three base variables; a direct override is ignored.
#
# shellcheck disable=SC2034
# File-wide: INPUT_DIR, UNENCODED_DIR, DOWNLOADS_INPUT_DIR, NAS_ARCHIVE_DIR,
# INGEST_SETTLE_SECONDS, ARCHIVE_SETTLE_SECONDS and ENCODER_ARGS are written here and
# read by media.sh; shellcheck cannot see across that boundary standalone.

: "${VIDEOS_BASE:=$HOME/Videos}"
: "${DOWNLOADS_BASE:=$HOME/Downloads}"
# Mount point of the NAS share (see nas_setup_mount.sh). The share root, not a
# subpath: nas_setup_mount.sh refuses a "#" in a subpath, so the "#archive"
# folder name is added below instead.
: "${NAS_MOUNT:=/mnt/nas/plexmedia}"

INPUT_DIR="$VIDEOS_BASE/input"
OUTPUT_DIR="$VIDEOS_BASE/output"
ARCHIVE_DIR="$VIDEOS_BASE/encoded"
BACKUP_DIR="$VIDEOS_BASE/backup"
UNENCODED_DIR="$VIDEOS_BASE/unencoded"

DOWNLOADS_INPUT_DIR="$DOWNLOADS_BASE/Complete"

# NAS folder that archive.sh fills from $ARCHIVE_DIR.
NAS_ARCHIVE_DIR="$NAS_MOUNT/#archive"

CRF="${CRF:-20}"
PRESET="${PRESET:-slow}"

# x264 -tune value; empty passes none. animation suits anime and other 2D
# animation with flat textures; 3D animation and live action suit film or none.
TUNE="${TUNE:-}"

# An h264 source whose overall bitrate (kb/s, audio included) is above this is
# re-encoded instead of copied, so Blu-ray remuxes shrink; 0 always copies.
MAX_COPY_KBPS="${MAX_COPY_KBPS:-8000}"

# Seconds the completed-downloads directory must stay unchanged before ingest
# touches it; 0 skips the check.
INGEST_SETTLE_SECONDS="${INGEST_SETTLE_SECONDS:-60}"

# Seconds a file in $ARCHIVE_DIR must have gone unmodified before archive moves it,
# so a copy encode.sh -M is still writing is not picked up; 0 skips the check.
ARCHIVE_SETTLE_SECONDS="${ARCHIVE_SETTLE_SECONDS:-60}"

ENCODER_ARGS=(-r -s -c "$CRF" -p "$PRESET" -K "$MAX_COPY_KBPS" -o "$OUTPUT_DIR" -M "$ARCHIVE_DIR" -A "$BACKUP_DIR")
[[ -z "$TUNE" ]] || ENCODER_ARGS+=(-T "$TUNE")
