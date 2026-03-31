# subtool - All-in-one Subtitle CLI

## Project Overview

Single bash script (`subtool.sh`, ~4500 lines) for subtitle management: download, translate, transcribe, convert, sync, clean, merge, fix, extract, embed, diff, text export.

## Architecture

- **One file**: `subtool.sh` — everything is in this script
- **Config**: `~/.config/subtool/config` (API keys, `DEFAULT_LANG`, defaults)
- **Cache**: `~/.cache/subtool/` (temp files, chunks)
- **Tests**: `tests/run_tests.sh` + `tests/fixtures/`
  - The test script uses `$TMP_DIR` (with underscore) for its temp directory — never use `$TMPDIR`
  - **Always run `./tests/run_tests.sh` after any change** to verify nothing is broken before committing

## Key Subsystems

### Subtitle Sources (search + download)

- **OpenSubtitles.org** (`rest.opensubtitles.org`) — free, no API key. Default source. Queries must be lowercase. Server-side season/episode filtering via path segments in alphabetical order (e.g., `/search/episode-1/query-foo/season-2/sublanguageid-eng`).
- **Podnapisi** — scrapes podnapisi.net JSON API, no API key

Default source: `opensubtitles-org`. Podnapisi available via `--sources opensubtitles-org,podnapisi`. No API keys needed.

Search flow: `search_all_sources()` → fuzzy-normalizes query via `_fuzzy_normalize()` (strips accents, collapses separators) → iterates `SOURCES` (comma-separated) → calls `search_<source>()` for each.

### Translation Providers

- `google` (default) — uses `translate-shell` (`trans`), Google Translate, no API key. Parallel chunks.
- `claude-code` — calls `claude -p` CLI (haiku by default, effort configurable via `CLAUDE_EFFORT`), no API key needed
- `zai-codeplan` — Z.ai Coding Plan API
- `openai`, `claude`, `mistral`, `gemini` — standard chat APIs

All providers send subtitles in a single API call by default (threshold 50k lines). Chunking only kicks in for truly massive files. Google provider does its own chunking internally (default 80 lines/chunk). Chunk size configurable via `--chunk-size` or `TRANSLATE_CHUNK_SIZE`. Max parallel chunks configurable via `--max-parallel` or `TRANSLATE_MAX_PARALLEL` (default 3 LLM, 8 google). Max output tokens configurable via `--max-tokens` or `MAX_TOKENS` (auto per provider by default via `_max_tokens_for()`). Translation includes retry logic: truncated LLM output auto-retries missing portion, failed chunks retry once before falling back to original text.

### Transcription Providers

- `whisper` (default) — local, uses `openai-whisper` CLI (or `uvx openai-whisper`), no API key. Model configurable via `WHISPER_MODEL` (default: `small`).
- `openai-api` — cloud, uses OpenAI Whisper API (`/v1/audio/transcriptions`), requires `OPENAI_WHISPER_API_KEY` (falls back to `OPENAI_API_KEY`). 25MB file limit.

### Smart Query Parsing

`parse_smart_query()` extracts title, season, episode, range, year, IMDB ID from free-text input like "Die Discounter S01E03-E08".

## Commands

`get`, `search`, `batch`, `scan`, `auto`, `transcribe`, `translate`, `info`, `clean`, `sync`, `autosync`, `convert`, `merge`, `mix`, `fix`, `extract`, `embed`, `strip`, `text`, `diff`, `config`, `check`, `providers`, `sources`, `completions`, `manpage`

### `auto` command

All-in-one: download + translate + sync (ffsubsync) + embed (ffmpeg). Pass a file, directory, or playlist (.txt) as positional argument (auto-detected). Embed is on by default when ffmpeg is available (`--no-embed` to disable). Sync is automatic via ffsubsync. Source language is auto-detected from subtitle filename. Falls back to transcription (speech-to-text) when no subtitles are found online (`--no-transcribe` to disable, `--force-transcribe` to skip download and always transcribe). Supports `--dry-run` to preview actions without executing. `--skip-steps download,translate,sync,mix,embed` to skip specific steps. Directory mode tracks completed files in `.subtool_batch_state` for resume on interrupt (`--no-resume` to re-process all). Playlist mode (`--playlist file.txt` or auto-detected from `.txt` extension): reads one video path per line (comments with `#`, blank lines ignored, relative paths resolved from playlist directory).

