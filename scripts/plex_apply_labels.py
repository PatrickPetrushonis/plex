#!/usr/bin/env python3
"""Applies Age and Target labels from a labels CSV to the shows and movies of Plex libraries.

Each CSV row maps a Plex folder name to one Age (Kids/Teen/Adult) and one Target
(Male/Female/Unspecified). The script labels the item whose folder on disk has that name
(a show's folder, or the folder holding a movie's file, or the movie file's name
without extension) with "Age-<value>" and "Target-<value>". Labels that start with "Age-" or
"Target-" but are not the row's values are removed, so a show ends with exactly one
of each. Labels with any other prefix are never touched. The CSV is read-only.
Without --library every show and movie library on the server is searched; --library
(repeatable) restricts the search to the named libraries. A folder name found in
more than one library is reported as ambiguous and skipped.

Usage:
    python3 plex_apply_labels.py LABELS.csv [--library NAME ...] [--url URL]
                                 [-n|--dry-run] [--log PATH]
Environment:
    PLEX_TOKEN   Plex authentication token (required)
    PLEX_URL     server base URL including scheme and port, e.g. http://192.0.2.10:32400
                 (--url overrides; there is no default because the server is not
                 assumed to run on this machine)

Exit codes: 0 every row labeled or already correct; 1 aborted (server unreachable,
bad token, repeated failures, bad input); 2 finished with unmatched rows or failures.
"""
import argparse
import csv
import hashlib
import os
import posixpath
import sys
import time
from contextlib import contextmanager

from plex_labels_common import (ABORT_AFTER_FAILURES, LIVE, LOG_DIR, close_logging, hold_lock,
                                runtime_since, setup_logging)
from plex_api import (PAGE_SIZE, SECTION_TYPE_IDS, PlexError, env_token, env_url,
                      find_sections, folder_basename, plex_request, require_credentials)

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
DEFAULT_LOG = os.path.join(LOG_DIR, "plex_apply_labels.log")

AGE_VALUES = ("Kids", "Teen", "Adult")
TARGET_VALUES = ("Male", "Female", "Unspecified")
AGE_PREFIX = "Age-"
TARGET_PREFIX = "Target-"
OWNED_PREFIXES = (AGE_PREFIX, TARGET_PREFIX)
REQUIRED_COLUMNS = ("Plex Folder", "Age", "Target")



def item_folders(meta, section_type):
    """Returns the folder names an item can be matched by. A show has its Location
    folders; a movie has, for each media file, its parent folder and its file name
    without extension (covers both one-folder-per-movie and flat layouts)."""
    if section_type == "show":
        return [folder_basename(loc["path"]) for loc in meta.get("Location", [])]
    names = []
    for media in meta.get("Media", []):
        for part in media.get("Part", []):
            path = (part.get("file") or "").replace("\\", "/")
            if path:
                names.append(posixpath.basename(posixpath.dirname(path)))
                names.append(os.path.splitext(posixpath.basename(path))[0])
    return names


def list_items(base_url, token, section):
    """Returns every item in section (key, title, type) as dicts: rating_key, title,
    labels (tag strings), folders (see item_folders), section_key, section_title and
    type_id. Makes one metadata request per item for its labels (and for its location
    data when the listing lacks it)."""
    key, title, stype = section
    needed = "Location" if stype == "show" else "Media"
    items, start = [], 0
    while True:
        data = plex_request(
            base_url, token, "GET", f"/library/sections/{key}/all",
            {"type": SECTION_TYPE_IDS[stype], "X-Plex-Container-Start": start,
             "X-Plex-Container-Size": PAGE_SIZE})
        mc = data.get("MediaContainer", {})
        page = mc.get("Metadata", [])
        items.extend(page)
        start += len(page)
        if not page or start >= mc.get("totalSize", start):
            break
    result = []
    for n, it in enumerate(items, 1):
        LIVE.set(f"Reading {title} {n}/{len(items)}")
        # The listing may omit an item's labels, and an item with none looks the same,
        # so the labels always come from the item's own metadata record.
        detail = plex_request(base_url, token, "GET", f"/library/metadata/{it['ratingKey']}")
        full = detail.get("MediaContainer", {}).get("Metadata", [{}])[0]
        meta = it if needed in it else full
        result.append({
            "rating_key": str(it["ratingKey"]),
            "title": it.get("title", ""),
            "labels": [lb.get("tag", "") for lb in full.get("Label", [])],
            "folders": item_folders(meta, stype),
            "section_key": key,
            "section_title": title,
            "type_id": SECTION_TYPE_IDS[stype],
        })
    return result


def list_all(base_url, token, sections):
    """Returns the items of every section in sections, concatenated."""
    return [item for section in sections for item in list_items(base_url, token, section)]


