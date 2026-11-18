#!/usr/bin/env python3
"""Assign Age/Target to every Plex folder: from MyAnimeList (MAL) data, and for titles MAL does
not carry, from the US TV Parental Guidelines rating on The Movie Database (TMDB).

Usage:
    python3 plex_get_labels.py FOLDERS.csv LABELS.csv [--source jikan|mal-api] [--no-tmdb]
                         [--no-source-works] [--check-source-route] [--assess-genres]
                         [--no-idmap] [--refresh-idmap] [--idmap PATH]
                         [-f|--force] [-n|--dry-run] [--cache PATH] [--log PATH]

FOLDERS.csv  plex_folders.csv, written by plex_sync_folders.py. First column "Plex Folder"
          (header row required). Optional columns, all written by the sync from Plex's own
          match and never edited by hand: Plex Title, Plex Original Title, Plex TMDB ID,
          Plex TVDB ID, Plex IMDB ID. Any other column is ignored. A wrong match is fixed
          in Plex (Fix Match); the next sync brings the new IDs here.
LABELS.csv   plex_labels.csv, the output. An existing file is never replaced unless --force.
--source  Where MAL data comes from. "jikan" (default) is the unofficial Jikan API.
          "mal-api" is MAL's official API v2 and needs a client ID in the
          MAL_CLIENT_ID environment variable (register an app at
          myanimelist.net/apiconfig; the client secret is not used).
--no-tmdb Skips TMDB. Without it, TMDB_API_KEY must hold a free TMDB v3 API key
          (themoviedb.org account settings, API section).
--no-source-works  Skips the source-work lookup described under Rules. That lookup runs
          with --source mal-api only and also needs access to graphql.anilist.co.
--assess-genres  Logs leave-one-out accuracy of genre-based Target on anime that already
                      have a demographic: the fixed rules and a naive Bayes model, with
                      accuracy and coverage at probability cut-offs. Output unchanged.
--check-source-route  Logs whether source-work demographics agree with MAL's own for
          anime that already have a demographic (mal-api only; output unchanged).
--no-idmap  Does not use the ID map (see Rules); every folder is found by title search.
--refresh-idmap  Downloads the ID map again even when the saved copy is recent.
--idmap   Where the ID map is saved (default: data/cache/plex_get_labels_idmap.json).
--cache   One JSON file for every finished lookup, with a section per source (jikan,
          mal-api, tmdb), so records from one are never read as another's. Default:
          data/cache/plex_get_labels_cache.json. When the file does not exist,
          get_anime_labels_cache*.json and get_western_labels_cache.json beside it are
          imported into it once; they are not modified. Delete it to refresh everything.
--dry-run Reports what would be looked up and written; makes no network calls and
          writes no files (no output, cache, ID map, lock or log).

Needs only the Python 3 standard library and internet access. Resumable: finished
lookups are cached, so a re-run makes no API calls for them. The cache defaults to the
directory containing this script and the log to the logs directory beside it, never the
caller's directory. An API key is never written to the log or to any output file.

ID map: the community list github.com/Fribb/anime-lists (anime-list-full.json, master
branch) maps TVDB, TMDB (TV) and IMDB IDs to MAL IDs. It is downloaded when absent or
older than IDMAP_MAX_AGE_DAYS and saved in a reduced form. If the download fails, a saved
copy is used however old it is; with none, title search alone is used and the log says so.

Order per folder: MAL first, then TMDB for a folder with no MAL match. Folders neither
knows are listed at the end of the run with the reason; fix the folder's match in Plex.

Rules for MAL (mechanical, no judgment):
  Match   1. Plex's TVDB, TMDB or IMDB ID, in that order, looked up in the ID map. One MAL
             entry is taken as is. Several (one TVDB series spanning several MAL entries)
             are decided by the folder year: entries starting that year, the best title
             match among them; failing that, entries one year off (Match Check "Review").
             Match Check shows "Plex ID".
          2. Otherwise a search by the folder's title, then Plex's title and original
             title, accepted by the scoring in pick() (title, year).
  Target  MAL demographic: Shounen/Seinen -> Male, Shoujo/Josei -> Female,
          none or Kids -> Unspecified (MAL has no both-genders
          value, so no demographic means unclassified, not an equal audience).
          When the anime has no demographic, the demographic of the work it adapts
          is used instead: AniList names the source manga or
          novel (its "SOURCE" relation, linked to MAL by MAL ID) and MAL's manga
          endpoint gives that work's demographic. A light novel with no
          demographic of its own contributes its comic adaptation's (MAL relation
          "adaptation"); Source Basis names both links. Source works that disagree on
          gender, no source work, or no demographic anywhere leave Target Unspecified.
          When no demographic exists anywhere, genre decides (Target Basis names
          the genres): Reverse Harem, Boys Love -> Female; Harem -> Male. Specific
          tags that disagree leave Target Unspecified. Romance is not used (see
          GENRE_FALLBACK). Girls Love and all other genres give no Target. This is inference, not a
          published demographic.
          Before genre: the source work's serialization (MAGAZINE_TARGETS, from
          Wikipedia's list of manga magazines) when its mapped magazines agree.
          Magazines never change Age.
  Age     MAL demographic Kids, or rating G/PG       -> Kids
          rating PG-13                               -> Teen
          rating R, R+ (mild nudity), Rx             -> Adult
          demographic Shounen or Shoujo (adolescents) -> Teen
          demographic Seinen or Josei (adults)        -> Adult
          Kids wins outright; otherwise the higher of the rating's age and the
          demographic's age (the source work's demographic counts when the anime has
          none). Neither one present                  -> Undefined
  No MAL match, or an API failure, gives Age and Target "Undefined".

Rules for TMDB (only for a folder with no MAL match; mechanical, no judgment):
  Match   1. Plex's TMDB ID, used directly.
          2. Plex's TVDB ID, then IMDB ID, through TMDB's find-by-external-ID endpoint; one
             TV result is taken.
          3. A search by the folder's title, then Plex's title and original title. A
             result is accepted when its name equals the searched text (ignoring case and
             punctuation) and its first air year equals the folder year; zero or several
             leave the row Undefined, with the reason in Match Check.
          Match Check reads "TV rating (Plex ID)" or "TV rating (title search)"; review
          the latter.
  Rating  The "US" entry of the show's content ratings.
  Age     TV-Y, TV-Y7, TV-Y7-FV, TV-G -> Kids; TV-PG, TV-14 -> Teen; TV-MA -> Adult.
          Any other value, or no US entry, leaves the row Undefined.
  Target  Unspecified: US ratings name no gendered audience.
  Only a show that resolved to a TMDB ID with a US rating is cached; a miss or a missing
  rating is retried on the next run.

Output columns: Plex Folder, Age, Target, Basis (MAL or TMDB URL), Match Check, MAL Title,
MAL Demographic, MAL Rating (the US rating for a TMDB row), Source Demographic, Source Basis,
Target Basis ("Magazine: ..." or "Genre: ..." when Target was inferred), Source Magazine (the
source work's serialization, informational only), Source (MAL, TMDB, or None when neither
resolved the folder). Source Demographic and Source Basis (the source work's MAL URL, or why
none applied) are filled only when the anime has no demographic of its own. Match Check is
"Review" when the MAL match did not agree on both title and year; verify those rows against
the MAL page.

Known limitation: a title that differs from MAL's only by a long shared substring
(e.g. "Example Show" vs "Example Show Returns", same year) is accepted as a match
because substring plus year scores at the acceptance threshold. Those rows are
marked "Review". Titles shorter than MIN_CONTAINS_LEN characters match only on
exact equality.
"""
import argparse
import contextlib
import csv
import hashlib
import json
import math
import os
import re
import sys
import time
import urllib.parse

from plex_labels_common import (ABORT_AFTER_FAILURES, LOG_DIR, ApiError, atomic_write,
                           close_logging, fetch_json, hold_lock, normalize_title,
                           setup_logging, split_folder_name)

if sys.version_info < (3, 8):
    sys.exit(f"ERROR: Python 3.8+ required (current: {sys.version.split()[0]})")




