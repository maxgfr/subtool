# subtool

All-in-one CLI for subtitle management: download, translate, transcribe, convert, sync, clean, merge, fix, extract, and embed subtitles.

## Features

- **Multi-source download** from OpenSubtitles.org (default) and Podnapisi — no API keys needed
- **Multi-language** — download subtitles in multiple languages at once (`-l en,fr`)
- **Fast translation** with Google Translate (default, via [translate-shell](https://github.com/soimort/translate-shell)) — no API key needed
- **AI translation** with Claude Code, OpenAI, Gemini, Mistral, etc.
- **Auto mode** — one command: download + translate + sync + embed (`subtool auto`), with transcription fallback
- **Transcription** — generate subtitles from video audio via Whisper (local) or OpenAI API
- **Smart parsing** — auto-detects movies, episodes, seasons, ranges, IMDb IDs
- **Format conversion** between SRT, VTT, and ASS
- **Subtitle tools**: info, clean, sync, fix, merge, extract, embed
- **Auto-sync** with video using [ffsubsync](https://github.com/smacke/ffsubsync)
- **Folder scan** — auto-download subtitles for all video files in a directory
- **Batch download** for full seasons
- **Configurable models** per provider

## Installation

### Homebrew

```bash
brew install maxgfr/tap/subtool
subtool --help
```

### Manual

```bash
curl -Lo subtool https://github.com/maxgfr/subtool/raw/main/subtool.sh
chmod +x subtool
sudo mv subtool /usr/local/bin/
```

### Dependencies

- `jq` — JSON parsing
- `curl` — HTTP requests
- `translate-shell` — Google Translate CLI (default translation provider). Install: `brew install translate-shell`
- `ffmpeg` / `ffprobe` (optional) — extract/embed subtitles, video analysis
- `ffsubsync` (optional) — auto-sync subtitles with video. Runs automatically via `uvx` if [uv](https://docs.astral.sh/uv/) is installed, or install permanently with `uv tool install ffsubsync`
- `openai-whisper` (optional) — speech-to-text transcription. Runs automatically via `uvx` if uv is installed, or install with `pip install openai-whisper`

## Translation Providers

### Default: Google Translate (free, fast, no API key)

| Provider | ID | Description |
|---|---|---|
| **Google Translate** | `google` | Default. Uses [translate-shell](https://github.com/soimort/translate-shell) (`trans`) |

### AI providers (optional, for higher quality)

| Provider | ID | Default Model | Description |
|---|---|---|---|
| **Claude Code** | `claude-code` | `haiku` | Claude Code CLI (effort low). No API key required. |
| **OpenAI** | `openai` | `gpt-5-mini` | OpenAI Chat Completions API |
| **Claude API** | `claude` | `claude-haiku-4-5` | Anthropic Messages API |
| **Mistral** | `mistral` | `mistral-small-latest` | Mistral AI API |
| **Gemini** | `gemini` | `gemini-2.5-flash` | Google Gemini API |

```bash
# Default: Google Translate (fast)
subtool translate subs.srt -l fr --from de

# Use an AI provider for higher quality
subtool translate subs.srt -l fr -p claude-code -m sonnet
subtool translate subs.srt -l fr -p openai
```

## Transcription Providers

Generate subtitles from video audio when no subtitles are available online.

| Provider | ID | Description |
|---|---|---|
| **Whisper** | `whisper` | Default. Local, free. Uses [openai-whisper](https://github.com/openai/whisper) (or `uvx openai-whisper`) |
| **OpenAI API** | `openai-api` | Cloud. Requires `OPENAI_WHISPER_API_KEY` or `OPENAI_API_KEY`. 25MB file limit. |

```bash
# Transcribe video to subtitles
subtool transcribe movie.mkv                             # auto-detect language
subtool transcribe movie.mkv --from en                   # hint source language
subtool transcribe movie.mkv --whisper-model large        # use larger model
subtool transcribe movie.mkv --transcribe-provider openai-api  # use cloud API
```

## Usage

```bash
# Auto mode: download + translate + sync + embed — one command
subtool auto ~/Movies/Die.Discounter -l fr               # all-in-one (Google Translate)
subtool auto ~/Movies/Die.Discounter -l fr -p claude-code # use Claude for translation
subtool auto ~/Movies/Die.Discounter -l fr -p openai      # use OpenAI for translation
subtool auto movie.mkv -l fr                              # single file
subtool auto ~/Movies/Die.Discounter -l en,fr             # multi-language
subtool auto ~/Movies/Die.Discounter -l fr --no-embed     # skip embed
subtool auto movie.mkv -l fr --force-transcribe           # skip download, always transcribe
subtool auto movie.mkv -l fr --no-transcribe              # disable transcription fallback

# Transcribe (generate subtitles from audio)
subtool transcribe movie.mkv
subtool transcribe movie.mkv --from en --whisper-model large

# Download subtitles
subtool get -q "Inception 2010" -l fr
subtool get -q "Breaking Bad S05E14" -l en
subtool get -q "Breaking Bad S05E14" -l en,fr --auto      # both languages

# Batch download a full season
subtool batch -q "Dark S01" -l en

# Scan a folder and auto-download subtitles for all videos
subtool scan ~/Movies/Die.Discounter -l fr
subtool scan ~/Movies/Die.Discounter -l fr --dry-run          # preview only
subtool scan ~/Movies/Die.Discounter -l fr -q "Die Discounter" # override title

# Search without downloading
subtool search -q "Parasite" -l en

# Translate subtitles (default: Google Translate — fast, free)
subtool translate subs.srt -l fr --from de
subtool translate subs.srt -l fr --from de -p claude-code    # use AI instead

# Subtitle info
subtool info subs.srt

# Clean (remove HTML tags, HI/SDH, ads)
subtool clean subs.srt

# Time sync (shift timestamps)
subtool sync subs.srt --shift +2000
subtool sync subs.srt --shift -500

# Auto-sync with video
subtool autosync subs.srt --ref video.mkv

# Convert between formats
subtool convert subs.srt --to vtt
subtool convert subs.srt --to ass
subtool convert subs.ass --to srt

# Merge bilingual subtitles
subtool merge primary.srt --merge-with secondary.srt

# Fix broken subtitles (renumber, fix overlaps, sort by timestamp, UTF-8)
subtool fix broken.srt

# Extract subtitles from video
subtool extract video.mkv                  # interactive track selection
subtool extract video.mkv --all            # extract all subtitle tracks
subtool extract video.mkv --track 2        # extract specific track

# Embed subtitles into video
subtool embed video.mkv --sub subs.srt -l fr

# Check environment (deps, API keys, config)
subtool check
```

## Flags

| Flag | Description |
|---|---|
| `--auto` | Auto-select most downloaded result (no interactive prompt) |
| `--dry-run` | Show results without downloading |
| `--embed` | Force embed subtitles into video (default in `auto` if ffmpeg available) |
| `--no-embed` | Disable auto-embed in `auto` mode |
| `--url <url>` | Provide a subtitle URL directly for download |
| `--json` | Output results as JSON (implies `--quiet`) |
| `--transcribe-provider <p>` | Transcription provider (`whisper` or `openai-api`) |
| `--whisper-model <model>` | Whisper model size (`tiny`, `base`, `small`, `medium`, `large`) |
| `--force-transcribe` | Force transcription in `auto` (skip subtitle download) |
| `--no-transcribe` | Disable transcription fallback in `auto` mode |
| `--chunk-size <n>` | Translation chunk size in lines (default: 80 google, 500 LLM) |
| `--max-tokens <n>` | Max output tokens for LLM translation (default: auto per provider) |
| `--all` | Extract all subtitle tracks at once (`extract` command) |
| `--track <num>` | Extract a specific subtitle track (`extract` command) |
| `--verbose` | Show debug output |
| `--quiet` | Suppress informational messages |

```bash
# Auto-select first subtitle match
subtool get -q "Inception" -l fr --auto

# Dry-run: see what would be downloaded
subtool get -q "Inception" -l fr --dry-run

# JSON output for scripting
subtool search -q "Inception" -l fr --json

# Verbose debug output
subtool get -q "Inception" -l fr --verbose
```

## Configuration

```bash
subtool config                    # Show current config
subtool config set key value      # Set a config value
subtool config get key            # Get a config value
subtool providers                 # List AI providers and models
subtool sources                   # List subtitle sources
subtool check                     # Diagnostic: deps, config
```

subtool works out of the box — no API keys needed for downloading or translating subtitles. The default translation provider is Google Translate via `translate-shell`.

Configuration is stored in `~/.config/subtool/config`:

```
# Default language (so you don't need -l every time)
DEFAULT_LANG="fr"

# Optional API keys for AI translation providers
OPENAI_API_KEY="..."
ANTHROPIC_API_KEY="..."
MISTRAL_API_KEY="..."
GEMINI_API_KEY="..."
ZAI_API_KEY="..."

# Transcription settings
DEFAULT_TRANSCRIBE_PROVIDER=""   # whisper (default) or openai-api
WHISPER_MODEL=""                 # tiny, base, small (default), medium, large
OPENAI_WHISPER_API_KEY=""        # separate key for transcription (falls back to OPENAI_API_KEY)

# Translation tuning
TRANSLATE_CHUNK_SIZE=""          # lines per chunk (default: 80 google, 500 LLM)
MAX_TOKENS=""                    # max output tokens for LLM (default: auto per provider)
```

## Smart Query Parsing

subtool auto-detects the type of query:

| Input | Mode | Parsed |
|---|---|---|
| `Die Discounter S01E03` | Episode | Season 1, Episode 3 |
| `Die Discounter S01` | Season | Season 1 (batch) |
| `Breaking Bad S05E14-E16` | Range | Season 5, Episodes 14-16 |
| `Die Discounter 1x05` | Episode | Season 1, Episode 5 |
| `Die Discounter saison 2` | Season | Season 2 |
| `Inception 2010` | Film | Year 2010 |
| `tt16463942 S01E01` | Episode | IMDb ID + S01E01 |
| `Parasite` | Film | Title search |

## Folder Scan

The `scan` command recursively finds video files in a directory and auto-downloads subtitles for each one, placing `.srt` files next to the videos.

```
~/Movies/Die.Discounter/
├── S1/
│   ├── Die Discounter S01E01-Der Anfang vom Ende [x8kvivs].mp4
│   ├── Die Discounter S01E01-Der Anfang vom Ende [x8kvivs].fr.srt  ← downloaded
│   ├── Die Discounter S01E02-Große Frauen [...].mp4
│   └── Die Discounter S01E02-Große Frauen [...].fr.srt             ← downloaded
├── S2/
│   └── ...
```

**How it works:**

1. Finds all video files (`.mp4`, `.mkv`, `.avi`, etc.) recursively
2. Parses each filename to extract title, season, and episode (`S01E03`, `1x05`, dots/spaces)
3. Searches all configured sources for matching subtitles
4. Saves the `.srt` next to the video with the same base name
5. Skips videos that already have a subtitle file

**Options:**

| Flag | Description |
|---|---|
| `-l / --lang <code>` | Target language (or set `DEFAULT_LANG` in config) |
| `-q / --query <title>` | Override the parsed title for all files |
| `-i / --imdb <id>` | Use an IMDb ID for more accurate results |
| `--force-translate` | If not found in target language, try fallback languages + AI translation |
| `--dry-run` | Preview what would be downloaded without actually downloading |
| `--sources` | Choose subtitle sources (default: `opensubtitles-org`) |
| `--fallback-langs` | Languages to try for fallback translation (default: `en,de,es,pt`) |

**Tips:**

- Use `--dry-run` first to verify filename parsing is correct
- Pass `-q "Show Name"` when filenames are messy or inconsistent
- Pass `-i tt1234567` for the best search accuracy (especially for non-English titles)
- Combine `--force-translate -p openai` to translate from any available language using AI
- Re-run the same command safely — already downloaded subtitles are skipped

## License

MIT
