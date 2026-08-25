#!/usr/bin/env bash
# Run this FIRST. Preview only — nothing is renamed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./config.sh
source ./config.sh

# Passed as -O's base, not the log dir directly: rename_params.sh appends
# /Logs and /.locks itself, so this becomes $DOWNLOADS_BASE/Logs and
# $DOWNLOADS_BASE/.locks — passing ".../Logs" here would have doubled up
# into ".../Logs/Logs".
./rename_params.sh -n -O "$DOWNLOADS_BASE" "$DOWNLOADS_INPUT_DIR"