API = "https://api.jikan.moe/v4/anime"
MAL_API = "https://api.myanimelist.net/v2/anime"
MAL_API_FIELDS = "alternative_titles,start_date,media_type,genres,rating"
MAL_MANGA_API = "https://api.myanimelist.net/v2/manga"
ANILIST_API = "https://graphql.anilist.co"
# AniList documents 90 requests/minute and states a temporary 30/minute limit; one
# request every 2 seconds stays under 30.
ANILIST_INTERVAL = 2.0
# relationType only reports SOURCE when asked for version 2 of the enum (AniList docs:
# "SOURCE: Version 2 only"); without the argument the edge to the manga is not SOURCE.
ANILIST_SOURCE_QUERY = ("query ($id: Int) { Media(idMal: $id, type: ANIME) "
                        "{ relations { edges { relationType(version: 2) "
                        "node { idMal type } } } } }")
# Stored in each cached source record; a record from another version is looked up again.
SOURCE_VERSION = 4
# MAL media_type values of a prose source whose comic adaptation may carry the demographic.
NOVEL_TYPES = ("light_novel", "novel")
# MAL ID used only to check that AniList answers; no anime has it, so AniList replies 404.
ANILIST_PROBE_ID = 0
# Outcomes of a source-work lookup, as stored in the cache and shown in Source Basis.
SRC_FOUND = "found"
SRC_NO_ANILIST = "no AniList entry"
SRC_NONE = "no source work"
SRC_NO_DEMOGRAPHIC = "source has no demographic"
SRC_CONFLICT = "conflicting demographics"
# The official API reports the rating as a lowercase code; Jikan reports it as
# "CODE - description". Codes are normalized to the Jikan form's leading code.
MAL_RATING_CODES = {"g": "G", "pg": "PG", "pg_13": "PG-13", "r": "R", "r+": "R+", "rx": "Rx"}
# The official API lists demographics among the genres; only these count as demographics.
DEMOGRAPHICS = ("Shounen", "Shoujo", "Seinen", "Josei", "Kids")
SOURCES = ("jikan", "mal-api")
CLIENT_ID_ENV = "MAL_CLIENT_ID"
TMDB_API = "https://api.themoviedb.org/3"
TMDB_PAGE = "https://www.themoviedb.org/tv/"
TMDB_KEY_ENV = "TMDB_API_KEY"
# US TV Parental Guidelines rating -> Age.
RATING_AGE = {"TV-Y": "Kids", "TV-Y7": "Kids", "TV-Y7-FV": "Kids", "TV-G": "Kids",
              "TV-PG": "Teen", "TV-14": "Teen", "TV-MA": "Adult"}
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
DEFAULT_CACHE = os.path.join(os.path.dirname(SCRIPT_DIR), "data", "cache", "plex_get_labels_cache.json")
DEFAULT_LOG = os.path.join(LOG_DIR, "plex_get_labels.log")
# Sections of the cache file: one per MAL source, plus TMDB.
TMDB_SECTION = "tmdb"
# Cache files imported into the cache when it does not exist yet.
IMPORTED_CACHES = (("jikan", "get_anime_labels_cache.json"),
                 ("mal-api", "get_anime_labels_cache_mal_api.json"),
                 (TMDB_SECTION, "get_western_labels_cache.json"))
FOLDER_COLUMN = "Plex Folder"
# Columns written by plex_sync_folders.py from Plex's own metadata.
PLEX_COLUMNS = {"title": "Plex Title", "original": "Plex Original Title",
                "tmdb": "Plex TMDB ID", "tvdb": "Plex TVDB ID", "imdb": "Plex IMDB ID"}
IDMAP_URL = "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json"
DEFAULT_IDMAP = os.path.join(os.path.dirname(SCRIPT_DIR), "data", "cache", "plex_get_labels_idmap.json")
IDMAP_MAX_AGE_DAYS = 7
HEADER = ["Plex Folder", "Age", "Target", "Basis", "Match Check", "MAL Title",
          "MAL Demographic", "MAL Rating", "Source Demographic", "Source Basis",
          "Target Basis", "Source Magazine", "Source"]

# Match scoring. A candidate scores the sum of its applicable parts.
SCORE_TITLE_EXACT = 10      # normalized title equals a MAL title/synonym
SCORE_TITLE_CONTAINS = 4    # one normalized title contains the other
SCORE_YEAR_EXACT = 5        # MAL start year equals the folder year
SCORE_YEAR_NEAR = 3         # MAL start year is one year off (season/cour splits)
SCORE_TYPE_BONUS = 1        # TV/ONA preferred over specials and shorts
# Exact title alone (10) or substring + exact year (9) is accepted. Substring
# without a year agreement (4-7) is not.
ACCEPT_SCORE = 9
# Both title and year agreeing exactly (10 + 5) is confident; anything lower is
# flagged for review.
REVIEW_BELOW = 15
MIN_CONTAINS_LEN = 5        # shorter titles must match exactly, never by substring
# Observed: search text of 66+ characters failed on both sources' API while 63 succeeded,
# so searches are cut to 64. The limit is inferred from those results, not documented.
MAX_QUERY_LEN = 64
ID_SCORE = 98               # Plex's own ID (through the ID map) names the entry
ID_YEAR_NEAR_SCORE = 14     # chosen among several ID candidates on a year one off: Review



def mal_year(entry):
    """Returns the MAL start year of an API entry as an int, or None if unknown."""
    start = (entry.get("aired", {}).get("prop", {}).get("from") or {})
    return start.get("year")


def score_entry(r, nt, year):
    """Returns the match score of one Jikan-shaped entry r against the normalized title nt
    and folder year. Scoring parts are the SCORE_* constants."""
    names = [r.get("title"), r.get("title_english")] + [
        t.get("title") for t in r.get("titles", [])
    ]
    names = [normalize_title(n) for n in names if n]
    score = 0
    if nt in names:
        score += SCORE_TITLE_EXACT
    elif len(nt) >= MIN_CONTAINS_LEN and any(
        len(n) >= MIN_CONTAINS_LEN and (nt in n or n in nt) for n in names
    ):
        score += SCORE_TITLE_CONTAINS
    ry = mal_year(r)
    if year and ry:
        if ry == year:
            score += SCORE_YEAR_EXACT
        elif abs(ry - year) == 1:
            score += SCORE_YEAR_NEAR
    if r.get("type") in ("TV", "ONA"):
        score += SCORE_TYPE_BONUS
    return score


def pick(results, title, year):
    """Returns (entry, score) for the best candidate, or (None, best_score) if no
    candidate reaches ACCEPT_SCORE. Scoring parts are the SCORE_* constants."""
    nt = normalize_title(title)
    best, best_score = None, -1
    for r in results:
        score = score_entry(r, nt, year)
        if score > best_score:
            best, best_score = r, score
    return (best, best_score) if best_score >= ACCEPT_SCORE else (None, best_score)


def from_mal_api(node):
    """Converts an official-API anime node into the Jikan-shaped entry that pick()
    and lookup() consume: title, title_english, titles, type, rating (leading code),
    demographics, and aired.prop.from.year."""
    alt = node.get("alternative_titles") or {}
    extra = ([alt["en"]] if alt.get("en") else []) + list(alt.get("synonyms") or [])
    start = node.get("start_date") or ""
    year = int(start[:4]) if start[:4].isdigit() else None
    return {
        "mal_id": node["id"],
        "title": node["title"],
        "title_english": alt.get("en"),
        "titles": [{"title": t} for t in extra],
        "type": (node.get("media_type") or "").upper(),
        "rating": MAL_RATING_CODES.get(node.get("rating")),
        "demographics": [g for g in node.get("genres", []) if g.get("name") in DEMOGRAPHICS],
        "genres": [g for g in node.get("genres", []) if g.get("name") not in DEMOGRAPHICS],
        "aired": {"prop": {"from": {"year": year}}},
    }


def query_text(title):
    """Returns title cut to MAX_QUERY_LEN characters with trailing space removed."""
    return title[:MAX_QUERY_LEN].rstrip()


def search_candidates(title, source, client_id):
    """Returns up to 10 Jikan-shaped candidate entries for title from the chosen
    source. Raises ApiError if the search fails."""
    if source == "mal-api":
        # nsfw=true: the official API omits some entries by default, including
        # ones rated PG-13 on the site.
        query = urllib.parse.urlencode(
            {"q": query_text(title), "limit": 10, "nsfw": "true", "fields": MAL_API_FIELDS}
        )
        body = fetch_json(f"{MAL_API}?{query}", {"X-MAL-CLIENT-ID": client_id})
        return [from_mal_api(item["node"]) for item in body.get("data", [])]
    # sfw=false: the default would drop adult-rated entries from the results, and
    # an Rx title in the library must still resolve to its rating.
    # order_by=popularity: puts the mainstream entry first when titles collide.
    query = urllib.parse.urlencode(
        {"q": query_text(title), "limit": 10, "order_by": "popularity", "sfw": "false"}
    )
    return fetch_json(f"{API}?{query}").get("data", [])


