#!/usr/bin/env python3
"""Chooses the category folder for one ingested entry.

Usage:
    python3 media_classify.py -E EXTS [-C OVERRIDES] [-L FOLDERS_CSV] [--cache PATH] [--] ENTRY

ENTRY is a top-level folder of the ingest source directory after media_rename.sh has run: a
show folder ("Series (YYYY)/Season XX/Series - SxxEyy.ext") or a movie folder ("Title/Title
(YYYY)/Title (YYYY).ext"). One line is printed, "<first field><TAB><reason>", and the exit
code says what the first field is:
    0  a category folder name
    2  HOLD: a person must decide; the reason says why
    3  DEFER: a lookup could not complete (network or service error); the next run retries
    1  ERROR: bad usage, bad input files or a missing tool; the reason says why
-E is the video_exts.sh extension list ("mp4|mkv|..."). A missing -C or -L file is treated as
empty: no overrides, no library titles (a warning on stderr for a -L path that is missing).

Categories: "Anime - Movies", "Anime - Series", "Anime - Series Movies", "Anime - Shorts",
"Movies", "Series", "Series Movies", "Shorts". "Anime" means animation of any origin. The same
eight names are listed in media_categories.sh, which media_ingest.sh checks the answer
against.

Rules, first match wins:
  1. Overrides. -C is a tab-separated file: "Title (YYYY)", a tab, a category. Case and
     punctuation are ignored; a line without a year matches any year. Lines starting with #
     and blank lines are skipped. It applies to the show folder's name and to each movie's
     "Title (YYYY)" name.
  2. Series or movie. An entry with an SxxEyy token in a video file name is a series; any
     other is a movie. A folder holding several movies is classified movie by movie and must
     agree, or it is held.
  3. Animation or live action, from TMDB. A show or movie with the Animation genre (id 16) is
     animation, except that a title carrying an animation/live-action hybrid keyword
     (HYBRID_KEYWORDS) is decided by its US rating: G or PG (TV-Y, TV-Y7, TV-Y7-FV, TV-G,
     TV-PG) animation; PG-13, R or NC-17 (TV-14, TV-MA) live action; any other value, or none,
     is held. A movie's US rating is its theatrical certification, else the first other US
     one. A series is matched by its Plex TMDB ID when -L lists the folder, else by a title
     and first-air-year search that must find exactly one show; a movie by a title search in
     its year (then a year either side) that must find exactly one movie.
  4. A movie shorter than SHORT_SECONDS by ffprobe (its longest video file) is a short.
  5. A movie whose title begins, word for word, with the title of a show in -L, and is longer
     than it, is a series movie.
  6. Otherwise a movie.

Needs the TMDB_API_KEY environment variable (the key plex_labels.sh uses) and ffprobe. Finished
TMDB lookups are cached in --cache (default data/cache/media_classify_cache.json); a search
that finds nothing is not cached and is retried on the next run.

Known limitations: a live-action movie that supplements a series with a different title
("Firefly" and its movie), and a feature made of sequential shorts, are not detectable and
need an override line. A series movie sharing a title word-for-word with its show is not
detected. Whether TMDB's hybrid keywords carry exactly the names in HYBRID_KEYWORDS is
unconfirmed; a hybrid without one is treated as its genre says.
"""
import argparse
import csv
import dataclasses
import json
import os
import re
import subprocess
import sys

import plex_get_labels as labels
from plex_labels_common import ApiError, atomic_write, normalize_title, split_folder_name

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
DEFAULT_CACHE = os.path.join(os.path.dirname(SCRIPT_DIR), "data", "cache",
                             "media_classify_cache.json")
