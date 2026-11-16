#!/usr/bin/env python3
"""Reads a media file's streams with ffprobe and prints them as lines for a shell caller.

Usage:
    python3 probe_streams.py encode FILE SUB_LANGS LANG_TABLE_TSV
    python3 probe_streams.py scan FILE

encode mode (called by encode.sh) prints one line per stream group:
    VIDEO <codec> <height> <fps> <label>
    VIDEOFMT <pix_fmt>                       ("unknown" when the probe reports none)
    VIDEOCOLOR <color_transfer> <has_dovi>   (transfer is "unknown" when untagged; has_dovi is
                                              1 when the video stream carries a Dolby Vision
                                              configuration record)
    AUDIO <index> <codec> <lang> <title>
    SUB <index> <codec> <lang> <is_target> <is_forced> <is_signs> <is_cc> <label>
    ERROR <message>                          (probe failure, or no video stream)
SUB_LANGS is a comma-separated list of 3-letter codes; is_target is 1 when the track's
language is in it, an untagged ("und") track counting as "eng". LANG_TABLE_TSV is the path
of lang_table.tsv, which supplies the display labels.

scan mode (called by scan_subtitle_types.sh) prints one tab-separated line per subtitle
stream: FILE, INDEX, CODEC, LANG, CLASS. CLASS is TEXT_RISK (subrip, mov_text: can carry a
literal ASS override tag), ASS_NATIVE, BITMAP or OTHER. A failed probe prints one line with
ERROR in the INDEX, CODEC and LANG columns and PROBE_FAILED:<message> or
PARSE_FAILED:<message> as the class.

Exit status: 0 whenever the probe ran, including a probe failure (reported as a line, so a
caller reading the output sees it); 2 on a usage error.
"""
import argparse
import json
import subprocess
import sys

VIDEO_CODEC_NAMES = {
    'h264': 'H.264',
    'hevc': 'H.265',
    'mpeg2video': 'MPEG-2',
    'mpeg4': 'MPEG-4',
    'vp8': 'VP8',
    'vp9': 'VP9',
    'av1': 'AV1',
    'vc1': 'VC-1',
    'theora': 'Theora',
    'mjpeg': 'MJPEG',
    'prores': 'ProRes',
}

AUDIO_CODEC_NAMES = {
    'aac': 'AAC',
    'ac3': 'Dolby Digital',
    'eac3': 'Dolby Digital Plus',
    'dts': 'DTS',
    'truehd': 'TrueHD',
    'flac': 'FLAC',
    'opus': 'Opus',
    'mp3': 'MP3',
    'vorbis': 'Vorbis',
    'pcm_s16le': 'PCM',
    'pcm_s24le': 'PCM',
    'pcm_s32le': 'PCM',
}

CHANNEL_LAYOUTS = {
    'mono': 'Mono',
    'stereo': 'Stereo',
    '2.1': '2.1',
    '3.0': '3.0',
    '3.0(back)': '3.0',
    'quad': '4.0',
    'quad(side)': '4.0',
    '4.0': '4.0',
    '4.1': '4.1',
    '5.0': '5.0',
    '5.0(side)': '5.0',
    '5.1': '5.1',
    '5.1(side)': '5.1',
    '6.0': '6.0',
    '6.1': '6.1',
    '7.0': '7.0',
    '7.1': '7.1',
    '7.1(wide)': '7.1',
    '7.1(wide-side)': '7.1',
    'hexagonal': '6.0',
    'octagonal': '8.0',
}

CC_TERMS = {'sdh', 'cc', 'hi', 'hearing impaired', 'closed caption', 'closed captions'}

TEXT_RISK = {'subrip', 'mov_text'}
ASS_NATIVE = {'ass', 'ssa'}
BITMAP = {'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvbsub'}


def run_ffprobe(path, select=None):
    """Returns (streams, failure). streams is the list of stream dicts ffprobe reports
    (restricted to one stream type with select, e.g. "s"); failure is None on success,
    else ("probe", returncode, stderr) when ffprobe exited non-zero or
    ("parse", exception) when its output was not JSON, with streams empty."""
    cmd = ['ffprobe', '-v', 'quiet', '-print_format', 'json', '-show_streams']
    if select:
        cmd += ['-select_streams', select]
    result = subprocess.run(cmd + [path], capture_output=True, text=True)
    if result.returncode != 0:
        return [], ("probe", result.returncode, result.stderr.strip())
    try:
        return json.loads(result.stdout).get('streams', []), None
    except json.JSONDecodeError as e:
        return [], ("parse", e)


def load_lang_names(tsv_path):
    """Reads lang_table.tsv (also loaded by lang_table.sh for the bash side). Returns
    {code or alias: display label}. A file that cannot be read is reported on stderr and
    gives an empty mapping, so labels fall back to the upper-cased code."""
    names = {}
    try:
        with open(tsv_path, encoding='utf-8') as f:
            for line in f:
                line = line.rstrip('\n')
                if not line or line.startswith('#'):
                    continue
                parts = line.split('\t')
                if len(parts) < 3:
                    continue
                code3, label = parts[0], parts[2]
                aliases = parts[3].split(',') if len(parts) > 3 and parts[3] != '-' else []
                names[code3] = label
                for alias in aliases:
                    names[alias] = label
    except OSError as e:
        print(f"ERROR could not read lang_table_tsv ({tsv_path}): {e}", file=sys.stderr)
    return names


def lang_name(names, code):
    """Returns the display label for code, or the upper-cased code when it has none."""
    return names.get(code.lower(), code.upper())


