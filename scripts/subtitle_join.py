#!/usr/bin/env python3
"""Joins SubRip (.srt) files into one, shifting each by a time offset.

Usage:
    python3 subtitle_join.py join DEST OFFSET SRT [OFFSET SRT ...]

join reads each SRT file in the order given, adds OFFSET (seconds, decimal) to the start
and end time of every cue in it, and writes all the cues to DEST renumbered from 1. It is
called by media_encode.sh for the subtitle files of a multi-part movie, where the
second part's subtitles start at the end of the first part. Cue text and any position
coordinates after the end time are kept as they are. Text that is not a cue is ignored.
DEST is written whole or not at all: an unreadable input leaves DEST untouched.

Exit status: 0 on success; 1 when an input cannot be read or DEST cannot be written;
2 on a usage error.
"""
import argparse
import os
import re
import sys
import tempfile

CUE_TIME = re.compile(
    r'^\s*(\d+):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*'
    r'(\d+):(\d{2}):(\d{2})[,.](\d{1,3})(.*)$')


def to_ms(hours, minutes, seconds, fraction):
    """Returns the time as whole milliseconds; fraction is the digits after the comma
    (one to three, so "5" is 500 ms)."""
    return ((int(hours) * 60 + int(minutes)) * 60 + int(seconds)) * 1000 + int(fraction.ljust(3, '0'))


def format_ms(ms):
    """Returns ms as an SRT time, HH:MM:SS,mmm."""
    seconds, millis = divmod(ms, 1000)
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{millis:03d}"


def parse_cues(text):
    """Returns the cues in text as (start_ms, end_ms, trailer, lines) tuples: trailer is
    whatever follows the end time on the timing line, lines the cue's text lines."""
    cues = []
    for block in re.split(r'\n\s*\n', text.replace('\r\n', '\n').replace('\r', '\n')):
        lines = block.strip('\n').split('\n')
        for i, line in enumerate(lines):
            m = CUE_TIME.match(line)
            if m:
                g = m.groups()
                cues.append((to_ms(*g[0:4]), to_ms(*g[4:8]), g[8], lines[i + 1:]))
                break
    return cues


def join_files(pairs):
    """Returns the joined SRT text for pairs, a list of (offset_seconds, path)."""
    out = []
    for offset, path in pairs:
        shift = int(round(float(offset) * 1000))
        with open(path, encoding='utf-8-sig') as f:
            for start, end, trailer, lines in parse_cues(f.read()):
                out.append((start + shift, end + shift, trailer, lines))
    chunks = []
    for n, (start, end, trailer, lines) in enumerate(out, 1):
        chunks.append(f"{n}\n{format_ms(start)} --> {format_ms(end)}{trailer}\n" + "\n".join(lines) + "\n")
    return "\n".join(chunks)


def main(argv=None):
    p = argparse.ArgumentParser(description="Join SubRip files, shifting each by an offset.")
    sub = p.add_subparsers(dest='mode', required=True)
    j = sub.add_parser('join', help="join OFFSET SRT pairs into DEST")
    j.add_argument('dest')
    j.add_argument('pairs', nargs='+', help="OFFSET SRT, repeated")
    a = p.parse_args(argv)
    if len(a.pairs) % 2:
        p.error("each SRT needs an OFFSET before it")
    pairs = list(zip(a.pairs[0::2], a.pairs[1::2]))
    try:
        for offset, _ in pairs:
            float(offset)
    except ValueError:
        p.error(f"not a number of seconds: {offset}")
    try:
        text = join_files(pairs)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(a.dest)), prefix='.join_')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
                f.write(text)
            os.replace(tmp, a.dest)
        except BaseException:
            os.unlink(tmp)
            raise
    except (OSError, UnicodeDecodeError) as e:
        print(f"ERROR {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
