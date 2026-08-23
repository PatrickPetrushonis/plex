#!/usr/bin/env bash
# Run this SECOND, after reviewing encoder_dry.sh's output.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./config.sh
source ./config.sh

./encoder_params.sh "${ENCODER_ARGS[@]}" "$INPUT_DIR"