KINDS = ("Movies", "Series", "Series Movies", "Shorts")
ANIME_PREFIX = "Anime - "
CATEGORIES = frozenset(KINDS) | frozenset(ANIME_PREFIX + k for k in KINDS)
ANIMATION_GENRE_ID = 16
# Lowercase TMDB keyword names that mark a title mixing animation and live action.
HYBRID_KEYWORDS = frozenset({"live action and animation", "combined animation and live action"})
# US rating -> animation (True) or live action (False), for a hybrid title.
MOVIE_RATING_SIDE = {"G": True, "PG": True, "PG-13": False, "R": False, "NC-17": False}
TV_RATING_SIDE = {"TV-Y": True, "TV-Y7": True, "TV-Y7-FV": True, "TV-G": True, "TV-PG": True,
                  "TV-14": False, "TV-MA": False}
# TMDB release types, most authoritative first: theatrical, limited theatrical, premiere,
# then digital, physical and TV.
CERT_TYPE_ORDER = (3, 2, 1, 4, 5, 6)
SHORT_SECONDS = 2700        # a movie of exactly 45 minutes is not a short
MIN_SHOW_TITLE_LEN = 5      # shorter show titles never make a series movie
EPISODE_TOKEN = re.compile(r"(?<![0-9A-Za-z])[Ss]\d{1,2}[Ee]\d{1,3}(?:\.\d{1,2})?(?![0-9A-Za-z])")
EXTS_PATTERN = re.compile(r"[A-Za-z0-9]+(\|[A-Za-z0-9]+)*")


class Hold(Exception):
    """A person must decide; the message says why."""


class ClassifyError(Exception):
    """Bad usage, bad input files or a missing tool; the message says why."""


@dataclasses.dataclass
class Unit:
    """One series or movie inside an entry: kind ('series' or 'movie'), title, year (None
    when the name has none), and the video files that belong to it."""
    kind: str
    title: str
    year: object
    files: list

    def name(self):
        """Returns "Title (YYYY)", or the bare title when there is no year."""
        return f"{self.title} ({self.year})" if self.year else self.title


class ArgParser(argparse.ArgumentParser):
    """ArgumentParser whose usage errors exit 1, since 2 means a person must decide."""
    def error(self, message):
        self.exit(1, f"ERROR\t{message}\n")


def title_words(title):
    """Returns the lowercase alphanumeric words of title as a tuple."""
    return tuple(re.findall(r"[a-z0-9]+", title.lower()))


def read_overrides(path):
    """Returns {(normalized title, year or None): category} from the overrides file at
    path; {} when it does not exist. Raises ClassifyError on a malformed line or an unknown
    category."""
    if not path or not os.path.isfile(path):
        return {}
    out = {}
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\r\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 2 or not parts[0].strip():
                raise ClassifyError(f"{path} line {n}: expected 'Title (YYYY)', a tab, a category")
            title, year = split_folder_name(parts[0].strip())
            category = parts[1].strip()
            if category not in CATEGORIES:
                raise ClassifyError(f"{path} line {n}: unknown category '{category}'")
            out[(normalize_title(title), year)] = category
    return out


def read_library(path):
    """Returns (rows, titles) from the folders CSV at path: rows is {Plex Folder: Plex TMDB
    ID or None}; titles is a list of (word tuple, title) for the show titles (folder title
    and Plex title) long enough to be a series-movie prefix. Both are empty when path is
    empty, and empty with a warning on stderr when the file does not exist. Raises ClassifyError on a file without the
    folder column."""
    if not path:
        return {}, []
    if not os.path.isfile(path):
        print(f"WARNING: library list not found: {path}; series movies are not detected",
              file=sys.stderr)
        return {}, []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames or reader.fieldnames[0] != labels.FOLDER_COLUMN:
            raise ClassifyError(f"{path} must start with a header whose first column is "
                                f"'{labels.FOLDER_COLUMN}'")
        rows, titles = {}, {}
        for r in reader:
            folder = (r.get(labels.FOLDER_COLUMN) or "").strip()
            if not folder:
                continue
            tmdb = (r.get(labels.PLEX_COLUMNS["tmdb"]) or "").strip()
            rows[folder] = int(tmdb) if tmdb.isdigit() else None
            for text in (split_folder_name(folder)[0], r.get(labels.PLEX_COLUMNS["title"])):
                words = title_words(text or "")
                if len("".join(words)) >= MIN_SHOW_TITLE_LEN:
                    titles.setdefault(words, text.strip())
    return rows, sorted(titles.items())


