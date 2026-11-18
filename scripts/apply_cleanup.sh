#!/usr/bin/env bash
# apply_cleanup.sh: Apply scripts_cleanup_plan.md: rename eight scripts to the
# domain_verb_noun scheme, move the label cache JSON files to ../data/cache, and
# update every reference. Run from the repo's scripts/ directory. Edits and moves
# only; no commit.
#
# Usage:  ./apply_cleanup.sh
#
# Exit codes: 0 done, 1 failed.
set -euo pipefail

[[ "$(basename "$PWD")" == "scripts" ]] || { echo "ERROR: run from the scripts/ directory" >&2; exit 1; }

RENAMES=(
    "plex_sync_folders.py:plex_sync_folders.py"
    "plex_get_labels.py:plex_get_labels.py"
    "plex_apply_labels.py:plex_apply_labels.py"
    "plex_labels_common.py:plex_labels_common.py"
    "subtitle_strip_tags.py:subtitle_strip_tags.py"
    "subtitle_scan_types.sh:subtitle_scan_types.sh"
    "nas_setup_mount.sh:nas_setup_mount.sh"
    "systemd_install_units.sh:systemd_install_units.sh"
)

# Rename first: git mv fails before any text is edited if a file is missing or untracked.
for pair in "${RENAMES[@]}"; do
    git mv -- "${pair%%:*}" "${pair##*:}"
done

# Files whose text is edited. Logs are excluded: they are records, not references.
# Expanded after the renames so the globs see the new names.
TARGETS=(./*.sh ./*.py ../README.md)

# Path edits come first, while the old names still match inside the files.
# 1. The two cache files live in ../data/cache, not beside the script.
sed -i \
    -e 's|os\.path\.join(SCRIPT_DIR, "plex_get_labels_cache\.json")|os.path.join(os.path.dirname(SCRIPT_DIR), "data", "cache", "plex_get_labels_cache.json")|' \
    -e 's|os\.path\.join(SCRIPT_DIR, "plex_get_labels_idmap\.json")|os.path.join(os.path.dirname(SCRIPT_DIR), "data", "cache", "plex_get_labels_idmap.json")|' \
    -e 's|plex_get_labels_idmap\.json next to this script|data/cache/plex_get_labels_idmap.json|' \
    -e 's|plex_get_labels_cache\.json next to this script|data/cache/plex_get_labels_cache.json|' \
    plex_get_labels.py
sed -i \
    -e 's|`plex_get_labels_idmap\.json` next to the scripts|`plex_get_labels_idmap.json` in `data/cache/`|' \
    -e 's|`plex_get_labels_cache\.json` next to the scripts|`plex_get_labels_cache.json` in `data/cache/`|' \
    ../README.md

# 2. Token rename across every reference (file names, module name, log and lock names).
sed -i \
    -e 's/\bsync_plex_folders/plex_sync_folders/g' \
    -e 's/\bget_plex_labels/plex_get_labels/g' \
    -e 's/\bapply_plex_labels/plex_apply_labels/g' \
    -e 's/\blabels_common/plex_labels_common/g' \
    -e 's/\bstrip_subtitle_tags/subtitle_strip_tags/g' \
    -e 's/\bscan_subtitle_types/subtitle_scan_types/g' \
    -e 's/\bsetup_smb_mount/nas_setup_mount/g' \
    -e 's/\binstall_units/systemd_install_units/g' \
    "${TARGETS[@]}"

# 2b. Re-align the README tree: the description column starts after a 28-wide name field.
python3 -I - ../README.md <<'PY'
import re, sys
path = sys.argv[1]
out = []
for line in open(path, encoding="utf-8").read().split("\n"):
    m = re.match(r"^(    [├└]── )(\S+)\s+(\S.*)$", line)
    if m:
        name = m.group(2)
        line = m.group(1) + (name.ljust(28) if len(name) < 28 else name + "  ") + m.group(3)
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out))
PY

# 3. Move the generated JSON files, keeping them so no lookup is repeated.
mkdir -p -- ../data/cache
for name in cache idmap; do
    src="plex_get_labels_${name}.json"
    [[ -e "$src" ]] || continue
    if git ls-files --error-unmatch -- "$src" >/dev/null 2>&1; then
        git rm -q --cached -- "$src"
    fi
    mv -- "$src" "../data/cache/plex_get_labels_${name}.json"
done

# 4. .gitignore: replace the two old JSON entries with the directory.
if [[ -f ../.gitignore ]]; then
    sed -i '/^plex_get_labels_\(cache\|idmap\)\.json$/d' ../.gitignore
    grep -qxF 'data/cache/' ../.gitignore || echo 'data/cache/' >> ../.gitignore
fi

echo "Done. Remaining old names (expect none):"
grep -rnE '\b(plex_sync_folders|plex_get_labels|plex_apply_labels|plex_labels_common|subtitle_strip_tags|subtitle_scan_types|nas_setup_mount|systemd_install_units)' .. \
    --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=logs || true