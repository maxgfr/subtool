# subtool

All-in-one CLI for subtitle management: download, translate, convert, sync, clean, merge, fix, extract, and embed subtitles.

## Features

- **Multi-source download** from OpenSubtitles, Podnapisi, and SubDL
- **AI translation** with Claude Code, Z.ai GLM-4.7, OpenAI, Claude API, Mistral, Gemini
- **Smart parsing** — auto-detects movies, episodes, seasons, ranges, IMDb IDs
- **Format conversion** between SRT, VTT, and ASS
- **Subtitle tools**: info, clean, sync, fix, merge, extract, embed
- **Auto-sync** with video using [ffsubsync](https://github.com/smacke/ffsubsync)
- **Batch download** for full seasons

## Installation

### Homebrew

```bash
brew tap maxgfr/homebrew-tap
brew install subtool
```

### Manual

```bash
curl -Lo subtool https://github.com/maxgfr/subtool/raw/main/subtool
chmod +x subtool
sudo mv subtool /usr/local/bin/
```

### Dependencies

- `jq` — JSON parsing
- `python3` — subtitle processing
- `ffmpeg` / `ffprobe` — extract/embed subtitles, video analysis
- `ffsubsync` (optional) — auto-sync subtitles with video (`pip install ffsubsync`)

## Usage

```bash
# Download subtitles
subtool get -q "Inception 2010" -l fr
subtool get -q "Breaking Bad S05E14" -l en

# Batch download a full season
subtool batch -q "Dark S01" -l en

# Search without downloading
subtool search -q "Parasite" -l en

# Translate subtitles
subtool translate -f subs.srt -l fr --from en -p claude-code
subtool translate -f subs.srt -l fr -p zai
subtool translate -f subs.srt -l fr -p openai

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

# Fix broken subtitles (renumber, fix overlaps, UTF-8)
subtool fix -f broken.srt

# Extract subtitles from video
subtool extract -f video.mkv --track 0

# Embed subtitles into video
subtool embed -f video.mkv --sub subs.srt -l fr
```

## Configuration

```bash
subtool config                    # Show current config
subtool config set key value      # Set a config value
subtool providers                 # List AI providers
subtool sources                   # List subtitle sources
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

## License

MIT