Supports `--mix` to create dual-language subtitles for language learning: source language in bold on top, target language in grey italic below. Output: `.mix.srt`. Use `--mix-lang <lang>` to specify the learning language explicitly. In the translate path, BOTH `target_srt` and `existing_srt` are synced before mixing — this ensures both files drop the same blocks when ffsubsync skips negative timestamps, keeping the block pairing aligned. Track title is set to "Mix German-French" (etc.) when embedding.

### `transcribe` command

Generate subtitles from video audio via speech-to-text. Providers: `whisper` (default, local) and `openai-api` (cloud). Language auto-detected from output. Auto-syncs with video via ffsubsync after transcription. Use `--from` to hint source language, `--whisper-model` to select model size (tiny/base/small/medium/large), `--transcribe-provider` to switch provider.

### `extract` command

Extract subtitle tracks from a video file (MKV, MP4, etc.). Supports `--track <num>` for a single track or `--all` to extract all tracks at once. Interactive prompt allows typing `all`. Output filenames use language code: `movie.fr.srt`. When multiple tracks share the same language, a track index is appended for disambiguation: `movie.en.0.srt`, `movie.en.1.srt`.

### `embed` command

Embed an SRT subtitle into a video file. Uses `-map 0 -map 1:0` to preserve all existing streams. Properly sets `language` and `title` metadata on the new subtitle stream AND re-sets metadata on all existing subtitle streams (prevents "piste 1/2" generic labels in players).

### `strip` command

Remove all subtitle tracks from a video file. Uses `ffmpeg -map 0 -map -0:s -c copy` to copy all streams except subtitles. Validates the input is a video file (has video streams). Shows existing subtitle tracks before removing. Output: `movie.clean.mkv`.

### `mix` command

Mix two subtitle files into one dual-language file for language learning. Learning language displayed in bold (top), native language in grey italic (bottom). Output: `.mix.srt`.

Two modes:
- `subtool mix movie.de.srt --mix-with movie.fr.srt` — from two existing files
- `subtool mix movie.de.srt -l fr` — translate first, then mix

In `auto` mode: `--mix` enables dual-language output, `--mix-lang <lang>` specifies the learning language. The `_auto_mix()` helper finds a source subtitle (Priority: 1. existing_srt from translate path, 2. `--mix-lang` specific file, 3. scan for any `.XX.srt`). Skips `.mix.srt` files from previous runs.

### `text` command

Export plain text from a subtitle file (no timestamps, no indices). Output goes to stdout. E.g., `subtool text movie.srt > script.txt`.

### `diff` command

Compare two subtitle files side by side. Shows block-by-block differences with color coding. Usage: `subtool diff file1.srt --diff-with file2.srt`. Reports identical files or number of differing blocks.

### `completions` command

Generate shell completion scripts for bash, zsh, or fish. Usage: `eval "$(subtool completions bash)"`, `subtool completions fish > ~/.config/fish/completions/subtool.fish`.

### `manpage` command

Generate a man page in troff format. Usage: `subtool manpage | man -l -`.

## CLI

- Positional argument after command = file or directory (auto-detected). E.g., `subtool info movie.srt`, `subtool auto ~/Movies/`
- `-l` / `--lang` — target language(s), comma-separated for multi-lang (e.g., `-l en,fr`). Or set `DEFAULT_LANG` in config
- `--auto` — auto-select most downloaded result (skip interactive prompt)
- `--embed` / `--no-embed` — force/disable subtitle embedding (auto: on by default)
- `--url <url>` — provide a subtitle URL directly
- `--mix-with <file>` — second file for `mix` command
- `--mix` — enable dual-language mix in `auto` mode
- `--mix-lang <lang>` — learning language for mix (implies `--mix`)
- `--diff-with <file>` — second file for `diff` command
- `--playlist <file>` — text file listing video paths for batch `auto`
- `--dry-run` — show results without downloading
- `--json` — JSON output (implies `--quiet`)
- `--verbose` — debug output via `debug()` to stderr
- `--quiet` — suppress informational messages

