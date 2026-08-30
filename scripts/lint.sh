#!/usr/bin/env bash
# lint.sh: Runs shellcheck against every script in this repo's scripts/
# directory, installing the tool itself via apt first if it isn't
# already present.
#
# Usage:  ./scripts/lint.sh
#
# Exits non-zero if shellcheck finds anything, so it's usable as a
# pre-commit gate later if wanted — not wired up as one yet, this is
# just the standalone runner.

set -euo pipefail

if ! command -v shellcheck &>/dev/null; then
    echo "shellcheck not found — installing via apt..."
    sudo apt-get update -qq
    sudo apt-get install -y shellcheck
fi

echo "shellcheck $(shellcheck --version | grep version:)"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t SCRIPTS < <(find "$SCRIPT_DIR" -name '*.sh' | sort)

if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
    echo "No .sh files found."
    exit 0
fi

echo "Checking ${#SCRIPTS[@]} script(s):"
printf '  %s\n' "${SCRIPTS[@]}"
echo ""

FAILED=0
for f in "${SCRIPTS[@]}"; do
    echo "=== $f ==="
    file_dir="$(dirname "$f")"
    file_base="$(basename "$f")"
    if ( cd "$file_dir" && shellcheck -x "$file_base" ); then
        echo "  clean"
    else
        FAILED=$(( FAILED + 1 ))
    fi
    echo ""
done

echo "------------------------------------------"
if [[ $FAILED -eq 0 ]]; then
    echo "All ${#SCRIPTS[@]} scripts clean."
else
    echo "$FAILED of ${#SCRIPTS[@]} script(s) have findings — see above."
fi

exit "$FAILED"