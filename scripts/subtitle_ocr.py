#!/usr/bin/env python3
"""subtitle_ocr.py: Reads a VobSub subtitle pair (.idx and .sub) and converts one track
to SubRip by OCR with tesseract. Run by media_encode.sh; not meant to be sourced.

Commands:
    subtitle_ocr.py tracks IDX
        Prints one "LANG INDEX" line per track in the IDX file (LANG is the 2-letter code
        the file declares, INDEX the track number).
    subtitle_ocr.py ocr IDX INDEX OUT_SRT TESSERACT_LANG
        Converts track INDEX of the pair to OUT_SRT. The .sub is the file beside the IDX
        with the same base name. OUT_SRT is written through a temporary file, so a failed
        run leaves no partial output. Prints "<cues> cues, <skipped> skipped" on success.

Exit status: 0 on success, 1 on a failed conversion (missing .sub, no readable cues,
tesseract missing), 2 on a usage error.

Needs Pillow and the tesseract command with the language data for TESSERACT_LANG.
"""
import os
import re
import struct
import subprocess
import sys
import tempfile

try:
    from PIL import Image
except ImportError:
    Image = None


def read_idx(path):
    """Returns (palette, tracks) from an IDX file. tracks is a list of
    (lang, index, [(start_ms, filepos)])."""
    palette = []
    tracks = []
    with open(path, encoding='latin-1') as f:
        for line in f:
            line = line.strip()
            if line.startswith('palette:'):
                try:
                    palette = [int(x.strip(), 16) for x in line.split(':', 1)[1].split(',')]
                except ValueError:
                    palette = []
                continue
            m = re.match(r'id:\s*([A-Za-z]*)\s*,\s*index:\s*(\d+)', line)
            if m:
                tracks.append((m.group(1).lower(), int(m.group(2)), []))
                continue
            m = re.match(r'timestamp:\s*(-?)(\d+):(\d+):(\d+):(\d+)\s*,\s*filepos:\s*([0-9a-fA-F]+)', line)
            if m and tracks:
                sign, h, mi, s, ms, pos = m.groups()
                t = ((int(h) * 60 + int(mi)) * 60 + int(s)) * 1000 + int(ms)
                tracks[-1][2].append((-t if sign else t, int(pos, 16)))
    return palette, tracks


def read_spu(data, pos):
    """Returns the bytes of the subtitle packet that starts in the sector at pos."""
    spu = b''
    want = None
    sid = None
    while pos + 14 <= len(data) and data[pos:pos + 4] == b'\x00\x00\x01\xba':
        p = pos + 14 + (data[pos + 13] & 7)
        end = pos + 2048
        while p + 6 <= end and data[p:p + 3] == b'\x00\x00\x01':
            code = data[p + 3]
            length = struct.unpack('>H', data[p + 4:p + 6])[0]
            if code == 0xBD:
                payload = data[p + 9 + data[p + 8]:p + 6 + length]
                if payload:
                    if sid is None:
                        sid = payload[0]
                    if payload[0] == sid:
                        spu += payload[1:]
                        if want is None and len(spu) >= 2:
                            want = struct.unpack('>H', spu[:2])[0]
            p += 6 + length
        if want is not None and len(spu) >= want:
            return spu[:want]
        pos = end
    return spu


def decode_field(spu, offset, width, rows):
    """Decodes one field's run-length data into rows of 2-bit pixel values."""
    nib = offset * 2
    total = len(spu) * 2

    def get():
        nonlocal nib
        if nib >= total:
            return 0
        b = spu[nib >> 1]
        v = (b >> 4) if (nib & 1) == 0 else (b & 15)
        nib += 1
        return v

    out = []
    for _ in range(rows):
        row = []
        while len(row) < width:
            v = get()
            if v < 4:
                v = (v << 4) | get()
                if v < 16:
                    v = (v << 4) | get()
                    if v < 64:
                        v = (v << 4) | get()
            run, color = v >> 2, v & 3
            if run == 0:
                run = width - len(row)
            row.extend([color] * min(run, width - len(row)))
        if nib & 1:
            nib += 1
        out.append(row)
    return out