def video_files(entry, exts):
    """Returns the video files under the folder entry (extensions from the '|'-separated
    exts, any case), sorted by path."""
    pattern = re.compile(rf"\.({exts})$", re.IGNORECASE)
    found = []
    for root, dirs, files in os.walk(entry):
        dirs.sort()
        found += [os.path.join(root, f) for f in sorted(files) if pattern.search(f)]
    return found


def build_units(entry, files):
    """Returns the Units of an entry: one series when any file name carries an SxxEyy token
    (named by the entry folder), else one movie per distinct title and year in the file
    names. Raises Hold for a movie file name without a title and year."""
    if any(EPISODE_TOKEN.search(os.path.basename(f)) for f in files):
        title, year = split_folder_name(os.path.basename(os.path.normpath(entry)))
        return [Unit("series", title, year, files)]
    movies = {}
    for f in files:
        title, year = split_folder_name(os.path.splitext(os.path.basename(f))[0])
        if year is None or not normalize_title(title):
            raise Hold(f"no title and year in file name '{os.path.basename(f)}'")
        movies.setdefault((normalize_title(title), year), Unit("movie", title, year, [])).files.append(f)
    return list(movies.values())


def video_seconds(path):
    """Returns the container duration of path in seconds from ffprobe. Raises ClassifyError
    when ffprobe is missing or reports no usable duration."""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True)
    except FileNotFoundError:
        raise ClassifyError("ffprobe not found on PATH") from None
    if result.returncode != 0:
        raise ClassifyError(f"ffprobe failed for {os.path.basename(path)}")
    try:
        seconds = float(result.stdout.strip())
    except ValueError:
        raise ClassifyError(f"ffprobe gave no duration for {os.path.basename(path)}") from None
    return seconds


def us_certification(release_dates):
    """Returns the US certification from a TMDB release_dates block: the first non-empty one
    in CERT_TYPE_ORDER, else the first other; '' when there is none."""
    for country in (release_dates or {}).get("results") or []:
        if country.get("iso_3166_1") != "US":
            continue
        by_type = {}
        for item in country.get("release_dates") or []:
            cert = (item.get("certification") or "").strip()
            if cert:
                by_type.setdefault(item.get("type"), cert)
        for kind in CERT_TYPE_ORDER:
            if kind in by_type:
                return by_type[kind]
        return next(iter(by_type.values()), "")
    return ""


def keyword_names(block):
    """Returns the lowercase keyword names of a TMDB keywords block (a movie's list is under
    'keywords', a show's under 'results')."""
    items = (block or {}).get("keywords") or (block or {}).get("results") or []
    return [(k.get("name") or "").lower() for k in items]


def verdict(facts, sides):
    """Returns (is_animation, why) from stored TMDB facts. A hybrid is decided by its rating
    through sides ({rating: True for animation}); any other title by the Animation genre.
    Raises Hold for a hybrid whose rating is not in sides."""
    if facts["hybrid"]:
        rating = facts["rating"]
        if rating not in sides:
            raise Hold(f"animation/live-action hybrid with "
                       f"{'US rating ' + rating if rating else 'no US rating'}")
        return sides[rating], (f"hybrid rated {rating}: "
                               f"{'animation' if sides[rating] else 'live action'}")
    return facts["animation"], "animation genre" if facts["animation"] else "no animation genre"


