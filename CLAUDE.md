# subtool - All-in-one Subtitle CLI

## Project Overview

Single bash script (`subtool.sh`, ~2350 lines) for subtitle management: download, translate, convert, sync, clean, merge, fix, extract, embed.

## Architecture

- **One file**: `subtool.sh` — everything is in this script
- **Config**: `~/.config/subtool/config` (API keys, defaults)
- **Cache**: `~/.cache/subtool/` (temp files, chunks)
- **Tests**: `tests/run_tests.sh` + `tests/fixtures/`

## Key Subsystems

### Subtitle Sources (search + download)

- **OpenSubtitles.org** (`rest.opensubtitles.org`) — free, no API key. Default source. Queries must be lowercase. Client-side season/episode filtering (API doesn't support combined query+season+episode).
- **Podnapisi** — scrapes podnapisi.net JSON API, no API key

Default order: `opensubtitles-org,podnapisi`. No API keys needed for any source.

Search flow: `search_all_sources()` → iterates `SOURCES` (comma-separated) → calls `search_<source>()` for each.

### AI Translation Providers

- `claude-code` (default) — calls `claude -p` CLI, no API key needed
- `zai-codeplan` — Z.ai Coding Plan API
- `openai`, `claude`, `mistral`, `gemini` — standard chat APIs

Translation uses chunking for large files (`chunk_srt()`, 250 lines per chunk).

### Smart Query Parsing

`parse_smart_query()` extracts title, season, episode, range, year, IMDB ID from free-text input like "Die Discounter S01E03-E08".

## Commands

`get`, `search`, `batch`, `scan`, `translate`, `info`, `clean`, `sync`, `autosync`, `convert`, `merge`, `fix`, `extract`, `embed`, `config`, `check`, `providers`, `sources`

## CLI Flags

- `--auto` — auto-select first result (skip interactive prompt)
- `--dry-run` — show results without downloading
- `--json` — JSON output (implies `--quiet`)
- `--verbose` — debug output via `debug()` to stderr
- `--quiet` — suppress informational messages

## Utility Functions

- `api_retry()` — retry with backoff for 429/rate-limit responses
- `detect_lang()` — auto-detect language from subtitle text sample
- `validate_srt()` — check SRT format validity (indices, timestamps, text)
- `_translate_prompt()` / `_translate_dispatch()` — shared translation logic (deduplicated)

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
- Dependencies: `jq`, `curl` (required), `ffmpeg`/`ffprobe` (optional), `ffsubsync` via `uvx` (optional)

## GitHub

- Repo: `maxgfr/subtool`
- Homebrew: `maxgfr/tap/subtool`