def match_lang(code):
    """Returns code, except that "und" (untagged) tracks match as English."""
    return 'eng' if code == 'und' else code


def audio_layout_label(stream):
    """Returns the channel layout label of an audio stream ('' when it has no channels)."""
    layout_raw = stream.get('channel_layout', '')
    channels = stream.get('channels', 0)
    if layout_raw and layout_raw in CHANNEL_LAYOUTS:
        return CHANNEL_LAYOUTS[layout_raw]
    if channels == 1:
        return 'Mono'
    if channels == 2:
        return 'Stereo'
    if channels > 0:
        return f"{channels}ch"
    return ''


def video_lines(streams):
    """Returns the VIDEO, VIDEOFMT and VIDEOCOLOR lines for the first video stream, or
    one ERROR line when there is none."""
    video = [s for s in streams if s.get('codec_type') == 'video']
    if not video:
        return ["ERROR no video stream found in file"]
    v = video[0]
    fps = v.get('r_frame_rate', '24/1')
    if fps in ('0/0', '0'):
        fps = '24/1'
    codec_raw = v.get('codec_name', '')
    codec_label = VIDEO_CODEC_NAMES.get(codec_raw, codec_raw.upper())
    has_dovi = int(any(sd.get('side_data_type') == 'DOVI configuration record'
                       for sd in v.get('side_data_list', [])))
    return [f"VIDEO {codec_raw} {v.get('height', 0)} {fps} {codec_label}",
            f"VIDEOFMT {v.get('pix_fmt', 'unknown')}",
            f"VIDEOCOLOR {v.get('color_transfer', 'unknown')} {has_dovi}"]


def audio_lines(streams, names):
    """Returns one AUDIO line per audio stream; its title is codec, language and layout."""
    lines = []
    for s in (s for s in streams if s.get('codec_type') == 'audio'):
        codec = s.get('codec_name', 'unknown')
        out_lang = match_lang(s.get('tags', {}).get('language', 'und'))
        codec_label = AUDIO_CODEC_NAMES.get(codec, codec.upper())
        title = f"{codec_label} {lang_name(names, out_lang)} {audio_layout_label(s)}".strip()
        lines.append(f"AUDIO {s.get('index', 0)} {codec} {out_lang} {title}")
    return lines


def sub_lines(streams, sub_langs, names):
    """Returns one SUB line per subtitle stream. is_signs marks a title containing "sign"
    or "song"; is_cc marks the hearing-impaired disposition or a CC_TERMS title."""
    lines = []
    for s in (s for s in streams if s.get('codec_type') == 'subtitle'):
        lang = s.get('tags', {}).get('language', 'und')
        title_low = s.get('tags', {}).get('title', '').lower()
        disp = s.get('disposition', {})
        is_forced = int(disp.get('forced', 0) == 1)
        is_hi = int(disp.get('hearing_impaired', 0) == 1)
        is_target = int(match_lang(lang) in sub_langs)
        is_signs = int(any(w in title_low for w in ('sign', 'song')))
        is_cc = int(is_hi or any(t in title_low for t in CC_TERMS))
        lines.append(f"SUB {s.get('index', 0)} {s.get('codec_name', 'unknown')} {lang} "
                     f"{is_target} {is_forced} {is_signs} {is_cc} {lang_name(names, lang)}")
    return lines


def encode_output(path, sub_langs, names):
    """Returns the lines encode mode prints for the file at path."""
    streams, failure = run_ffprobe(path)
    if failure and failure[0] == "probe":
        return [f"ERROR ffprobe exited {failure[1]}: {failure[2]}"]
    if failure:
        return [f"ERROR failed to parse ffprobe output: {failure[1]}"]
    return video_lines(streams) + audio_lines(streams, names) + sub_lines(streams, sub_langs, names)


def scan_class(codec):
    """Returns the scan class of a subtitle codec name."""
    if codec in TEXT_RISK:
        return 'TEXT_RISK'
    if codec in ASS_NATIVE:
        return 'ASS_NATIVE'
    if codec in BITMAP:
        return 'BITMAP'
    return 'OTHER'


def scan_output(path):
    """Returns the lines scan mode prints for the file at path."""
    streams, failure = run_ffprobe(path, select='s')
    if failure and failure[0] == "probe":
        return [f"{path}\tERROR\tERROR\tERROR\tPROBE_FAILED:{failure[2]}"]
    if failure:
        return [f"{path}\tERROR\tERROR\tERROR\tPARSE_FAILED:{failure[1]}"]
    return [f"{path}\t{s.get('index', 0)}\t{s.get('codec_name', 'unknown')}\t"
            f"{s.get('tags', {}).get('language', 'und')}\t"
            f"{scan_class(s.get('codec_name', 'unknown'))}" for s in streams]


def main(argv=None):
    p = argparse.ArgumentParser(description="Print a media file's streams as lines for a shell caller.")
    sub = p.add_subparsers(dest='mode', required=True)
    enc = sub.add_parser('encode', help="video, audio and subtitle lines for encode.sh")
    enc.add_argument('file')
    enc.add_argument('sub_langs', help="comma-separated 3-letter codes of the wanted subtitle languages")
    enc.add_argument('lang_table_tsv', help="path of lang_table.tsv")
    scan = sub.add_parser('scan', help="subtitle class lines for scan_subtitle_types.sh")
    scan.add_argument('file')
    a = p.parse_args(argv)
    if a.mode == 'encode':
        lines = encode_output(a.file, set(a.sub_langs.split(',')), load_lang_names(a.lang_table_tsv))
    else:
        lines = scan_output(a.file)
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