def fetch_by_id(mal_id, source, client_id):
    """Returns the Jikan-shaped entry for a MAL ID, or None if MAL has no such entry.
    Raises ApiError if the request fails."""
    if source == "mal-api":
        body = fetch_json(f"{MAL_API}/{mal_id}?fields={MAL_API_FIELDS}",
                          {"X-MAL-CLIENT-ID": client_id})
        return from_mal_api(body) if "id" in body else None
    data = fetch_json(f"{API}/{mal_id}").get("data")
    return data if isinstance(data, dict) else None


def make_record(entry, score):
    """Returns the cache record for a Jikan-shaped entry matched with score."""
    return {
        "mal_id": entry["mal_id"],
        "mal_title": entry["title"],
        "year": mal_year(entry),
        "demographics": [d["name"] for d in entry.get("demographics", [])],
        "rating": entry.get("rating"),
        "genres": entry_genres(entry),
        "score": score,
    }


def entry_genres(entry):
    """Returns the names of an entry's genres, themes and explicit genres. Jikan reports
    these as separate lists; the official API's entry is converted with all of them under
    genres (whether the API includes theme tags such as Harem is unconfirmed)."""
    names = []
    for key in ("genres", "themes", "explicit_genres"):
        names += [g["name"] for g in entry.get(key) or [] if g.get("name")]
    return names


def distinct_titles(folder, plex):
    """Returns the texts to search by, in order: the folder's title, then Plex's title and
    original title, each once (ignoring case and punctuation)."""
    seen, out = set(), []
    for t in (split_folder_name(folder)[0], (plex or {}).get("title"),
              (plex or {}).get("original")):
        n = normalize_title(t)
        if t and t.strip() and n and n not in seen:
            seen.add(n)
            out.append(t.strip())
    return out


def resolve_by_ids(folder, plex, idmap, source, client_id, entries):
    """Returns (entry, score) for the MAL entry Plex's IDs name through the ID map, or
    (None, None) when they name none. One candidate is taken as is (ID_SCORE). Several are
    decided by the folder year: those starting that year (best title match, ID_SCORE), else
    those one year off (ID_YEAR_NEAR_SCORE). entries is a per-run {mal_id: entry} cache.
    Raises ApiError if a request fails."""
    title, year = split_folder_name(folder)
    nt = normalize_title(title)

    def get(mal_id):
        if mal_id not in entries:
            entries[mal_id] = fetch_by_id(mal_id, source, client_id)
        return entries[mal_id]

    for kind in ("tvdb", "tmdb", "imdb"):
        mals = idmap[kind].get((plex or {}).get(kind)) if (plex or {}).get(kind) else None
        if not mals:
            continue
        if len(mals) == 1:
            entry = get(mals[0])
            if entry:
                return entry, ID_SCORE
            continue
        found = [e for e in (get(m) for m in mals) if e]
        for gap, score in ((0, ID_SCORE), (1, ID_YEAR_NEAR_SCORE)):
            same = [e for e in found if year and mal_year(e)
                    and abs(mal_year(e) - year) == gap]
            if same:
                return max(same, key=lambda e: score_entry(e, nt, year)), score
    return None, None


def lookup(folder, source="jikan", client_id=None, plex=None, idmap=None, entries=None):
    """Returns a record dict for the folder's MAL match, or None if there is none. Raises
    ApiError if the lookup itself fails.

    plex is the folder's Plex info (keys title, original, tmdb, tvdb, imdb; see read_inputs)
    and idmap the index from load_idmap (or None): the IDs are tried first (see
    resolve_by_ids), then a title search (see distinct_titles).

    Record keys: mal_id, mal_title, year, demographics (list of names),
    rating (str|None), genres, score (int, see pick).
    """
    entries = {} if entries is None else entries
    if idmap:
        entry, score = resolve_by_ids(folder, plex, idmap, source, client_id, entries)
        if entry:
            return make_record(entry, score)
    year = split_folder_name(folder)[1]
    for text in distinct_titles(folder, plex):
        entry, score = pick(search_candidates(text, source, client_id), text, year)
        if entry:
            return make_record(entry, score)
    return None


def anilist_source_ids(mal_id):
    """Returns the MAL IDs of the manga/novel works AniList records as the source of
    anime mal_id ([] when it records none), or None when AniList has no entry for
    that anime. Raises ApiError if the request fails or AniList reports an error."""
    payload = json.dumps({"query": ANILIST_SOURCE_QUERY,
                          "variables": {"id": int(mal_id)}}).encode()
    body = fetch_json(ANILIST_API,
                      {"Content-Type": "application/json", "Accept": "application/json"},
                      payload, ANILIST_INTERVAL)
    if body.get("errors"):
        raise ApiError(f"AniList error: {body['errors'][0].get('message')}")
    media = (body.get("data") or {}).get("Media")
    if not media:
        return None
    edges = (media.get("relations") or {}).get("edges") or []
    return [e["node"]["idMal"] for e in edges
            if e.get("relationType") == "SOURCE" and (e.get("node") or {}).get("type") == "MANGA"
            and e["node"].get("idMal")]


def manga_info(manga_id, client_id):
    """Returns {"demographics", "media_type", "adaptations", "magazines"} for a MAL
    manga/novel entry: its demographic names, its media_type ('' when absent), the MAL IDs
    of entries it lists with relation_type 'adaptation', and its serialization names. Raises ApiError if the request fails."""
    body = fetch_json(f"{MAL_MANGA_API}/{manga_id}?fields=genres,media_type,related_manga,serialization",
                      {"X-MAL-CLIENT-ID": client_id})
    return {
        "demographics": [g["name"] for g in body.get("genres", []) if g.get("name") in DEMOGRAPHICS],
        "media_type": body.get("media_type") or "",
        "adaptations": [r["node"]["id"] for r in body.get("related_manga", [])
                        if r.get("relation_type") == "adaptation" and r.get("node", {}).get("id")],
        "magazines": [m["node"]["name"] for m in body.get("serialization", [])
                      if (m.get("node") or {}).get("name")],
    }


def lookup_source(mal_id, client_id):
    """Returns the source-work record for anime mal_id: {"v", "status", "demographics",
    "mal_ids", "via", "magazines"}. status is one of the SRC_* constants; demographics (sorted names)
    is non-empty only when status is SRC_FOUND; mal_ids lists the source works' MAL IDs.
    A source of a NOVEL_TYPES media_type with no demographic of its own contributes
    the demographics of its 'adaptation' entries; via lists the adaptation IDs that
    supplied one. Works whose demographics map to both Male and Female give
    SRC_CONFLICT, since no single Target follows from them. Raises ApiError if a
    request fails."""
    ids = anilist_source_ids(mal_id)
    rec = {"v": SOURCE_VERSION, "status": SRC_NONE, "demographics": [], "mal_ids": ids or [],
           "via": [], "magazines": []}
    if ids is None:
        rec["status"] = SRC_NO_ANILIST
        return rec
    if not ids:
        return rec
    found, magazines = set(), set()
    for i in ids:
        info = manga_info(i, client_id)
        magazines.update(info["magazines"])
        if info["demographics"]:
            found.update(info["demographics"])
        elif info["media_type"] in NOVEL_TYPES:
            for a in info["adaptations"]:
                adapted = manga_info(a, client_id)
                magazines.update(adapted["magazines"])
                if adapted["demographics"]:
                    found.update(adapted["demographics"])
                    rec["via"].append(a)
    targets = {target([d]) for d in found}
    if {"Male", "Female"} <= targets:
        rec["status"], found = SRC_CONFLICT, set()
    elif not found:
        rec["status"] = SRC_NO_DEMOGRAPHIC
    else:
        rec["status"] = SRC_FOUND
    rec["demographics"] = sorted(found)
    rec["magazines"] = sorted(magazines)
    return rec