class Classifier:
    """Chooses categories: holds the TMDB key, the lookup cache, the overrides and the
    library list for one run."""

    def __init__(self, key, cache_path, overrides, library_rows, library_titles):
        self.key = key
        self.cache_path = cache_path
        self.overrides = overrides
        self.library_rows = library_rows
        self.library_titles = library_titles
        self.cache = self._load_cache()

    def _load_cache(self):
        """Returns the cache dict from cache_path, {} when it does not exist. Raises
        ClassifyError on a file that is not valid JSON, rather than discarding lookups."""
        if not os.path.isfile(self.cache_path):
            return {}
        try:
            with open(self.cache_path, encoding="utf-8") as f:
                return json.load(f)
        except ValueError:
            raise ClassifyError(f"cache {self.cache_path} is not valid JSON; fix or remove it") from None

    def _remember(self, key, value):
        """Stores value under key in the cache and writes the cache file."""
        self.cache[key] = value
        os.makedirs(os.path.dirname(self.cache_path), exist_ok=True)
        atomic_write(self.cache_path, lambda f: json.dump(self.cache, f))

    def override(self, unit):
        """Returns the override category for unit, or None."""
        nt = normalize_title(unit.title)
        return self.overrides.get((nt, unit.year)) or self.overrides.get((nt, None))

    def find_movie(self, unit):
        """Returns the TMDB id of the one movie named unit.title in unit.year (else a year
        either side). Raises Hold for none or several; ApiError if a request fails."""
        cache_key = f"movie-search:{normalize_title(unit.title)}:{unit.year}"
        if cache_key in self.cache:
            return self.cache[cache_key]
        want = normalize_title(unit.title)
        body = labels.tmdb_get("/search/movie", {"query": unit.title, "year": unit.year}, self.key)
        problem = "No TMDB match"
        for gap in (0, -1, 1):
            hits = [r for r in body.get("results", [])
                    if (r.get("release_date") or "")[:4] == str(unit.year + gap)
                    and want in (normalize_title(r.get("title")),
                                 normalize_title(r.get("original_title")))]
            if len(hits) == 1:
                self._remember(cache_key, hits[0]["id"])
                return hits[0]["id"]
            if hits:
                problem = "Multiple TMDB matches: " + ", ".join(str(r["id"]) for r in hits)
                break
        raise Hold(f"{problem} for {unit.name()}")

    def find_series(self, unit, folder):
        """Returns the TMDB id of the show for unit: the Plex TMDB ID the library list gives
        the folder, else the one title-and-year search match. Raises Hold for none, several or
        no year; ApiError if a request fails."""
        if self.library_rows.get(folder):
            return self.library_rows[folder]
        if unit.year is None:
            raise Hold(f"no year in show folder name '{folder}'")
        cache_key = f"tv-search:{normalize_title(unit.title)}:{unit.year}"
        if cache_key in self.cache:
            return self.cache[cache_key]
        tmdb_id, problem = labels.find_show(unit.title, unit.year, self.key)
        if tmdb_id is None:
            raise Hold(f"{problem} for {unit.name()}")
        self._remember(cache_key, tmdb_id)
        return tmdb_id

    def facts(self, kind, tmdb_id):
        """Returns {"animation", "hybrid", "rating"} for a TMDB movie ('movie') or show
        ('tv'). Raises Hold when TMDB has no such entry; ApiError if a request fails."""
        cache_key = f"{kind}:{tmdb_id}"
        if cache_key in self.cache:
            return self.cache[cache_key]
        extra = "release_dates,keywords" if kind == "movie" else "content_ratings,keywords"
        body = labels.tmdb_get(f"/{kind}/{tmdb_id}", {"append_to_response": extra}, self.key)
        if "id" not in body:
            raise Hold(f"TMDB has no {kind} {tmdb_id}")
        if kind == "movie":
            rating = us_certification(body.get("release_dates"))
        else:
            rating = next((r.get("rating") or "" for r in
                           (body.get("content_ratings") or {}).get("results") or []
                           if r.get("iso_3166_1") == "US"), "")
        facts = {"animation": any(g.get("id") == ANIMATION_GENRE_ID for g in body.get("genres") or []),
                 "hybrid": any(k in HYBRID_KEYWORDS for k in keyword_names(body.get("keywords"))),
                 "rating": rating}
        self._remember(cache_key, facts)
        return facts

    def series_movie_of(self, unit):
        """Returns the library show title that unit's title begins with, or None."""
        words = title_words(unit.title)
        for show_words, show_title in self.library_titles:
            if len(words) > len(show_words) and words[:len(show_words)] == show_words:
                return show_title
        return None

    def classify_series(self, unit, folder):
        """Returns (category, reason) for a series unit. Raises Hold or ApiError."""
        forced = self.override(unit)
        if forced:
            return forced, f"override for {unit.name()}"
        tmdb_id = self.find_series(unit, folder)
        animated, why = verdict(self.facts("tv", tmdb_id), TV_RATING_SIDE)
        return (ANIME_PREFIX if animated else "") + "Series", f"TMDB tv {tmdb_id}: {why}"

    def classify_movie(self, unit):
        """Returns (category, reason) for a movie unit. Raises Hold, ClassifyError or
        ApiError."""
        forced = self.override(unit)
        if forced:
            return forced, f"override for {unit.name()}"
        tmdb_id = self.find_movie(unit)
        animated, why = verdict(self.facts("movie", tmdb_id), MOVIE_RATING_SIDE)
        reason = f"TMDB movie {tmdb_id}: {why}"
        minutes = max(video_seconds(f) for f in unit.files) / 60
        parent = self.series_movie_of(unit)
        if minutes * 60 < SHORT_SECONDS:
            kind, reason = "Shorts", f"{reason}, {minutes:.0f} min"
        elif parent:
            kind, reason = "Series Movies", f"{reason}, title follows library show '{parent}'"
        else:
            kind = "Movies"
        return (ANIME_PREFIX if animated else "") + kind, reason

    def classify_entry(self, entry, exts):
        """Returns (category, reason) for the entry folder. Raises Hold when a person must
        decide, ClassifyError on bad input, ApiError when a lookup cannot complete."""
        if not os.path.isdir(entry):
            raise Hold(f"entry is not a folder: {os.path.basename(entry)}")
        files = video_files(entry, exts)
        if not files:
            raise Hold("no video files in the entry")
        results = []
        for unit in build_units(entry, files):
            if unit.kind == "series":
                folder = os.path.basename(os.path.normpath(entry))
                results.append((unit.name(),) + self.classify_series(unit, folder))
            else:
                results.append((unit.name(),) + self.classify_movie(unit))
        if len({category for _, category, _ in results}) > 1:
            raise Hold("movies in this folder sort differently: " + "; ".join(
                f"{name} -> {category}" for name, category, _ in results))
        if len(results) == 1:
            return results[0][1], results[0][2]
        return results[0][1], "; ".join(f"{name}: {reason}" for name, _, reason in results)


