#!/usr/bin/env bash
# Run this FIRST. Preview only — writes nothing.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./config.sh
source ./config.sh

./encoder_params.sh "${ENCODER_ARGS[@]}" -n "$INPUT_DIR"