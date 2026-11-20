#!/usr/bin/env python3
"""Creates or updates the folder list that starts the label pipeline.

Usage:
    python3 plex_sync_folders.py CSV [--library NAME ...] [--url URL] [--dir PATH]
                                     [-n|--dry-run] [-f|--force] [--log PATH]

Lists the folder of every show in the Plex show libraries (all of them, or the titles
given with --library) and makes CSV match: folders new to the library are added,
folders no longer in it are removed, and rows for folders that are still there are kept
as they are, including any columns after the first. A missing CSV is created with the
header "Plex Folder". Rows are sorted by folder name, ignoring case.

Asking Plex also fills five columns from each item's own match: Plex Title, Plex Original
Title, Plex TMDB ID, Plex TVDB ID, Plex IMDB ID. These are generated: they are rewritten
on every run from what Plex currently says, so correcting a match in Plex (Fix Match)
reaches the label stage on the next sync. The IDs come from the item's Guid entries
(tmdb://, tvdb://, imdb://) or, for a library on the legacy TheTVDB agent, from its guid;
when Plex lists several of one kind the first is used. With --dir there is no Plex
metadata and these columns are left as they are.

--dir PATH lists the sub-directories of PATH instead of asking Plex (for a mounted
share). Names starting with ".", "@" or "#" are skipped (hidden entries, Synology's
"@eaDir" metadata folders and "#recycle").

Nothing is written when the listing is empty, or when it would remove more than half of
the existing rows, unless --force is given: both usually mean the wrong library, a
wrong path or an unmounted share, not a library that really emptied out.

Needs PLEX_TOKEN and PLEX_URL (or --url) unless --dir is used. Exit code 0 on success
(including "nothing to change"), 1 on any error.
"""
import argparse
import csv
import os
import re
import sys
import time

from plex_labels_common import (LIVE, LOG_DIR, atomic_write, close_logging, hold_lock,
                                runtime_since, setup_logging)
from plex_api import (PAGE_SIZE, PlexError, env_token, env_url, find_sections, folder_basename,
                      plex_request, require_credentials)

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
DEFAULT_LOG = os.path.join(LOG_DIR, "plex_sync_folders.log")
FOLDER_COLUMN = "Plex Folder"
SKIP_PREFIXES = (".", "@", "#")
MAX_REMOVE_FRACTION = 0.5
# Generated columns, in order, and the item-info key each holds.
PLEX_COLUMNS = (("Plex Title", "title"), ("Plex Original Title", "original"),
                ("Plex TMDB ID", "tmdb"), ("Plex TVDB ID", "tvdb"), ("Plex IMDB ID", "imdb"))
GUID_PATTERN = re.compile(r"(tmdb|tvdb|imdb)://([A-Za-z0-9]+)$")
LEGACY_TVDB_PATTERN = re.compile(r"com\.plexapp\.agents\.thetvdb://(\d+)")


def parse_guid(guid):
    """Returns (kind, id) for a Plex guid string of the form tmdb://ID, tvdb://ID or
    imdb://ID, or of the legacy TheTVDB agent (com.plexapp.agents.thetvdb://ID?lang=en,
    kind 'tvdb'); None for any other guid."""
    guid = guid or ""
    m = GUID_PATTERN.match(guid)
    if m:
        return m.group(1), m.group(2)
    m = LEGACY_TVDB_PATTERN.match(guid)
    return ("tvdb", m.group(1)) if m else None


def item_info(meta):
    """Returns {"title", "original", "tmdb", "tvdb", "imdb"} for a Plex item's metadata
    dict: its title, original title and the first ID of each kind among its Guid entries
    and its guid ('' where Plex has none)."""
    info = {"title": meta.get("title") or "", "original": meta.get("originalTitle") or "",
            "tmdb": "", "tvdb": "", "imdb": ""}
    for guid in [g.get("id") for g in meta.get("Guid") or []] + [meta.get("guid")]:
        parsed = parse_guid(guid)
        if parsed and not info[parsed[0]]:
            info[parsed[0]] = parsed[1]
    return info