def main(argv=None):
    """Runs the classifier for the command line argv and returns the exit code."""
    p = ArgParser(description="Choose the category folder for one ingested entry.")
    p.add_argument("-E", "--exts", required=True, help="video extensions, e.g. 'mp4|mkv'")
    p.add_argument("-C", "--overrides", default=None, help="category overrides file")
    p.add_argument("-L", "--folders", default=None, help="plex_folders.csv")
    p.add_argument("--cache", default=DEFAULT_CACHE, help="lookup cache file")
    p.add_argument("entry", help="top-level entry folder")
    a = p.parse_args(argv)
    try:
        if not EXTS_PATTERN.fullmatch(a.exts):
            raise ClassifyError("-E must be extensions joined by '|', e.g. 'mp4|mkv'")
        key = os.environ.get(labels.TMDB_KEY_ENV, "").strip()
        if not key:
            raise ClassifyError(f"set the {labels.TMDB_KEY_ENV} environment variable to a TMDB v3 API key")
        rows, titles = read_library(a.folders)
        classifier = Classifier(key, a.cache, read_overrides(a.overrides), rows, titles)
        category, reason = classifier.classify_entry(a.entry, a.exts)
    except Hold as e:
        print(f"HOLD\t{' '.join(str(e).split())}")
        return 2
    except ApiError as e:
        print(f"DEFER\t{' '.join(str(e).split())}")
        return 3
    except (ClassifyError, OSError) as e:
        print(f"ERROR\t{' '.join(str(e).split())}")
        return 1
    print(f"{category}\t{' '.join(reason.split())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
