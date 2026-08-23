#!/usr/bin/env bash
# Run this SECOND, after reviewing rename_dry.sh's output.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./config.sh
source ./config.sh

./rename_plex.sh -O "$DOWNLOADS_BASE" "$DOWNLOADS_INPUT_DIR"