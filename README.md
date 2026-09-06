# video-encoder

Batch video encoding and Plex media renaming for a personal media library, with a shared configuration layer, a concurrency lock, a single source of truth for subtitle language codes, and a standalone subtitle-repair toolset for the leftover-ASS-tag problem some sidecar and embedded subtitles carry.

```
video-encoder/
├── .git/
├── README.md                     ← this file
└── scripts/
    ├── config.sh                  Shared paths, flags, and the concurrency lock
    ├── encoder_dry.sh             Preview an encode batch (writes nothing)
    ├── encoder.sh                  Run an encode batch for real
    ├── encoder_params.sh         Core batch encoder (called by the two above; can also be run standalone)
    ├── rename_dry.sh               Preview a rename batch (writes nothing)
    ├── rename.sh                     Run a rename batch for real
    ├── rename_params.sh             Plex-convention renamer for movies + TV episodes + subtitles (called by the two above; can also be run standalone)
    ├── subtitle_mux.sh             Shared: container-aware subtitle codec choice, sidecar discovery, external-subtitle ffmpeg arg building
    ├── subtitle_tag_strip.sh      Shared: strips leftover ASS override tags (e.g. {\an8}) from a plain-text subtitle file
    ├── subtitle_embed_dry.sh        Preview embedding a subtitle into one video (writes nothing)
    ├── subtitle_embed.sh              Embed a subtitle into one video for real
    ├── subtitle_embed_params.sh      Core single-file subtitle embedder (called by the two above; can also be run standalone)
    ├── subtitle_extract_dry.sh       Preview extracting an embedded subtitle to a sidecar (writes nothing)
    ├── subtitle_extract.sh             Extract an embedded subtitle to a sidecar for real
    ├── subtitle_extract_params.sh      Core single-file subtitle extractor (called by the two above; can also be run standalone)
    ├── scan_subtitle_types.sh     Standalone, read-only inventory of embedded subtitle codecs across a directory - no wrapper, no config.sh dependency
    ├── lang_table.sh              Shared language-code loader (bash side)
    └── lang_table.tsv             Canonical language data (single source of truth)
```

---

## Workflow

### 1. Encode a batch

```bash
cd scripts
./encoder_dry.sh    # preview — review the plan, nothing is written
./encoder.sh         # run it for real
```

