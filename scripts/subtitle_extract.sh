#!/usr/bin/env bash
# Run this SECOND, after reviewing subtitle_extract_dry.sh's output.
# Same pathing as encoder.sh / subtitle_embed.sh - see subtitle_embed.sh's
# header comment for the -I INPUT_DIR / caller-relative-path note
# (identical here).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./config.sh
source ./config.sh

./subtitle_extract_params.sh -I "$INPUT_DIR" "$@"