def plex_folders(base_url, token, libraries):
    """Returns (library titles, sorted folder names, info) for the show libraries named in
    libraries (titles), or every show library when libraries is None. info is {folder:
    item_info} (the first item listing a folder wins). An item's own metadata is requested
    only when the listing lacks its Location or its IDs. Raises PlexError on a request
    failure or when no show library matches."""
    sections = [s for s in find_sections(base_url, token, libraries) if s[2] == "show"]
    if not sections:
        raise PlexError("no show library to list (movie libraries are not listed)")
    folders, info = set(), {}
    for key, section_title, _ in sections:
        start = 0
        while True:
            data = plex_request(base_url, token, "GET", f"/library/sections/{key}/all",
                                {"type": 2, "includeGuids": 1, "X-Plex-Container-Start": start,
                                 "X-Plex-Container-Size": PAGE_SIZE})
            mc = data.get("MediaContainer", {})
            page = mc.get("Metadata", [])
            for n, item in enumerate(page, 1):
                LIVE.set(f"Reading {section_title} {start + n}/{mc.get('totalSize', start + len(page))}")
                if "Location" not in item or not (
                        "Guid" in item or parse_guid(item.get("guid"))):
                    detail = plex_request(base_url, token, "GET",
                                          f"/library/metadata/{item['ratingKey']}")
                    item = detail.get("MediaContainer", {}).get("Metadata", [{}])[0]
                names = [folder_basename(loc["path"]) for loc in item.get("Location", [])]
                folders.update(names)
                for name in names:
                    info.setdefault(name, item_info(item))
            start += len(page)
            if not page or start >= mc.get("totalSize", start):
                break
    LIVE.stop()
    return [t for _, t, _ in sections], sorted(folders, key=str.casefold), info


def directory_folders(path):
    """Returns the sorted names of the sub-directories of path, skipping names that
    start with a SKIP_PREFIXES character. Raises OSError when path cannot be listed."""
    with os.scandir(path) as entries:
        names = [e.name for e in entries
                 if e.is_dir() and not e.name.startswith(SKIP_PREFIXES)]
    return sorted(names, key=str.casefold)


def read_csv(path):
    """Returns (header, rows) of an existing CSV, rows being lists. A missing file gives
    ([FOLDER_COLUMN], []). Exits when the first column is not FOLDER_COLUMN."""
    if not os.path.isfile(path):
        return [FOLDER_COLUMN], []
    with open(path, newline="", encoding="utf-8") as f:
        data = list(csv.reader(f))
    if not data or not data[0] or data[0][0] != FOLDER_COLUMN:
        sys.exit(f"ERROR: {path} must start with a header whose first column is "
                 f"{FOLDER_COLUMN!r}")
    return data[0], [r for r in data[1:] if r and r[0].strip()]


def plan(rows, folders):
    """Returns (merged rows, added names, removed names): rows for folders still present
    are kept as they are (first occurrence), new folders get a one-cell row, and the
    result is sorted by folder name ignoring case."""
    present = set(folders)
    kept, seen = [], set()
    for r in rows:
        if r[0] in present and r[0] not in seen:
            kept.append(r)
            seen.add(r[0])
    added = [f for f in folders if f not in seen]
    removed = sorted({r[0] for r in rows} - present, key=str.casefold)
    merged = sorted(kept + [[f] for f in added], key=lambda r: r[0].casefold())
    return merged, added, removed


def apply_info(header, rows, info):
    """Returns (header, rows, changed): header with the PLEX_COLUMNS added when absent, and
    copies of rows padded to it with each row's Plex cells set from info (blank for a
    folder info lacks). changed counts the rows whose Plex cells differ from before."""
    header = list(header)
    for column, _ in PLEX_COLUMNS:
        if column not in header:
            header.append(column)
    spots = [(header.index(column), key) for column, key in PLEX_COLUMNS]
    out, changed = [], 0
    for row in rows:
        before = list(row) + [""] * (len(header) - len(row))
        new = list(before)
        item = info.get(row[0], {})
        for i, key in spots:
            new[i] = item.get(key, "")
        changed += new != before
        out.append(new)
    return header, out, changed


