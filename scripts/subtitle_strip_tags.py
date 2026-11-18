#!/usr/bin/env python3
"""Strips leftover ASS/SSA override tags from a plain-text subtitle file.

Usage:
    python3 subtitle_strip_tags.py has SRC
    python3 subtitle_strip_tags.py strip SRC DEST

Override tags (e.g. {\\an8}, {\\pos(400,300)}, {\\c&HFF0000&}) are valid ASS/SSA syntax but
are not part of the SRT spec. When a subtitle service converts ASS to SRT and keeps the
tags, they end up as literal text: a player that does not parse them renders "{\\an8}" on
screen instead of positioning the line.

has mode (called by encode.sh): exits 0 when SRC contains at least one tag, 1 when it
contains none, 2 when SRC cannot be read. Prints nothing on 0 and 1.

strip mode (called by encode.sh): writes a copy of SRC to DEST with every tag removed.
SRC is never modified, and an existing DEST is overwritten. Exits 0 on success, 1 on a
read or write failure (message on stderr).

Scope: sidecar files whose probed codec is subrip, and embedded SubRip or mov_text tracks
that encode.sh has extracted to a temporary .srt. The caller gates on the codec. ASS/SSA,
WebVTT and MicroDVD sidecars never reach this script, and a real embedded ASS/SSA track
must never be run through it: \\an8 there is genuine positioning, rendered correctly by an
ASS-capable player, not a conversion artifact.

Matching is structural: any "{\\" ... "}" span on a single line, whichever override tag it
is. SRT text has no legitimate use for that bracket syntax, so no list of tag names is
needed. The file is handled as bytes, so the encoding does not matter ("}" never occurs
inside a multi-byte UTF-8 character). Known limitation: only the bracketed {\\...} form is
covered. A source using some other, unbracketed convention is not; none has been observed
in sidecar .srt files from subtitle services, which are the only input this sees.

Exit status: as above per mode; 2 also on a usage error.
"""
import argparse
import re
import sys

# A span cannot cross a line, so a stray "{\" on one line never swallows text up to a "}"
# several lines later.
TAG_PATTERN = re.compile(rb'\{\\[^}\n]*\}')


def read_bytes(path):
    with open(path, 'rb') as f:
        return f.read()


def has_tags(path):
    """Returns 0 when the file contains an override tag, 1 when it does not, 2 on a read error."""
    try:
        data = read_bytes(path)
    except OSError as e:
        print(f"ERROR: cannot read {path}: {e.strerror}", file=sys.stderr)
        return 2
    return 0 if TAG_PATTERN.search(data) else 1


def strip_tags(src, dest):
    """Writes src to dest with every override tag removed. Returns 0, or 1 on an I/O error."""
    try:
        data = read_bytes(src)
        with open(dest, 'wb') as f:
            f.write(TAG_PATTERN.sub(b'', data))
    except OSError as e:
        print(f"ERROR: cannot strip {src}: {e.strerror}", file=sys.stderr)
        return 1
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description="Strip leftover ASS override tags from a plain-text subtitle file.")
    sub = p.add_subparsers(dest='mode', required=True)
    has = sub.add_parser('has', help="exit 0 if SRC contains an override tag, 1 if not, 2 if unreadable")
    has.add_argument('src')
    strip = sub.add_parser('strip', help="write SRC to DEST with every override tag removed")
    strip.add_argument('src')
    strip.add_argument('dest')
    a = p.parse_args(argv)
    if a.mode == 'has':
        return has_tags(a.src)
    return strip_tags(a.src, a.dest)


if __name__ == "__main__":
    sys.exit(main())
