#!/usr/bin/env bash
# Run this SECOND, after reviewing subtitle_embed_dry.sh's output.
#
# Same pathing as encoder.sh: cd into this script's own directory, then
# source ./config.sh and call the params script by relative path. Unlike
# encoder_params.sh (which only ever receives config.sh's own $INPUT_DIR,
# never a caller-typed path), subtitle_embed_params.sh takes a
# user-supplied <video>/<srt> argument that's naturally relative to
# wherever the caller was standing - after this cd, a relative path like
# "movie.mkv" resolves against THIS directory, not the caller's. -I
# "$INPUT_DIR" (below) covers the common case regardless: a bare filename
# that lives under INPUT_DIR still resolves via that fallback, since
# INPUT_DIR is absolute and unaffected by the cd. What this cd does give
# up is a relative path to a file outside INPUT_DIR (e.g. "cd
# ~/Downloads && subtitle_embed.sh clip.mkv") - use an absolute path for
# that case - a relative path only resolves against this directory, not the caller's.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./config.sh
source ./config.sh

./subtitle_embed_params.sh -I "$INPUT_DIR" "$@"