## Utility Functions

- `api_retry()` — retry with backoff for 429/rate-limit responses
- `detect_lang()` — auto-detect language from subtitle text sample
- `validate_srt()` — check SRT format validity (indices, timestamps, text)
- `_translate_prompt()` / `_translate_dispatch()` — shared translation logic (deduplicated)
- `_srt_extract_for_translation()` — extract text-only from SRT (numbered lines + timestamp structure)
- `_srt_rebuild_from_translation()` — rebuild SRT from timestamps + translated text (with original fallback)
- `_max_tokens_for()` — returns provider-specific max_tokens default (respects `MAX_TOKENS` override)
- `_multi_lang_dispatch()` — handles comma-separated `-l en,fr` by looping over each language
- `transcribe_video()` — orchestrator: extract audio -> transcribe -> validate SRT
- `_transcribe_dispatch()` — case dispatch for transcription providers (same pattern as `_translate_dispatch`)
- `_lang_title()` — converts language code to human-readable title (e.g., `fr` → "French") for subtitle track metadata
- `_detect_stream_lang()` — extracts a text sample from an embedded subtitle stream and auto-detects its language via `detect_lang()`. Used when stream has `language=und`
- `progress()` — visual progress bar for long operations (translation chunks, batch processing)
- `_fuzzy_normalize()` — strips accents (via `iconv`), collapses separators, removes punctuation for typo-tolerant search
- `_mix_subtitles()` — merges two SRT files into one bilingual (supports swap mode for timestamp source)
- `_auto_mix()` — finds source subtitle + mixes with target in auto flow. Uses swap mode (target_srt timestamps, source text on top). Returns `lang|path` on stdout

## CI/CD

- `.github/workflows/release.yml` — semantic-release (bumps VERSION in subtool.sh)
- `.github/workflows/ci.yml` — tests
- `.releaserc` + `.version-hook.sh` — version management
- Homebrew tap at `~/Downloads/homebrew-tap/Formula/subtool.rb`

## Conventions

- All output/logs via stderr (`>&2`), only data on stdout
- Colors: RED/GREEN/YELLOW/BLUE/CYAN/BOLD/NC
- Helper functions: `log()`, `warn()`, `err()`, `info()`, `debug()`, `header()`, `die()`
- `debug()` must always end with `|| true` (script uses `set -euo pipefail`)
- URL encoding: `urlencode()` via jq
- Default source: `opensubtitles-org` (podnapisi available via `--sources`)
- Dependencies: `jq`, `curl`, `translate-shell` (required), `ffmpeg`/`ffprobe` (optional), `ffsubsync` via `uvx` (optional), `whisper` via `uvx` (optional, transcription)
- Config keys: `DEFAULT_TRANSCRIBE_PROVIDER`, `WHISPER_MODEL`, `OPENAI_WHISPER_API_KEY`, `TRANSLATE_CHUNK_SIZE`, `MAX_TOKENS`, `CLAUDE_EFFORT`, `TRANSLATE_MAX_PARALLEL`

### Embed/extract subtitle metadata (critical)

When embedding subtitles with ffmpeg, **always**:
1. Use `-map 0 -map 1:0` to copy ALL existing streams (never rely on ffmpeg's default stream selection)
2. Set `-metadata:s:s:N language=XX` AND `-metadata:s:s:N title=XX` for EVERY subtitle stream (existing + new)
3. Use `_lang_title()` as fallback when a stream has no title tag — otherwise players show generic "piste 1/2" labels
   - When `language=und`, call `_detect_stream_lang()` first to auto-detect the real language from subtitle text content
4. Target the correct stream index: count existing subtitle streams with `jq '.streams | length'` on ffprobe JSON output
5. For MP4/M4V, use `mov_text` codec; for MKV, use `srt` — via `-c:s:"$sub_count" "$sub_codec"` (only the new stream)

Pattern used in both `cmd_embed()` and `_auto_embed()`: build an ffmpeg command array, loop over existing streams to add their metadata args, then add the new stream metadata.

## GitHub

- Repo: `maxgfr/subtool`
- Homebrew: `maxgfr/tap/subtool`
