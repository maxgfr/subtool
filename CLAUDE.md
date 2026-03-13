# subtool - All-in-one Subtitle CLI

## Project Overview

Single bash script (`subtool.sh`, ~3400 lines) for subtitle management: download, translate, transcribe, convert, sync, clean, merge, fix, extract, embed.

## Architecture

- **One file**: `subtool.sh` — everything is in this script
- **Config**: `~/.config/subtool/config` (API keys, `DEFAULT_LANG`, defaults)
- **Cache**: `~/.cache/subtool/` (temp files, chunks)
- **Tests**: `tests/run_tests.sh` + `tests/fixtures/`

## Key Subsystems

### Subtitle Sources (search + download)

- **OpenSubtitles.org** (`rest.opensubtitles.org`) — free, no API key. Default source. Queries must be lowercase. Server-side season/episode filtering via path segments in alphabetical order (e.g., `/search/episode-1/query-foo/season-2/sublanguageid-eng`).
- **Podnapisi** — scrapes podnapisi.net JSON API, no API key

Default source: `opensubtitles-org`. Podnapisi available via `--sources opensubtitles-org,podnapisi`. No API keys needed.

Search flow: `search_all_sources()` → iterates `SOURCES` (comma-separated) → calls `search_<source>()` for each.

### Translation Providers

- `google` (default) — uses `translate-shell` (`trans`), Google Translate, no API key. Parallel chunks.
- `claude-code` — calls `claude -p` CLI (haiku, effort low), no API key needed
- `zai-codeplan` — Z.ai Coding Plan API
- `openai`, `claude`, `mistral`, `gemini` — standard chat APIs

Google provider does its own chunking internally. LLM providers use `chunk_srt()` (250 lines/chunk).

### Transcription Providers

- `whisper` (default) — local, uses `openai-whisper` CLI (or `uvx openai-whisper`), no API key. Model configurable via `WHISPER_MODEL` (default: `small`).
- `openai-api` — cloud, uses OpenAI Whisper API (`/v1/audio/transcriptions`), requires `OPENAI_WHISPER_API_KEY` (falls back to `OPENAI_API_KEY`). 25MB file limit.

### Smart Query Parsing

`parse_smart_query()` extracts title, season, episode, range, year, IMDB ID from free-text input like "Die Discounter S01E03-E08".

## Commands

`get`, `search`, `batch`, `scan`, `auto`, `transcribe`, `translate`, `info`, `clean`, `sync`, `autosync`, `convert`, `merge`, `fix`, `extract`, `embed`, `config`, `check`, `providers`, `sources`

### `auto` command

All-in-one: download + translate + sync (ffsubsync) + embed (ffmpeg). Pass a file or directory as positional argument (auto-detected). Embed is on by default when ffmpeg is available (`--no-embed` to disable). Sync is automatic via ffsubsync. Source language is auto-detected from subtitle filename. Falls back to transcription (speech-to-text) when no subtitles are found online (`--no-transcribe` to disable, `--force-transcribe` to skip download and always transcribe).

### `transcribe` command

Generate subtitles from video audio via speech-to-text. Providers: `whisper` (default, local) and `openai-api` (cloud). Language auto-detected from output. Auto-syncs with video via ffsubsync after transcription. Use `--from` to hint source language, `--whisper-model` to select model size (tiny/base/small/medium/large), `--transcribe-provider` to switch provider.

## CLI

- Positional argument after command = file or directory (auto-detected). E.g., `subtool info movie.srt`, `subtool auto ~/Movies/`
- `-l` / `--lang` — target language(s), comma-separated for multi-lang (e.g., `-l en,fr`). Or set `DEFAULT_LANG` in config
- `--auto` — auto-select most downloaded result (skip interactive prompt)
- `--embed` / `--no-embed` — force/disable subtitle embedding (auto: on by default)
- `--url <url>` — provide a subtitle URL directly
- `--dry-run` — show results without downloading
- `--json` — JSON output (implies `--quiet`)
- `--verbose` — debug output via `debug()` to stderr
- `--quiet` — suppress informational messages

## Utility Functions

- `api_retry()` — retry with backoff for 429/rate-limit responses
- `detect_lang()` — auto-detect language from subtitle text sample
- `validate_srt()` — check SRT format validity (indices, timestamps, text)
- `_translate_prompt()` / `_translate_dispatch()` — shared translation logic (deduplicated)
- `_multi_lang_dispatch()` — handles comma-separated `-l en,fr` by looping over each language
- `transcribe_video()` — orchestrator: extract audio -> transcribe -> validate SRT
- `_transcribe_dispatch()` — case dispatch for transcription providers (same pattern as `_translate_dispatch`)

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
- Config keys: `DEFAULT_TRANSCRIBE_PROVIDER`, `WHISPER_MODEL`, `OPENAI_WHISPER_API_KEY`

## GitHub

- Repo: `maxgfr/subtool`
- Homebrew: `maxgfr/tap/subtool`