def needs_source(rec):
    """True when rec is a matched record with no demographic of its own and no
    source-work lookup of the current SOURCE_VERSION stored yet."""
    return (bool(rec) and not rec["demographics"]
            and (rec.get("source") or {}).get("v") != SOURCE_VERSION)


def effective_demographics(rec):
    """Returns the demographics that decide Target: the anime's own, else the source
    work's when its lookup found one."""
    src = rec.get("source") or {}
    if src.get("v") != SOURCE_VERSION:
        return rec["demographics"]
    return rec["demographics"] or src["demographics"]


def magazine_cell(rec):
    """Returns the source work's serialization names ('; '-joined) for a record with no
    demographic of its own, else ''. Informational only: no Target or Age uses it."""
    src = rec.get("source") or {}
    if rec["demographics"] or src.get("v") != SOURCE_VERSION:
        return ""
    return "; ".join(src.get("magazines", []))


def source_columns(rec, source_failed):
    """Returns [Source Demographic, Source Basis] cells for a matched record."""
    if rec["demographics"]:
        return ["", ""]
    if source_failed:
        return ["", "API failure"]
    src = rec.get("source")
    if not src or src.get("v") != SOURCE_VERSION:
        return ["", "Not looked up"]
    urls = " ".join(f"https://myanimelist.net/manga/{i}" for i in src["mal_ids"])
    if src["status"] == SRC_FOUND:
        if src.get("via"):
            urls += " via comic adaptation " + " ".join(
                f"https://myanimelist.net/manga/{i}" for i in src["via"])
        return ["/".join(src["demographics"]), urls]
    return ["", f"{src['status']} ({urls})" if urls else src["status"]]



def plex_signature(folder, plex):
    """Returns the part of a cache key that depends on Plex's info: its IDs and the titles
    that are searched besides the folder's, so a changed match is never served an old
    result. '' when Plex gave nothing."""
    plex = plex or {}
    parts = [f"{k}={plex[k]}" for k in ("tvdb", "tmdb", "imdb") if plex.get(k)]
    extra = distinct_titles(folder, plex)[1:]
    if extra:
        parts.append("t=" + "|".join(extra))
    return ";".join(parts)


def cache_key(folder, plex):
    """Returns the MAL cache key for folder: the folder name alone when Plex gave no info
    (the key the earlier scripts used), else the name and plex_signature."""
    sig = plex_signature(folder, plex)
    return f"{folder}\t{sig}" if sig else folder


def target(demographics):
    """Returns 'Male', 'Female' or 'Unspecified' from a list of MAL demographic names."""
    for d in demographics:
        if d in ("Shounen", "Seinen"):
            return "Male"
        if d in ("Shoujo", "Josei"):
            return "Female"
    return "Unspecified"


# Genre inference for Target, used only when no demographic exists anywhere. Specific tags
# decide first. This is inference, not a MAL-published
# demographic. Harem (one boy among girls) and Boys Love (developed by creators of manga
# for girls and women) have a documented audience; Reverse Harem mirrors Harem.
# Girls Love is deliberately absent: it has no single audience (Wikipedia, "Yuri").
# Romance -> Female (the project owner's rule) is disabled: on 2026-11-12 --assess-genres
# measured it at 12 correct of 29 (41.4%) against the 181 anime with a known demographic,
# below chance and far below the 85.6% Male baseline. Set GENRE_FALLBACK = ROMANCE_RULE
# to re-enable it.
# Add Ecchi or Mahou Shoujo here only as an explicit, unsourced owner choice.
GENRE_TARGETS = {"Reverse Harem": "Female", "Boys Love": "Female", "Harem": "Male"}
ROMANCE_RULE = ("Romance", "Female")
GENRE_FALLBACK = None


def genre_target(genres):
    """Returns (target, matched genre names) from genre names: the specific GENRE_TARGETS
    tags first (disagreeing tags give Unspecified), else GENRE_FALLBACK when set."""
    hits = [g for g in genres if g in GENRE_TARGETS]
    if hits:
        values = {GENRE_TARGETS[g] for g in hits}
        return (values.pop() if len(values) == 1 else "Unspecified"), hits
    if GENRE_FALLBACK and GENRE_FALLBACK[0] in genres:
        return GENRE_FALLBACK[1], [GENRE_FALLBACK[0]]
    return "Unspecified", []


def needs_genres(rec):
    """True when rec is a matched record cached before genres were stored."""
    return bool(rec) and "genres" not in rec


AGE_ORDER = ("Kids", "Teen", "Adult")
# Age implied by who a demographic is published for: Shounen and Shoujo target
# adolescents, Seinen and Josei target adults. Kids is handled separately.
DEMOGRAPHIC_AGE = {"Shounen": "Teen", "Shoujo": "Teen", "Seinen": "Adult", "Josei": "Adult"}


def age(demographics, rating):
    """Returns 'Kids', 'Teen', 'Adult' or 'Undefined'. The Kids demographic gives Kids.
    Otherwise the result is the higher of the age implied by the demographics
    (DEMOGRAPHIC_AGE) and the age implied by the MAL rating string (which begins with
    the rating code, e.g. 'PG-13 - ...'): G/PG -> Kids, PG-13 -> Teen, R/R+/Rx -> Adult.
    A missing or unknown value on one side leaves the other side's age; neither gives
    'Undefined'."""
    if "Kids" in demographics:
        return "Kids"
    found = [DEMOGRAPHIC_AGE[d] for d in demographics if d in DEMOGRAPHIC_AGE]
    code = (rating or "").split(" - ")[0].strip()
    if code in ("G", "PG"):
        found.append("Kids")
    elif code == "PG-13":
        found.append("Teen")
    elif code.startswith("R"):
        found.append("Adult")
    return max(found, key=AGE_ORDER.index) if found else "Undefined"


