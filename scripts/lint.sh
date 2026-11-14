#!/usr/bin/env bash
# lint.sh: Checks every script in this repo's scripts/ directory: runs
# shellcheck against each .sh file (installing the tool itself via apt first
# if it isn't already present) and a syntax check against each .py file
# (Python's own compiler, no extra packages; nothing is written to disk).
#
# Usage:  ./scripts/lint.sh
#
# Exits non-zero if any file has findings, so it's usable as a
# pre-commit gate later if wanted — not wired up as one yet, this is
# just the standalone runner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t SHELL_SCRIPTS < <(find "$SCRIPT_DIR" -name '*.sh' | sort)
mapfile -t PY_SCRIPTS < <(find "$SCRIPT_DIR" -name '*.py' -not -path '*/__pycache__/*' | sort)

if [[ ${#SHELL_SCRIPTS[@]} -eq 0 && ${#PY_SCRIPTS[@]} -eq 0 ]]; then
    echo "No .sh or .py files found."
    exit 0
fi

FAILED=0

# -- Shell: shellcheck ------------------------------------------------------------
if [[ ${#SHELL_SCRIPTS[@]} -gt 0 ]]; then
    if ! command -v shellcheck &>/dev/null; then
        echo "shellcheck not found — installing via apt..."
        sudo apt-get update -qq
        sudo apt-get install -y shellcheck
    fi

    echo "shellcheck $(shellcheck --version | grep version:)"
    echo ""
    echo "Checking ${#SHELL_SCRIPTS[@]} shell script(s):"
    printf '  %s\n' "${SHELL_SCRIPTS[@]}"
    echo ""

    for f in "${SHELL_SCRIPTS[@]}"; do
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
fi

# -- Python: syntax check ---------------------------------------------------------
if [[ ${#PY_SCRIPTS[@]} -gt 0 ]]; then
    command -v python3 &>/dev/null || { echo "ERROR: 'python3' not found on PATH" >&2; exit 1; }

    echo "Checking ${#PY_SCRIPTS[@]} Python script(s):"
    printf '  %s\n' "${PY_SCRIPTS[@]}"
    echo ""

    for f in "${PY_SCRIPTS[@]}"; do
        echo "=== $f ==="
        # compile() parses without importing the module or writing bytecode.
        if python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f"; then
            echo "  clean"
        else
            FAILED=$(( FAILED + 1 ))
        fi
        echo ""
    done
fi

TOTAL=$(( ${#SHELL_SCRIPTS[@]} + ${#PY_SCRIPTS[@]} ))
echo "------------------------------------------"
if [[ $FAILED -eq 0 ]]; then
    echo "All $TOTAL file(s) clean."
else
    echo "$FAILED of $TOTAL file(s) have findings — see above."
fi

exit "$FAILED"