def decode_spu(spu, palette):
    """Returns (start_offset_ms, end_offset_ms or None, black-on-white PIL image) or None."""
    if len(spu) < 4:
        return None
    pos = struct.unpack('>H', spu[2:4])[0]
    colors = alpha = coords = offs = None
    start = stop = None
    seen = set()
    while 0 < pos <= len(spu) - 4 and pos not in seen:
        seen.add(pos)
        date, nxt = struct.unpack('>HH', spu[pos:pos + 4])
        ms = date * 1024 // 90
        p = pos + 4
        while p < len(spu):
            c = spu[p]
            p += 1
            if c in (0, 1):
                start = ms if start is None else start
            elif c == 2:
                stop = ms
            elif c == 3:
                colors = [spu[p] >> 4, spu[p] & 15, spu[p + 1] >> 4, spu[p + 1] & 15]
                p += 2
            elif c == 4:
                alpha = [spu[p] >> 4, spu[p] & 15, spu[p + 1] >> 4, spu[p + 1] & 15]
                p += 2
            elif c == 5:
                b = spu[p:p + 6]
                coords = ((b[0] << 4) | (b[1] >> 4), ((b[1] & 15) << 8) | b[2],
                          (b[3] << 4) | (b[4] >> 4), ((b[4] & 15) << 8) | b[5])
                p += 6
            elif c == 6:
                offs = struct.unpack('>HH', spu[p:p + 4])
                p += 4
            else:
                break
        if nxt == pos:
            break
        pos = nxt
    if start is None or coords is None or offs is None or colors is None:
        return None
    x1, x2, y1, y2 = coords
    w, h = x2 - x1 + 1, y2 - y1 + 1
    if w <= 0 or h <= 0:
        return None
    even = decode_field(spu, offs[0], w, (h + 1) // 2)
    odd = decode_field(spu, offs[1], w, h // 2)
    img = Image.new('L', (w, h), 255)
    px = img.load()
    for y in range(h):
        row = even[y // 2] if y % 2 == 0 else odd[y // 2]
        for x in range(w):
            v = row[x]
            # colors and alpha list the entries for pixel values 3, 2, 1, 0 in that order.
            if alpha is not None and alpha[3 - v] == 0:
                continue
            idx = colors[3 - v]
            rgb = palette[idx] if idx < len(palette) else 0
            lum = (299 * ((rgb >> 16) & 255) + 587 * ((rgb >> 8) & 255) + 114 * (rgb & 255)) // 1000
            if lum >= 150:
                px[x, y] = 0
    return start, stop, img


def ocr_image(img, lang):
    """Returns the recognised text lines of the image."""
    pad = Image.new('L', (img.width + 40, img.height + 40), 255)
    pad.paste(img, (20, 20))
    pad = pad.resize((pad.width * 2, pad.height * 2), Image.LANCZOS)
    fd, name = tempfile.mkstemp(suffix='.png')
    os.close(fd)
    try:
        pad.save(name)
        r = subprocess.run(['tesseract', name, '-', '-l', lang, '--psm', '6'],
                           capture_output=True, text=True)
    finally:
        os.unlink(name)
    if r.returncode != 0:
        raise RuntimeError('tesseract failed: ' + r.stderr.strip()[:200])
    return [fix_pipes(l.strip()) for l in r.stdout.splitlines() if l.strip()]


def fix_pipes(line):
    """Tesseract reads a capital I as a pipe; a pipe standing as a word becomes I."""
    line = re.sub(r"(?<![\w|])\|(?=\s|'|$)", 'I', line)
    return re.sub(r'(?<![\w|])\|(?=[a-z])', 'I', line)


def fmt(ms):
    s, m = divmod(max(ms, 0), 1000)
    mi, s = divmod(s, 60)
    h, mi = divmod(mi, 60)
    return f'{h:02d}:{mi:02d}:{s:02d},{m:03d}'


def cmd_tracks(idx):
    _, tracks = read_idx(idx)
    for lang, index, cues in tracks:
        if cues:
            print(lang, index)
    return 0


def cmd_ocr(idx, index, out, lang):
    if Image is None:
        print('subtitle_ocr.py: Pillow is not installed', file=sys.stderr)
        return 1
    sub = os.path.splitext(idx)[0] + '.sub'
    if not os.path.isfile(sub):
        print(f'subtitle_ocr.py: no .sub beside {idx}', file=sys.stderr)
        return 1
    palette, tracks = read_idx(idx)
    cues = next((c for _, i, c in tracks if i == index), None)
    if not cues:
        print(f'subtitle_ocr.py: track {index} has no cues in {idx}', file=sys.stderr)
        return 1
    with open(sub, 'rb') as f:
        data = f.read()
    entries = []
    skipped = 0
    try:
        for t, pos in cues:
            dec = decode_spu(read_spu(data, pos), palette)
            lines = ocr_image(dec[2], lang) if dec else []
            if not lines:
                skipped += 1
                continue
            end = t + dec[1] if dec[1] is not None else None
            entries.append([t + dec[0], end, lines])
    except (RuntimeError, FileNotFoundError, OSError) as e:
        print(f'subtitle_ocr.py: {e}', file=sys.stderr)
        return 1
    if not entries:
        print('subtitle_ocr.py: no readable cues', file=sys.stderr)
        return 1
    for i, e in enumerate(entries):
        if e[1] is None or e[1] <= e[0]:
            nxt = entries[i + 1][0] if i + 1 < len(entries) else e[0] + 3000
            e[1] = min(nxt - 1, e[0] + 5000)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(out)), suffix='.part')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
            for i, (s, e, lines) in enumerate(entries, 1):
                f.write(f'{i}\n{fmt(s)} --> {fmt(e)}\n' + '\n'.join(lines) + '\n\n')
        os.replace(tmp, out)
    except OSError as e:
        print(f'subtitle_ocr.py: {e}', file=sys.stderr)
        return 1
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print(f'{len(entries)} cues, {skipped} skipped')
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == 'tracks':
        return cmd_tracks(argv[2])
    if len(argv) == 6 and argv[1] == 'ocr' and argv[3].isdigit():
        return cmd_ocr(argv[2], int(argv[3]), argv[4], argv[5])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
