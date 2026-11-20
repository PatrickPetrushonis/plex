"""Helpers shared by plex_get_labels.py, plex_sync_folders.py and plex_apply_labels.py.

HTTP with throttling and retries (fetch_json), folder-name parsing, atomic file
writes, a self-cleaning single-run lock, logging to the logs directory beside the
scripts directory, and a live status line (LIVE) with the elapsed time of a slow step.
"""
import contextlib
import fcntl
import json
import logging
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
LOG_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "logs"))   # created on first run

# Minimum seconds between requests made through fetch_json. Jikan documents
# 3 requests/second and 60/minute; one request per second stays under the sustained limit.
USER_AGENT = "plex-label-tools/1.0"  # urllib's default agent is refused by some hosts
MIN_INTERVAL = 1.0
MAX_RETRIES = 6
BACKOFF = 2.0
RETRY_CODES = (429, 500, 502, 503, 504)
# Consecutive per-item failures before a run stops (an outage, not a bad item).
ABORT_AFTER_FAILURES = 5


class ApiError(Exception):
    """Raised when the API cannot be reached or keeps failing after all retries."""


_last_request = {}   # host -> time.monotonic() of its latest request


def _throttle(host, interval):
    """Sleeps so consecutive requests to host are at least interval seconds apart;
    each host has its own clock, so a slow API never delays a fast one."""
    wait = interval - (time.monotonic() - _last_request.get(host, 0.0))
    if wait > 0:
        time.sleep(wait)
    _last_request[host] = time.monotonic()


def _retry_after(err):
    """Returns the Retry-After header in seconds as a float, or None if absent/invalid."""
    value = err.headers.get("Retry-After") if err.headers else None
    try:
        return float(value) if value is not None else None
    except ValueError:
        return None


def fetch_json(url, headers=None, body=None, min_interval=MIN_INTERVAL):
    """Returns the parsed JSON body for url, sending the optional headers dict
    (a User-Agent is always sent; the caller's headers may override it).

    body (bytes) makes the request a POST with that payload; min_interval is the
    minimum seconds between requests to url's host.

    A 404 returns {"data": []} (the entry does not exist). Rate limits and server
    errors are retried, honoring Retry-After. Raises ApiError once retries are
    exhausted or on a non-retryable HTTP error, so a failure is never mistaken
    for "no result".
    """
    last = "unknown error"
    for attempt in range(MAX_RETRIES):
        _throttle(urllib.parse.urlsplit(url).netloc, min_interval)
        try:
            req = urllib.request.Request(url, data=body,
                                         headers={"User-Agent": USER_AGENT, **(headers or {})})
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return {"data": []}
            last = f"HTTP {e.code}"
            if e.code not in RETRY_CODES:
                raise ApiError(f"{last} for {url}") from e
            time.sleep(_retry_after(e) or BACKOFF * (attempt + 1))
        except (urllib.error.URLError, OSError, ValueError) as e:
            last = str(e)
            time.sleep(BACKOFF * (attempt + 1))
    raise ApiError(f"{last} for {url} after {MAX_RETRIES} attempts")


def split_folder_name(folder):
    """Returns (title, year) from a Plex folder name.

    Strips a trailing '{edition-...}' tag and a '(YYYY)' suffix; year is None when
    the folder has no '(YYYY)'.
    """
    year = None
    m = re.search(r"\((\d{4})\)", folder)
    if m:
        year = int(m.group(1))
    title = re.sub(r"\s*\{edition-.*?\}", "", folder)
    title = re.sub(r"\s*\(\d{4}\)\s*$", "", title)
    return title, year


def normalize_title(s):
    """Returns s lowercased with everything except a-z and 0-9 removed."""
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def atomic_write(path, write_fn):
    """Writes via write_fn(file_object) to a temp file beside path, then renames it
    over path, so an interruption never leaves a half-written file."""
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp_", suffix=".part")
    try:
        with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
            write_fn(f)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def hold_lock(lock_path, busy_message):
    """Holds a non-blocking exclusive lock on lock_path for the with-block and deletes
    the lock file on exit, including on error or interrupt. Exits with busy_message
    when another process holds the lock (and leaves that process's file alone).

    The file is deleted while the lock is still held, and an acquirer re-checks that
    the file it locked is still the one at lock_path, so a deletion between another
    process's open and its flock cannot leave two holders on different inodes."""
    while True:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            sys.exit(busy_message)
        except BaseException:
            os.close(fd)
            raise
        try:
            same_file = os.stat(lock_path).st_ino == os.fstat(fd).st_ino
        except FileNotFoundError:
            same_file = False
        if same_file:
            break
        os.close(fd)
    try:
        yield
    finally:
        try:
            os.unlink(lock_path)
        except FileNotFoundError:
            pass
        os.close(fd)