def index_by_folder(shows):
    """Returns (by_folder, ambiguous): by_folder maps a folder name to its single
    item; ambiguous is the set of names that more than one item claims."""
    by_folder, ambiguous = {}, set()
    for show in shows:
        for folder in show["folders"]:
            if folder in by_folder and by_folder[folder] is not show:
                ambiguous.add(folder)
            by_folder[folder] = show
    for folder in ambiguous:
        del by_folder[folder]
    return by_folder, ambiguous


def read_rows(path):
    """Returns (rows, problems): rows is a list of (folder, age, target) with valid
    values, in file order, first occurrence only; problems is a list of
    (folder, reason) for rows that cannot be applied (Undefined, unknown value,
    duplicate). Exits when the header lacks a required column."""
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        missing = [c for c in REQUIRED_COLUMNS if c not in (reader.fieldnames or [])]
        if missing:
            sys.exit(f"ERROR: {path} lacks column(s) {', '.join(missing)}; "
                     f"found header: {','.join(reader.fieldnames or [])}")
        rows, problems, seen = [], [], set()
        for rec in reader:
            folder = (rec["Plex Folder"] or "").strip()
            if not folder:
                continue
            age, target = (rec["Age"] or "").strip(), (rec["Target"] or "").strip()
            if folder in seen:
                problems.append((folder, "duplicate row"))
            elif age not in AGE_VALUES or target not in TARGET_VALUES:
                problems.append((folder, f"not labelable (Age={age!r}, Target={target!r})"))
            else:
                rows.append((folder, age, target))
            seen.add(folder)
    return rows, problems


def plan_changes(current_labels, age, target):
    """Returns (to_remove, to_add) for one show: owned-prefix labels that are not the
    wanted ones, and wanted labels the show lacks. Other labels are ignored."""
    wanted = {AGE_PREFIX + age, TARGET_PREFIX + target}
    to_remove = [lb for lb in current_labels if lb.startswith(OWNED_PREFIXES) and lb not in wanted]
    to_add = sorted(wanted - set(current_labels))
    return to_remove, to_add


def apply_labels(base_url, token, item, to_remove, to_add, dry_run):
    """Removes then adds labels on one item (add locks the label field). Makes no
    request when dry_run is true. Raises PlexError on a failed request."""
    if dry_run:
        return
    path = f"/library/sections/{item['section_key']}/all"
    base = {"type": item["type_id"], "id": item["rating_key"]}
    if to_remove:
        plex_request(base_url, token, "PUT", path,
                     {**base, "label[].tag.tag-": ",".join(to_remove)})
    if to_add:
        params = {**base, "label.locked": 1}
        for i, label in enumerate(to_add):
            params[f"label[{i}].tag.tag"] = label
        plex_request(base_url, token, "PUT", path, params)


@contextmanager
def exclusive_lock(base_url, scope):
    """Holds a lock scoped to this server URL and scope (the library keys being
    labeled), so a second run over the same libraries exits while runs over others
    proceed. See hold_lock."""
    key = f"{base_url.rstrip('/')}|{scope}"
    digest = hashlib.sha256(key.encode()).hexdigest()[:16]
    lock_path = os.path.join(SCRIPT_DIR, f".plex_apply_labels_{digest}.lock")
    busy = f"ERROR: another run is already labeling libraries {scope} on {base_url}"
    with hold_lock(lock_path, busy):
        yield


def run(csv_path, base_url, token, libraries, dry_run, log_path):
    """Labels the libraries (titles, or None for all show and movie libraries) from
    csv_path and returns the exit code (0, 1 or 2).

    Counters: labeled (changes made or, in dry-run, needed), unchanged (already
    correct), not_found (CSV folder absent from Plex), ambiguous (folder claimed by
    several shows), skipped (CSV rows not labelable), failed (request errors),
    verify_mismatch (items whose labels differ from the plan after applying)."""
    if not os.path.isfile(csv_path):
        sys.exit(f"ERROR: labels file not found: {csv_path}")
    require_credentials(base_url, token)
    rows, problems = read_rows(csv_path)
    if not rows:
        sys.exit(f"ERROR: no labelable rows in {csv_path}")
    log = setup_logging(log_path)
    started = time.monotonic()
    try:
        return _run(log, rows, problems, base_url, token, libraries, dry_run)
    finally:
        LIVE.stop()
        log.info("Runtime: %s", runtime_since(started))
        close_logging(log)