def read_inputs(src):
    """Returns (folders, plex) from the folders CSV at src. plex is {folder: {"title",
    "original", "tmdb", "tvdb", "imdb"}}: the PLEX_COLUMNS cells (None when absent or
    blank; tmdb and tvdb as int, imdb as 'tt...'). Exits on a malformed file."""
    with open(src, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames or reader.fieldnames[0] != FOLDER_COLUMN:
            sys.exit(f"ERROR: {src} must start with a header whose first column is "
                     f"{FOLDER_COLUMN!r}")
        rows = list(enumerate(reader, 2))
    folders, plex = [], {}
    for n, r in rows:
        folder = r.get(FOLDER_COLUMN) or ""
        if not folder.strip():
            continue
        folders.append(folder)
        info = {}
        for key, column in PLEX_COLUMNS.items():
            value = (r.get(column) or "").strip()
            if value and key in ("tmdb", "tvdb"):
                if not value.isdigit():
                    sys.exit(f"ERROR: {src} line {n}: {column} must be a number")
                value = int(value)
            elif value and key == "imdb" and not re.fullmatch(r"tt\d+", value):
                sys.exit(f"ERROR: {src} line {n}: {column} must look like tt1234567")
            info[key] = value or None
        plex[folder] = info
    return folders, plex


def as_int(value):
    """Returns value as an int when it is an int or a string of digits, else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    return int(value) if isinstance(value, str) and value.isdigit() else None


def reduce_idmap(raw):
    """Returns the saved form of the ID map from the parsed anime-list-full.json: a list of
    [mal_id, tvdb_id|None, tmdb_tv_id|None, [imdb ids]] for every entry with a MAL ID.
    Entries without one, and TMDB movie IDs (TMDB and TVDB IDs are shared across movies
    and shows, so only the TV ID is used), are dropped."""
    out = []
    for e in raw:
        mal = as_int(e.get("mal_id"))
        if mal is None:
            continue
        tmdb = e.get("themoviedb_id")
        tmdb = as_int(tmdb.get("tv")) if isinstance(tmdb, dict) else None
        imdb = e.get("imdb_id") or []
        imdb = [imdb] if isinstance(imdb, str) else [i for i in imdb if isinstance(i, str)]
        out.append([mal, as_int(e.get("tvdb_id")), tmdb, imdb])
    return out


def index_idmap(entries):
    """Returns {"tvdb": {id: [mal ids]}, "tmdb": {...}, "imdb": {...}} from the saved
    form, each MAL ID once per key, in file order."""
    idx = {"tvdb": {}, "tmdb": {}, "imdb": {}}
    for mal, tvdb, tmdb, imdb in entries:
        for kind, keys in (("tvdb", [tvdb]), ("tmdb", [tmdb]), ("imdb", imdb)):
            for k in keys:
                if k is not None and mal not in idx[kind].setdefault(k, []):
                    idx[kind][k].append(mal)
    return idx


def load_idmap(path, refresh, dry_run, log, now=None):
    """Returns the ID map index (see index_idmap), or None when there is none. Uses the
    saved copy at path when it is younger than IDMAP_MAX_AGE_DAYS (and refresh is False),
    else downloads IDMAP_URL and saves it. A failed download falls back to a saved copy of
    any age, else None; the log says which. In dry-run nothing is downloaded or saved."""
    now = time.time() if now is None else now
    saved = None
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                saved = json.load(f)
            if not isinstance(saved.get("entries"), list):
                raise ValueError("no entries")
        except (ValueError, AttributeError):
            log.info("WARNING: ID map %s is unreadable; ignoring it", path)
            saved = None
    age_days = (now - saved.get("fetched", 0)) / 86400 if saved else None
    if saved and (dry_run or (not refresh and age_days < IDMAP_MAX_AGE_DAYS)):
        log.info("ID map: %s, %d entries, %.1f days old", path, len(saved["entries"]), age_days)
        return index_idmap(saved["entries"])
    if dry_run:
        log.info("[DRY RUN] ID map: none saved at %s; it would be downloaded", path)
        return None
    try:
        raw = fetch_json(IDMAP_URL, min_interval=0)
        if not isinstance(raw, list):
            raise ApiError(f"unexpected reply from {IDMAP_URL}")
    except ApiError as e:
        if saved:
            log.info("WARNING: ID map download failed (%s); using the saved copy, %.1f days "
                     "old", e, age_days)
            return index_idmap(saved["entries"])
        log.info("WARNING: ID map download failed (%s) and none is saved; title search only", e)
        return None
    entries = reduce_idmap(raw)
    atomic_write(path, lambda f: json.dump({"fetched": now, "entries": entries}, f))
    log.info("ID map: downloaded %d entries to %s", len(entries), path)
    return index_idmap(entries)


def load_store(path):
    """Returns (store, imported): the cache dict at path ({section: {key: record}}), and
    the sections imported from the cache files named in IMPORTED_CACHES beside it when path does not exist.
    Exits on a corrupt file rather than silently discarding finished lookups."""
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f), []
        except ValueError:
            sys.exit(f"ERROR: cache {path} is not valid JSON; fix or remove it")
    store, imported = {}, []
    for section, name in IMPORTED_CACHES:
        legacy = os.path.join(os.path.dirname(os.path.realpath(path)), name)
        if os.path.isfile(legacy):
            try:
                with open(legacy, encoding="utf-8") as f:
                    store[section] = json.load(f)
            except ValueError:
                sys.exit(f"ERROR: cache {legacy} is not valid JSON; fix or remove it")
            imported.append(name)
    return store, imported


def save_store(path, store):
    """Atomically writes the cache dict to path as JSON."""
    atomic_write(path, lambda f: json.dump(store, f))


@contextlib.contextmanager
def exclusive_lock(cache_path):
    """Holds a lock scoped to the canonical cache path, so a second run against the
    same cache exits while runs against other caches proceed. See hold_lock."""
    real = os.path.realpath(cache_path)
    digest = hashlib.sha256(real.encode()).hexdigest()[:16]
    lock_path = os.path.join(os.path.dirname(real), f".plex_get_labels_{digest}.lock")
    with hold_lock(lock_path, f"ERROR: another run is already using cache {real}"):
        yield


def tmdb_get(path, params, key):
    """Returns the parsed JSON for a TMDB v3 path. The key is sent as the api_key query
    parameter, so it is removed from any error message before it is raised."""
    query = urllib.parse.urlencode(dict(params, api_key=key))
    try:
        return fetch_json(f"{TMDB_API}{path}?{query}")
    except ApiError as e:
        raise ApiError(str(e).replace(key, "***")) from None


def first_air_year(result):
    """Returns the year of a TMDB TV result's first_air_date as an int, or None."""
    date = result.get("first_air_date") or ""
    return int(date[:4]) if date[:4].isdigit() else None


def find_show(search, year, key):
    """Returns (tmdb_id, problem): the one TMDB show whose name equals search and whose
    first air year equals year, or (None, reason) for none or several. Raises ApiError
    if the request fails."""
    body = tmdb_get("/search/tv", {"query": search}, key)
    want = normalize_title(search)
    hits = [r for r in body.get("results", [])
            if first_air_year(r) == year
            and want in (normalize_title(r.get("name")), normalize_title(r.get("original_name")))]
    if len(hits) == 1:
        return hits[0]["id"], None
    if not hits:
        return None, "No TMDB match"
    return None, "Multiple TMDB matches: " + ", ".join(str(r["id"]) for r in hits)


def us_rating(tmdb_id, key):
    """Returns the US content rating string for a TMDB show id (e.g. 'TV-14'), or None
    if TMDB has no US rating. Raises ApiError if the request fails."""
    body = tmdb_get(f"/tv/{tmdb_id}/content_ratings", {}, key)
    for item in body.get("results", []):
        if item.get("iso_3166_1") == "US" and item.get("rating"):
            return item["rating"]
    return None


def classify(rating):
    """Returns (age, check) for a US rating string or None."""
    if rating is None:
        return "Undefined", "No US rating on TMDB"
    if rating in RATING_AGE:
        return RATING_AGE[rating], "TV rating"
    return "Undefined", f"Unmapped rating: {rating}"


def tmdb_cache_key(folder, plex):
    """Returns the TMDB cache key for a folder: folder, the Plex signature (or the folder's
    title when Plex gave nothing, the key the earlier scripts used) and an empty ID part."""
    sig = plex_signature(folder, plex) or split_folder_name(folder)[0]
    return f"{folder}\t{sig}\t"


def tmdb_find(external_id, source, key):
    """Returns the TMDB TV show ids that external_id (a TVDB or IMDB id) names, via the
    find endpoint; source is 'tvdb_id' or 'imdb_id'. Raises ApiError if the request fails."""
    body = tmdb_get(f"/find/{external_id}", {"external_source": source}, key)
    return [r["id"] for r in body.get("tv_results", []) if r.get("id")]


def lookup_tmdb(folder, plex, key):
    """Returns (tmdb_id, rating, problem, how) for one folder: how is 'Plex ID' or 'title
    search'; problem is a Match Check reason when no single show was found. Tries Plex's
    TMDB ID, then its TVDB and IMDB IDs, then a search by title (see distinct_titles).
    Raises ApiError if a request fails."""
    plex = plex or {}
    problem = "No TMDB match"
    if plex.get("tmdb"):
        return plex["tmdb"], us_rating(plex["tmdb"], key), None, "Plex ID"
    for kind, source in (("tvdb", "tvdb_id"), ("imdb", "imdb_id")):
        if plex.get(kind):
            ids = tmdb_find(plex[kind], source, key)
            if len(ids) == 1:
                return ids[0], us_rating(ids[0], key), None, "Plex ID"
            if len(ids) > 1:
                problem = "Multiple TMDB matches: " + ", ".join(str(i) for i in ids)
    year = split_folder_name(folder)[1]
    for text in distinct_titles(folder, plex):
        tmdb_id, found = find_show(text, year, key)
        if tmdb_id is not None:
            return tmdb_id, us_rating(tmdb_id, key), None, "title search"
        if found != "No TMDB match":
            problem = found
    return None, None, problem, "title search"


def tmdb_row(folder, tmdb_id, rating, how):
    """Returns the output row for a folder resolved on TMDB; how is 'Plex ID' or
    'title search'."""
    age_, check = classify(rating)
    if check == "TV rating":
        check = f"TV rating ({how})"
    return [folder, age_, "Unspecified" if age_ != "Undefined" else "Undefined",
            f"{TMDB_PAGE}{tmdb_id}", check, "", "", rating or "", "", "", "", "", "TMDB"]


def unresolved_reason(row):
    """Returns why an output row with Age Undefined has none."""
    if row[12] == "TMDB":
        return row[4]
    if row[3] == "API failure":
        return "API failure (re-run to retry)"
    if row[3] == "No MAL match":
        return "No MAL match" + (f"; {row[4]}" if row[4] else "")
    return "MAL match has no rating or demographic"


def check_preconditions(src, dst, force, dry_run, source="jikan", client_id=None,
                        source_works=False, check_route=False, tmdb_key=None, use_tmdb=True):
    """Exits with a message if src is unusable, dst is src, dst exists without
    --force, source mal-api has no client ID, or TMDB is wanted without a key. With
    source_works or check_route, also probes AniList. Skips the API probes in dry-run
    (which makes no network calls)."""
    if not os.path.isfile(src):
        sys.exit(f"ERROR: source file not found: {src}")
    if os.path.realpath(src) == os.path.realpath(dst):
        sys.exit("ERROR: output path is the source file; refusing to overwrite the input")
    if os.path.exists(dst) and not force:
        sys.exit(f"ERROR: {dst} already exists (use --force to overwrite)")
    if not read_inputs(src)[0]:
        sys.exit(f"ERROR: no folder names found in {src}")
    if source == "mal-api" and not client_id:
        sys.exit(f"ERROR: --source mal-api needs the {CLIENT_ID_ENV} environment variable")
    if use_tmdb and not dry_run and not tmdb_key:
        sys.exit(f"ERROR: set the {TMDB_KEY_ENV} environment variable to a TMDB v3 API key "
                 "(or use --no-tmdb)")
    if not dry_run:
        try:
            if source == "mal-api":
                fetch_json(f"{MAL_API}?q=probe&limit=1", {"X-MAL-CLIENT-ID": client_id})
            else:
                fetch_json(f"{API}?q=probe&limit=1")
        except ApiError as e:
            sys.exit(f"ERROR: {source} API unreachable or refused the request: {e}")
        if source_works or check_route:
            try:
                anilist_source_ids(ANILIST_PROBE_ID)
            except ApiError as e:
                sys.exit(f"ERROR: AniList unreachable or refused the request: {e} "
                         "(use --no-source-works to skip the source-work lookup)")


def mal_row(folder, rec, failed, source_failed=False):
    """Returns the output CSV row for one folder.

    rec is the cached record or None (no match); failed is True when the lookup
    raised ApiError this run; source_failed is True when only the source-work lookup
    did (the row keeps the anime's own values).
    """
    if failed:
        return [folder, "Undefined", "Undefined", "API failure", "", "", "", "", "", "", "", ""]
    if rec is None:
        return [folder, "Undefined", "Undefined", "No MAL match", "", "", "", "", "", "", "", ""]
    if rec["score"] == ID_SCORE:
        check = "Plex ID"
    else:
        check = "OK" if rec["score"] >= REVIEW_BELOW else "Review"
    demos = effective_demographics(rec)
    tgt, basis = target(demos), ""
    if not demos:
        src = rec.get("source") or {}
        mag, labels = magazine_target(src.get("magazines", [])
                                      if src.get("v") == SOURCE_VERSION else [])
        if labels:
            tgt, basis = mag, "Magazine: " + "; ".join(labels)
        else:
            guess, hits = genre_target(rec.get("genres") or [])
            if hits:
                tgt, basis = guess, "Genre: " + "/".join(hits)
    return [
        folder,
        age(demos, rec["rating"]),
        tgt,
        f"https://myanimelist.net/anime/{rec['mal_id']}",
        check,
        rec["mal_title"],
        "/".join(rec["demographics"]),
        rec["rating"] or "",
        *source_columns(rec, source_failed),
        basis,
        magazine_cell(rec),
    ]



def build_row(folder, rec, failed, source_failed=False):
    """Returns the output CSV row (HEADER) for a folder resolved by MAL or not at all:
    mal_row plus the Source cell (MAL for a match, None otherwise)."""
    row = mal_row(folder, rec, failed, source_failed)
    return row + ["MAL" if rec is not None and not failed else "None"]


# Target by the source work's serialization, used when no demographic exists and before
# genre. Values are the Demographic / Genre column of Wikipedia's "List of manga magazines"
# (read 2026-11-12), keyed by the names MAL returns. Digital platforms and magazines the
# list gives no value for (Manga UP!, Gangan Online, MangaONE, comico, LINE Manga,
# Kurage Bunch, ComicWalker, AlphaPolis, Young Ace UP, Comic Corona, Ura Sunday, ...) and
# Monthly GFantasy ("Mixed") are left out, so they decide nothing. Comp Ace is "Shonen" in
# that list but "mixed shonen/seinen" in Wikipedia's Seinen article; both give Male.
MAGAZINE_TARGETS = {
    "Comic Alive": ("Seinen", "Male"), "Dragon Age": ("Shounen", "Male"),
    "Shounen Ace": ("Shounen", "Male"), "Dengeki Daioh": ("Shounen", "Male"),
    "Comp Ace": ("Shounen", "Male"), "Young Gangan": ("Seinen", "Male"),
    "Comic Flapper": ("Seinen", "Male"), "Gangan Joker": ("Shounen", "Male"),
    "Big Gangan": ("Seinen", "Male"), "Sunday Gene-X": ("Seinen", "Male"),
    "Dengeki Maoh": ("Seinen", "Male"), "Shounen Gangan": ("Shounen", "Male"),
    "Dengeki Comic Gao!": ("Shounen", "Male"), "Young Ace": ("Seinen", "Male"),
    "Dengeki G's Comic": ("Seinen", "Male"), "Dengeki hp": ("Seinen", "Male"),
    "Manga Time Kirara MAX": ("Seinen", "Male"), "Comic Gum": ("Seinen", "Male"),
    "Comic Earth\u2606Star": ("Shounen", "Male"), "Opera": ("Yaoi", "Female"),
}


def magazine_target(magazines):
    """Returns (target, labels) from serialization names: the Target of the mapped
    magazines when they agree, else ('Unspecified', []). Unmapped names are ignored.
    labels are 'Name (demographic)' strings for the mapped magazines."""
    hits = [(m, MAGAZINE_TARGETS[m]) for m in magazines if m in MAGAZINE_TARGETS]
    if len({t for _, (_, t) in hits}) != 1:
        return "Unspecified", []
    return hits[0][1][1], [f"{m} ({d})" for m, (d, _) in hits]


ASSESS_CUTOFFS = (0.6, 0.7, 0.8, 0.9)


def genre_bayes(train, genres):
    """Returns P(Female) for a genre set from train, a list of (genres, target) pairs with
    target 'Male' or 'Female'. Naive Bayes over the genres seen in train, Laplace-smoothed."""
    vocab = {g for gs, _ in train for g in gs}
    n = {"Male": 0, "Female": 0}
    count = {"Male": {}, "Female": {}}
    for gs, t in train:
        n[t] += 1
        for g in gs:
            count[t][g] = count[t].get(g, 0) + 1
    logp = {}
    for t in n:
        lp = math.log((n[t] + 1) / (len(train) + 2))
        for g in vocab:
            p = (count[t].get(g, 0) + 1) / (n[t] + 2)
            lp += math.log(p if g in genres else 1 - p)
        logp[t] = lp
    m = max(logp.values())
    e = {t: math.exp(v - m) for t, v in logp.items()}
    return e["Female"] / (e["Male"] + e["Female"])


def assess_genre_model(folders, keys, cache, log):
    """Scores genre-based Target prediction leave-one-out on anime whose own MAL demographic
    gives Male or Female, and logs the result. Compares the fixed rules (genre_target)
    with genre_bayes at each ASSESS_CUTOFFS probability. The labeled anime are those
    adapted from manga; the anime that need a guess are not, so these figures
    are an optimistic bound for them, not their accuracy. Changes no output."""
    data = []
    for f in folders:
        rec = cache.get(keys[f])
        if rec and "genres" in rec and target(rec["demographics"]) in ("Male", "Female"):
            data.append((set(rec["genres"]), target(rec["demographics"])))
    n = len(data)
    log.info("Genre assessment: %d anime with a Male/Female demographic and stored genres", n)
    if n < 20:
        log.info("  too few to assess (need at least 20)")
        return
    base = max(sum(1 for _, t in data if t == c) for c in ("Male", "Female"))
    log.info("  baseline (always the larger class): %.1f%%", 100 * base / n)
    buckets = {"specific tags (Harem, Reverse Harem, Boys Love)": [0, 0],
               "Romance fallback": [0, 0]}
    for gs, t in data:
        guess, hits = genre_target(list(gs))
        key = "specific tags (Harem, Reverse Harem, Boys Love)"
        if not hits and ROMANCE_RULE[0] in gs:
            guess, hits, key = ROMANCE_RULE[1], [ROMANCE_RULE[0]], "Romance fallback"
        if hits:
            buckets[key][0] += 1
            buckets[key][1] += guess == t
    for key, (tried, hit) in buckets.items():
        if tried:
            log.info("  fixed rules, %s: cover %d of %d, correct %d (%.1f%%)", key, tried, n,
                     hit, 100 * hit / tried)
        else:
            log.info("  fixed rules, %s: cover 0 of %d", key, n)
    for cut in ASSESS_CUTOFFS:
        tried = hit = 0
        for i, (gs, t) in enumerate(data):
            pf = genre_bayes(data[:i] + data[i + 1:], gs)
            if max(pf, 1 - pf) >= cut:
                tried += 1
                hit += ("Female" if pf >= 0.5 else "Male") == t
        if tried:
            log.info("  naive Bayes at >=%.0f%%: cover %d of %d, correct %d (%.1f%%)",
                     100 * cut, tried, n, hit, 100 * hit / tried)
        else:
            log.info("  naive Bayes at >=%.0f%%: cover 0 of %d", 100 * cut, n)


def run_route_check(folders, keys, cache, save, client_id, log):
    """Validates the source-work route against anime whose own MAL demographic is known:
    traces each through its source work (cached as rec["control"]) and logs whether the
    resulting Target agrees with the anime's own. Changes no output. Returns the number
    of failed lookups."""
    failed = agree = differ = nothing = hopped = 0
    for i, folder in enumerate(folders, 1):
        rec = cache.get(keys[folder])
        if not rec or not rec["demographics"]:
            continue
        ctl = rec.get("control")
        if not ctl or ctl.get("v") != SOURCE_VERSION:
            try:
                ctl = rec["control"] = lookup_source(rec["mal_id"], client_id)
            except ApiError as e:
                failed += 1
                log.info("%d/%d CONTROL FAILED %s: %s", i, len(folders), folder, e)
                continue
            save()
        own = target(rec["demographics"])
        if ctl["status"] != SRC_FOUND:
            nothing += 1
            log.info("CONTROL NO RESULT %s: own %s, source %s", folder,
                     "/".join(rec["demographics"]), ctl["status"])
            continue
        via = bool(ctl["via"])
        hopped += via
        same = target(ctl["demographics"]) == own
        agree += same
        differ += not same
        log.info("CONTROL %s %s: own %s, source %s%s", "MATCH" if same else "DIFFER", folder,
                 "/".join(rec["demographics"]), "/".join(ctl["demographics"]),
                 " (via comic adaptation)" if via else "")
    log.info("Route check: %d agree, %d differ, %d with no source result (%d of the "
             "results used a comic adaptation), %d failed", agree, differ, nothing, hopped, failed)
    return failed



def run(src, dst, force, dry_run, cache_path, log_path, source="jikan", client_id=None,
        source_works=False, check_route=False, assess_genres=False, tmdb_key=None,
        use_tmdb=True, use_idmap=True, idmap_path=DEFAULT_IDMAP, refresh_idmap=False):
    """Looks up every folder in src and writes dst. MAL decides first (through Plex's IDs
    and the ID map when use_idmap, else by title); a folder with no MAL match is then looked
    up on TMDB when use_tmdb. With source_works (only effective with source "mal-api"),
    anime without a demographic also get their source work's. With check_route (same
    condition), anime that have a demographic are also traced through their source work and
    the agreement is logged; dst is unaffected. With assess_genres, the genre-to-Target
    rules and a naive Bayes model are scored leave-one-out on anime whose own demographic is
    known, and the result is logged; dst is unaffected.
    Returns the process exit code: 0 complete, 1 aborted on an outage, 2 complete but
    some lookups failed (re-run to retry them)."""
    source_works = source_works and source == "mal-api"
    check_route = check_route and source == "mal-api"
    check_preconditions(src, dst, force, dry_run, source, client_id, source_works, check_route,
                        tmdb_key, use_tmdb)
    folders, plex = read_inputs(src)
    log = setup_logging(None if dry_run else log_path)
    try:
        idmap = (load_idmap(idmap_path, refresh_idmap, dry_run, log) if use_idmap else None)
        return _run(folders, dst, dry_run, cache_path, log, source, client_id, plex, idmap,
                    source_works, check_route, assess_genres, tmdb_key, use_tmdb)
    finally:
        close_logging(log)


def _run(folders, dst, dry_run, cache_path, log, source="jikan", client_id=None,
         plex=None, idmap=None, source_works=False, check_route=False,
         assess_genres=False, tmdb_key=None, use_tmdb=True):
    """Body of run(): performs the lookups and writes dst using the open logger."""
    plex = plex or {f: {} for f in folders}
    keys = {f: cache_key(f, plex[f]) for f in folders}
    tkeys = {f: tmdb_cache_key(f, plex[f]) for f in folders}
    entries = {}   # per-run {mal_id: entry} cache for ID-map candidates

    if dry_run:
        store, imported = load_store(cache_path)
        cache, tcache = store.get(source, {}), store.get(TMDB_SECTION, {})
        if imported:
            log.info("[DRY RUN] would import %s into %s", ", ".join(imported), cache_path)
        pending = [f for f in folders if keys[f] not in cache]
        log.info("[DRY RUN] %d folders: %d cached, %d would be looked up on MAL", len(folders),
                 len(folders) - len(pending), len(pending))
        if source_works:
            todo = [f for f in folders if keys[f] in cache and needs_source(cache[keys[f]])]
            log.info("[DRY RUN] %d cached matches without a demographic would get a "
                     "source-work lookup (more once the %d new lookups finish)",
                     len(todo), len(pending))
        log.info("[DRY RUN] %d cached matches would get a genre lookup",
                 sum(1 for f in folders if keys[f] in cache and needs_genres(cache[keys[f]])))
        log.info("[DRY RUN] ID map %s", "loaded" if idmap else "not available")
        if use_tmdb:
            nomatch = [f for f in folders if keys[f] in cache and cache[keys[f]] is None]
            hits = sum(1 for f in nomatch if tkeys[f] in tcache)
            log.info("[DRY RUN] %d folders with no MAL match would go to TMDB (%d cached, "
                     "%d requested; more once the %d new MAL lookups finish)", len(nomatch),
                     hits, len(nomatch) - hits, len(pending))
        log.info("[DRY RUN] Would write %s", dst)
        return 0

    with exclusive_lock(cache_path):
        store, imported = load_store(cache_path)
        if imported:
            log.info("Imported %s into %s", ", ".join(imported), cache_path)
        cache = store.setdefault(source, {})
        tcache = store.setdefault(TMDB_SECTION, {})

        def save():
            save_store(cache_path, store)

        failed, source_failed, looked_up, consecutive = set(), set(), 0, 0
        sourced, backfilled, genre_failed = 0, 0, set()
        for i, folder in enumerate(folders, 1):
            key = keys[folder]
            if key not in cache:
                try:
                    cache[key] = lookup(folder, source, client_id, plex[folder], idmap, entries)
                except ApiError as e:
                    failed.add(folder)
                    consecutive += 1
                    log.info("%d/%d FAILED %s: %s", i, len(folders), folder, e)
                    if consecutive >= ABORT_AFTER_FAILURES:
                        log.info("ABORT: %d consecutive API failures; finished lookups are "
                                 "cached, re-run to continue. No output written.", consecutive)
                        return 1
                    continue
                looked_up += 1
                rec, old = cache[key], cache.get(folder)
                if rec and old and key != folder and old.get("mal_id") == rec["mal_id"]:
                    # Same entry the earlier run found by title: keep its source-work and
                    # control lookups instead of repeating them.
                    for k in ("source", "control"):
                        if k in old and k not in rec:
                            rec[k] = old[k]
                save()
                log.info("%d/%d %s -> %s", i, len(folders), folder,
                         rec["mal_title"] if rec else "no match")
                if not (source_works and needs_source(rec)):
                    consecutive = 0
            rec = cache[key]
            if needs_genres(rec) and (assess_genres or not rec["demographics"]):
                try:
                    entry = fetch_by_id(rec["mal_id"], source, client_id)
                except ApiError as e:
                    genre_failed.add(folder)
                    log.info("%d/%d FAILED genres of %s: %s", i, len(folders), folder, e)
                    entry = None
                if entry is not None:
                    rec["genres"] = entry_genres(entry)
                    save()
                    backfilled += 1
                    log.info("%d/%d %s genres -> %s", i, len(folders), folder,
                             "/".join(rec["genres"]) or "none")
            if not (source_works and needs_source(rec)):
                continue
            try:
                rec["source"] = lookup_source(rec["mal_id"], client_id)
            except ApiError as e:
                source_failed.add(folder)
                consecutive += 1
                log.info("%d/%d FAILED source work of %s: %s", i, len(folders), folder, e)
                if consecutive >= ABORT_AFTER_FAILURES:
                    log.info("ABORT: %d consecutive API failures; finished lookups are "
                             "cached, re-run to continue. No output written.", consecutive)
                    return 1
                continue
            consecutive = 0
            sourced += 1
            save()
            log.info("%d/%d %s source work -> %s %s", i, len(folders), folder,
                     rec["source"]["status"], "/".join(rec["source"]["demographics"]))

        check_failed = (run_route_check(folders, keys, cache, save, client_id, log)
                        if check_route else 0)
        if assess_genres:
            assess_genre_model(folders, keys, cache, log)

        # TMDB: folders MAL has no entry for (lookup failures are not "no entry").
        tmdb_rows, tmdb_failed, tmdb_looked, tmdb_cached = {}, set(), 0, 0
        if use_tmdb:
            todo = [f for f in folders if f not in failed and keys[f] in cache
                    and cache[keys[f]] is None]
            consecutive = 0
            for n, folder in enumerate(todo, 1):
                tkey = tkeys[folder]
                hit = tcache.get(tkey)
                if hit:
                    tmdb_id, rating, problem = hit["tmdb_id"], hit["rating"], None
                    how = hit.get("how", "title search")
                    tmdb_cached += 1
                else:
                    try:
                        tmdb_id, rating, problem, how = lookup_tmdb(folder, plex[folder],
                                                                    tmdb_key)
                    except ApiError as e:
                        tmdb_failed.add(folder)
                        consecutive += 1
                        log.info("%d/%d FAILED TMDB %s: %s", n, len(todo), folder, e)
                        if consecutive >= ABORT_AFTER_FAILURES:
                            log.info("ABORT: %d consecutive API failures; finished lookups "
                                     "are cached, re-run to continue. No output written.",
                                     consecutive)
                            return 1
                        continue
                    consecutive = 0
                    tmdb_looked += 1
                    if tmdb_id is not None and rating is not None:
                        tcache[tkey] = {"tmdb_id": tmdb_id, "rating": rating, "how": how}
                        save()
                tmdb_rows[folder] = (tmdb_id, rating, problem, how)
                log.info("%d/%d TMDB %s -> %s%s", n, len(todo), folder,
                         problem or f"{tmdb_id} {rating or 'no US rating'}",
                         " (cached)" if hit else "")

        rows = []
        for f in folders:
            row = build_row(f, cache.get(keys[f]), f in failed, f in source_failed)
            if f in tmdb_rows:
                tmdb_id, rating, problem, how = tmdb_rows[f]
                if problem:
                    row[4] = problem
                else:
                    row = tmdb_row(f, tmdb_id, rating, how)
            elif f in tmdb_failed:
                row[4] = "TMDB request failed (re-run to retry)"
            rows.append(row)

        def write(f):
            w = csv.writer(f)
            w.writerow(HEADER)
            w.writerows(rows)

        atomic_write(dst, write)

    mal_rows = [r for r in rows if r[12] == "MAL"]
    matched = sum(1 for r in mal_rows if r[4] == "OK")
    review = sum(1 for r in mal_rows if r[4] == "Review")
    by_id = sum(1 for r in mal_rows if r[4] == "Plex ID")
    inferred = sum(1 for r in rows if r[10])
    log.info("Summary: %d folders written to %s", len(rows), dst)
    log.info("  %d looked up on MAL this run, %d served from cache", looked_up,
             len(folders) - looked_up - len(failed))
    log.info("  %d matched on MAL by title and year (OK)", matched)
    log.info("  %d matched through Plex's IDs and the ID map (Plex ID)", by_id)
    log.info("  %d matched on MAL on one signal only (Review: check the MAL page)", review)
    log.info("  %d API failures on MAL (Undefined; re-run to retry)", len(failed))
    log.info("  %d genre lookups this run; %d rows take Target by inference (magazine or genre)",
             backfilled, inferred)
    if genre_failed:
        log.info("  %d genre lookups failed (Target left Unspecified; re-run to retry)",
                 len(genre_failed))
    if source_works:
        used = sum(1 for r in rows if r[8])
        log.info("  %d source-work lookups this run; %d rows take Target from the source work",
                 sourced, used)
        log.info("  %d source-work lookups failed (Target left from the anime; re-run to retry)",
                 len(source_failed))
    if use_tmdb:
        tmdb_ok = sum(1 for r in rows if r[12] == "TMDB" and r[1] != "Undefined")
        log.info("  %d folders went to TMDB (%d requested this run, %d from cache): %d resolved, "
                 "%d request failures", len(tmdb_rows) + len(tmdb_failed), tmdb_looked,
                 tmdb_cached, tmdb_ok, len(tmdb_failed))
        by_title = sum(1 for r in rows if r[4] == "TV rating (title search)")
        if by_title:
            log.info("  %d TMDB rows were found by title search (Match Check "
                     "'TV rating (title search)'); review them", by_title)
    by_source = {s: sum(1 for r in rows if r[12] == s) for s in ("MAL", "TMDB", "None")}
    log.info("  Source: %d MAL, %d TMDB, %d None", by_source["MAL"], by_source["TMDB"],
             by_source["None"])
    unresolved = [r for r in rows if r[1] == "Undefined"]
    if unresolved:
        log.info("  %d folders have no Age/Target (fix their match in Plex, then sync):",
                 len(unresolved))
        for r in unresolved:
            log.info("    UNRESOLVED %s: %s", r[0], unresolved_reason(r))
    return 2 if failed or source_failed or genre_failed or check_failed or tmdb_failed else 0


def main(argv=None):
    p = argparse.ArgumentParser(description="Label Plex folders with Age/Target from MAL "
                                            "and TMDB.")
    p.add_argument("src", help="plex_folders.csv")
    p.add_argument("dst", help="plex_labels.csv")
    p.add_argument("-f", "--force", action="store_true", help="overwrite an existing DST")
    p.add_argument("-n", "--dry-run", action="store_true", help="report only; touch nothing")
    p.add_argument("--source", choices=SOURCES, default="jikan")
    p.add_argument("--cache", default=DEFAULT_CACHE)
    p.add_argument("--log", default=DEFAULT_LOG)
    p.add_argument("--no-tmdb", action="store_true", help="skip TMDB for folders MAL lacks")
    p.add_argument("--no-source-works", action="store_true",
                   help="skip the AniList/MAL lookup of the source manga's demographic")
    p.add_argument("--check-source-route", action="store_true",
                   help="log whether source-work demographics agree with MAL's own for "
                        "anime that already have one (mal-api only; output unchanged)")
    p.add_argument("--assess-genres", action="store_true",
                   help="log how well genre predicts Target on anime that already have a "
                        "demographic (output unchanged)")
    p.add_argument("--no-idmap", action="store_true",
                   help="do not use the ID map; find every folder by title search")
    p.add_argument("--refresh-idmap", action="store_true",
                   help="download the ID map again even when the saved copy is recent")
    p.add_argument("--idmap", default=DEFAULT_IDMAP, help="where the ID map is saved")
    a = p.parse_args(argv)
    client_id = os.environ.get(CLIENT_ID_ENV, "").strip() or None
    tmdb_key = os.environ.get(TMDB_KEY_ENV, "").strip() or None
    return run(a.src, a.dst, a.force, a.dry_run, a.cache, a.log, a.source, client_id,
               not a.no_source_works, a.check_source_route, a.assess_genres, tmdb_key,
               not a.no_tmdb, not a.no_idmap, a.idmap, a.refresh_idmap)


if __name__ == "__main__":
    sys.exit(main())
