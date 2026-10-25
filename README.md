# plex

Batch video encoding and Plex media renaming for a personal media library, with a shared configuration layer, a concurrency lock, a single source of truth for subtitle language codes, and subtitle handling built into the encoder: embed or sidecar delivery, and stripping of the leftover ASS tags some sidecar and embedded subtitles carry.

```
plex/
├── README.md                       ← this file
└── scripts/
    ├── config.sh                   Shared paths, flags, and the concurrency lock
    ├── encoder_dry.sh              Preview an encode batch (writes nothing)
    ├── encoder.sh                  Run an encode batch for real
    ├── encoder_params.sh           Core batch encoder: copy/transcode decisions, HDR-to-SDR conversion, output verification (called by the two above; can also be run standalone)
    ├── rename_dry.sh               Preview a rename batch (writes nothing)
    ├── rename.sh                   Run a rename batch for real
    ├── rename_params.sh            Plex-convention renamer for movies + TV episodes + subtitles (called by the two above; can also be run standalone)
    ├── subtitle_mux.sh             Shared: container-aware subtitle codec choice, sidecar discovery, embedded/sidecar matching, output stream-count check, external-subtitle ffmpeg arg building
    ├── subtitle_tag_strip.sh       Shared: strips leftover ASS override tags (e.g. {\an8}) from a plain-text subtitle file
    ├── scan_subtitle_types.sh      Standalone, read-only inventory of embedded subtitle codecs across a directory - no wrapper, no config.sh dependency
    ├── lang_table.sh               Shared language-code loader (bash side) and canon_lang()
    └── lang_table.tsv              Canonical language data (single source of truth)
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

The dry run prints each file's decision, including whether an HDR source is tone-mapped to SDR (see [HEVC and HDR sources](#hevc-and-hdr-sources)).

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

**This targets `$DOWNLOADS_INPUT_DIR` (`$DOWNLOADS_BASE/Complete`), not `$INPUT_DIR`.** Renaming is a pipeline stage *before* encoding: it runs against files fresh out of a download client's completed-downloads folder, not against the video library `encoder_dry.sh`/`encoder.sh` read from. The wrappers also pass `-O "$DOWNLOADS_BASE"`, which only sets where the lock and logs go (see [Concurrency lock](#concurrency-lock)).

To rename a directory other than `$DOWNLOADS_INPUT_DIR`, call `rename_params.sh` directly with an explicit target instead of going through the wrappers.

### 3. Move the renamed files, then encode

Renaming and encoding read different directories, and no script moves files between them. After `rename.sh` finishes, move the renamed items from `$DOWNLOADS_INPUT_DIR` into `$INPUT_DIR` by hand, then:

```bash
cd scripts
./encoder_dry.sh    # preview
./encoder.sh         # run it for real
```

Rename must finish first: filenames must already be correct by the time the encoder builds sidecar-subtitle paths from them.

### 4. Choose how subtitles are delivered

Subtitle handling happens during the encode; there is no separate per-file tool. `-S embed` muxes subtitles into the output, and `-S sidecar` writes them next to it as Plex-named files (see [`encoder_params.sh`](#encoder_paramssh)). The default is `DEFAULT_SUB_MODE` near the top of `encoder_params.sh`. To pick a mode for the wrapper runs, add `-S embed` or `-S sidecar` to `ENCODER_ARGS` in `config.sh`; to pick one for a single run, call `encoder_params.sh` directly.

### 5. Scan a library for subtitle risk (optional, read-only)

```bash
cd scripts
./scan_subtitle_types.sh -r "$INPUT_DIR"
```

Inventories every embedded subtitle stream under a directory, classified by whether its codec can carry a leftover ASS override tag as literal on-screen text (`subrip`/`mov_text`) or not (`ass`/`ssa`, bitmap). Use it to find which files carry tracks that may need tag stripping. It takes its target directory as a plain argument and writes nothing beyond an optional `-o` report file.

---

## `config.sh`

Defines two independent variable groups, one for the video-library pipeline (from `VIDEOS_BASE`) and one for the rename pipeline's own source (from `DOWNLOADS_BASE`):

| Variable | Default | Passed to |
|---|---|---|
| `VIDEOS_BASE` | `$HOME/Videos` | Base for the five video-library variables below |
| `INPUT_DIR` | `$VIDEOS_BASE/input` | `encoder_params.sh` positional arg |
| `OUTPUT_DIR` | `$VIDEOS_BASE/output` | `encoder_params.sh` `-o` (via `ENCODER_ARGS`) |
| `ARCHIVE_DIR` | `$VIDEOS_BASE/encoded` | `encoder_params.sh` `-M` (via `ENCODER_ARGS`) |
| `BACKUP_DIR` | `$VIDEOS_BASE/backup` | `encoder_params.sh` `-A` (via `ENCODER_ARGS`) |
| `CRF` | `22` | `encoder_params.sh` `-c` (via `ENCODER_ARGS`) |
| `PRESET` | `fast` | `encoder_params.sh` `-p` (via `ENCODER_ARGS`) |
| `DOWNLOADS_BASE` | `$HOME/Downloads` | `rename_params.sh` `-O` (lock/log location only, not the rename target) |
| `DOWNLOADS_INPUT_DIR` | `$DOWNLOADS_BASE/Complete` | `rename_params.sh` positional arg (the actual rename target) |

No paths or usernames are hardcoded — everything derives from `$HOME` unless overridden. `ENCODER_ARGS` is a prebuilt array (`-r -s -c "$CRF" -p "$PRESET" -o "$OUTPUT_DIR" -M "$ARCHIVE_DIR" -A "$BACKUP_DIR"`) that `encoder.sh`/`encoder_dry.sh` splice in ahead of `$INPUT_DIR`; there is no equivalent prebuilt array for rename, since `rename_params.sh` only ever needs the two raw directory values passed directly.

`config.sh` does not set the maximum output height. The encoder's `-H` flag does (default 1080), so the wrappers always use 1080; call `encoder_params.sh` directly to change it.

## Concurrency lock

`encoder_params.sh` and `rename_params.sh` each take their own exclusive, non-blocking `flock`, once the directory they work from is ready: `encoder_params.sh` creates `OUTPUT_DIR` first, and `rename_params.sh` resolves the target's canonical path. A second run against the same directory, from any invocation path (the wrappers, or either script called directly), exits immediately with an error instead of racing. The lock releases automatically when the process exits, including on Ctrl-C.

Neither script's lock (or logs) live inside the directory being processed — both route through an operational directory instead:
- `encoder_params.sh` locks `OUTPUT_DIR/.media.lock` and logs to `OUTPUT_DIR/Logs`, since `OUTPUT_DIR` is a working/encoding area, not a curated library.
- `rename_params.sh` takes an `-O DIR` flag (operational directory) for the same purpose: `rename.sh`/`rename_dry.sh` pass `-O "$DOWNLOADS_BASE"`, so its lock (`DOWNLOADS_BASE/.locks/<hash-of-target>.lock`) and logs (`DOWNLOADS_BASE/Logs`) stay out of the actual rename target. Since `rename_params.sh` can also run standalone against any target, `-O` defaults to the script's own directory when omitted.

`config.sh` and the wrappers contain no locking logic — they're path/flag plumbing only. Every `_params.sh` script can be run standalone, without going through a wrapper, and is still protected.

## Centralized language table

`lang_table.tsv` is the single source of truth for every language code, alias, and display label used across the project — add a language once here and it's picked up everywhere. Each row has a primary 3-letter code (`code3`, ISO 639-2), a 2-letter code (`code2`, ISO 639-1, used in sidecar filenames), a display label, and a comma-separated alias list (e.g. `fra`'s alias is the bibliographic `fre`). **Pass the primary `code3` to `-l`.** Sidecar discovery looks each `-l` value up in `LANG_3TO2` and silently skips a value with no entry, and the encoder's own check only warns when a value is not 2–3 letters. Aliases are for matching a file's own language tag and for display.

- `encoder_params.sh` sources `lang_table.sh` for its bash-side sidecar matching (`LANG_TABLE`, `LANG_3TO2`, `LANG_LABEL_BASH`, `canon_lang()`), and its Python probe step reads `lang_table.tsv` directly for embedded-track display labels (which resolve aliases).
- `rename_params.sh` sources `lang_table.sh` for its `LANG_ALIASES` lookup, used to normalize subtitle filename language tags (e.g. `.eng.srt` → `.en.srt`, `.fre.srt` → `.fr.srt`) to the 2-letter form `encoder_params.sh`'s sidecar matching expects.
- `subtitle_mux.sh` does not source `lang_table.sh`: it depends on `LANG_3TO2`/`LANG_LABEL_BASH`/`canon_lang()` already being loaded by whichever script sourced it. `canon_lang()` maps any code3, code2, or alias to the primary code3 (`und` → `eng`); `subtitle_mux.sh` and `encoder_params.sh` use it so a file's own tag compares equal to a code typed for `-l`.

Both `lang_table.sh` and `lang_table.tsv` resolve their own file locations relative to themselves, not the caller's working directory, so this works regardless of where a script is invoked from. `lang_table.sh` is also safe to source more than once in the same process (an include guard makes the second call a no-op).

## `encoder_params.sh`

The core encoder is documented in full detail — every flag, the audio/subtitle decision logic, sidecar handling, and logging format — in its own header comment (`-h`). It can be run directly (bypassing `config.sh`; it still takes its own lock) for one-off jobs outside the standard `VIDEOS_BASE` layout. Run directly, its defaults are CRF 18, preset `slow` and output to `./encoded`; the wrappers override them through `config.sh` (22 and `fast`). It requires an ffmpeg build with the `zscale` and `tonemap` filters and exits before any work if either is missing.

### Video decisions

`MAX_HEIGHT` is the encoder's `-H` value (default 1080).

| Source | Result |
|---|---|
| h264, SDR, 8-bit 4:2:0 (`yuv420p`/`yuvj420p`), height ≤ `MAX_HEIGHT` | Stream copy (colour tags are unchanged because the stream is not touched) |
| h264, SDR, any other pixel format (e.g. 10-bit), height ≤ `MAX_HEIGHT` | Re-encoded to x264 as `yuv420p` |
| h264 with a PQ or HLG transfer, height ≤ `MAX_HEIGHT` | Tone-mapped to SDR, re-encoded to x264, tagged bt709 |
| h264, height > `MAX_HEIGHT` | Scaled to `MAX_HEIGHT` (width derived from the aspect ratio, even-numbered), re-encoded to x264; if PQ or HLG, scaled and then tone-mapped |
| Any other codec, SDR | Re-encoded to x264 at native or `MAX_HEIGHT` height |
| Any other codec, PQ or HLG | Tone-mapped to SDR, re-encoded to x264, tagged bt709 |

A source whose probe reports no pixel format is treated as eligible for stream copy.

An HDR source is identified by its colour *transfer function* (`smpte2084` for PQ, `arib-std-b67` for HLG), read by the probe step. Colour primaries are not used: they describe gamut, and BT.2020 primaries can accompany an SDR curve.

Every encoded file's video stream is probed while it is still the `.tmp` file. A file whose transfer function is still PQ or HLG is rejected: it is deleted, logged as `FAILED (HDR transfer in output)`, and never reaches `OUTPUT_DIR`. This ordering matters because `-M` copies the output to the archive and then deletes it, and `-A` moves the source to the backup directory; both run only after the probe passes. The encode can exit 0 with wrong tags, and those two steps are destructive.

The same ordering applies to subtitles: the `.tmp` file's subtitle stream count is probed against the number of streams the encoder emitted. A mismatch deletes the file, logs `FAILED (subtitle stream count ...)`, and leaves the source and its sidecars untouched.

### HEVC and HDR sources

**HEVC sources** are always re-encoded to x264. The script prints a warning because the x264 output can be larger than the HEVC source, and reports the size change after each encode.

**HDR sources are converted to SDR rather than carried through, and tagged explicitly, for these reasons:**

1. **libx264 copies the input's colour tags into the output header unless they are set.** The three tags (colour primaries, transfer characteristics, matrix coefficients) tell a player which gamut, brightness curve and YCbCr conversion to apply. `-pix_fmt yuv420p` changes bit depth only; it does not change the transfer curve. An HDR10 source encoded to 8-bit h264 without tone-mapping therefore yields PQ-coded pixels tagged BT.2020/PQ. Observed with ffmpeg 6.1.1: an encode without colour handling reports `color_transfer=smpte2084`, `color_primaries=bt2020`, `color_space=bt2020nc`.

2. **Roku does not list HDR10 for h264.** Roku's media specification lists HDR support for AVC (H.264) only as Dolby Vision profile 9 (`dvav.09`), with HDR10 listed under HEVC, VP9 and AV1 ([developer.roku.com/dev/docs/media](https://developer.roku.com/dev/docs/media)). Dolby Vision profile 8 is 10-bit HEVC; the 8-bit AVC profile is 9 ([Dolby Vision profiles](https://en.wikipedia.org/wiki/Dolby_Vision)). An 8-bit h264 stream tagged PQ/BT.2020, or carrying a profile 8 configuration record, matches no HDR combination Roku lists for AVC.

3. **Observed behavior on a Roku running the Plex app.** Files of that shape stop within about 0.4 s of the playback start request, before any transcode segment is requested, and play in the Plex app on Android. Rewriting only the h264 colour tags to bt709 (no re-encode) made one such file play on the Roku. The Roku-side reason for rejecting the tags is not documented in any source found. The Plex Roku client's declared decoder capabilities (from the server log) are h264 high profile, 1080p, level 4.1, which is what the encode path targets.

4. **Tone-mapping, rather than retagging, makes the tags true.** Tags describe pixels. If the pixels are PQ-coded and the tags say BT.709, a player displays them as SDR and the picture is flat or dim. The tone-map converts the pixels to BT.709 before libx264 sees them, so the explicit bt709 tags describe the actual content.

The conversion filter chain lives in one constant, `SDR_TONEMAP_CHAIN`, near the top of the script. It uses `hable` tone-mapping with `npl=100`, and was run on a synthetic PQ clip, where it produced bt709 tags; it has not been tuned on real footage, and changing it changes only the look of converted sources.

### Known limitations

- **Missing primaries or matrix tags.** A PQ source whose colour primaries and matrix tags are unspecified fails in `zscale` with `no path between colorspaces`. The file is logged `FAILED`, no output is written, and the source is untouched. Reproduced with a PQ-tagged clip that carries no primaries or matrix tag.
- **HLG.** HLG sources take the same chain; it was run with PQ input only.
- **Dolby Vision configuration record.** A source's Dolby Vision record is carried onto an encoded output by ffmpeg 6.1.1 (a libx264 output with one was observed), and no verified method strips it at encode time. The script warns when a source or an output carries one. Whether the record alone prevents Roku playback is untested.
- **Mislabelled SDR.** A source with SDR pixels wrongly tagged PQ is tone-mapped like an HDR source, because the tag is the only machine-readable signal.
- **Existing HDR-sourced outputs.** An output encoded without tone-mapping from an HDR source holds PQ-coded pixels. Re-encode it from the source; a tag rewrite makes it play but leaves the picture misdescribed.

### Subtitles

Sidecar discovery, the container-aware subtitle codec choice, embedded/sidecar matching, the output stream-count check, and external-subtitle ffmpeg arg building live in `subtitle_mux.sh`.

- **Discovered sidecars:** `<name>.<lang2>.<ext>`, `.cc.<ext>` (or `.sdh.<ext>` when no `.cc` file exists), and `.forced.<ext>`, for each `-l` language. `<ext>` is `srt`, `vtt`, `ass`, `ssa` or `sub`, tried in that order; the first file whose probed codec is `subrip`, `webvtt`, `ass` or `microdvd` is claimed, and the others are reported as not embedded. A `.sub` that is not MicroDVD text (a VobSub bitmap) is not claimed.
- **Sidecar codec:** in MKV, `webvtt` and `microdvd` convert to `srt`, and `ass` is copied; in MP4 every claimed format becomes `mov_text`. Only `subrip` sidecars are tag-stripped before muxing (see [Subtitle tag stripping](#subtitle-tag-stripping-subtitle_tag_stripsh)); an `ass` sidecar keeps its tags as positioning.
- **Sidecar vs. embedded:** an embedded track is dropped only when a sidecar of the same primary language and the same type (standard, CC, forced) exists. Language codes are compared after alias resolution (`fre` = `fra`) and an untagged track counts as `eng`. An embedded forced or CC track survives a plain sidecar. A second standard embedded track of the same language is dropped.
- **Files not embedded:** any other subtitle-extension file named `<video name>.*` next to the video (`.idx`, `.sup`, `.smi`, a bitmap `.sub`, a lower-precedence duplicate format such as `.en.ass` beside `.en.srt`, a language outside `-l`, an unrecognized modifier such as `.en.hi.srt`, an `.sdh` file shadowed by a `.cc` file) produces a warning and a log line. It is not embedded and not moved, and stays in the source directory.
- **`-A` and sidecars:** the muxed sidecar originals move to the backup directory before the video, mirroring the same relative path (flat by file name for file and glob inputs). A destination that already exists is never overwritten. If any sidecar move fails, the video stays in place with its remaining sidecars.
- **UTF-8 only:** a sidecar whose text is not valid UTF-8 is not claimed and is reported with the other unclaimed files. Plex expects UTF-8. `iconv` is a dependency.
- **Sidecar mode (`-S sidecar`):** instead of embedding, the encode extracts embedded text tracks in the `-l` languages and writes the input sidecars next to the output as `<output name>.<lang2>[.cc|.forced].<ext>` (`srt`; `ass` for ASS/SSA; `vtt` for WebVTT), in the same ffmpeg run as the video. Extracted `srt` files are tag-stripped. Bitmap tracks (PGS, VobSub) stay embedded in MKV and are dropped in MP4. Sidecars are promoted before the video, so an existing output video means a complete set. A second track with the same language and type is dropped. `-M` copies the sidecars with the video; `-A` moves the input sidecars as before. `-S embed` muxes the subtitles into the output instead. The default is set by `DEFAULT_SUB_MODE` near the top of `encoder_params.sh` (currently `embed`); `-h` prints the active default.
- **`-M` failure:** a failed archive leaves the output in place, skips `-A` for that file, and counts the file as failed.

In `-S embed` mode, an *embedded* SubRip or mov_text track that carries ASS override tags is extracted to a scratch file, tag-stripped, and muxed from the stripped copy in place of the source track; a track without tags is muxed from the source. A dry run does not inspect embedded tracks. The stripped track keeps its language, type and title, but its language tag becomes the primary code (`fre` becomes `fra`, `und` becomes `eng`), and it is placed after the other embedded tracks, as sidecars are.

## `rename_params.sh`

Renames movie and TV-episode video and subtitle files into Plex convention:

- **Movies:** `Franchise/Movie Name (YYYY) {edition-A B}/Movie Name (YYYY) {edition-A B}.ext`. Several editions in one name are joined alphabetically with Remastered last.
- **Episodes:** `Series Name (YYYY)/Season XX/Series Name - SxxEyy[ - Title].ext`. The year comes from the show folder's name or the file's name. When neither has one, the show folder is `Series Name` and you add the year to that one folder by hand. A release folder that names the series in its own `(...)` group (`Native Title (Series Title) (Season 02)`) is emptied into the series folder beside it, so every season merges into one show folder. A name without an `SxxEyy` token (`Episode 12`, `- 12`, `- 12 - Title`, `Show.12`) is read as an episode only when at least two videos in the same folder share the title before the number; the title after it is dropped. A `.5` after the number is kept as a special (`Show - 02.5` becomes `S01E02.5`).
- **Subtitles:** language tags and modifiers (`cc`/`sdh`/`forced`) are normalized against `lang_table.sh`, so files renamed here match what `encoder_params.sh`'s sidecar discovery looks for.

Skipped and logged rather than guessed: an unrecognized subtitle language or modifier, ranged or multi-episode numbering (`S01E01-E02`, `S01E01E02`), a movie name with no year, and a rename target that already exists (unless `-f`, which asks for a typed `yes` before overwriting). The script refuses to run as root, so the folders and logs it creates belong to the library's owner. The script's header comment has the full name-parsing rules and known limitations; `-h` has usage.

## Subtitle tag stripping (`subtitle_tag_strip.sh`)

Some subtitle files carry leftover ASS/SSA override tags (for example `{\an8}`, a positioning tag) as literal text, from an ASS→SRT conversion that keeps the tags in the text. A player that does not parse the tag displays it as on-screen text. `subtitle_tag_strip.sh` provides `strip_sidecar_sub()`, which strips any `{\...}` bracketed override sequence (structural match, not a tag-name keyword list) from a `subrip` subtitle file, writing the result to a scratch copy — the original file is never modified.

This is sidecar-file logic specifically (a real file already on disk); an *embedded* subtitle stream can't be edited in place the same way. For that case `encoder_params.sh` (`-S embed`) extracts the track to a temp file first, then runs it through the same `strip_sidecar_sub()`; in `-S sidecar` mode the extracted file is stripped the same way.

Genuine `ass`/`ssa` tracks are never run through this pipeline anywhere in this project: their override tags are real positioning, correctly rendered by an ASS-capable player, not a conversion artifact to remove.