Both wrappers source `config.sh` for paths/flags and call the real work out to `encoder_params.sh`, targeting `$INPUT_DIR`. Never run `encoder_dry.sh` and `encoder.sh` at the same time against the same output directory — see [Concurrency lock](#concurrency-lock).

To change quality, paths, or run against a different tree without editing any file:

```bash
CRF=18 PRESET=slow ./encoder.sh
VIDEOS_BASE=/mnt/scratch/Videos ./encoder_dry.sh
```

### 2. Rename freshly downloaded files into Plex convention

```bash
cd scripts
./rename_dry.sh    # preview — review the plan, nothing is written
./rename.sh          # run it for real
```

**This targets `$DOWNLOADS_INPUT_DIR` (`$DOWNLOADS_BASE/Complete`), not `$INPUT_DIR`.** Renaming is a pipeline stage *before* encoding: it runs against files fresh out of a download client's completed-downloads folder, not against the video library `encoder_dry.sh`/`encoder.sh` read from. `-O "$DOWNLOADS_BASE"` is passed separately — that's only where `rename_params.sh` keeps its own lock and logs (`$DOWNLOADS_BASE/.locks`, `$DOWNLOADS_BASE/Logs`), never the rename target itself.

To rename a directory other than `$DOWNLOADS_INPUT_DIR`, call `rename_params.sh` directly with an explicit target instead of going through the wrappers.

### 3. Rename, then encode

```bash
./rename_dry.sh && ./rename.sh
./encoder_dry.sh && ./encoder.sh
```

Run rename to completion before encoding: filenames must already be correct by the time the encoder builds sidecar-subtitle paths from them.

### 4. Fix a single subtitle's leftover ASS tags

Two single-file tools exist outside the main batch pipeline, for working on one video at a time rather than a whole library:

```bash
cd scripts
./subtitle_embed_dry.sh some_movie.mkv       # preview embedding an auto-discovered sidecar
./subtitle_embed.sh some_movie.mkv            # embed it for real

./subtitle_extract_dry.sh some_movie.mkv     # preview pulling an embedded track out to a sidecar
./subtitle_extract.sh some_movie.mkv           # do it for real
```

Both accept a bare filename relative to `$INPUT_DIR` (via `-I`, resolved as a fallback if the literal path doesn't exist) or an absolute path; a *relative* path to a file outside `$INPUT_DIR` won't resolve, since both wrappers `cd` into their own directory first, matching `encoder.sh`'s own pathing. See each `_params.sh` script's `-h` for the full flag set (explicit `-l`/`-t`/`-i`/`-o`, dry-run, force-overwrite, etc).

### 5. Scan a library for subtitle risk (optional, read-only)

```bash
cd scripts
./scan_subtitle_types.sh -r "$INPUT_DIR"
```

Inventories every embedded subtitle stream under a directory, classified by whether its codec can carry a leftover ASS override tag as literal on-screen text (`subrip`/`mov_text`) or not (`ass`/`ssa`, bitmap). Use it to find which files are worth running `subtitle_extract_params.sh` against. Unlike every other script here, it has no wrapper pair and doesn't source `config.sh` — it's read-only and takes its target directory as a plain argument.

---

## `config.sh`

Defines two independent variable groups, one for the video-library pipeline (from `VIDEOS_BASE`, default `$HOME/Videos`) and one for the rename pipeline's own source (from `DOWNLOADS_BASE`, default `$HOME/Downloads`):

| Variable | Default | Passed to |
|---|---|---|
| `INPUT_DIR` | `$VIDEOS_BASE/input` | `encoder_params.sh` positional arg; `subtitle_embed_params.sh`/`subtitle_extract_params.sh`'s `-I` |
| `OUTPUT_DIR` | `$VIDEOS_BASE/output` | `encoder_params.sh` `-o` (via `ENCODER_ARGS`) |
| `ARCHIVE_DIR` | `$VIDEOS_BASE/encoded` | `encoder_params.sh` `-M` (via `ENCODER_ARGS`) |
| `BACKUP_DIR` | `$VIDEOS_BASE/backup` | `encoder_params.sh` `-A` (via `ENCODER_ARGS`) |
| `CRF` | `22` | `encoder_params.sh` `-c` (via `ENCODER_ARGS`) |
| `PRESET` | `fast` | `encoder_params.sh` `-p` (via `ENCODER_ARGS`) |
| `DOWNLOADS_INPUT_DIR` | `$DOWNLOADS_BASE/Complete` | `rename_params.sh` positional arg (the actual rename target) |
| `DOWNLOADS_BASE` | `$HOME/Downloads` | `rename_params.sh` `-O` (lock/log location only, not the rename target) |

No paths or usernames are hardcoded — everything derives from `$HOME` unless overridden. `ENCODER_ARGS` is a prebuilt array (`-r -s -c "$CRF" -p "$PRESET" -o "$OUTPUT_DIR" -M "$ARCHIVE_DIR" -A "$BACKUP_DIR"`) that `encoder.sh`/`encoder_dry.sh` splice in ahead of `$INPUT_DIR`; there is no equivalent prebuilt array for rename, since `rename_params.sh` only ever needs the two raw directory values passed directly.

The subtitle single-file tools (`subtitle_embed.sh`/`_dry.sh`, `subtitle_extract.sh`/`_dry.sh`) source `config.sh` too, but only ever read `$INPUT_DIR` from it, passed as their `-I` fallback-resolution base — see Workflow step 4.

On the primary machine, `$HOME/Videos` resolves onto `/raid` — an mdadm RAID 1 array (`/dev/md0`, ext4) across two 8TB drives. See `../system/System Architecture.md` for the full storage/hardware/network reference.

## Concurrency lock

`encoder_params.sh` and `rename_params.sh` each take their own exclusive, non-blocking `flock`, immediately after validating the directory they operate on exists. A second run against the same directory, from any invocation path (the wrappers, or either script called directly), exits immediately with an error instead of racing. The lock releases automatically when the process exits, including on Ctrl-C.

Neither script's lock (or logs) live inside `TARGET_DIR`/the movie library — both route through an operational directory instead:
- `encoder_params.sh` locks `OUTPUT_DIR/.media.lock` and logs to `OUTPUT_DIR/Logs`, since `OUTPUT_DIR` is a working/encoding area, not a curated library.
- `rename_params.sh` takes an `-O DIR` flag (operational directory) for the same purpose: `rename.sh`/`rename_dry.sh` pass `-O "$DOWNLOADS_BASE"`, so its lock (`DOWNLOADS_BASE/.locks/<hash-of-target>.lock`) and logs (`DOWNLOADS_BASE/Logs`) stay out of the actual rename target. Since `rename_params.sh` can also run standalone against any target, `-O` defaults to the script's own directory when omitted.

`config.sh` and the wrappers contain no locking logic — they're path/flag plumbing only. Every `_params.sh` script can be run standalone, without going through a wrapper, and is still protected.

The subtitle single-file tools take their own locks too, scoped per input file (`subtitle_embed_params.sh`) or per destination sidecar path (`subtitle_extract_params.sh`), under `${TMPDIR:-/tmp}/subtitle_embed_locks` and `.../subtitle_extract_locks` respectively — independent of `encoder_params.sh`'s and `rename_params.sh`'s locks, since they operate on individual files rather than a batch directory.

## Centralized language table

`lang_table.tsv` is the single source of truth for every language code, alias, and display label used across the project — add a language once here and it's picked up everywhere. Each row has a primary 3-letter code (`code3`, ISO 639-2), a 2-letter code (`code2`, ISO 639-1, used in sidecar filenames), a display label, and a comma-separated alias list (e.g. `fra`'s alias is the bibliographic `fre`). **Only the primary `code3` is a valid `-l` value** anywhere in this project — an alias resolves for matching a file's own tag or for display, but isn't accepted as user input.

- `encoder_params.sh` sources `lang_table.sh` for its bash-side sidecar matching (`LANG_TABLE`, `LANG_3TO2`, `LANG_LABEL_BASH`), and its Python probe step reads `lang_table.tsv` directly for embedded-track display labels (which do resolve aliases, for display purposes only).
- `rename_params.sh` sources `lang_table.sh` for its `LANG_ALIASES` lookup, used to normalize subtitle filename language tags (e.g. `.eng.srt` → `.en.srt`, `.fre.srt` → `.fr.srt`) to the 2-letter form `encoder_params.sh`'s sidecar matching expects.
- `subtitle_embed_params.sh` and `subtitle_extract_params.sh` both source `lang_table.sh` directly. `subtitle_mux.sh` does not source it itself — it depends on `LANG_3TO2`/`LANG_LABEL_BASH` already being loaded by whichever script sourced `subtitle_mux.sh` first (see that file's own header). `subtitle_extract_params.sh` specifically resolves an embedded track's own language tag to a 2-letter sidecar suffix via `LANG_ALIASES` rather than `LANG_3TO2`, since that tag is read from the file, not typed by a user, and commonly is a bibliographic alias (`fre`, `ger`, `chi`, `dut`, `cze`, `rum`) rather than the primary code.

Both `lang_table.sh` and `lang_table.tsv` resolve their own file locations relative to themselves, not the caller's working directory, so this works regardless of where a script is invoked from. `lang_table.sh` is also safe to source more than once in the same process (an include guard makes the second call a no-op).

## `encoder_params.sh`

The core encoder is documented in full detail — every flag, the encoding/audio/subtitle decision logic, sidecar handling, logging format, and design rationale — in its own header comment. It can be run directly (bypassing `config.sh` and the lock) for one-off jobs outside the standard `VIDEOS_BASE` layout.

Its container-aware subtitle codec choice, sidecar discovery, and external-subtitle ffmpeg arg building live in the shared `subtitle_mux.sh` (also used by `subtitle_embed_params.sh`), and sidecar tag-stripping lives in the shared `subtitle_tag_strip.sh` (also used by `subtitle_embed_params.sh` and `subtitle_extract_params.sh`) — see those two files and the subtitle-tooling section below. A video whose *embedded* (not sidecar) subtitle track needs tag-stripping isn't handled by `encoder_params.sh` itself; run `subtitle_extract_params.sh` against it first, which turns the embedded track into a sidecar that `encoder_params.sh`'s existing sidecar discovery then picks up on the next encode with no further changes needed.

## `rename_params.sh`

Renames movie and TV-episode video and subtitle files into Plex convention (`Name (YYYY) {edition-X}` for movies; `Series - SxxEyy - Episode Title` for TV), including franchise-folder and show-root-folder restructuring, normalizing subtitle language tags and modifiers (`cc`/`sdh`/`forced`) against `lang_table.sh` so files renamed here are guaranteed to match what `encoder_params.sh`'s sidecar discovery looks for. Files it can't confidently normalize (unrecognized language, unrecognized modifier, or an episode-shaped name it can't fully parse) are skipped and logged rather than guessed — see the script's own header comment for the full name-parsing rules and known limitations, or `-h` for usage.

## Subtitle tag stripping (`subtitle_tag_strip.sh`)

Some subtitle files carry leftover ASS/SSA override tags (most commonly `{\an8}`, a positioning tag) as literal text, usually from a lazy ASS→SRT conversion somewhere upstream (a subtitle service, an encoder, etc). Most players, including Plex on TV clients, don't parse the tag and instead display it as on-screen text. `subtitle_tag_strip.sh` provides `strip_sidecar_sub()`, which strips any `{\...}` bracketed override sequence (structural match, not a tag-name keyword list) from a plain-text subtitle file, writing the result to a scratch copy — the original file is never modified.

This is sidecar-file logic specifically (a real file already on disk); an *embedded* subtitle stream can't be edited in place the same way. `subtitle_extract_params.sh` (below) handles that case by extracting the embedded track to a temp file first, then running it through the exact same `strip_sidecar_sub()`.

Genuine `ass`/`ssa` tracks are never run through this pipeline anywhere in this project: their override tags are real positioning, correctly rendered by an ASS-capable player, not a conversion artifact to remove.

## `subtitle_embed_params.sh` / `subtitle_embed.sh` / `subtitle_embed_dry.sh`

Muxes a sidecar `.srt` file into a video as a new subtitle stream, without re-encoding video or audio — `encoder_params.sh`'s sidecar-embedding mechanism, pulled out as a standalone tool for embedding into an already-encoded file outside of a full batch encode. Takes an explicit `.srt` path or auto-discovers a Plex-convention sidecar next to the video (same convention as `encoder_params.sh`'s own `-l`/sidecar lookup). Every subtitle muxed in has ASS override tags stripped first. Supports `.mkv`/`.mp4` only. See `-h` for the full flag set.

## `subtitle_extract_params.sh` / `subtitle_extract.sh` / `subtitle_extract_dry.sh`

The reverse: extracts an embedded `subrip`/`mov_text` subtitle track into a Plex-convention sidecar `.srt`, tag-stripped via the same pipeline. Refuses to run on a genuine `ass`/`ssa` track (real positioning, not a conversion artifact) or a bitmap track (no text to extract). Auto-pick prefers a plain target track over a CC/forced one for the requested language, regardless of stream order in the container. The source video is never modified. See `-h` for the full flag set.

## `scan_subtitle_types.sh`

Standalone, read-only directory scanner — see Workflow step 5 above. No config.sh dependency, no wrapper pair, no writes beyond an optional `-o` report file.
