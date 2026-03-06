# subtool

All-in-one CLI for subtitle management: download, translate, convert, sync, clean, merge, fix, extract, and embed subtitles.

## Features

- **Multi-source download** from OpenSubtitles, Podnapisi, and SubDL
- **AI translation** with multiple providers (see below)
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
- `ffmpeg` / `ffprobe` (optional) — extract/embed subtitles, video analysis
- `ffsubsync` (optional) — auto-sync subtitles with video (`pip install ffsubsync`)

## AI Translation Providers

subtool supports two categories of AI providers:

### Code Plan providers (no classic API key needed)

| Provider | ID | Default Model | Description |
|---|---|---|---|
| **Claude Code** | `claude-code` | *(uses Claude Code CLI)* | Default provider. Uses your local Claude Code installation — no API key required. |
| **Z.ai Coding Plan** | `zai-codeplan` | `glm-4.7` | Uses Z.ai's Coding Plan API endpoint with GLM-4.7. Requires `ZAI_API_KEY`. |

### Classic API key providers

| Provider | ID | Default Model | Description |
|---|---|---|---|
| **OpenAI** | `openai` | `gpt-4o` | OpenAI Chat Completions API |
| **Claude API** | `claude` | `claude-sonnet-4-20250514` | Anthropic Messages API |
| **Mistral** | `mistral` | `mistral-large-latest` | Mistral AI API |
| **Gemini** | `gemini` | `gemini-2.0-flash` | Google Gemini API |

You can override the model for any provider with `-m / --model`:

```bash
# Use a specific model
subtool translate -f subs.srt -l fr -p openai -m gpt-4-turbo
subtool translate -f subs.srt -l fr -p claude -m claude-opus-4-20250514
subtool translate -f subs.srt -l fr -p gemini -m gemini-2.5-pro
```

Or set default models in `~/.config/subtool/config`:

```bash
MODEL_ZAI_CODEPLAN="glm-4.7"
MODEL_OPENAI="gpt-4o"
MODEL_CLAUDE="claude-sonnet-4-20250514"
MODEL_MISTRAL="mistral-large-latest"
MODEL_GEMINI="gemini-2.0-flash"
```

## Usage

```bash
# Download subtitles
subtool get -q "Inception 2010" -l fr
subtool get -q "Breaking Bad S05E14" -l en

# Batch download a full season
subtool batch -q "Dark S01" -l en

# Scan a folder and auto-download subtitles for all videos
subtool scan --dir ~/Movies/Die.Discounter -l fr
subtool scan --dir ~/Movies/Die.Discounter -l fr --dry-run          # preview only
subtool scan --dir ~/Movies/Die.Discounter -l fr -q "Die Discounter" # override title
subtool scan --dir ~/Movies/Die.Discounter -l fr -i tt16463942      # use IMDb ID
subtool scan --dir ~/Movies/Die.Discounter -l fr --force-translate   # fallback + AI translate

# Search without downloading
subtool search -q "Parasite" -l en

# Translate subtitles (default: claude-code)
subtool translate -f subs.srt -l fr --from en
subtool translate -f subs.srt -l fr -p zai-codeplan
subtool translate -f subs.srt -l fr -p openai
subtool translate -f subs.srt -l fr -p openai -m gpt-4-turbo

# Subtitle info
subtool info -f subs.srt

# Clean (remove HTML tags, HI/SDH, ads)
subtool clean -f subs.srt

# Time sync (shift timestamps)
subtool sync -f subs.srt --shift +2000
subtool sync -f subs.srt --shift -500

# Auto-sync with video
subtool autosync -f subs.srt --ref video.mkv

# Convert between formats
subtool convert -f subs.srt --to vtt
subtool convert -f subs.srt --to ass
subtool convert -f subs.ass --to srt

# Merge bilingual subtitles
subtool merge -f primary.srt --merge-with secondary.srt

# Fix broken subtitles (renumber, fix overlaps, sort by timestamp, UTF-8)
subtool fix -f broken.srt

# Extract subtitles from video
subtool extract -f video.mkv --track 0

# Embed subtitles into video
subtool embed -f video.mkv --sub subs.srt -l fr

# Check environment (deps, API keys, config)
subtool check
```

## Flags

| Flag | Description |
|---|---|
| `--auto` | Auto-select first result (no interactive prompt) |
| `--dry-run` | Show results without downloading |
| `--dir <path>` | Directory to scan for video files (used with `scan`) |
| `--json` | Output results as JSON (implies `--quiet`) |
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
subtool check                     # Diagnostic: deps, API keys, paths
```

API keys are stored in `~/.config/subtool/config`:

```
OPENSUBTITLES_API_KEY="..."
SUBDL_API_KEY="..."
ZAI_API_KEY="..."
OPENAI_API_KEY="..."
ANTHROPIC_API_KEY="..."
MISTRAL_API_KEY="..."
GEMINI_API_KEY="..."
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
| `--dir <path>` | Directory to scan (required) |
| `-l / --lang <code>` | Target language (required) |
| `-q / --query <title>` | Override the parsed title for all files |
| `-i / --imdb <id>` | Use an IMDb ID for more accurate results |
| `--force-translate` | If not found in target language, try fallback languages + AI translation |
| `--dry-run` | Preview what would be downloaded without actually downloading |
| `--sources` | Choose subtitle sources (default: `opensubtitles,podnapisi,subdl`) |
| `--fallback-langs` | Languages to try for fallback translation (default: `en,de,es,pt`) |

**Tips:**

- Use `--dry-run` first to verify filename parsing is correct
- Pass `-q "Show Name"` when filenames are messy or inconsistent
- Pass `-i tt1234567` for the best search accuracy (especially for non-English titles)
- Combine `--force-translate -p openai` to translate from any available language using AI
- Re-run the same command safely — already downloaded subtitles are skipped

## License

MIT
