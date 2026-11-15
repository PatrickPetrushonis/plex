"""Plex server access shared by sync_plex_folders.py and apply_plex_labels.py.

One JSON request function that keeps the token out of URLs and error messages, the
library lookup, folder-name parsing for Plex Location paths, and the PLEX_URL /
PLEX_TOKEN checks both scripts make before talking to the server.
"""
import json
import ntpath
import os
import posixpath
import sys
import urllib.error
import urllib.parse
import urllib.request

URL_ENV = "PLEX_URL"
TOKEN_ENV = "PLEX_TOKEN"
SECTION_TYPE_IDS = {"show": 2, "movie": 1}   # Plex's numeric types in listing and edit requests
PAGE_SIZE = 200
TIMEOUT_SECONDS = 30


class PlexError(Exception):
    """A request to Plex failed; the message never contains the token."""


def env_url():
    """Returns the PLEX_URL environment value, or None when it is unset or blank."""
    return os.environ.get(URL_ENV, "").strip() or None


def env_token():
    """Returns the PLEX_TOKEN environment value, or None when it is unset or blank."""
    return os.environ.get(TOKEN_ENV, "").strip() or None


def require_credentials(base_url, token):
    """Exits with an error message unless base_url is an http(s) URL with a host and
    token is non-empty."""
    parts = urllib.parse.urlsplit(base_url or "")
    if parts.scheme not in ("http", "https") or not parts.netloc:
        sys.exit(f"ERROR: set {URL_ENV} (or --url) to the server address with scheme and port, "
                 "e.g. http://192.0.2.10:32400")
    if not token:
        sys.exit(f"ERROR: set the {TOKEN_ENV} environment variable to a Plex token")


def folder_basename(path):
    """Returns the last component of a Plex Location path, accepting both / and \\
    separators because a Windows-hosted server reports backslash paths."""
    return ntpath.basename(posixpath.normpath(path.replace("\\", "/")))


def plex_request(base_url, token, method, path, params=None, headers=None):
    """Sends one request to Plex and returns the decoded JSON body ({} when the body
    is empty). The token travels in the X-Plex-Token header, never in the URL.
    Raises PlexError on HTTP errors, network errors and undecodable bodies."""
    url = base_url.rstrip("/") + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    hdrs = {"X-Plex-Token": token, "Accept": "application/json"}
    hdrs.update(headers or {})
    req = urllib.request.Request(url, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise PlexError(f"HTTP 401 for {method} {path}: the server rejected the token") from None
        raise PlexError(f"HTTP {e.code} for {method} {path}") from None
    except (urllib.error.URLError, OSError) as e:
        raise PlexError(f"cannot reach {base_url}: {getattr(e, 'reason', e)}") from None
    if not body.strip():
        return {}
    try:
        return json.loads(body)
    except ValueError:
        raise PlexError(f"non-JSON response for {method} {path}") from None


def find_sections(base_url, token, wanted):
    """Returns [(key, title, type)] for the libraries to label, type being "show" or
    "movie". wanted is a list of library titles or None; None selects every show and
    movie library. Raises PlexError when a wanted title is not a show or movie library
    or when the server has none."""
    data = plex_request(base_url, token, "GET", "/library/sections")
    sections = {d["title"]: d for d in data.get("MediaContainer", {}).get("Directory", [])
                if d.get("type") in SECTION_TYPE_IDS}
    if wanted:
        for title in wanted:
            if title not in sections:
                raise PlexError(f"no show or movie library titled {title!r}; "
                                f"available: {', '.join(repr(t) for t in sections) or 'none'}")
        chosen = [sections[t] for t in dict.fromkeys(wanted)]
    else:
        chosen = list(sections.values())
    if not chosen:
        raise PlexError("the server has no show or movie libraries")
    return [(str(d["key"]), d["title"], d["type"]) for d in chosen]