def _run(log, rows, problems, base_url, token, libraries, dry_run):
    """Body of run once logging exists; see run for counters and return codes."""
    try:
        sections = find_sections(base_url, token, libraries)
    except PlexError as e:
        log.info(f"ERROR: {e}")
        return 1
    with exclusive_lock(base_url, ",".join(sorted(key for key, _, _ in sections))):
        try:
            shows = list_all(base_url, token, sections)
        except PlexError as e:
            log.info(f"ERROR: cannot list libraries: {e}")
            return 1
        by_folder, ambiguous = index_by_folder(shows)
        mode = "DRY RUN" if dry_run else "APPLY"
        log.info(f"{mode}: libraries {', '.join(repr(t) for _, t, _ in sections)}, "
                 f"{len(shows)} items, {len(rows)} labelable rows")
        counts = dict(labeled=0, unchanged=0, not_found=0, ambiguous=0,
                      skipped=len(problems), failed=0, verify_mismatch=0)
        for folder, reason in problems:
            log.info(f"SKIP {folder}: {reason}")
        expected, consecutive = {}, 0
        for n, (folder, age, target) in enumerate(rows, 1):
            LIVE.set(f"Labeling {n}/{len(rows)}")
            if folder in ambiguous:
                counts["ambiguous"] += 1
                log.info(f"AMBIGUOUS {folder}: more than one item uses this folder name")
                continue
            show = by_folder.get(folder)
            if show is None:
                counts["not_found"] += 1
                log.info(f"NOT FOUND {folder}: no item in the searched libraries has this folder name")
                continue
            to_remove, to_add = plan_changes(show["labels"], age, target)
            if not to_remove and not to_add:
                counts["unchanged"] += 1
                log.info(f"OK {folder}: already Age-{age}, Target-{target}")
                expected[show["rating_key"]] = (age, target)
                continue
            try:
                apply_labels(base_url, token, show, to_remove, to_add, dry_run)
            except PlexError as e:
                counts["failed"] += 1
                consecutive += 1
                log.info(f"FAILED {folder}: {e}")
                if consecutive >= ABORT_AFTER_FAILURES:
                    log.info(f"ABORT: {consecutive} consecutive failures; summary below is partial")
                    _summary(log, counts, dry_run)
                    return 1
                continue
            consecutive = 0
            counts["labeled"] += 1
            expected[show["rating_key"]] = (age, target)
            log.info(f"{'WOULD LABEL' if dry_run else 'LABELED'} {folder} "
                     f"[{show['section_title']}]: +{to_add} -{to_remove}")
        if not dry_run:
            counts["verify_mismatch"] = _verify(log, base_url, token, sections, expected)
        _summary(log, counts, dry_run)
    bad = (counts["not_found"] + counts["ambiguous"] + counts["skipped"]
           + counts["failed"] + counts["verify_mismatch"])
    return 2 if bad else 0


def _verify(log, base_url, token, sections, expected):
    """Re-reads the libraries and returns how many items in expected (rating_key ->
    (age, target)) do not now carry exactly their Age and Target labels."""
    try:
        shows = {s["rating_key"]: s for s in list_all(base_url, token, sections)}
    except PlexError as e:
        log.info(f"VERIFY FAILED: cannot re-read libraries: {e}")
        return len(expected)
    mismatches = 0
    for key, (age, target) in expected.items():
        show = shows.get(key)
        to_remove, to_add = plan_changes(show["labels"], age, target) if show else ([], ["?"])
        if to_remove or to_add:
            mismatches += 1
            log.info(f"VERIFY MISMATCH {show['title'] if show else key}: "
                     f"missing {to_add}, extra {to_remove}")
    return mismatches


def _summary(log, counts, dry_run):
    """Stops the live status line and prints each counter with what it means."""
    LIVE.stop()
    log.info("SUMMARY")
    log.info(f"  {counts['labeled']:4d} {'need labels (dry run, nothing changed)' if dry_run else 'labeled'}")
    log.info(f"  {counts['unchanged']:4d} already correct")
    log.info(f"  {counts['not_found']:4d} CSV folders not found in Plex")
    log.info(f"  {counts['ambiguous']:4d} folders claimed by more than one item")
    log.info(f"  {counts['skipped']:4d} CSV rows skipped (Undefined, unknown value or duplicate)")
    log.info(f"  {counts['failed']:4d} request failures")
    log.info(f"  {counts['verify_mismatch']:4d} items whose labels differ after applying")


def main(argv=None):
    p = argparse.ArgumentParser(description="Apply Age/Target labels to Plex show and movie libraries.")
    p.add_argument("csv", help="labels CSV with Plex Folder, Age, Target columns")
    p.add_argument("--library", action="append", default=None,
                   help="library title to search; repeatable (default: all show and movie libraries)")
    p.add_argument("--url", default=env_url())
    p.add_argument("-n", "--dry-run", action="store_true", help="report changes; modify nothing")
    p.add_argument("--log", default=DEFAULT_LOG)
    a = p.parse_args(argv)
    return run(a.csv, a.url, env_token(), a.library, a.dry_run, a.log)


if __name__ == "__main__":
    sys.exit(main())