def run(csv_path, base_url, token, libraries, directory, dry_run, force, log_path):
    """Syncs csv_path with the library (or directory) listing and returns the exit
    code (0 or 1)."""
    if directory is None:
        require_credentials(base_url, token)
    header, rows = read_csv(csv_path)
    log = setup_logging(None if dry_run else log_path)
    started = time.monotonic()
    try:
        try:
            info = None
            if directory is None:
                titles, folders, info = plex_folders(base_url, token, libraries)
                where = "libraries " + ", ".join(repr(t) for t in titles)
            else:
                folders = directory_folders(directory)
                where = f"directory {directory}"
        except (PlexError, OSError) as e:
            log.info("ERROR: cannot list folders: %s", e)
            return 1
        log.info("%s%s: %d folders; %s has %d rows", "[DRY RUN] " if dry_run else "", where,
                 len(folders), csv_path, len(rows))
        if not folders:
            log.info("ERROR: the listing is empty; %s left unchanged", csv_path)
            return 1
        merged, added, removed = plan(rows, folders)
        changed = 0
        if info is not None:
            header, merged, changed = apply_info(header, merged, info)
            with_ids = sum(1 for f in folders if any(info.get(f, {}).get(k)
                                                     for k in ("tmdb", "tvdb", "imdb")))
            log.info("Plex has a TMDB, TVDB or IMDB ID for %d of %d folders", with_ids,
                     len(folders))
        for f in added:
            log.info("ADD %s", f)
        for f in removed:
            log.info("REMOVE %s", f)
        if rows and len(removed) > MAX_REMOVE_FRACTION * len(rows) and not force:
            log.info("ERROR: this would remove %d of %d rows; %s left unchanged "
                     "(check the library or path, or use --force)",
                     len(removed), len(rows), csv_path)
            return 1
        created = not os.path.isfile(csv_path)
        if not added and not removed and not created and not changed:
            log.info("Summary: %s already matches (%d folders)", csv_path, len(folders))
            return 0
        if dry_run:
            log.info("Summary: would %s %s: %d added, %d removed, %d with Plex data changed, "
                     "%d total", "create" if created else "update", csv_path, len(added),
                     len(removed), changed, len(merged))
            return 0
        lock = os.path.join(SCRIPT_DIR, ".plex_sync_folders.lock")
        with hold_lock(lock, "ERROR: another plex_sync_folders.py run is in progress"):
            def write(f):
                w = csv.writer(f)
                w.writerow(header)
                w.writerows(merged)
            atomic_write(csv_path, write)
        log.info("Summary: %s %s: %d added, %d removed, %d with Plex data changed, %d total",
                 "created" if created else "updated", csv_path, len(added), len(removed),
                 changed, len(merged))
        return 0
    finally:
        LIVE.stop()
        log.info("Runtime: %s", runtime_since(started))
        close_logging(log)


def main(argv=None):
    p = argparse.ArgumentParser(description="Create or update the Plex folder list CSV.")
    p.add_argument("csv", help="folder list CSV; created when missing")
    p.add_argument("--library", action="append", default=None,
                   help="show library title to list; repeatable (default: all show libraries)")
    p.add_argument("--url", default=env_url())
    p.add_argument("--dir", default=None, dest="directory",
                   help="list the sub-directories of this path instead of asking Plex")
    p.add_argument("-n", "--dry-run", action="store_true", help="report changes; write nothing")
    p.add_argument("-f", "--force", action="store_true",
                   help="allow removing more than half of the existing rows")
    p.add_argument("--log", default=DEFAULT_LOG)
    a = p.parse_args(argv)
    return run(a.csv, a.url, env_token(), a.library, a.directory, a.dry_run, a.force, a.log)


if __name__ == "__main__":
    sys.exit(main())
