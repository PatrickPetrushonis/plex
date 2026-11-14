#!/usr/bin/env bash
# video_exts.sh: Defines VIDEO_EXTS, the pipe-delimited video file extensions
# every plex script scans for (encoder_params.sh, rename_params.sh,
# scan_subtitle_types.sh). Source, don't run directly.
#
# Adding an extension: add it here; no consumer needs to change.
#
# shellcheck disable=SC2034
# File-wide: VIDEO_EXTS is written here and read by the scripts that source
# this file; shellcheck cannot see across that boundary standalone.

# Include guard: safe to source twice.
[[ -n "${VIDEO_EXTS_LOADED:-}" ]] && return 0
VIDEO_EXTS_LOADED=1

VIDEO_EXTS="mp4|mkv|avi|mov|ts|m4v|wmv|flv|webm|vob|ogv|3gp|mpg|mpeg|divx"