class LiveStatus:
    """One status line at the bottom of the terminal while a slow step runs: a spinner,
    the elapsed time since the first set() and the text last given to set(), redrawn
    once a second by a background thread. It draws only while stderr is a terminal, so
    a redirected or unattended run prints nothing extra, and not before the first
    second, so a quick step shows nothing. Log records written through the logger from
    setup_logging appear above the line, which is erased and redrawn around them."""

    FRAMES = "|/-\\"

    def __init__(self):
        self.lock = threading.RLock()
        self._text = ""
        self._started = 0.0
        self._frame = 0
        self._drawn = False
        self._thread = None
        self._stop = threading.Event()

    def set(self, text):
        """Sets the status text and starts the redraw thread on the first call. Does
        nothing when stderr is not a terminal."""
        if not sys.stderr.isatty():
            return
        with self.lock:
            self._text = text
            if self._thread is None:
                self._started = time.monotonic()
                self._stop = threading.Event()
                self._thread = threading.Thread(target=self._run, args=(self._stop,),
                                                daemon=True)
                self._thread.start()

    def stop(self):
        """Stops the redraw thread and erases the line. Safe to call when nothing is
        running."""
        with self.lock:
            thread, self._thread = self._thread, None
            self._stop.set()
        if thread is not None:
            thread.join(timeout=2)
        with self.lock:
            self.erase()

    def erase(self):
        """Erases the status line if it is on screen."""
        with self.lock:
            if self._drawn:
                sys.stderr.write("\r\033[K")
                sys.stderr.flush()
                self._drawn = False

    def redraw(self):
        """Draws the status line when the thread is running and the first second has
        passed."""
        with self.lock:
            if self._thread is None:
                return
            elapsed = int(time.monotonic() - self._started)
            if elapsed < 1:
                return
            width = max(shutil.get_terminal_size((80, 24)).columns - 1, 20)
            text = " %s  %02d:%02d elapsed  %s" % (
                self.FRAMES[self._frame % len(self.FRAMES)], elapsed // 60, elapsed % 60,
                self._text)
            sys.stderr.write("\r" + text[:width] + "\033[K")
            sys.stderr.flush()
            self._drawn = True

    def _run(self, stop):
        """Thread body: advances the spinner and redraws once a second until stop is set."""
        while not stop.wait(1.0):
            with self.lock:
                self._frame += 1
                self.redraw()


LIVE = LiveStatus()


class _TerminalHandler(logging.StreamHandler):
    """A stdout handler that keeps LIVE's status line below its records."""

    def emit(self, record):
        with LIVE.lock:
            LIVE.erase()
            super().emit(record)
            LIVE.redraw()


def runtime_since(start):
    """Returns the time since start (a time.monotonic() value) as '<m>m <s>s'."""
    seconds = int(time.monotonic() - start)
    return "%dm %ds" % (seconds // 60, seconds % 60)


def close_logging(log):
    """Stops the live status line, then closes and detaches every handler on log,
    releasing the log file."""
    LIVE.stop()
    for h in list(log.handlers):
        log.removeHandler(h)
        h.close()


def setup_logging(log_path):
    """Logs to stdout, and to log_path (append, creating its directory) when log_path is not None.
    Callers pair this with close_logging so the log file handle is released."""
    log = logging.getLogger("labels")
    close_logging(log)
    log.setLevel(logging.INFO)
    fmt = logging.Formatter("[%(asctime)s] %(message)s", "%Y-%m-%d %H:%M:%S")
    handlers = [_TerminalHandler(sys.stdout)]
    if log_path:
        os.makedirs(os.path.dirname(os.path.abspath(log_path)), exist_ok=True)
        handlers.append(logging.FileHandler(log_path, encoding="utf-8"))
    for h in handlers:
        h.setFormatter(fmt)
        log.addHandler(h)
    return log
