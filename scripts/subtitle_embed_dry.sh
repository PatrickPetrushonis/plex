#!/usr/bin/env bash
# Run this FIRST - preview only, nothing is written.
# Same pathing as subtitle_embed.sh; see that file for the -I INPUT_DIR /
# caller-relative-path note (identical here). Only difference: -n forced on.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./config.sh
source ./config.sh

./subtitle_embed_params.sh -I "$INPUT_DIR" -n "$@"
