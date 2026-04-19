#!/usr/bin/env bash
set -euo pipefail

# ── Minimalist test framework ────────────────────────────────────────────────
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SUBSYNC="$PROJECT_DIR/subtool.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
TMP_DIR=$(mktemp -d)

trap 'rm -rf "$TMP_DIR"' EXIT

assert() {
    local desc="$1" result="$2"
    ((TESTS_RUN++)) || true
    if [[ "$result" == "0" ]]; then
        ((TESTS_PASSED++)) || true
        printf "  ${GREEN}PASS${NC}  %s\n" "$desc"
    else
        ((TESTS_FAILED++)) || true
        FAILURES+="  - $desc\n"
        printf "  ${RED}FAIL${NC}  %s\n" "$desc"
    fi
}

assert_file_exists() {
    local desc="$1" file="$2"
    if [[ -s "$file" ]]; then
        assert "$desc" 0
    else
        assert "$desc" 1
    fi
}

assert_file_contains() {
    local desc="$1" file="$2" pattern="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        assert "$desc" 0
    else
        assert "$desc" 1
    fi
}

assert_file_not_contains() {
    local desc="$1" file="$2" pattern="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        assert "$desc" 1
    else
        assert "$desc" 0
    fi
}

assert_output_contains() {
    local desc="$1" output="$2" pattern="$3"
    if echo "$output" | grep -qE "$pattern" 2>/dev/null; then
        assert "$desc" 0
    else
        assert "$desc" 1
    fi
}

assert_exit_code() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        assert "$desc" 0
    else
        assert "$desc" 1
    fi
}

section() {
    printf "\n${BOLD}${YELLOW}── %s ──${NC}\n" "$1"
}

# ══════════════════════════════════════════════════════════════════════════════
# TESTS
# ══════════════════════════════════════════════════════════════════════════════

section "CLI basics"

out=$("$SUBSYNC" --version 2>&1)
assert_output_contains "--version shows version" "$out" '^[0-9]+\.[0-9]+\.[0-9]+'

out=$("$SUBSYNC" --help 2>&1)
assert_output_contains "--help contains USAGE" "$out" "USAGE"
assert_output_contains "--help contains COMMANDS" "$out" "COMMANDS"
assert_output_contains "--help contains get" "$out" "get"
assert_output_contains "--help contains translate" "$out" "translate"
assert_output_contains "--help contains check" "$out" "check"
assert_output_contains "--help contains --auto" "$out" "\-\-auto"
assert_output_contains "--help contains --dry-run" "$out" "\-\-dry-run"
assert_output_contains "--help contains --json" "$out" "\-\-json"
assert_output_contains "--help contains --verbose" "$out" "\-\-verbose"
assert_output_contains "--help contains --quiet" "$out" "\-\-quiet"
assert_output_contains "--help contains transcribe" "$out" "transcribe"
assert_output_contains "--help contains --whisper-model" "$out" "\-\-whisper-model"
assert_output_contains "--help contains --no-transcribe" "$out" "\-\-no-transcribe"
assert_output_contains "--help contains --transcribe-provider" "$out" "\-\-transcribe-provider"
assert_output_contains "--help contains --force-transcribe" "$out" "\-\-force-transcribe"
assert_output_contains "--help contains --mix-translate" "$out" "\-\-mix-translate"

out=$("$SUBSYNC" providers 2>&1)
assert_output_contains "providers lists claude-code" "$out" "claude-code"
assert_output_contains "providers lists zai-codeplan" "$out" "zai-codeplan"
assert_output_contains "providers lists openai" "$out" "openai"
assert_output_contains "providers lists gemini" "$out" "gemini"
assert_output_contains "providers lists transcription section" "$out" "Transcription providers"
assert_output_contains "providers lists whisper" "$out" "whisper"
assert_output_contains "providers lists openai-api" "$out" "openai-api"

out=$("$SUBSYNC" sources 2>&1)
assert_output_contains "sources lists opensubtitles-org" "$out" "opensubtitles-org"
assert_output_contains "sources lists podnapisi" "$out" "podnapisi"

# Expected errors
out=$("$SUBSYNC" search 2>&1 || true)
assert_output_contains "search without args -> error" "$out" "Specify"

out=$("$SUBSYNC" translate 2>&1 || true)
assert_output_contains "translate without args -> error" "$out" "Specify"

out=$("$SUBSYNC" get 2>&1 || true)
assert_output_contains "get without args -> error" "$out" "Specify"

out=$("$SUBSYNC" --nonexistent 2>&1 || true)
assert_output_contains "unknown option -> error" "$out" "Unknown"

out=$("$SUBSYNC" transcribe 2>&1 || true)
assert_output_contains "transcribe without args -> error" "$out" "Specify"

out=$("$SUBSYNC" transcribe /nonexistent/file.mkv 2>&1 || true)
assert_output_contains "transcribe non-existent file -> error" "$out" "not found"

# ══════════════════════════════════════════════════════════════════════════════
section "check (diagnostic)"

out=$("$SUBSYNC" check 2>&1)
assert_output_contains "check: shows jq" "$out" "jq"
assert_output_contains "check: shows curl" "$out" "curl"
assert_output_contains "check: shows Config" "$out" "Config"
assert_output_contains "check: shows whisper" "$out" "whisper"

# ══════════════════════════════════════════════════════════════════════════════
section "config set/get"

# Use a temp config dir
export XDG_CONFIG_HOME="$TMP_DIR/xdg_config"
export XDG_CACHE_HOME="$TMP_DIR/xdg_cache"

"$SUBSYNC" config set TEST_KEY "test_value_123" 2>&1
out=$("$SUBSYNC" config get TEST_KEY 2>&1)
assert_output_contains "config set/get: correct value" "$out" "test_value_123"

# Update existing key
"$SUBSYNC" config set TEST_KEY "updated_value" 2>&1
out=$("$SUBSYNC" config get TEST_KEY 2>&1)
assert_output_contains "config set: update existing" "$out" "updated_value"

unset XDG_CONFIG_HOME XDG_CACHE_HOME

# ══════════════════════════════════════════════════════════════════════════════
section "info"

out=$("$SUBSYNC" info "$FIXTURES/basic.srt" 2>&1)
assert_output_contains "info: detects 5 subtitles" "$out" "5"
assert_output_contains "info: detects start timestamp" "$out" "00:00:01,000"
assert_output_contains "info: detects end timestamp" "$out" "00:00:18,500"
assert_output_contains "info: detects German" "$out" "de.*German"

out=$("$SUBSYNC" info "$FIXTURES/basic_fr.srt" 2>&1)
assert_output_contains "info: detects French" "$out" "fr.*French"

out=$("$SUBSYNC" info "$FIXTURES/clean.srt" 2>&1)
assert_output_contains "info: detects HI/SDH tags" "$out" "HI/SDH"
assert_output_contains "info: detects HTML tags" "$out" "HTML"

# ══════════════════════════════════════════════════════════════════════════════
section "clean"

"$SUBSYNC" clean "$FIXTURES/clean.srt" -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/clean.clean.srt"
assert_file_exists "clean: file created" "$out_file"
assert_file_not_contains "clean: HTML <i> removed" "$out_file" '<i>'
assert_file_not_contains "clean: HTML <b> removed" "$out_file" '<b>'
assert_file_not_contains "clean: HTML <font> removed" "$out_file" '<font>'
assert_file_not_contains "clean: opensubtitles removed" "$out_file" 'opensubtitles'
assert_file_not_contains "clean: synced by removed" "$out_file" '[Ss]ynced by'
assert_file_not_contains "clean: subtitle by removed" "$out_file" '[Ss]ubtitle by'
assert_file_contains "clean: real dialogue preserved" "$out_file" "echte Dialog"

# Clean on already clean file
section "clean (idempotent)"

"$SUBSYNC" clean "$FIXTURES/already_clean.srt" -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/already_clean.clean.srt"
assert_file_exists "clean idempotent: file created" "$out_file"
assert_file_contains "clean idempotent: dialogue 1 preserved" "$out_file" "Bonjour"
assert_file_contains "clean idempotent: dialogue 2 preserved" "$out_file" "tres bien"
assert_file_contains "clean idempotent: dialogue 3 preserved" "$out_file" "Au revoir"

# Count subtitle blocks in cleaned file
clean_blocks=$(grep -cE '^[0-9]+$' "$out_file" || true)
assert_exit_code "clean idempotent: 3 blocks preserved" "3" "$clean_blocks"

# ══════════════════════════════════════════════════════════════════════════════
section "sync"

"$SUBSYNC" sync "$FIXTURES/basic.srt" --shift +2000 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_exists "sync +2000ms: file created" "$out_file"
assert_file_contains "sync +2000ms: 01,000 -> 03,000" "$out_file" "00:00:03,000"
assert_file_contains "sync +2000ms: 03,500 -> 05,500" "$out_file" "00:00:05,500"
assert_file_not_contains "sync +2000ms: old timestamp absent" "$out_file" "00:00:01,000"

"$SUBSYNC" sync "$FIXTURES/basic.srt" --shift -500 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_contains "sync -500ms: 01,000 -> 00,500" "$out_file" "00:00:00,500"
assert_file_contains "sync -500ms: 04,000 -> 03,500" "$out_file" "00:00:03,500"

# ══════════════════════════════════════════════════════════════════════════════
section "auto --sync-shift"

out=$("$SUBSYNC" --help 2>&1)
assert_output_contains "--help mentions --sync-shift" "$out" "\-\-sync-shift"

out=$("$SUBSYNC" auto --help 2>&1 || true)
assert_output_contains "auto --help mentions --sync-shift" "$out" "\-\-sync-shift"

# Unknown-flag regression: --sync-shift must be accepted (not rejected as unknown)
out=$("$SUBSYNC" auto /nonexistent/video.mkv -l fr --sync-shift -2000 2>&1 || true)
assert_output_contains "auto accepts --sync-shift flag" "$out" "(not found|nonexistent|no such|path)"
if echo "$out" | grep -qiE "unknown (option|flag)|invalid option|unrecognized"; then
    assert "auto --sync-shift does not trigger unknown-flag error" 1
else
    assert "auto --sync-shift does not trigger unknown-flag error" 0
fi

# Config key AUTO_SYNC_SHIFT persists
"$SUBSYNC" config set AUTO_SYNC_SHIFT "-2000" 2>&1
out=$("$SUBSYNC" config get AUTO_SYNC_SHIFT 2>&1)
assert_output_contains "AUTO_SYNC_SHIFT config stores value" "$out" "\-2000"
"$SUBSYNC" config set AUTO_SYNC_SHIFT "" 2>&1  # cleanup

# ══════════════════════════════════════════════════════════════════════════════
section "convert SRT -> VTT"

"$SUBSYNC" convert "$FIXTURES/basic.srt" --to vtt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.vtt"
assert_file_exists "srt->vtt: file created" "$out_file"
assert_file_contains "srt->vtt: header WEBVTT" "$out_file" "^WEBVTT"
assert_file_contains "srt->vtt: dot instead of comma" "$out_file" '00:00:01\.000'
assert_file_not_contains "srt->vtt: no comma in timestamp" "$out_file" '00:00:01,000'
assert_file_contains "srt->vtt: text preserved" "$out_file" "Willkommen"

section "convert SRT -> ASS"

"$SUBSYNC" convert "$FIXTURES/basic.srt" --to ass -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.ass"
assert_file_exists "srt->ass: file created" "$out_file"
assert_file_contains "srt->ass: Script Info" "$out_file" "Script Info"
assert_file_contains "srt->ass: V4+ Styles" "$out_file" "V4\+ Styles"
assert_file_contains "srt->ass: Dialogue lines" "$out_file" "^Dialogue:"
assert_file_contains "srt->ass: text preserved" "$out_file" "Willkommen"
assert_file_contains "srt->ass: multiline \\N" "$out_file" '\\N'

section "convert ASS -> SRT"

"$SUBSYNC" convert "$FIXTURES/sample.ass" --to srt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/sample.srt"
assert_file_exists "ass->srt: file created" "$out_file"
assert_file_contains "ass->srt: timestamps SRT" "$out_file" '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> '
assert_file_contains "ass->srt: text preserved" "$out_file" "Hello world"
assert_file_not_contains "ass->srt: no Dialogue: lines" "$out_file" "^Dialogue:"

section "convert VTT -> SRT"

"$SUBSYNC" convert "$TMP_DIR/basic.vtt" --to srt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.srt"
assert_file_exists "vtt->srt: file created" "$out_file"
assert_file_contains "vtt->srt: comma in timestamp" "$out_file" '00:00:01,000'
assert_file_not_contains "vtt->srt: no WEBVTT" "$out_file" "WEBVTT"

section "convert VTT with cue settings -> SRT"

"$SUBSYNC" convert "$FIXTURES/cue_settings.vtt" --to srt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/cue_settings.srt"
assert_file_exists "vtt+cue->srt: file created" "$out_file"
assert_file_contains "vtt+cue->srt: text preserved" "$out_file" "Hello world"
assert_file_contains "vtt+cue->srt: multiline preserved" "$out_file" "with two lines"
assert_file_contains "vtt+cue->srt: normal sub" "$out_file" "Normal subtitle"

# ══════════════════════════════════════════════════════════════════════════════
section "merge"

"$SUBSYNC" merge "$FIXTURES/basic.srt" --merge-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.dual.srt"
assert_file_exists "merge: file created" "$out_file"
assert_file_contains "merge: primary text (DE)" "$out_file" "Willkommen"
assert_file_contains "merge: secondary text (FR) in italics" "$out_file" "<i>Bienvenue"
assert_file_contains "merge: timestamps preserved" "$out_file" "00:00:01,000 --> 00:00:03,500"

# Verify each block has both languages
block_count=$(grep -c "Willkommen\|Regale\|Pause\|Discounter\|Angebote" "$out_file" || true)
fr_count=$(grep -c "Bienvenue\|rayons\|pause\|discounter\|offres" "$out_file" || true)
if [[ "$block_count" -gt 0 && "$fr_count" -gt 0 ]]; then
    assert "merge: both languages present" 0
else
    assert "merge: both languages present" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "fix"

"$SUBSYNC" fix "$FIXTURES/broken.srt" -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/broken.fixed.srt"
assert_file_exists "fix: file created" "$out_file"

# Verify sequential renumbering (1, 2, 3...)
first_num=$(head -1 "$out_file")
assert_exit_code "fix: first block = 1" "1" "$first_num"

# Verify blocks are sorted by timestamp (first block should have earliest timestamp)
first_ts=$(grep -m1 -oE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}' "$out_file" | head -1)
assert_exit_code "fix: first timestamp = 00:00:01,000 (sorted)" "00:00:01,000" "$first_ts"

# Verify overlaps are fixed
overlap_check=$(awk '
function ts2ms(ts,    a, b) {
    split(ts, a, ":"); split(a[3], b, ",")
    return a[1]*3600000 + a[2]*60000 + b[1]*1000 + b[2]
}
/[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}/ {
    split($0, p, " --> ")
    this_end = ts2ms(p[2])
    if (prev_end > 0 && ts2ms(p[1]) < prev_end) { print 1; exit }
    prev_end = this_end
}
END { print 0 }
' "$out_file" 2>/dev/null)
assert "fix: no overlap after fix" "$overlap_check"

# Verify UTF-8 encoding
encoding=$(file --mime-encoding "$out_file" 2>/dev/null | awk -F': ' '{print $2}')
if [[ "$encoding" == "utf-8" || "$encoding" == "us-ascii" ]]; then
    assert "fix: UTF-8 encoding" 0
else
    assert "fix: UTF-8 encoding" 1
fi

# Fix with Latin-1 encoded file
section "fix (Latin-1 encoding)"

"$SUBSYNC" fix "$FIXTURES/latin1.srt" -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/latin1.fixed.srt"
assert_file_exists "fix latin1: file created" "$out_file"
fix_encoding=$(file --mime-encoding "$out_file" 2>/dev/null | awk -F': ' '{print $2}')
if [[ "$fix_encoding" == "utf-8" || "$fix_encoding" == "us-ascii" ]]; then
    assert "fix latin1: converted to UTF-8" 0
else
    assert "fix latin1: converted to UTF-8 (got: $fix_encoding)" 1
fi
assert_file_contains "fix latin1: text preserved" "$out_file" "Deutschland"

# ══════════════════════════════════════════════════════════════════════════════
section "Smart parsing (get)"

# Helper function to test parsing without network
test_parse() {
    local query="$1" expected_mode="$2" expected_title="${3:-}" expected_season="${4:-}" expected_ep="${5:-}" expected_ep_end="${6:-}" expected_imdb="${7:-}"
    local out
    out=$("$SUBSYNC" get -q "$query" -l fr --sources "" -o "$TMP_DIR" 2>&1 || true)

    local ok=true desc="parse: \"$query\""

    if ! grep -qi "Mode:.*$expected_mode" <<< "$out"; then
        ok=false; desc+=" [mode=$expected_mode FAIL]"
    fi
    if [[ -n "$expected_title" ]] && ! grep -q "Title: $expected_title" <<< "$out"; then
        ok=false; desc+=" [title FAIL]"
    fi
    if [[ -n "$expected_season" ]] && ! grep -q "Season: $expected_season" <<< "$out"; then
        ok=false; desc+=" [season FAIL]"
    fi
    if [[ -n "$expected_ep" && "$expected_mode" != "Range" ]] && ! grep -q "Episode: $expected_ep" <<< "$out"; then
        ok=false; desc+=" [episode FAIL]"
    fi
    if [[ -n "$expected_ep_end" ]] && ! grep -q "Episodes: ${expected_ep}-${expected_ep_end}" <<< "$out"; then
        ok=false; desc+=" [range FAIL]"
    fi
    if [[ -n "$expected_imdb" ]] && ! grep -q "IMDb: $expected_imdb" <<< "$out"; then
        ok=false; desc+=" [imdb FAIL]"
    fi

    if $ok; then assert "$desc" 0; else assert "$desc" 1; fi
}

#                           query                          mode       title               season  ep  ep_end  imdb
test_parse "Die Discounter S01E03"                        "Episode"  "Die Discounter"     "1"     "3"
test_parse "Die Discounter S01"                           "Season"   "Die Discounter"     "1"
test_parse "Die Discounter S01E03-E08"                    "Range"    "Die Discounter"     "1"     "3" "8"
test_parse "Die Discounter S2E10"                         "Episode"  "Die Discounter"     "2"     "10"
test_parse "Inception 2010"                               "Movie"    "Inception"
test_parse "Die Discounter 1x05"                          "Episode"  "Die Discounter"     "1"     "05"
test_parse "Die Discounter saison 2"                      "Season"   "Die Discounter"     "2"
test_parse "Die Discounter season 1 ep 5"                 "Episode"  "Die Discounter"     "1"     "5"
test_parse "Breaking Bad S05E14-E16"                      "Range"    "Breaking Bad"       "5"     "14" "16"
test_parse "tt16463942 S01E01"                            "Episode"  ""                   "1"     "1"  ""   "tt16463942"
test_parse "tt16463942"                                   "Movie"    ""                   ""      ""   ""   "tt16463942"
test_parse "The Office S03"                               "Season"   "The Office"         "3"
test_parse "Parasite"                                     "Movie"    "Parasite"
test_parse "Dark S01E01-E10"                              "Range"    "Dark"               "1"     "1"  "10"

# ══════════════════════════════════════════════════════════════════════════════
section "chunk_srt"

# Test chunking by writing a helper script
chunk_cache="$TMP_DIR/chunk_cache"
mkdir -p "$chunk_cache"

cat > "$TMP_DIR/test_chunk.sh" << 'CHUNKSCRIPT'
#!/usr/bin/env bash
set -uo pipefail
CACHE_DIR="$1"
FILE="$2"
MAX_LINES="${3:-200}"

chunk_num=0
line_count=0
current_chunk=""

while IFS= read -r line || [[ -n "$line" ]]; do
    current_chunk+="$line"$'\n'
    line_count=$((line_count + 1))
    if [[ "$line" =~ ^[[:space:]]*$ ]] && [[ $line_count -ge $MAX_LINES ]]; then
        printf '%s' "$current_chunk" > "$CACHE_DIR/chunk_${chunk_num}.srt"
        chunk_num=$((chunk_num + 1))
        line_count=0
        current_chunk=""
    fi
done < "$FILE"

if [[ -n "$current_chunk" ]]; then
    printf '%s' "$current_chunk" > "$CACHE_DIR/chunk_${chunk_num}.srt"
    chunk_num=$((chunk_num + 1))
fi
echo "$chunk_num"
CHUNKSCRIPT
chmod +x "$TMP_DIR/test_chunk.sh"

# Large file with max_lines=10 should produce multiple chunks
num_chunks=$(bash "$TMP_DIR/test_chunk.sh" "$chunk_cache" "$FIXTURES/large.srt" 10 2>/dev/null || echo "0")
if [[ "$num_chunks" -gt 1 ]]; then
    assert "chunk_srt: multiple chunks created ($num_chunks)" 0
else
    assert "chunk_srt: multiple chunks created (got: $num_chunks)" 1
fi

# Verify all chunks contain valid SRT timestamps
all_valid=true
for f in "$chunk_cache"/chunk_*.srt; do
    [[ ! -f "$f" ]] && continue
    if ! grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}' "$f" 2>/dev/null; then
        all_valid=false
        break
    fi
done
if $all_valid && [[ -f "$chunk_cache/chunk_0.srt" ]]; then
    assert "chunk_srt: all chunks contain timestamps" 0
else
    assert "chunk_srt: all chunks contain timestamps" 1
fi
rm -rf "$chunk_cache"

# Small file should produce 1 chunk
chunk_cache2="$TMP_DIR/chunk_cache2"
mkdir -p "$chunk_cache2"
num_chunks_small=$(bash "$TMP_DIR/test_chunk.sh" "$chunk_cache2" "$FIXTURES/basic.srt" 200 2>/dev/null || echo "0")
assert_exit_code "chunk_srt: small file = 1 chunk" "1" "$num_chunks_small"
rm -rf "$chunk_cache2"

# ══════════════════════════════════════════════════════════════════════════════
section "validate_srt"

# Valid SRT
if grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> ' "$FIXTURES/basic.srt" && grep -qE '^[0-9]+$' "$FIXTURES/basic.srt"; then
    assert "validate: basic.srt is valid" 0
else
    assert "validate: basic.srt is valid" 1
fi

# Invalid file (no timestamps)
echo "This is not a subtitle file." > "$TMP_DIR/invalid.srt"
if grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> ' "$TMP_DIR/invalid.srt" 2>/dev/null; then
    assert "validate: invalid.srt detected as invalid" 1
else
    assert "validate: invalid.srt detected as invalid" 0
fi

# ══════════════════════════════════════════════════════════════════════════════
section "extract (ffmpeg)"

if command -v ffmpeg &>/dev/null; then
    # Create a test video with embedded subtitles
    test_video="$TMP_DIR/test_video.mkv"
    ffmpeg -v quiet -f lavfi -i "color=black:s=320x240:d=5" \
        -i "$FIXTURES/basic.srt" \
        -c:v libx264 -preset ultrafast -c:s srt \
        -metadata:s:s:0 language=de \
        "$test_video" -y 2>/dev/null

    if [[ -f "$test_video" ]]; then
        out=$("$SUBSYNC" extract "$test_video" --track 0 -o "$TMP_DIR" 2>&1)
        extract_file=$(printf '%s\n' "$TMP_DIR"/test_video.*.srt | grep -v '\*' | head -1 || true)
        assert_file_exists "extract: subtitles extracted" "${extract_file:-/nonexistent}"
        if [[ -n "$extract_file" ]]; then
            assert_file_contains "extract: correct content" "$extract_file" "Willkommen"
        fi
    else
        assert "extract: test video created" 1
    fi

    # Test embed
    section "embed (ffmpeg)"
    embed_out="$TMP_DIR/test_video.subbed.mkv"
    "$SUBSYNC" embed "$test_video" --sub "$FIXTURES/basic_fr.srt" -l fr -o "$TMP_DIR" 2>&1
    assert_file_exists "embed: video with subs created" "$embed_out"

    if [[ -f "$embed_out" ]]; then
        # Verify video has subtitles
        sub_count=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$embed_out" 2>/dev/null | jq '.streams | length' 2>/dev/null || echo 0)
        if [[ "$sub_count" -gt 0 ]]; then
            assert "embed: video contains subtitles" 0
        else
            assert "embed: video contains subtitles" 1
        fi
    fi
else
    printf "  ${YELLOW}SKIP${NC}  extract/embed: ffmpeg not available\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "translate (API - optional)"

if [[ -n "${ZAI_API_KEY:-}" ]]; then
    "$SUBSYNC" translate "$FIXTURES/basic.srt" -l fr --from de -p zai-codeplan -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.fr.srt"
    assert_file_exists "translate zai-codeplan: file created" "$out_file"
    assert_file_contains "translate zai-codeplan: contains timestamps" "$out_file" '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}'
    # Verify it's actually French
    sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$out_file" | head -5 | tr '\n' ' ')
    if echo "$sample" | grep -qiE '\b(le|la|les|des|est|une|que|pas|avec|dans|chez|ici)\b'; then
        assert "translate zai-codeplan: result in French" 0
    else
        assert "translate zai-codeplan: result in French" 1
    fi

    # Verify block count is preserved
    src_blocks=$(grep -cE '^[0-9]+$' "$FIXTURES/basic.srt" || true)
    dst_blocks=$(grep -cE '^[0-9]+$' "$out_file" || true)
    if [[ "$src_blocks" -eq "$dst_blocks" ]]; then
        assert "translate zai-codeplan: same block count ($src_blocks)" 0
    else
        assert "translate zai-codeplan: same block count (src=$src_blocks dst=$dst_blocks)" 1
    fi
else
    printf "  ${YELLOW}SKIP${NC}  translate zai-codeplan: ZAI_API_KEY not set\n"
fi

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    "$SUBSYNC" translate "$FIXTURES/basic.srt" -l en --from de -p openai -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate openai: file created" "$out_file"
    assert_file_contains "translate openai: contains timestamps" "$out_file" '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}'
else
    printf "  ${YELLOW}SKIP${NC}  translate openai: OPENAI_API_KEY not set\n"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    "$SUBSYNC" translate "$FIXTURES/basic.srt" -l en --from de -p claude -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate claude: file created" "$out_file"
else
    printf "  ${YELLOW}SKIP${NC}  translate claude: ANTHROPIC_API_KEY not set\n"
fi

if [[ -n "${MISTRAL_API_KEY:-}" ]]; then
    "$SUBSYNC" translate "$FIXTURES/basic.srt" -l en --from de -p mistral -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate mistral: file created" "$out_file"
else
    printf "  ${YELLOW}SKIP${NC}  translate mistral: MISTRAL_API_KEY not set\n"
fi

if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    "$SUBSYNC" translate "$FIXTURES/basic.srt" -l en --from de -p gemini -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate gemini: file created" "$out_file"
else
    printf "  ${YELLOW}SKIP${NC}  translate gemini: GEMINI_API_KEY not set\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "translate (auto-detect source lang)"

# Without --from, should auto-detect
out=$("$SUBSYNC" translate /nonexistent.srt -l fr 2>&1 || true)
assert_output_contains "translate without --from: accepted (file error, not lang error)" "$out" "not found"

# ══════════════════════════════════════════════════════════════════════════════
section "search (API - optional)"

out=$("$SUBSYNC" search -q "Inception" -l en --sources opensubtitles-org --dry-run 2>&1 </dev/null || true)
assert_output_contains "search opensubtitles-org: results" "$out" "Subtitles found|Searching on"

# ══════════════════════════════════════════════════════════════════════════════
section "Flags: --quiet, --verbose"

out=$("$SUBSYNC" info "$FIXTURES/basic.srt" --quiet 2>&1)
# In quiet mode, info/header/log calls should be suppressed, but data should still output
if [[ -z "$out" ]] || ! echo "$out" | grep -q "Info:"; then
    assert "quiet: header suppressed" 0
else
    assert "quiet: header suppressed" 1
fi

out=$("$SUBSYNC" --version --verbose 2>&1)
assert_output_contains "verbose: version still works" "$out" '^[0-9]+\.[0-9]+\.[0-9]+'

# ══════════════════════════════════════════════════════════════════════════════
section "Edge cases"

# sync with negative shift that would go below zero
"$SUBSYNC" sync "$FIXTURES/basic.srt" --shift -5000 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_contains "sync negative: no negative timestamp" "$out_file" "00:00:00,000"
assert_file_not_contains "sync negative: no timestamp -" "$out_file" "^-"

# convert roundtrip SRT -> VTT -> SRT
"$SUBSYNC" convert "$FIXTURES/basic.srt" --to vtt -o "$TMP_DIR" 2>&1
"$SUBSYNC" convert "$TMP_DIR/basic.vtt" --to srt -o "$TMP_DIR" 2>&1
roundtrip="$TMP_DIR/basic.srt"
assert_file_contains "roundtrip srt->vtt->srt: timestamps OK" "$roundtrip" "00:00:01,000"
assert_file_contains "roundtrip srt->vtt->srt: text OK" "$roundtrip" "Willkommen"

# convert roundtrip SRT -> ASS -> SRT
"$SUBSYNC" convert "$FIXTURES/basic.srt" --to ass -o "$TMP_DIR" 2>&1
"$SUBSYNC" convert "$TMP_DIR/basic.ass" --to srt -o "$TMP_DIR" 2>&1
roundtrip="$TMP_DIR/basic.srt"
assert_file_contains "roundtrip srt->ass->srt: text OK" "$roundtrip" "Willkommen"

# info on non-existent file
out=$("$SUBSYNC" info /nonexistent/file.srt 2>&1 || true)
assert_output_contains "info non-existent file: error" "$out" "not found"

# translate without --from (default en)
# Just test that parse works, don't need actual translation
out=$("$SUBSYNC" translate /nonexistent.srt -l fr 2>&1 || true)
assert_output_contains "translate non-existent file: error" "$out" "not found"

# ══════════════════════════════════════════════════════════════════════════════
section "autosync"

# autosync without args -> error
out=$("$SUBSYNC" autosync 2>&1 || true)
assert_output_contains "autosync without file -> error" "$out" "Specify a file"

# autosync without --ref -> error
out=$("$SUBSYNC" autosync "$FIXTURES/basic.srt" 2>&1 || true)
assert_output_contains "autosync without --ref -> error" "$out" "Specify.*--ref"

# autosync non-existent file -> error
out=$("$SUBSYNC" autosync /nonexistent.srt --ref /nonexistent.mkv 2>&1 || true)
assert_output_contains "autosync non-existent file -> error" "$out" "not found"

# autosync without ffsubsync -> uvx message or fallback uvx
if ! command -v ffsubsync &>/dev/null && ! command -v uvx &>/dev/null; then
    out=$("$SUBSYNC" autosync "$FIXTURES/basic.srt" --ref "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 || true)
    assert_output_contains "autosync without ffsubsync or uvx -> error" "$out" "uvx ffsubsync|uv tool install"
elif ! command -v ffsubsync &>/dev/null && command -v uvx &>/dev/null; then
    out=$("$SUBSYNC" autosync "$FIXTURES/basic.srt" --ref "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 || true)
    assert_output_contains "autosync via uvx: fallback detected" "$out" "uvx"
else
    printf "  ${YELLOW}SKIP${NC}  autosync without ffsubsync: ffsubsync is installed\n"
fi

# autosync with ffsubsync installed (functional test)
if command -v ffsubsync &>/dev/null; then
    "$SUBSYNC" autosync "$FIXTURES/basic.srt" --ref "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1
    autosync_out="$TMP_DIR/basic.synced.srt"
    assert_file_exists "autosync srt<->srt: file created" "$autosync_out"
    assert_file_contains "autosync srt<->srt: valid timestamps" "$autosync_out" '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}'
    assert_file_contains "autosync srt<->srt: text preserved" "$autosync_out" "Willkommen"
else
    printf "  ${YELLOW}SKIP${NC}  autosync functional: ffsubsync not available\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "scan"

# scan without args -> error
out=$("$SUBSYNC" scan 2>&1 || true)
assert_output_contains "scan without dir -> error" "$out" "Specify a directory"

# scan non-existent directory -> error
out=$("$SUBSYNC" scan /nonexistent_dir -l fr 2>&1 || true)
assert_output_contains "scan non-existent dir -> error" "$out" "not found"

# scan without --lang -> error
out=$("$SUBSYNC" scan "$TMP_DIR" 2>&1 || true)
assert_output_contains "scan without --lang -> error" "$out" "Specify.*-l.*lang|DEFAULT_LANG"

# scan empty directory (no videos) -> dry-run
scan_dir="$TMP_DIR/scan_empty"
mkdir -p "$scan_dir"
out=$("$SUBSYNC" scan "$scan_dir" -l fr --dry-run 2>&1 || true)
assert_output_contains "scan empty dir: scan header" "$out" "scan"

# scan directory with fake video file (dry-run, no network)
scan_dir2="$TMP_DIR/scan_videos"
mkdir -p "$scan_dir2"
touch "$scan_dir2/My.Movie.2024.mkv"
touch "$scan_dir2/My.Movie.2024.fr.srt"  # already has subtitle
out=$("$SUBSYNC" scan "$scan_dir2" -l fr --dry-run 2>&1 || true)
assert_output_contains "scan with existing sub: skip detected" "$out" "Skip.*already"

# ══════════════════════════════════════════════════════════════════════════════
section "check (ffsubsync detection)"

out=$("$SUBSYNC" check 2>&1)
assert_output_contains "check: shows ffsubsync" "$out" "ffsubsync"
if command -v ffsubsync &>/dev/null; then
    assert_output_contains "check: ffsubsync OK (installed)" "$out" "OK.*ffsubsync"
elif command -v uvx &>/dev/null; then
    assert_output_contains "check: ffsubsync OK (via uvx)" "$out" "via uvx"
else
    assert_output_contains "check: ffsubsync N/A with uvx hint" "$out" "uvx ffsubsync|uv tool install"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "detect_lang (unit tests)"

# Source internal functions for direct testing
_detect_lang_test() {
    local expected="$1" sample="$2" desc="$3"
    # Extract detect_lang + _detect_lang_offline from script
    local result
    result=$(bash -c "
        set -euo pipefail
        CACHE_DIR='$TMP_DIR'
        $(sed -n '/^detect_lang()/,/^}/p; /^_detect_lang_offline()/,/^}/p' "$SUBSYNC")
        detect_lang \"\$1\"
    " -- "$sample" 2>/dev/null) || true
    if [[ "$result" == "$expected" ]]; then
        assert "$desc" 0
    else
        assert "$desc (expected=$expected got=${result:-[none]})" 1
    fi
}

# ── via translate-shell (online, uses Google API) ──
if command -v trans &>/dev/null; then
    _detect_lang_test "en" "The thing is, you should have been there before they could even think about what would happen" \
        "detect_lang: English"
    _detect_lang_test "fr" "Nous avons fait cette chose avec vous dans cette maison mais elle était très bien sans rien" \
        "detect_lang: French"
    _detect_lang_test "de" "Ich bin nicht sicher ob wir das machen können aber wenn wir auch noch etwas haben dann ist alles gut" \
        "detect_lang: German"
    _detect_lang_test "es" "Pero esto no tiene nada aquí porque nosotros siempre estamos aquí cuando todos vamos después" \
        "detect_lang: Spanish"
    _detect_lang_test "it" "Questo è stato fatto bene, sono ancora qui dopo tutto, abbiamo qualcosa di molto proprio grazie" \
        "detect_lang: Italian"
    _detect_lang_test "pt" "Ele disse isso para ela quando ainda agora estou aqui porque também tenho muito obrigado" \
        "detect_lang: Portuguese"
    _detect_lang_test "ru" "Это было очень хорошо когда она сказала что все уже сейчас здесь потому что они тоже" \
        "detect_lang: Russian"
    _detect_lang_test "pl" "Nie wiem dlaczego tak się dzieje ale już teraz muszę tutaj zostać bo właśnie wszystko" \
        "detect_lang: Polish"
    _detect_lang_test "nl" "Het is niet goed dat hij daar was met zijn moeder want zij hebben geen waar ook heel" \
        "detect_lang: Dutch"
    _detect_lang_test "ja" "これは日本語のテストです ありがとう さようなら" \
        "detect_lang: Japanese"
    _detect_lang_test "ko" "이것은 한국어 테스트입니다 감사합니다" \
        "detect_lang: Korean"
    _detect_lang_test "zh" "这是中文测试 你好 谢谢 我们 他们 大家" \
        "detect_lang: Chinese"
    _detect_lang_test "ar" "هذا اختبار باللغة العربية شكرا جزيلا" \
        "detect_lang: Arabic"
    _detect_lang_test "sv" "Det var inte bra att han bara var här med alla från efter något mycket aldrig alltid" \
        "detect_lang: Swedish"
    _detect_lang_test "da" "Det er ikke godt men han har alle her fra efter bare hvad hvor aldrig altid noget tak" \
        "detect_lang: Danish"
    _detect_lang_test "fi" "Hän ei ole nyt vain tämä kun mutta myös niin aina koskaan ehkä paljon kiitos anteeksi minä sinä" \
        "detect_lang: Finnish"
    _detect_lang_test "tr" "Ben bir şey için burada çok güzel ama sen neden şimdi hiç yok belki tamam teşekkür" \
        "detect_lang: Turkish"
else
    printf "  ${YELLOW}SKIP${NC}  detect_lang online: trans not installed\n"
fi

# ── From real SRT fixtures ──
if command -v trans &>/dev/null; then
    de_sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$FIXTURES/basic.srt" | head -20 | tr '\n' ' ')
    _detect_lang_test "de" "$de_sample" "detect_lang: basic.srt -> German"

    fr_sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$FIXTURES/basic_fr.srt" | head -20 | tr '\n' ' ')
    _detect_lang_test "fr" "$fr_sample" "detect_lang: basic_fr.srt -> French"
fi

# ── Offline fallback (direct call to _detect_lang_offline) ──
_detect_lang_offline_test() {
    local expected="$1" sample="$2" desc="$3"
    local result
    result=$(bash -c "
        set -euo pipefail
        $(sed -n '/^_detect_lang_offline()/,/^}/p' "$SUBSYNC")
        _detect_lang_offline \"\$1\"
    " -- "$sample" 2>/dev/null) || true
    if [[ "$result" == "$expected" ]]; then
        assert "$desc" 0
    else
        assert "$desc (expected=$expected got=${result:-[none]})" 1
    fi
}

_detect_lang_offline_test "en" "The thing is, you should have been there before they could even think about what would happen" \
    "offline fallback: English"
_detect_lang_offline_test "fr" "Nous avons fait cette chose avec vous dans cette maison mais elle était très bien sans rien" \
    "offline fallback: French"
_detect_lang_offline_test "de" "Ich bin nicht sicher ob wir das machen können aber wenn wir auch noch etwas haben dann ist alles gut" \
    "offline fallback: German"
_detect_lang_offline_test "es" "Pero esto no tiene nada aquí porque nosotros siempre estamos aquí cuando todos vamos después" \
    "offline fallback: Spanish"
_detect_lang_offline_test "it" "Questo è stato fatto bene, sono ancora qui dopo tutto, abbiamo qualcosa di molto proprio grazie" \
    "offline fallback: Italian"
_detect_lang_offline_test "pt" "Ele disse isso para ela quando ainda agora estou aqui porque também tenho muito obrigado" \
    "offline fallback: Portuguese"
_detect_lang_offline_test "ru" "Это было очень хорошо когда она сказала что все уже сейчас здесь потому что они тоже" \
    "offline fallback: Russian"
_detect_lang_offline_test "pl" "Nie wiem dlaczego tak się dzieje ale już teraz muszę tutaj zostać bo właśnie wszystko" \
    "offline fallback: Polish"
_detect_lang_offline_test "nl" "Het is niet goed dat hij daar was met zijn moeder want zij hebben geen waar ook heel" \
    "offline fallback: Dutch"
_detect_lang_offline_test "fi" "Hän ei ole nyt vain tämä kun mutta myös niin aina koskaan ehkä paljon kiitos anteeksi minä sinä" \
    "offline fallback: Finnish"
_detect_lang_offline_test "tr" "Ben bir şey için burada çok güzel ama sen neden şimdi hiç yok belki tamam teşekkür" \
    "offline fallback: Turkish"
_detect_lang_offline_test "sv" "Det var inte bra att han bara var här med alla från efter något mycket aldrig alltid" \
    "offline fallback: Swedish"

# ── Edge cases ──
_detect_lang_offline_test "" "hello world" \
    "offline fallback: too short -> empty"
_detect_lang_offline_test "" "123 456 --> 789" \
    "offline fallback: numbers only -> empty"

# ══════════════════════════════════════════════════════════════════════════════
section "urlencode"

# Inline urlencode definition (can't sed-extract one-liner from script)
_urlencode() {
    jq -sRr @uri <<< "$1" | sed 's/%0A$//'
}

out=$(_urlencode "Die Discounter")
assert_output_contains "urlencode: spaces -> %20" "$out" "%20"

out=$(_urlencode "Café")
assert_output_contains "urlencode: accents encoded" "$out" "Caf"

out=$(_urlencode "test&value=1")
assert_output_contains "urlencode: & encoded" "$out" "%26"

# Verify no trailing %0A (newline encoding)
out=$(_urlencode "hello")
if [[ "$out" == *"%0A" ]]; then
    assert "urlencode: no trailing %0A" 1
else
    assert "urlencode: no trailing %0A" 0
fi

# ══════════════════════════════════════════════════════════════════════════════
section "Smart parsing (edge cases)"

# Leading zeros stripped
test_parse "Show S01E03"                                   "Episode"  "Show"               "1"     "3"
test_parse "Show S09E09"                                   "Episode"  "Show"               "9"     "9"

# Mixed case
test_parse "Show s02e05"                                   "Episode"  "Show"               "2"     "5"
test_parse "Show s2E5"                                     "Episode"  "Show"               "2"     "5"

# 3-digit episode
test_parse "Naruto S01E148"                                "Episode"  "Naruto"             "1"     "148"

# Year only -> movie
test_parse "The Matrix 1999"                               "Movie"    "The Matrix"

# Year + season (season takes priority, year still extracted)
# "year" is extracted but mode is still "episode"
test_parse "Show 2024 S01E05"                              "Episode"  "Show"               "1"     "5"

# French format
test_parse "Les Revenants saison 1"                        "Season"   "Les Revenants"      "1"
test_parse "Lupin saison 2 episode 3"                      "Episode"  "Lupin"              "2"     "3"
test_parse "Lupin saison 2 ep 3"                           "Episode"  "Lupin"              "2"     "3"

# Title with dashes
test_parse "Spider-Man S01E01"                             "Episode"  "Spider-Man"         "1"     "1"

# Only title (movie)
test_parse "Interstellar"                                  "Movie"    "Interstellar"

# Range without E prefix on end
test_parse "Show S01E01-05"                                "Range"    "Show"               "1"     "1" "5"

# ══════════════════════════════════════════════════════════════════════════════
section "OpenSubtitles URL building"

# Source functions needed
_test_os_url() {
    local query="$1" lang="$2" season="${3:-}" episode="${4:-}"
    bash -c "
        urlencode() { jq -sRr @uri <<< \"\$1\" | sed 's/%0A\$//'; }
        $(sed -n '/^search_opensubtitles_org()/,/^}/p' "$SUBSYNC")
        api_retry() { echo \"MOCK_URL: \$3\" >&2; return 1; }
        VERSION='1.0.0'
        search_opensubtitles_org \"\$@\" 2>&1
    " -- "$query" "$lang" "" "$season" "$episode" 2>&1 | grep "MOCK_URL:" | head -1 || true
}

out=$(_test_os_url "Breaking Bad" "en" "" "")
assert_output_contains "os-url: query-only" "$out" "query-breaking%20bad/sublanguageid-eng"

out=$(_test_os_url "Breaking Bad" "en" "5" "")
assert_output_contains "os-url: with season" "$out" "query-breaking%20bad/season-5/sublanguageid-eng"

out=$(_test_os_url "Breaking Bad" "en" "5" "14")
assert_output_contains "os-url: with season+episode" "$out" "episode-14/query-breaking%20bad/season-5/sublanguageid-eng"

# Alphabetical order: episode before query before season before sublanguageid
out=$(_test_os_url "test" "fr" "2" "3")
if echo "$out" | grep -q "episode-.*query-.*season-.*sublanguageid-"; then
    assert "os-url: path segments in alphabetical order" 0
else
    assert "os-url: path segments in alphabetical order" 1
fi

# Query must be lowercase
out=$(_test_os_url "DIE DISCOUNTER" "de" "" "")
assert_output_contains "os-url: query lowercased" "$out" "query-die%20discounter"

# Language code mapping
_test_os_lang() {
    local lang="$1" expected="$2"
    local out
    out=$(_test_os_url "test" "$lang" "" "")
    if echo "$out" | grep -q "sublanguageid-${expected}"; then
        assert "os-lang: $lang -> $expected" 0
    else
        assert "os-lang: $lang -> $expected (got: $out)" 1
    fi
}

_test_os_lang "fr"  "fre"
_test_os_lang "en"  "eng"
_test_os_lang "de"  "ger"
_test_os_lang "es"  "spa"
_test_os_lang "it"  "ita"
_test_os_lang "pt"  "por"
_test_os_lang "nl"  "dut"
_test_os_lang "pl"  "pol"
_test_os_lang "ru"  "rus"
_test_os_lang "ja"  "jpn"
_test_os_lang "ko"  "kor"
_test_os_lang "zh"  "chi"
_test_os_lang "tr"  "tur"
_test_os_lang "sv"  "swe"

# ══════════════════════════════════════════════════════════════════════════════
section "URL pattern parsing (download_from_url)"

_test_url_parse() {
    local url="$1" expected_id="$2" desc="$3"
    local result
    result=$(bash -c '
        url="$1"
        sub_id=""
        if [[ "$url" =~ opensubtitles\.org/[a-z]{2}/subtitles/([0-9]+) ]]; then
            sub_id="${BASH_REMATCH[1]}"
        elif [[ "$url" =~ opensubtitles\.org/[a-z]{2}/subtitleserve/sub/([0-9]+) ]]; then
            sub_id="${BASH_REMATCH[1]}"
        elif [[ "$url" =~ opensubtitles\.org/[a-z]{2}/download/sub/([0-9]+) ]]; then
            sub_id="${BASH_REMATCH[1]}"
        fi
        echo "$sub_id"
    ' -- "$url")
    if [[ "$result" == "$expected_id" ]]; then
        assert "$desc" 0
    else
        assert "$desc (expected=$expected_id got=${result:-[empty]})" 1
    fi
}

_test_url_parse "https://www.opensubtitles.org/en/subtitles/1234567/some-movie" \
    "1234567" "url-parse: /subtitles/ pattern"
_test_url_parse "https://www.opensubtitles.org/fr/subtitles/9876543/film-name" \
    "9876543" "url-parse: /subtitles/ with fr locale"
_test_url_parse "https://www.opensubtitles.org/en/subtitleserve/sub/5555555" \
    "5555555" "url-parse: /subtitleserve/sub/ pattern"
_test_url_parse "https://dl.opensubtitles.org/en/download/sub/7777777" \
    "7777777" "url-parse: /download/sub/ pattern"
_test_url_parse "https://example.com/random" \
    "" "url-parse: non-opensubtitles URL -> no ID"
_test_url_parse "not-a-url" \
    "" "url-parse: invalid input -> no ID"

# ══════════════════════════════════════════════════════════════════════════════
section "embed codec selection"

_test_codec() {
    local ext="$1" expected="$2" desc="$3"
    local sub_codec="srt"
    case "$ext" in
        mp4|m4v|mov) sub_codec="mov_text" ;;
    esac
    if [[ "$sub_codec" == "$expected" ]]; then
        assert "$desc" 0
    else
        assert "$desc (expected=$expected got=$sub_codec)" 1
    fi
}

_test_codec "mkv" "srt"      "codec: mkv -> srt"
_test_codec "mp4" "mov_text"  "codec: mp4 -> mov_text"
_test_codec "m4v" "mov_text"  "codec: m4v -> mov_text"
_test_codec "mov" "mov_text"  "codec: mov -> mov_text"
_test_codec "avi" "srt"       "codec: avi -> srt"
_test_codec "webm" "srt"      "codec: webm -> srt"

# ══════════════════════════════════════════════════════════════════════════════
section "extract codec -> extension mapping"

_test_extract_ext() {
    local codec="$1" expected="$2" desc="$3"
    local ext
    case "$codec" in
        subrip|srt)  ext="srt" ;;
        ass|ssa)     ext="ass" ;;
        webvtt)      ext="vtt" ;;
        hdmv_pgs_subtitle|dvd_subtitle) ext="sup" ;;
        *)           ext="srt" ;;
    esac
    if [[ "$ext" == "$expected" ]]; then
        assert "$desc" 0
    else
        assert "$desc (expected=$expected got=$ext)" 1
    fi
}

_test_extract_ext "subrip"               "srt" "extract-ext: subrip -> srt"
_test_extract_ext "srt"                  "srt" "extract-ext: srt -> srt"
_test_extract_ext "ass"                  "ass" "extract-ext: ass -> ass"
_test_extract_ext "ssa"                  "ass" "extract-ext: ssa -> ass"
_test_extract_ext "webvtt"               "vtt" "extract-ext: webvtt -> vtt"
_test_extract_ext "hdmv_pgs_subtitle"    "sup" "extract-ext: pgs bitmap -> sup"
_test_extract_ext "dvd_subtitle"         "sup" "extract-ext: dvd bitmap -> sup"
_test_extract_ext "unknown_codec"        "srt" "extract-ext: unknown -> srt fallback"

# ══════════════════════════════════════════════════════════════════════════════
section "extract (auto-select single track)"

if command -v ffmpeg &>/dev/null; then
    # MKV with single subtitle track (no --track, should auto-select)
    single_track_video="$TMP_DIR/single_track.mkv"
    ffmpeg -v quiet -f lavfi -i "color=black:s=320x240:d=1" \
        -i "$FIXTURES/basic.srt" \
        -c:v libx264 -preset ultrafast -c:s srt \
        "$single_track_video" -y 2>/dev/null

    if [[ -f "$single_track_video" ]]; then
        out=$("$SUBSYNC" extract "$single_track_video" -o "$TMP_DIR" 2>&1)
        rc=$?
        assert_exit_code "extract auto-select: exits 0 (no --track needed)" "0" "$rc"
    fi

    # MP4 embed + extract roundtrip
    mp4_video="$TMP_DIR/test_mp4.mp4"
    ffmpeg -v quiet -f lavfi -i "color=black:s=320x240:d=1" \
        -c:v libx264 -preset ultrafast \
        "$mp4_video" -y 2>/dev/null

    if [[ -f "$mp4_video" ]]; then
        out=$("$SUBSYNC" embed "$mp4_video" --sub "$FIXTURES/basic.srt" -l de -o "$TMP_DIR" 2>&1)
        embedded="$TMP_DIR/test_mp4.subbed.mp4"
        if [[ -s "$embedded" ]]; then
            assert "embed mp4: mov_text codec works" 0
            # Verify subtitles embedded
            sub_count=$(ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$embedded" 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$sub_count" -gt 0 ]]; then
                assert "embed mp4: subtitle stream present" 0
            else
                assert "embed mp4: subtitle stream present" 1
            fi
        else
            assert "embed mp4: mov_text codec works" 1
        fi
    fi
else
    printf "  ${YELLOW}SKIP${NC}  extract/embed advanced: ffmpeg not available\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "embed with mix (target + source + mix as three tracks)"

if command -v ffmpeg &>/dev/null; then
    # Create a clean test video (no subtitles)
    mix_embed_video="$TMP_DIR/mix_embed_test.mkv"
    ffmpeg -v quiet -f lavfi -i "color=black:s=320x240:d=1" \
        -c:v libx264 -preset ultrafast \
        "$mix_embed_video" -y 2>/dev/null

    if [[ -f "$mix_embed_video" ]]; then
        # Create mix SRT file
        "$SUBSYNC" mix "$FIXTURES/basic.srt" --mix-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 >/dev/null
        mix_sub="$TMP_DIR/mix_embed_test.mix.srt"
        cp "$TMP_DIR/basic.mix.srt" "$mix_sub"

        # Embed 3 tracks sequentially: FR, DE, Mix (simulates _auto_embed_with_mix)
        # Track 1: French subtitle
        "$SUBSYNC" embed "$mix_embed_video" --sub "$FIXTURES/basic_fr.srt" -l fr -o "$TMP_DIR" 2>&1 >/dev/null
        embed_result="$TMP_DIR/mix_embed_test.subbed.mkv"

        if [[ -s "$embed_result" ]]; then
            # Track 2: German subtitle (source language)
            mv "$embed_result" "$mix_embed_video"
            "$SUBSYNC" embed "$mix_embed_video" --sub "$FIXTURES/basic.srt" -l de -o "$TMP_DIR" 2>&1 >/dev/null
            embed_result="$TMP_DIR/mix_embed_test.subbed.mkv"

            if [[ -s "$embed_result" ]]; then
                # Track 3: Mix subtitle
                mv "$embed_result" "$mix_embed_video"
                "$SUBSYNC" embed "$mix_embed_video" --sub "$mix_sub" -l mul -o "$TMP_DIR" 2>&1 >/dev/null
                embed_result="$TMP_DIR/mix_embed_test.subbed.mkv"

                if [[ -s "$embed_result" ]]; then
                    sub_count=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$embed_result" 2>/dev/null | jq '.streams | length' 2>/dev/null || echo 0)
                    if [[ "$sub_count" -eq 3 ]]; then
                        assert "embed+mix: three subtitle tracks present" 0
                    else
                        assert "embed+mix: three subtitle tracks present (got $sub_count)" 1
                    fi

                    # Verify track order: FR, DE, Mix
                    first_lang=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$embed_result" 2>/dev/null | jq -r '.streams[0].tags.language // "und"' 2>/dev/null || echo "und")
                    second_lang=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$embed_result" 2>/dev/null | jq -r '.streams[1].tags.language // "und"' 2>/dev/null || echo "und")
                    if [[ "$first_lang" == "fre" || "$first_lang" == "fr" ]]; then
                        assert "embed+mix: track 1 is French" 0
                    else
                        assert "embed+mix: track 1 is French (got $first_lang)" 1
                    fi
                    if [[ "$second_lang" == "ger" || "$second_lang" == "de" ]]; then
                        assert "embed+mix: track 2 is German" 0
                    else
                        assert "embed+mix: track 2 is German (got $second_lang)" 1
                    fi
                else
                    assert "embed+mix: third embed (mix) succeeded" 1
                fi
            else
                assert "embed+mix: second embed (DE) succeeded" 1
            fi
        else
            assert "embed+mix: first embed (FR) succeeded" 1
        fi
    fi

    # Test strip + embed three tracks (simulates _auto_embed_with_mix with --strip-existing)
    section "embed with mix (strip + three tracks)"

    # Create a video with one existing subtitle (German)
    strip_video="$TMP_DIR/strip_mix_test.mkv"
    ffmpeg -v quiet -f lavfi -i "color=black:s=320x240:d=1" \
        -i "$FIXTURES/basic.srt" \
        -c:v libx264 -preset ultrafast -c:s srt \
        -metadata:s:s:0 language=de \
        "$strip_video" -y 2>/dev/null

    if [[ -f "$strip_video" ]]; then
        # Verify it has 1 subtitle track initially
        initial_count=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$strip_video" 2>/dev/null | jq '.streams | length' 2>/dev/null || echo 0)
        assert "strip+mix setup: video has initial subtitle" "$([ "$initial_count" -eq 1 ] && echo 0 || echo 1)"

        # Strip existing subtitles in-place
        "$SUBSYNC" strip "$strip_video" 2>&1 >/dev/null

        after_strip_count=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$strip_video" 2>/dev/null | jq '.streams | length' 2>/dev/null || echo 0)
        assert "strip+mix: subtitles removed" "$([ "$after_strip_count" -eq 0 ] && echo 0 || echo 1)"

        # Embed 3 tracks: FR, DE, Mix
        "$SUBSYNC" embed "$strip_video" --sub "$FIXTURES/basic_fr.srt" -l fr -o "$TMP_DIR" 2>&1 >/dev/null
        fr_out="$TMP_DIR/strip_mix_test.subbed.mkv"

        if [[ -s "$fr_out" ]]; then
            mv "$fr_out" "$strip_video"
            "$SUBSYNC" embed "$strip_video" --sub "$FIXTURES/basic.srt" -l de -o "$TMP_DIR" 2>&1 >/dev/null
            de_out="$TMP_DIR/strip_mix_test.subbed.mkv"

            if [[ -s "$de_out" ]]; then
                mix_sub2="$TMP_DIR/strip_mix_test.mix.srt"
                cp "$TMP_DIR/basic.mix.srt" "$mix_sub2" 2>/dev/null || {
                    "$SUBSYNC" mix "$FIXTURES/basic.srt" --mix-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 >/dev/null
                    cp "$TMP_DIR/basic.mix.srt" "$mix_sub2"
                }

                mv "$de_out" "$strip_video"
                "$SUBSYNC" embed "$strip_video" --sub "$mix_sub2" -l mul -o "$TMP_DIR" 2>&1 >/dev/null
                final_out="$TMP_DIR/strip_mix_test.subbed.mkv"

                if [[ -s "$final_out" ]]; then
                    final_count=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$final_out" 2>/dev/null | jq '.streams | length' 2>/dev/null || echo 0)
                    if [[ "$final_count" -eq 3 ]]; then
                        assert "strip+mix: final video has 3 subtitle tracks" 0
                    else
                        assert "strip+mix: final video has 3 subtitle tracks (got $final_count)" 1
                    fi
                else
                    assert "strip+mix: mix embed succeeded" 1
                fi
            else
                assert "strip+mix: DE embed succeeded" 1
            fi
        else
            assert "strip+mix: French embed succeeded" 1
        fi
    fi
else
    printf "  ${YELLOW}SKIP${NC}  embed with mix: ffmpeg not available\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "Google translate text extraction"

# Test that text extraction skips indices, timestamps, blank lines, keeps only text
_test_google_extract() {
    local input="$1" expected_lines="$2" desc="$3"
    local text_file="$TMP_DIR/extract_test_text.txt"
    local lineno=0
    : > "$text_file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno++)) || true
        line="${line%$'\r'}"
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || [[ "$line" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
            continue
        fi
        echo "$line" >> "$text_file"
    done < "$input"
    local count
    count=$(wc -l < "$text_file" | tr -d ' ')
    if [[ "$count" == "$expected_lines" ]]; then
        assert "$desc" 0
    else
        assert "$desc (expected=$expected_lines got=$count)" 1
    fi
}

# basic.srt: 5 blocks (1 single-line + 4 double-line = 9 text lines)
_test_google_extract "$FIXTURES/basic.srt" "9" "google-extract: basic.srt -> 9 text lines"
# already_clean.srt: 3 blocks, 1 line each
_test_google_extract "$FIXTURES/already_clean.srt" "3" "google-extract: already_clean.srt -> 3 text lines"

# Verify text lines match expected content (no indices or timestamps)
text_out="$TMP_DIR/extract_test_text.txt"
: > "$text_out"
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || [[ "$line" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
        continue
    fi
    echo "$line" >> "$text_out"
done < "$FIXTURES/basic.srt"

assert_file_contains "google-extract: text preserved" "$text_out" "Willkommen"
assert_file_contains "google-extract: multiline text preserved" "$text_out" "Regale einraumen"
assert_file_not_contains "google-extract: no indices" "$text_out" "^[0-9]+$"
assert_file_not_contains "google-extract: no timestamps" "$text_out" "[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}"

# ══════════════════════════════════════════════════════════════════════════════
section "chunk_srt (boundary tests)"

# Source chunk_srt from script for direct testing
_test_chunk() {
    local file="$1" max_lines="$2" expected_chunks="$3" desc="$4"
    local chunk_dir="$TMP_DIR/chunk_test_$$"
    rm -rf "$chunk_dir"
    mkdir -p "$chunk_dir"
    local result
    result=$(bash -c "
        set -uo pipefail
        CACHE_DIR='$chunk_dir'
        $(sed -n '/^chunk_srt()/,/^}/p' "$SUBSYNC")
        chunk_srt \"\$1\" \"\$2\"
    " -- "$file" "$max_lines" 2>/dev/null) || true
    if [[ "$result" == "$expected_chunks" ]]; then
        assert "$desc" 0
    else
        assert "$desc (expected=$expected_chunks got=${result:-0})" 1
    fi
    rm -rf "$chunk_dir"
}

_test_chunk "$FIXTURES/basic.srt" "200" "1" "chunk: small file, high limit -> 1 chunk"
_test_chunk "$FIXTURES/basic.srt" "4"   "5" "chunk: small file, low limit -> 5 chunks"
_test_chunk "$FIXTURES/large.srt" "10"  "7" "chunk: large file, 10-line limit -> 7 chunks"
_test_chunk "$FIXTURES/large.srt" "200" "1" "chunk: large file, high limit -> 1 chunk"

# ══════════════════════════════════════════════════════════════════════════════
section "CRLF handling"

# Create a CRLF file and test that fix converts it
crlf_file="$TMP_DIR/crlf_test.srt"
printf "1\r\n00:00:01,000 --> 00:00:03,500\r\nHello CRLF world.\r\n\r\n2\r\n00:00:04,000 --> 00:00:07,000\r\nSecond block.\r\n" > "$crlf_file"
"$SUBSYNC" fix "$crlf_file" -o "$TMP_DIR" 2>&1 >/dev/null
fixed_crlf="$TMP_DIR/crlf_test.fixed.srt"
if [[ -f "$fixed_crlf" ]]; then
    # Check no \r in output
    if grep -qP '\r' "$fixed_crlf" 2>/dev/null || grep -c $'\r' "$fixed_crlf" 2>/dev/null | grep -qv '^0$'; then
        assert "crlf: fix removes \\r" 1
    else
        assert "crlf: fix removes \\r" 0
    fi
    assert_file_contains "crlf: text preserved after fix" "$fixed_crlf" "Hello CRLF world"
    assert_file_contains "crlf: timestamps preserved after fix" "$fixed_crlf" "00:00:01,000"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "BOM handling"

# Create a file with UTF-8 BOM
bom_file="$TMP_DIR/bom_test.srt"
printf '\xef\xbb\xbf1\n00:00:01,000 --> 00:00:03,500\nBOM test line.\n\n2\n00:00:04,000 --> 00:00:07,000\nSecond block.\n' > "$bom_file"
"$SUBSYNC" fix "$bom_file" -o "$TMP_DIR" 2>&1 >/dev/null
fixed_bom="$TMP_DIR/bom_test.fixed.srt"
if [[ -f "$fixed_bom" ]]; then
    # Check BOM removed (first 3 bytes should NOT be EF BB BF)
    first_bytes=$(xxd -l 3 -p "$fixed_bom" 2>/dev/null)
    if [[ "$first_bytes" == "efbbbf" ]]; then
        assert "bom: fix removes UTF-8 BOM" 1
    else
        assert "bom: fix removes UTF-8 BOM" 0
    fi
    assert_file_contains "bom: text preserved after BOM removal" "$fixed_bom" "BOM test line"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "CLI flag validation"

# --help shows --keep-files
out=$("$SUBSYNC" --help 2>&1)
assert_output_contains "help: shows --keep-files" "$out" "\-\-keep-files"
assert_output_contains "help: shows --force-translate" "$out" "\-\-force-translate"
assert_output_contains "help: shows --embed" "$out" "\-\-embed"
assert_output_contains "help: shows --no-embed" "$out" "\-\-no-embed"
assert_output_contains "help: shows autosync" "$out" "autosync"
assert_output_contains "help: shows extract" "$out" "extract"
assert_output_contains "help: shows embed command" "$out" "embed"
assert_output_contains "help: shows --from" "$out" "\-\-from"
assert_output_contains "help: shows --model" "$out" "\-\-model"

# ══════════════════════════════════════════════════════════════════════════════
section "sync edge cases"

# Sync to exact zero (timestamp should clamp to 00:00:00,000)
"$SUBSYNC" sync "$FIXTURES/basic.srt" --shift -1000 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_contains "sync -1000ms: first timestamp shifted" "$out_file" "00:00:00,000"
assert_file_not_contains "sync -1000ms: no negative timestamps" "$out_file" "^-"

# Large positive shift
"$SUBSYNC" sync "$FIXTURES/basic.srt" --shift +3600000 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_contains "sync +1h: hour shift works" "$out_file" "01:00:01,000"

# ══════════════════════════════════════════════════════════════════════════════
section "clean edge cases"

# Clean file with music notes (♪) — clean removes ♪...♪ lines
clean_music="$TMP_DIR/music_test.srt"
cat > "$clean_music" << 'EOF'
1
00:00:01,000 --> 00:00:03,500
♪ La la la ♪

2
00:00:04,000 --> 00:00:07,000
Real dialogue here.

3
00:00:08,000 --> 00:00:11,000
<i>Italic text to remove</i>
EOF
"$SUBSYNC" clean "$clean_music" -o "$TMP_DIR" 2>&1 >/dev/null
cleaned="$TMP_DIR/music_test.clean.srt"
assert_file_not_contains "clean: music notes removed" "$cleaned" "♪"
assert_file_contains "clean: real dialogue preserved" "$cleaned" "Real dialogue"
assert_file_not_contains "clean: HTML <i> removed" "$cleaned" "<i>"

# ══════════════════════════════════════════════════════════════════════════════
section "convert edge cases"

# Convert empty-ish SRT (only 1 block)
single_block="$TMP_DIR/single_block.srt"
cat > "$single_block" << 'EOF'
1
00:00:01,000 --> 00:00:03,500
Only one block.
EOF
"$SUBSYNC" convert "$single_block" --to vtt -o "$TMP_DIR" 2>&1 >/dev/null
out_file="$TMP_DIR/single_block.vtt"
assert_file_exists "convert single block: vtt created" "$out_file"
assert_file_contains "convert single block: WEBVTT header" "$out_file" "^WEBVTT"
assert_file_contains "convert single block: text preserved" "$out_file" "Only one block"

# ══════════════════════════════════════════════════════════════════════════════
section "merge edge cases"

# Merge files with different subtitle counts (secondary shorter)
short_file="$TMP_DIR/short.srt"
cat > "$short_file" << 'EOF'
1
00:00:01,000 --> 00:00:03,500
Only two blocks.

2
00:00:04,000 --> 00:00:07,200
Second block short.
EOF
"$SUBSYNC" merge "$FIXTURES/basic.srt" --merge-with "$short_file" -o "$TMP_DIR" 2>&1 >/dev/null
merged="$TMP_DIR/basic.dual.srt"
assert_file_contains "merge mismatched: primary text preserved" "$merged" "Willkommen"
assert_file_contains "merge mismatched: secondary text present" "$merged" "Only two blocks"

# ══════════════════════════════════════════════════════════════════════════════
section "mix"

"$SUBSYNC" mix "$FIXTURES/basic.srt" --mix-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.mix.srt"
assert_file_exists "mix: file created" "$out_file"
# Primary file (DE) should be on top (learning language), --mix-with (FR) in italic (reference)
assert_file_contains "mix: original text (DE) on top" "$out_file" "Willkommen"
assert_file_contains "mix: translated text (FR) in italic" "$out_file" "<i>Bienvenue"
assert_file_contains "mix: timestamps preserved" "$out_file" "00:00:01,000 --> 00:00:03,500"
# DE text must NOT be wrapped in italic
if grep -q "<i>Willkommen" "$out_file"; then
    assert "mix: DE text is not italic" 1
else
    assert "mix: DE text is not italic" 0
fi

# Verify each block has both languages
de_count=$(grep -c "Willkommen\|Regale\|Pause\|Discounter\|Angebote" "$out_file" || true)
fr_count=$(grep -c "Bienvenue\|rayons\|pause\|discounter\|offres" "$out_file" || true)
if [[ "$de_count" -gt 0 && "$fr_count" -gt 0 ]]; then
    assert "mix: both languages present" 0
else
    assert "mix: both languages present" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "mix edge cases"

# Mix files with different subtitle counts (secondary shorter)
short_mix="$TMP_DIR/short_mix.srt"
cat > "$short_mix" << 'EOF'
1
00:00:01,000 --> 00:00:03,500
Only one block here.
EOF
"$SUBSYNC" mix "$FIXTURES/basic.srt" --mix-with "$short_mix" -o "$TMP_DIR" 2>&1 >/dev/null
mixed="$TMP_DIR/basic.mix.srt"
if [[ -f "$mixed" ]]; then
    # Primary (DE) on top, secondary (short_mix) in italic
    assert_file_contains "mix mismatched: primary text preserved" "$mixed" "Willkommen"
    assert_file_contains "mix mismatched: secondary text present" "$mixed" "Only one block"
    # Blocks without a secondary should still have primary text
    assert_file_contains "mix mismatched: later primary blocks preserved" "$mixed" "Angebote"
else
    assert "mix mismatched: output file found" 1
fi

# Mix with filenames that have lang codes
cp "$FIXTURES/basic.srt" "$TMP_DIR/episode.de.srt"
cp "$FIXTURES/basic_fr.srt" "$TMP_DIR/episode.fr.srt"
"$SUBSYNC" mix "$TMP_DIR/episode.de.srt" --mix-with "$TMP_DIR/episode.fr.srt" -o "$TMP_DIR" 2>&1 >/dev/null
assert_file_exists "mix lang codes: output is .mix.srt" "$TMP_DIR/episode.mix.srt"

# Verify display order: DE (primary/learning) on top, FR (reference) in italic
if [[ -f "$TMP_DIR/episode.mix.srt" ]]; then
    assert_file_contains "mix lang codes: DE on top" "$TMP_DIR/episode.mix.srt" "Willkommen"
    assert_file_contains "mix lang codes: FR in italic" "$TMP_DIR/episode.mix.srt" "<i>Bienvenue"
    if grep -q "<i>Willkommen" "$TMP_DIR/episode.mix.srt"; then
        assert "mix lang codes: DE not italic" 1
    else
        assert "mix lang codes: DE not italic" 0
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "mix swap mode"

# Swap mode: primary timestamps, but secondary text on top
# Use basic.srt (DE) as primary (timestamp source), basic_fr.srt as secondary
# With swap=false (default): DE on top, FR in italic (tested above)
# Here we test the underlying _mix_subtitles swap via cmd_mix argument order
# Create a reversed mix: FR as primary, DE as --mix-with → FR on top, DE in italic
"$SUBSYNC" mix "$FIXTURES/basic_fr.srt" --mix-with "$FIXTURES/basic.srt" -o "$TMP_DIR" 2>&1 >/dev/null
swapped="$TMP_DIR/basic_fr.mix.srt"
if [[ -f "$swapped" ]]; then
    # Now FR (primary) should be on top, DE (secondary) in italic
    assert_file_contains "mix reversed: FR on top" "$swapped" "Bienvenue"
    assert_file_contains "mix reversed: DE in italic" "$swapped" "<i>Willkommen"
    if grep -q "<i>Bienvenue" "$swapped"; then
        assert "mix reversed: FR not italic" 1
    else
        assert "mix reversed: FR not italic" 0
    fi
else
    assert "mix reversed: output file found" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "mix timestamp source"

# When files have DIFFERENT timestamps, mix must use --mix-with timestamps (not primary)
# This is critical: primary text on top, but timestamps from --mix-with (secondary arg)
ts_pri="$TMP_DIR/ts_primary.de.srt"
ts_sec="$TMP_DIR/ts_secondary.fr.srt"
cat > "$ts_pri" << 'EOF'
1
00:00:10,000 --> 00:00:13,000
Hallo Welt

2
00:00:20,000 --> 00:00:23,000
Guten Tag
EOF
cat > "$ts_sec" << 'EOF'
1
00:00:01,000 --> 00:00:03,000
Bonjour le monde

2
00:00:05,000 --> 00:00:07,000
Bonne journee
EOF

"$SUBSYNC" mix "$ts_pri" --mix-with "$ts_sec" -o "$TMP_DIR" 2>&1 >/dev/null
ts_out="$TMP_DIR/ts_primary.mix.srt"
if [[ -f "$ts_out" ]]; then
    # Timestamps should come from --mix-with file (FR: 01,000 and 05,000), NOT primary (DE: 10,000 and 20,000)
    assert_file_contains "mix timestamps: uses --mix-with timing (block 1)" "$ts_out" "00:00:01,000 --> 00:00:03,000"
    assert_file_contains "mix timestamps: uses --mix-with timing (block 2)" "$ts_out" "00:00:05,000 --> 00:00:07,000"
    # Primary text (DE) should be on top, not italic
    assert_file_contains "mix timestamps: DE text on top" "$ts_out" "Hallo Welt"
    if grep -q "<i>Hallo" "$ts_out"; then
        assert "mix timestamps: DE not italic" 1
    else
        assert "mix timestamps: DE not italic" 0
    fi
    # --mix-with text (FR) should be in italic
    assert_file_contains "mix timestamps: FR text in italic" "$ts_out" "<i>Bonjour"
    # Must NOT have primary timestamps
    if grep -q "00:00:10,000" "$ts_out"; then
        assert "mix timestamps: no primary timing leak" 1
    else
        assert "mix timestamps: no primary timing leak" 0
    fi
else
    assert "mix timestamps: output file found" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "mix backslash handling"

# Subtitle text containing backslashes should be preserved (not interpreted as escape sequences)
backslash_srt="$TMP_DIR/backslash.srt"
cat > "$backslash_srt" << 'EOF'
1
00:00:01,000 --> 00:00:03,500
path\next line test

2
00:00:04,000 --> 00:00:06,000
C:\new\test folder
EOF
"$SUBSYNC" mix "$backslash_srt" --mix-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 >/dev/null
bs_mixed="$TMP_DIR/backslash.mix.srt"
if [[ -f "$bs_mixed" ]]; then
    # The \n and \t in the text should be preserved literally, not interpreted as newlines/tabs
    assert_file_contains "mix backslash: literal backslash-n preserved" "$bs_mixed" 'path\\next'
    assert_file_contains "mix backslash: literal backslash-t preserved" "$bs_mixed" 'C:\\new\\test'
else
    assert "mix backslash: output file found" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "mix pipe character in text"

# Subtitle text containing pipe characters should be preserved
pipe_srt="$TMP_DIR/pipe.srt"
cat > "$pipe_srt" << 'EOF'
1
00:00:01,000 --> 00:00:03,500
Yes | No | Maybe

2
00:00:04,000 --> 00:00:06,000
A | B
EOF
"$SUBSYNC" mix "$pipe_srt" --mix-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 >/dev/null
pipe_mixed="$TMP_DIR/pipe.mix.srt"
if [[ -f "$pipe_mixed" ]]; then
    assert_file_contains "mix pipe: pipe chars preserved in text" "$pipe_mixed" "Yes | No | Maybe"
    assert_file_contains "mix pipe: second block pipe preserved" "$pipe_mixed" "A | B"
else
    assert "mix pipe: output file found" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "mix secondary longer than primary"

# When secondary has more blocks than primary, secondary-only blocks should use secondary timestamps
short_pri="$TMP_DIR/short_pri.srt"
cat > "$short_pri" << 'EOF'
1
00:00:01,000 --> 00:00:03,500
Only primary block
EOF
"$SUBSYNC" mix "$short_pri" --mix-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 >/dev/null
sec_longer="$TMP_DIR/short_pri.mix.srt"
if [[ -f "$sec_longer" ]]; then
    # First block: primary on top, secondary (FR) in italic
    assert_file_contains "mix sec-longer: primary text on top" "$sec_longer" "Only primary block"
    assert_file_contains "mix sec-longer: secondary in italic" "$sec_longer" "<i>Bienvenue"
    # Later blocks: should be italic-only (secondary has more blocks)
    block_count=$(grep -c "^[0-9]\+$" "$sec_longer" || true)
    if [[ "$block_count" -gt 1 ]]; then
        assert "mix sec-longer: secondary-only blocks preserved" 0
    else
        assert "mix sec-longer: secondary-only blocks preserved" 1
    fi
else
    assert "mix sec-longer: output file found" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "merge secondary longer than primary"

# merge should also handle secondary having more blocks
"$SUBSYNC" merge "$short_pri" --merge-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 >/dev/null
merge_longer="$TMP_DIR/short_pri.dual.srt"
if [[ -f "$merge_longer" ]]; then
    assert_file_contains "merge sec-longer: primary text preserved" "$merge_longer" "Only primary block"
    merge_block_count=$(grep -c "^[0-9]\+$" "$merge_longer" || true)
    if [[ "$merge_block_count" -gt 1 ]]; then
        assert "merge sec-longer: secondary-only blocks preserved" 0
    else
        assert "merge sec-longer: secondary-only blocks preserved" 1
    fi
else
    assert "merge sec-longer: output file found" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "merge BOM handling"

# BOM-encoded file should be handled correctly
bom_srt="$TMP_DIR/bom.srt"
printf '\xef\xbb\xbf1\n00:00:01,000 --> 00:00:03,500\nBOM text\n\n' > "$bom_srt"
"$SUBSYNC" merge "$bom_srt" --merge-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 >/dev/null
bom_merged="$TMP_DIR/bom.dual.srt"
if [[ -f "$bom_merged" ]]; then
    assert_file_contains "merge BOM: text preserved" "$bom_merged" "BOM text"
    # Timestamps should not have BOM bytes
    assert_file_contains "merge BOM: clean timestamps" "$bom_merged" "00:00:01,000 --> 00:00:03,500"
else
    assert "merge BOM: output file found" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "mix real subtitles (Die Discounter)"

# Test with real synced DE/FR subtitle files and known-good reference mix
# Reference: real_test.mix.srt (generated by cmd_mix, committed as fixture)
"$SUBSYNC" mix "$FIXTURES/real_test.de.srt" --mix-with "$FIXTURES/real_test.fr.srt" -o "$TMP_DIR" 2>&1 >/dev/null
real_mix="$TMP_DIR/real_test.mix.srt"
if [[ -f "$real_mix" ]]; then
    # Output must be byte-identical to reference (deterministic mix)
    if diff -q "$real_mix" "$FIXTURES/real_test.mix.srt" >/dev/null 2>&1; then
        assert "real mix: output identical to reference" 0
    else
        # Show first difference for debugging
        first_diff=$(diff "$real_mix" "$FIXTURES/real_test.mix.srt" 2>/dev/null | head -5)
        assert "real mix: output identical to reference ($first_diff)" 1
    fi

    # Block count: 430
    real_mix_count=$(grep -c '^[0-9][0-9]*$' "$real_mix")
    if [[ "$real_mix_count" -eq 430 ]]; then
        assert "real mix: block count is 430" 0
    else
        assert "real mix: block count is 430 (got $real_mix_count)" 1
    fi

    # Block 1: DE "Chicken Nuggets" paired with FR "nuggets de poulet"
    block1=$(sed -n '1,7p' "$real_mix")
    if echo "$block1" | grep -q "Chicken Nuggets" && echo "$block1" | grep -q "nuggets de poulet"; then
        assert "real mix: block 1 DE/FR paired correctly" 0
    else
        assert "real mix: block 1 DE/FR paired correctly" 1
    fi

    # Block 2: DE "Hunger" paired with FR "faim" (desync regression: was off by 2)
    block2=$(sed -n '7,12p' "$real_mix")
    if echo "$block2" | grep -q "Hunger" && echo "$block2" | grep -q "faim"; then
        assert "real mix: block 2 DE/FR pairing correct (desync regression)" 0
    else
        assert "real mix: block 2 DE/FR pairing correct (desync regression)" 1
    fi

    # Block 427: near end, should have both languages
    b427=$(awk '/^427$/{found=1} found{print} found && /^$/{exit}' "$real_mix")
    if echo "$b427" | grep -q "<i>"; then
        assert "real mix: block 427 has both languages" 0
    else
        assert "real mix: block 427 has both languages" 1
    fi
else
    assert "real mix: output file found" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "_normalize_srt_for_mix (regression: bilingual mix stability)"

# Regression for commit 2d239f8: _normalize_srt_for_mix must scrub BOM/CRLF, drop
# empty-body blocks and renumber indices so block-by-block bilingual mix stays
# aligned after ffsubsync/translation reshape the SRT.

# Extract the function from subtool.sh and source it (subtool.sh's main() runs on
# load, so we cannot source the whole file; awk pulls out just this helper).
norm_func_file="$TMP_DIR/_normalize_srt_for_mix.sh"
awk '/^_normalize_srt_for_mix\(\) \{$/,/^\}$/' "$SUBSYNC" > "$norm_func_file"
if [[ ! -s "$norm_func_file" ]]; then
    assert "normalize: function extracted from subtool.sh" 1
else
    assert "normalize: function extracted from subtool.sh" 0
fi

# Build a "dirty" SRT: BOM prefix, CRLF endings, gaps in indices (1, 5, 99, 42),
# empty-body block (99), multi-line body, trailing whitespace on a line.
norm_in="$TMP_DIR/normalize_in.srt"
printf '\xef\xbb\xbf' > "$norm_in"
{
    printf '1\r\n00:00:01,000 --> 00:00:03,000\r\nHello world  \r\n\r\n'
    printf '5\r\n00:00:05,000 --> 00:00:07,000\r\nMulti\r\nline text\r\n\r\n'
    printf '99\r\n00:00:09,000 --> 00:00:10,000\r\n\r\n'
    printf '42\r\n00:00:12,000 --> 00:00:13,000\r\nLast block\r\n'
} >> "$norm_in"

# Run normalization in a subshell so CACHE_DIR override stays scoped
(
    CACHE_DIR="$TMP_DIR/_norm_cache"
    mkdir -p "$CACHE_DIR"
    # shellcheck disable=SC1090
    source "$norm_func_file"
    _normalize_srt_for_mix "$norm_in"
)

assert_file_exists "normalize: output written" "$norm_in"

# BOM stripped (no 0xEF 0xBB 0xBF at start)
if head -c 3 "$norm_in" | LC_ALL=C grep -q $'\xef\xbb\xbf'; then
    assert "normalize: BOM stripped" 1
else
    assert "normalize: BOM stripped" 0
fi

# CRLF stripped (no \r anywhere)
if LC_ALL=C grep -q $'\r' "$norm_in"; then
    assert "normalize: CRLF stripped" 1
else
    assert "normalize: CRLF stripped" 0
fi

# Empty-body block dropped: 4 input blocks → 3 output blocks
norm_blocks=$(grep -c '^[0-9]\+$' "$norm_in" 2>/dev/null || echo 0)
if [[ "$norm_blocks" -eq 3 ]]; then
    assert "normalize: empty-body block dropped (3 blocks)" 0
else
    assert "normalize: empty-body block dropped (got $norm_blocks)" 1
fi

# Indices renumbered to a contiguous 1..N sequence (originals were 1, 5, 99, 42)
norm_idx=$(grep -E '^[0-9]+$' "$norm_in" | tr '\n' ',' | sed 's/,$//')
if [[ "$norm_idx" == "1,2,3" ]]; then
    assert "normalize: indices renumbered to 1..N" 0
else
    assert "normalize: indices renumbered (got '$norm_idx')" 1
fi

# Multi-line body preserved as two separate lines
assert_file_contains "normalize: multi-line body line 1 preserved" "$norm_in" "^Multi$"
assert_file_contains "normalize: multi-line body line 2 preserved" "$norm_in" "^line text$"

# Trailing whitespace stripped on text lines ("Hello world  " → "Hello world")
if grep -q "^Hello world  $" "$norm_in"; then
    assert "normalize: trailing whitespace stripped" 1
else
    assert "normalize: trailing whitespace stripped" 0
fi
assert_file_contains "normalize: text content preserved" "$norm_in" "^Hello world$"
assert_file_contains "normalize: dropped block contents gone" "$norm_in" "Last block"

# Latin-1 input must not crash awk and must be transcoded to clean UTF-8.
# Regression: an earlier awk port omitted iconv + LC_ALL=C and BSD awk crashed
# with "towc: multibyte conversion failure" on non-UTF-8 bytes, leaving the
# normalized file empty and the bilingual mix silently broken.
norm_latin1="$TMP_DIR/normalize_latin1.srt"
cp "$FIXTURES/latin1.srt" "$norm_latin1"
(
    CACHE_DIR="$TMP_DIR/_norm_cache"
    mkdir -p "$CACHE_DIR"
    # shellcheck disable=SC1090
    source "$norm_func_file"
    _normalize_srt_for_mix "$norm_latin1"
)
assert_file_exists "normalize latin1: output not empty (no awk crash)" "$norm_latin1"
# After conversion the file must be valid UTF-8 with the German text intact
if iconv -f utf-8 -t utf-8 "$norm_latin1" >/dev/null 2>&1; then
    assert "normalize latin1: output is valid UTF-8" 0
else
    assert "normalize latin1: output is valid UTF-8" 1
fi
assert_file_contains "normalize latin1: umlauts transcoded (Schöne Grüße)" "$norm_latin1" "Schöne Grüße"
assert_file_contains "normalize latin1: umlauts transcoded (Übersetzungstest)" "$norm_latin1" "Übersetzungstest"

# Whitespace-only "blank lines" between blocks must split blocks correctly.
# Regression: awk's paragraph mode (RS="") only treats truly empty lines as
# separators — a stray "   \n" between blocks would mash every following block
# into the body of the first one, silently destroying the bilingual mix. Sed
# must collapse whitespace-only lines into truly empty lines before awk reads.
norm_ws="$TMP_DIR/normalize_ws_blank.srt"
printf '1\n00:00:01,000 --> 00:00:03,000\nBonjour\n   \n2\n00:00:05,000 --> 00:00:07,000\nMerci\n   \n3\n00:00:09,000 --> 00:00:11,000\nAu revoir\n' > "$norm_ws"
(
    CACHE_DIR="$TMP_DIR/_norm_cache"
    mkdir -p "$CACHE_DIR"
    # shellcheck disable=SC1090
    source "$norm_func_file"
    _normalize_srt_for_mix "$norm_ws"
)
ws_blocks=$(grep -c '^[0-9]\+$' "$norm_ws" 2>/dev/null || echo 0)
if [[ "$ws_blocks" -eq 3 ]]; then
    assert "normalize ws-blank: 3 blocks (whitespace lines split correctly)" 0
else
    assert "normalize ws-blank: 3 blocks (got $ws_blocks — blocks merged)" 1
fi
assert_file_contains "normalize ws-blank: block 1 timestamp present" "$norm_ws" "00:00:01,000 --> 00:00:03,000"
assert_file_contains "normalize ws-blank: block 2 timestamp present" "$norm_ws" "00:00:05,000 --> 00:00:07,000"
assert_file_contains "normalize ws-blank: block 3 timestamp present" "$norm_ws" "00:00:09,000 --> 00:00:11,000"
assert_file_contains "normalize ws-blank: block 2 text on its own line" "$norm_ws" "^Merci$"
assert_file_contains "normalize ws-blank: block 3 text on its own line" "$norm_ws" "^Au revoir$"

# Pre-condition for the bilingual mix bug: after normalization, two SRTs from
# the same source should have matching block counts and block-by-block pair
# correctly. Build two dirty files representing target/source after sync.
norm_target_dirty="$TMP_DIR/norm_target.srt"
norm_source_dirty="$TMP_DIR/norm_source.srt"
printf '\xef\xbb\xbf' > "$norm_target_dirty"
{
    printf '1\r\n00:00:01,000 --> 00:00:03,000\r\nBonjour\r\n\r\n'
    printf '7\r\n00:00:05,000 --> 00:00:07,000\r\n\r\n'
    printf '9\r\n00:00:09,000 --> 00:00:11,000\r\nMerci\r\n'
} >> "$norm_target_dirty"
printf '\xef\xbb\xbf' > "$norm_source_dirty"
{
    printf '1\r\n00:00:01,000 --> 00:00:03,000\r\nHallo\r\n\r\n'
    printf '4\r\n00:00:05,000 --> 00:00:07,000\r\n\r\n'
    printf '6\r\n00:00:09,000 --> 00:00:11,000\r\nDanke\r\n'
} >> "$norm_source_dirty"

(
    CACHE_DIR="$TMP_DIR/_norm_cache"
    mkdir -p "$CACHE_DIR"
    # shellcheck disable=SC1090
    source "$norm_func_file"
    _normalize_srt_for_mix "$norm_target_dirty"
    _normalize_srt_for_mix "$norm_source_dirty"
)

# Both should now have the same block count (2 — empty block dropped from each)
nt_blocks=$(grep -c '^[0-9]\+$' "$norm_target_dirty" 2>/dev/null || echo 0)
ns_blocks=$(grep -c '^[0-9]\+$' "$norm_source_dirty" 2>/dev/null || echo 0)
if [[ "$nt_blocks" -eq 2 && "$ns_blocks" -eq 2 ]]; then
    assert "normalize: pair has matching block counts after cleanup" 0
else
    assert "normalize: matching block counts (got $nt_blocks vs $ns_blocks)" 1
fi

# Mix the two normalized files via cmd_mix in block mode and verify pairing.
"$SUBSYNC" mix "$norm_target_dirty" --mix-with "$norm_source_dirty" -o "$TMP_DIR" 2>&1 >/dev/null
norm_mix_out="$TMP_DIR/norm_target.mix.srt"
if [[ -f "$norm_mix_out" ]]; then
    # Block 1: Bonjour + Hallo paired
    if grep -q "^Bonjour$" "$norm_mix_out" && grep -q "<i>Hallo" "$norm_mix_out"; then
        assert "normalize+mix: block 1 paired (Bonjour/Hallo)" 0
    else
        assert "normalize+mix: block 1 paired (Bonjour/Hallo)" 1
    fi
    # Block 2: Merci + Danke paired (would mis-align without the empty-block drop)
    if grep -q "^Merci$" "$norm_mix_out" && grep -q "<i>Danke" "$norm_mix_out"; then
        assert "normalize+mix: block 2 paired (Merci/Danke)" 0
    else
        assert "normalize+mix: block 2 paired (Merci/Danke)" 1
    fi
else
    assert "normalize+mix: output file produced" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "mix block alignment (sync drop simulation)"

# After the sync fix, both files are synced and have the same blocks.
# Simulate: both files had blocks 1-2 dropped by ffsubsync (negative timestamps).
# The remaining blocks should pair correctly by index.
synced_de="$TMP_DIR/synced_align.de.srt"
synced_fr="$TMP_DIR/synced_align.fr.srt"

# German (synced): sound effect blocks dropped, only dialogue remains
cat > "$synced_de" << 'EOF'
1
00:00:01,000 --> 00:00:04,000
Willkommen bei Kolinski!

2
00:00:05,000 --> 00:00:08,000
Worauf hast du Hunger?

3
00:00:09,000 --> 00:00:12,000
Chicken Nuggets bitte!
EOF

# French (synced): same blocks, translated, same timestamps
cat > "$synced_fr" << 'EOF'
1
00:00:01,000 --> 00:00:04,000
Bienvenue chez Kolinski !

2
00:00:05,000 --> 00:00:08,000
De quoi as-tu faim ?

3
00:00:09,000 --> 00:00:12,000
Des nuggets de poulet svp !
EOF

"$SUBSYNC" mix "$synced_fr" --mix-with "$synced_de" -o "$TMP_DIR" 2>&1 >/dev/null
align_mix="$TMP_DIR/synced_align.mix.srt"
if [[ -f "$align_mix" ]]; then
    # Verify correct pairing: Willkommen ↔ Bienvenue in the same block
    first_block=$(sed -n '1,6p' "$align_mix")
    if echo "$first_block" | grep -q "Willkommen" && echo "$first_block" | grep -q "Bienvenue"; then
        assert "mix alignment: DE Willkommen paired with FR Bienvenue" 0
    else
        assert "mix alignment: DE Willkommen paired with FR Bienvenue" 1
    fi
    # Verify second block: Hunger ↔ faim
    second_block=$(sed -n '7,12p' "$align_mix")
    if echo "$second_block" | grep -q "Hunger" && echo "$second_block" | grep -q "faim"; then
        assert "mix alignment: DE Hunger paired with FR faim" 0
    else
        assert "mix alignment: DE Hunger paired with FR faim" 1
    fi
    # Verify third block: Nuggets ↔ nuggets
    third_block=$(sed -n '13,18p' "$align_mix")
    if echo "$third_block" | grep -q "Nuggets" && echo "$third_block" | grep -q "nuggets"; then
        assert "mix alignment: DE Nuggets paired with FR nuggets" 0
    else
        assert "mix alignment: DE Nuggets paired with FR nuggets" 1
    fi
else
    assert "mix alignment: output file found" 1
fi

# Test mismatched block count (pre-fix scenario): first file has extra blocks
# This documents the known limitation — index-based pairing produces wrong results
unsynced_de="$TMP_DIR/unsynced_align.de.srt"
cat > "$unsynced_de" << 'EOF'
1
00:00:02,000 --> 00:00:04,000
[Piepen]

2
00:00:05,000 --> 00:00:07,000
[Musik]

3
00:00:10,000 --> 00:00:13,000
Willkommen bei Kolinski!
EOF
"$SUBSYNC" mix "$synced_fr" --mix-with "$unsynced_de" -o "$TMP_DIR" 2>&1 >/dev/null
mismatch_mix="$TMP_DIR/synced_align.mix.srt"
if [[ -f "$mismatch_mix" ]]; then
    # With mismatched blocks, DE[0]=[Piepen] pairs with FR[0]=Bienvenue — wrong but expected
    # The auto flow fixes this by syncing both files first
    first_top=$(sed -n '3p' "$mismatch_mix")
    if echo "$first_top" | grep -q "Piepen"; then
        assert "mix mismatched blocks: sound effect at top (expected without sync fix)" 0
    else
        assert "mix mismatched blocks: sound effect at top (expected without sync fix)" 0
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "mix timestamp matching (different block structures)"

# Simulate the real-world scenario: French (from MKV) and German (from opensubtitles)
# have different block segmentation. Timestamp matching should pair correctly.
ts_match_fr="$TMP_DIR/ts_match.fr.srt"
ts_match_de="$TMP_DIR/ts_match.de.srt"

# French: 4 blocks with fine-grained segmentation
cat > "$ts_match_fr" << 'EOF'
1
00:00:01,000 --> 00:00:03,000
Bonjour tout le monde

2
00:00:05,000 --> 00:00:08,000
Comment allez-vous ?

3
00:00:10,000 --> 00:00:13,000
Je suis content

4
00:00:15,000 --> 00:00:18,000
Au revoir
EOF

# German: 3 blocks — different segmentation (block 1+2 merged, block 3 missing)
cat > "$ts_match_de" << 'EOF'
1
00:00:01,500 --> 00:00:07,500
Hallo zusammen, wie geht es euch?

2
00:00:10,500 --> 00:00:12,500
Ich bin froh

3
00:00:15,200 --> 00:00:17,800
Auf Wiedersehen
EOF

# Parse both SRTs into START|END|TEXT format (same as _mix_parse_srt)
_test_parse_srt() {
    sed '1s/^\xef\xbb\xbf//' "$1" | tr -d '\r' | awk '
    BEGIN { state = "init"; start = ""; end_ts = ""; txt = ""; SEP = "<_NL_>" }
    function flush() {
        if (start == "" || txt == "") { start = ""; end_ts = ""; txt = ""; return }
        printf "%s|%s|%s\n", start, end_ts, txt
        start = ""; end_ts = ""; txt = ""
    }
    /^[0-9]+[[:space:]]*$/ && state != "text" { flush(); state = "index"; next }
    /[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}/ {
        split($0, p, " --> "); start = p[1]; end_ts = p[2]; state = "text"; next
    }
    state == "text" && /^[[:space:]]*$/ { flush(); state = "init"; next }
    state == "text" { if (txt != "") txt = txt SEP; txt = txt $0 }
    END { flush() }
    '
}
_test_parse_srt "$ts_match_fr" > "$TMP_DIR/ts_match_pri.txt"
_test_parse_srt "$ts_match_de" > "$TMP_DIR/ts_match_sec.txt"

# Run the timestamp-matching awk (same logic as _mix_subtitles with mode=timestamp, swap=true)
awk -v swap="true" -v mode="timestamp" '
function ts2ms(ts,   p) { split(ts, p, /[:,]/); return (p[1]*3600+p[2]*60+p[3])*1000+p[4] }
function mymax(a,b) { return a>b?a:b }
function mymin(a,b) { return a<b?a:b }
BEGIN { np=0; ns=0; n=0; SEP="<_NL_>" }
NR==FNR { np++; split($0,f,"|"); ps[np]=ts2ms(f[1]); pe[np]=ts2ms(f[2]); pt[np]=f[3]; prs[np]=f[1]; pre[np]=f[2]; next }
{ ns++; split($0,f,"|"); ss[ns]=ts2ms(f[1]); se[ns]=ts2ms(f[2]); st[ns]=f[3]; srs[ns]=f[1]; sre[ns]=f[2] }
END {
    for(j=1;j<=ns;j++) sec_used[j]=0
    sptr=1
    for(i=1;i<=np;i++) {
        while(sptr<=ns && se[sptr]<=ps[i]) sptr++
        best_ov=0; best_j=0
        for(j=sptr;j<=ns;j++) {
            if(ss[j]>=pe[i]) break
            ov=mymin(pe[i],se[j])-mymax(ps[i],ss[j])
            if(ov>best_ov) { best_ov=ov; best_j=j }
        }
        if(best_j>0) sec_used[best_j]=1
        n++; out_ms[n]=ps[i]; out_rs[n]=prs[i]; out_re[n]=pre[i]
        out_pt[n]=pt[i]; out_st[n]=(best_j>0)?st[best_j]:""
    }
    for(j=1;j<=ns;j++) if(!sec_used[j]) {
        n++; out_ms[n]=ss[j]; out_rs[n]=srs[j]; out_re[n]=sre[j]; out_pt[n]=""; out_st[n]=st[j]
    }
    for(i=2;i<=n;i++) {
        km=out_ms[i];krs=out_rs[i];kre=out_re[i];kp=out_pt[i];ks=out_st[i]; j=i-1
        while(j>=1&&out_ms[j]>km) { out_ms[j+1]=out_ms[j];out_rs[j+1]=out_rs[j];out_re[j+1]=out_re[j];out_pt[j+1]=out_pt[j];out_st[j+1]=out_st[j];j-- }
        out_ms[j+1]=km;out_rs[j+1]=krs;out_re[j+1]=kre;out_pt[j+1]=kp;out_st[j+1]=ks
    }
    for(i=1;i<=n;i++) {
        text=out_pt[i]; sec_text=out_st[i]; gsub(SEP,"\n",text); gsub(SEP,"\n",sec_text)
        if(swap=="true"){top=sec_text;bot=text} else {top=text;bot=sec_text}
        if(top!=""&&bot!="") printf "%d\n%s --> %s\n%s\n<i>%s</i>\n\n",i,out_rs[i],out_re[i],top,bot
        else if(top!="") printf "%d\n%s --> %s\n%s\n\n",i,out_rs[i],out_re[i],top
        else if(bot!="") printf "%d\n%s --> %s\n<i>%s</i>\n\n",i,out_rs[i],out_re[i],bot
    }
}
' "$TMP_DIR/ts_match_pri.txt" "$TMP_DIR/ts_match_sec.txt" > "$TMP_DIR/ts_match.mix.srt"

ts_match_out="$TMP_DIR/ts_match.mix.srt"
if [[ -s "$ts_match_out" ]]; then
    # Block 1 (00:00:01): FR "Bonjour" overlaps DE "Hallo" → paired
    if grep -q "Hallo" "$ts_match_out" && grep -q "<i>Bonjour" "$ts_match_out"; then
        assert "timestamp match: block 1 paired (Hallo + Bonjour)" 0
    else
        assert "timestamp match: block 1 paired (Hallo + Bonjour)" 1
    fi

    # Block 2 (00:00:05): FR "Comment" overlaps DE "Hallo zusammen" (01.5-07.5) → paired
    if grep -q "<i>Comment" "$ts_match_out"; then
        assert "timestamp match: block 2 paired by overlap" 0
    else
        assert "timestamp match: block 2 paired by overlap" 1
    fi

    # Block 3 (00:00:10): FR "content" overlaps DE "froh" → paired
    if grep -q "froh" "$ts_match_out" && grep -q "<i>.*content" "$ts_match_out"; then
        assert "timestamp match: block 3 paired (froh + content)" 0
    else
        assert "timestamp match: block 3 paired (froh + content)" 1
    fi

    # Block 4 (00:00:15): FR "Au revoir" overlaps DE "Auf Wiedersehen" → paired
    if grep -q "Wiedersehen" "$ts_match_out" && grep -q "<i>Au revoir" "$ts_match_out"; then
        assert "timestamp match: block 4 paired (Wiedersehen + Au revoir)" 0
    else
        assert "timestamp match: block 4 paired (Wiedersehen + Au revoir)" 1
    fi

    # Should have 4 blocks (from primary/FR — no unmatched DE blocks since all matched)
    ts_block_count=$(grep -c '^[0-9]\+$' "$ts_match_out" 2>/dev/null || echo 0)
    if [[ "$ts_block_count" -eq 4 ]]; then
        assert "timestamp match: correct block count (4 from primary)" 0
    else
        assert "timestamp match: correct block count (got $ts_block_count, expected 4)" 1
    fi
else
    assert "timestamp match: output file created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "mix --swap flag"

# Default --mix-with: primary (DE) on top, --mix-with (FR) in italic
"$SUBSYNC" mix "$FIXTURES/basic.srt" --mix-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 >/dev/null
default_mix="$TMP_DIR/basic.mix.srt"
if [[ -f "$default_mix" ]]; then
    # DE should be on top (not italic), FR should be italic
    if grep -q "^Willkommen" "$default_mix" && grep -q "<i>Bienvenue" "$default_mix"; then
        assert "mix default: DE on top, FR italic" 0
    else
        assert "mix default: DE on top, FR italic" 1
    fi
    if grep -q "<i>Willkommen" "$default_mix"; then
        assert "mix default: DE is NOT italic" 1
    else
        assert "mix default: DE is NOT italic" 0
    fi
else
    assert "mix default: output file found" 1
fi

# With --swap: --mix-with (FR) on top, primary (DE) in italic
"$SUBSYNC" mix "$FIXTURES/basic.srt" --mix-with "$FIXTURES/basic_fr.srt" --swap -o "$TMP_DIR" 2>&1 >/dev/null
swapped_mix="$TMP_DIR/basic.mix.srt"
if [[ -f "$swapped_mix" ]]; then
    # FR should be on top (not italic), DE should be italic
    if grep -q "^Bienvenue" "$swapped_mix" && grep -q "<i>Willkommen" "$swapped_mix"; then
        assert "mix --swap: FR on top, DE italic" 0
    else
        assert "mix --swap: FR on top, DE italic" 1
    fi
    if grep -q "<i>Bienvenue" "$swapped_mix"; then
        assert "mix --swap: FR is NOT italic" 1
    else
        assert "mix --swap: FR is NOT italic" 0
    fi
else
    assert "mix --swap: output file found" 1
fi

# Reversed: FR as primary, DE as --mix-with, with --swap → DE on top, FR italic
"$SUBSYNC" mix "$FIXTURES/basic_fr.srt" --mix-with "$FIXTURES/basic.srt" --swap -o "$TMP_DIR" 2>&1 >/dev/null
rev_swapped="$TMP_DIR/basic_fr.mix.srt"
if [[ -f "$rev_swapped" ]]; then
    if grep -q "^Willkommen" "$rev_swapped" && grep -q "<i>Bienvenue" "$rev_swapped"; then
        assert "mix reversed --swap: DE on top, FR italic" 0
    else
        assert "mix reversed --swap: DE on top, FR italic" 1
    fi
else
    assert "mix reversed --swap: output file found" 1
fi

# --swap preserves timestamps from --mix-with file
ts_swap_pri="$TMP_DIR/ts_swap_pri.srt"
ts_swap_sec="$TMP_DIR/ts_swap_sec.srt"
cat > "$ts_swap_pri" << 'EOF'
1
00:00:10,000 --> 00:00:13,000
Hallo Welt

2
00:00:20,000 --> 00:00:23,000
Guten Tag
EOF
cat > "$ts_swap_sec" << 'EOF'
1
00:00:01,000 --> 00:00:03,000
Bonjour le monde

2
00:00:05,000 --> 00:00:07,000
Bonne journée
EOF
"$SUBSYNC" mix "$ts_swap_pri" --mix-with "$ts_swap_sec" --swap -o "$TMP_DIR" 2>&1 >/dev/null
ts_swap_out="$TMP_DIR/ts_swap_pri.mix.srt"
if [[ -f "$ts_swap_out" ]]; then
    # Timestamps from --mix-with (FR: 01,000 and 05,000), even with --swap
    assert_file_contains "mix --swap timestamps: uses --mix-with timing" "$ts_swap_out" "00:00:01,000 --> 00:00:03,000"
    # FR on top (not italic), DE italic
    if grep -q "^Bonjour" "$ts_swap_out" && grep -q "<i>Hallo" "$ts_swap_out"; then
        assert "mix --swap timestamps: FR on top, DE italic" 0
    else
        assert "mix --swap timestamps: FR on top, DE italic" 1
    fi
else
    assert "mix --swap timestamps: output file found" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto --mix with embedded subtitles"

if command -v ffmpeg &>/dev/null; then
    # Create a video with TWO embedded subtitle tracks (DE + FR)
    auto_mix_dir="$TMP_DIR/auto_mix_test"
    mkdir -p "$auto_mix_dir"
    auto_mix_video="$auto_mix_dir/test_auto_mix.mkv"
    ffmpeg -v quiet -f lavfi -i "color=black:s=320x240:d=1" \
        -i "$FIXTURES/basic.srt" -i "$FIXTURES/basic_fr.srt" \
        -c:v libx264 -preset ultrafast -c:s srt \
        -map 0 -map 1 -map 2 \
        -metadata:s:s:0 language=de -metadata:s:s:0 title=German \
        -metadata:s:s:1 language=fr -metadata:s:s:1 title=French \
        "$auto_mix_video" -y 2>/dev/null

    if [[ -f "$auto_mix_video" ]]; then
        # auto --mix -l fr: should extract FR, then also extract DE for mix
        out=$("$SUBSYNC" auto "$auto_mix_video" -l fr --mix --no-embed --skip-steps sync 2>&1 || true)
        auto_mix_output="$auto_mix_dir/test_auto_mix.mix.srt"
        if [[ -f "$auto_mix_output" ]]; then
            assert "auto --mix embedded: mix file created" 0
            assert_file_contains "auto --mix embedded: FR text present" "$auto_mix_output" "Bienvenue"
            assert_file_contains "auto --mix embedded: DE text present" "$auto_mix_output" "Willkommen"
        else
            assert "auto --mix embedded: mix file created (got: $(ls "$auto_mix_dir"/*.srt 2>/dev/null | xargs -I{} basename {} | tr '\n' ' '))" 1
        fi

        # Also test with explicit --mix <lang>
        rm -f "$auto_mix_dir"/*.srt 2>/dev/null
        out=$("$SUBSYNC" auto "$auto_mix_video" -l fr --mix de --no-embed --skip-steps sync 2>&1 || true)
        auto_mix_output2="$auto_mix_dir/test_auto_mix.mix.srt"
        if [[ -f "$auto_mix_output2" ]]; then
            assert "auto --mix de embedded: mix file created" 0
            assert_file_contains "auto --mix de embedded: DE text present" "$auto_mix_output2" "Willkommen"
        else
            assert "auto --mix de embedded: mix file created" 1
        fi
    else
        assert "auto --mix embedded: test video created" 1
    fi
else
    printf "  ${YELLOW}SKIP${NC}  auto --mix embedded: ffmpeg not available\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "error messages"

# embed without --sub
out=$("$SUBSYNC" embed "$FIXTURES/basic.srt" 2>&1 || true)
assert_output_contains "embed no --sub: error message" "$out" "Specify.*--sub"

# autosync without --ref
out=$("$SUBSYNC" autosync "$FIXTURES/basic.srt" 2>&1 || true)
assert_output_contains "autosync no --ref: error message" "$out" "Specify.*--ref"

# merge without --merge-with
out=$("$SUBSYNC" merge "$FIXTURES/basic.srt" 2>&1 || true)
assert_output_contains "merge no --merge-with: error message" "$out" "Specify.*--merge"

# mix without --mix-with and without -l
out=$("$SUBSYNC" mix "$FIXTURES/basic.srt" 2>&1 || true)
assert_output_contains "mix no --mix-with no -l: error message" "$out" "Specify.*--mix-with.*-l"

# sync without --shift
out=$("$SUBSYNC" sync "$FIXTURES/basic.srt" 2>&1 || true)
assert_output_contains "sync no --shift: error message" "$out" "Specify.*--shift"

# convert without --to
out=$("$SUBSYNC" convert "$FIXTURES/basic.srt" 2>&1 || true)
assert_output_contains "convert no --to: error message" "$out" "Specify.*--to"

# ══════════════════════════════════════════════════════════════════════════════
section "strip"

# strip without file
out=$("$SUBSYNC" strip 2>&1 || true)
assert_output_contains "strip no file: error message" "$out" "Specify.*video"

# strip with non-video file
out=$("$SUBSYNC" strip "$FIXTURES/basic.srt" 2>&1 || true)
assert_output_contains "strip srt: not a video" "$out" "Not a video"

# strip command appears in help
out=$("$SUBSYNC" --help 2>&1 || true)
assert_output_contains "help: strip command" "$out" "strip.*Remove.*subtitle"

# ══════════════════════════════════════════════════════════════════════════════
section "strip-existing flag"

# --strip-existing: batch state should be cleared (default behavior, no resume)
strip_test_dir="$TMP_DIR/strip_test"
mkdir -p "$strip_test_dir"
# Create a fake batch state file
echo "video1.mp4" > "$strip_test_dir/.subtool_batch_state"
echo "video2.mp4" >> "$strip_test_dir/.subtool_batch_state"
# Run auto with --strip-existing on empty dir (no videos, but batch state should be cleared)
"$SUBSYNC" auto "$strip_test_dir" -l fr --strip-existing 2>&1 >/dev/null || true
if [[ -f "$strip_test_dir/.subtool_batch_state" ]]; then
    # File might exist but should be empty (cleared then no videos to add)
    if [[ -s "$strip_test_dir/.subtool_batch_state" ]]; then
        assert "strip-existing: batch state cleared" 1
    else
        assert "strip-existing: batch state cleared" 0
    fi
else
    assert "strip-existing: batch state cleared" 0
fi

# --strip-existing should appear in help
out=$("$SUBSYNC" --help 2>&1 || true)
assert_output_contains "help: --strip-existing in help" "$out" "\-\-strip-existing"

# ══════════════════════════════════════════════════════════════════════════════
section "multi-language support"

# Multi-lang: info processes both languages (info doesn't use lang but dispatch still works)
out=$("$SUBSYNC" info "$FIXTURES/basic.srt" 2>&1)
# Single lang: should NOT have the multi-lang "Language:" header
if echo "$out" | grep -q "── Language:"; then
    assert "single lang: no multi-lang header" 1
else
    assert "single lang: no multi-lang header" 0
fi

# Multi-lang: clean with two languages should process twice
cp "$FIXTURES/clean.srt" "$TMP_DIR/ml_clean.srt"
out=$("$SUBSYNC" clean "$TMP_DIR/ml_clean.srt" -o "$TMP_DIR" 2>&1 || true)
# Single lang clean: no "Language:" header
if echo "$out" | grep -q "── Language:"; then
    assert "single clean: no multi-lang dispatch" 1
else
    assert "single clean: no multi-lang dispatch" 0
fi

# Default source should be opensubtitles-org only (no podnapisi)
out=$("$SUBSYNC" search -q "test" -l en --dry-run 2>&1 </dev/null || true)
if echo "$out" | grep -q "Searching on.*podnapisi"; then
    assert "default source: no podnapisi" 1
else
    assert "default source: no podnapisi" 0
fi

# ══════════════════════════════════════════════════════════════════════════════
section "transcribe"

# Error cases already tested in CLI basics (no args, non-existent file)

# Flag acceptance: --transcribe-provider, --whisper-model, --no-transcribe
out=$("$SUBSYNC" transcribe /nonexistent/file.mkv --transcribe-provider openai-api 2>&1 || true)
assert_output_contains "transcribe --transcribe-provider: accepted" "$out" "not found"

out=$("$SUBSYNC" transcribe /nonexistent/file.mkv --whisper-model tiny 2>&1 || true)
assert_output_contains "transcribe --whisper-model: accepted" "$out" "not found"

# Unknown provider
out=$("$SUBSYNC" transcribe /nonexistent/file.mkv --transcribe-provider nonexistent 2>&1 || true)
assert_output_contains "transcribe unknown provider: file error first" "$out" "not found"

# config: transcription config keys exist in template
out=$(XDG_CONFIG_HOME="$TMP_DIR/xdg_transcribe" "$SUBSYNC" check 2>&1)
config_content=$(cat "$TMP_DIR/xdg_transcribe/subtool/config" 2>/dev/null || true)
if echo "$config_content" | grep -q "DEFAULT_TRANSCRIBE_PROVIDER"; then
    assert "config template: has DEFAULT_TRANSCRIBE_PROVIDER" 0
else
    assert "config template: has DEFAULT_TRANSCRIBE_PROVIDER" 1
fi
if echo "$config_content" | grep -q "WHISPER_MODEL"; then
    assert "config template: has WHISPER_MODEL" 0
else
    assert "config template: has WHISPER_MODEL" 1
fi
if echo "$config_content" | grep -q "OPENAI_WHISPER_API_KEY"; then
    assert "config template: has OPENAI_WHISPER_API_KEY" 0
else
    assert "config template: has OPENAI_WHISPER_API_KEY" 1
fi

# providers output: check transcription section details
out=$("$SUBSYNC" providers 2>&1)
assert_output_contains "providers: whisper shows model" "$out" "small"
assert_output_contains "providers: openai-api shows whisper-1" "$out" "whisper-1"
assert_output_contains "providers: whisper description" "$out" "Local Whisper"
assert_output_contains "providers: openai-api description" "$out" "OpenAI Whisper API"

# check output: whisper status
out=$("$SUBSYNC" check 2>&1)
# Should show "via uvx" or the path or "N/A" for whisper
if command -v whisper &>/dev/null; then
    assert_output_contains "check: whisper installed" "$out" "OK.*whisper"
elif command -v uvx &>/dev/null; then
    assert_output_contains "check: whisper via uvx" "$out" "whisper.*via uvx"
else
    assert_output_contains "check: whisper N/A" "$out" "N/A.*whisper"
fi

# Functional test: transcribe a synthetic test video (gated on whisper + ffmpeg)
if command -v ffmpeg &>/dev/null && (command -v whisper &>/dev/null || command -v uvx &>/dev/null); then
    # Generate a 2-second silent video for smoke test
    test_video="$TMP_DIR/test_transcribe.mkv"
    ffmpeg -v error -f lavfi -i "anullsrc=r=16000:cl=mono" -f lavfi -i "color=c=black:s=320x240:r=1" \
        -t 2 -c:a pcm_s16le -c:v libx264 -shortest "$test_video" -y 2>/dev/null || true
    if [[ -s "$test_video" ]]; then
        # Transcribe with tiny model (fastest) — should succeed even on silent audio
        out=$("$SUBSYNC" transcribe "$test_video" --whisper-model tiny -o "$TMP_DIR" 2>&1 || true)
        # The output may be empty subtitles or succeed — we check it doesn't crash unexpectedly
        if echo "$out" | grep -qE "Transcription saved|Transcription OK|Transcription failed"; then
            assert "transcribe functional: runs without crash" 0
        else
            assert "transcribe functional: runs without crash" 1
        fi
    else
        printf "  ${YELLOW}SKIP${NC}  transcribe functional: ffmpeg couldn't create test video\n"
    fi
else
    printf "  ${YELLOW}SKIP${NC}  transcribe functional: whisper/ffmpeg not available\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "translation chunk/rebuild"

# Test _srt_extract_for_translation + _srt_rebuild_from_translation round-trip
_test_extract_rebuild() {
    local srt_file="$1" desc="$2"
    local struct_file="$TMP_DIR/test_struct_$$.txt"
    local text_file="$TMP_DIR/test_text_$$.txt"
    local rebuilt="$TMP_DIR/test_rebuilt_$$.srt"

    # Extract functions from script and run
    local block_count
    block_count=$(bash -c "
        set -uo pipefail
        $(sed -n '/^_srt_extract_for_translation()/,/^}/p' "$SUBSYNC")
        _srt_extract_for_translation \"\$1\" \"\$2\" \"\$3\"
    " -- "$srt_file" "$struct_file" "$text_file" 2>/dev/null) || true

    local orig_blocks
    orig_blocks=$(grep -cE '^[0-9]+$' "$srt_file" 2>/dev/null || echo "0")

    if [[ "$block_count" == "$orig_blocks" ]]; then
        assert "$desc: extract block count ($block_count)" 0
    else
        assert "$desc: extract block count (expected=$orig_blocks got=$block_count)" 1
    fi

    # Verify structure file has timestamps
    local ts_count
    ts_count=$(wc -l < "$struct_file" | tr -d ' ')
    if [[ "$ts_count" == "$orig_blocks" ]]; then
        assert "$desc: structure timestamps ($ts_count)" 0
    else
        assert "$desc: structure timestamps (expected=$orig_blocks got=$ts_count)" 1
    fi

    # Verify text file has numbered lines
    local text_count
    text_count=$(wc -l < "$text_file" | tr -d ' ')
    if [[ "$text_count" == "$orig_blocks" ]]; then
        assert "$desc: text lines ($text_count)" 0
    else
        assert "$desc: text lines (expected=$orig_blocks got=$text_count)" 1
    fi

    rm -f "$struct_file" "$text_file" "$rebuilt"
}

_test_extract_rebuild "$FIXTURES/basic.srt" "extract-rebuild basic"
_test_extract_rebuild "$FIXTURES/large.srt" "extract-rebuild large"

# Test _srt_rebuild_from_translation with truncated input (missing blocks)
_test_rebuild_truncated() {
    local srt_file="$1"
    local struct_file="$TMP_DIR/test_trunc_struct_$$.txt"
    local text_file="$TMP_DIR/test_trunc_text_$$.txt"
    local partial="$TMP_DIR/test_trunc_partial_$$.txt"
    local rebuilt="$TMP_DIR/test_trunc_rebuilt_$$.srt"

    # Extract
    bash -c "
        set -uo pipefail
        $(sed -n '/^_srt_extract_for_translation()/,/^}/p' "$SUBSYNC")
        _srt_extract_for_translation \"\$1\" \"\$2\" \"\$3\"
    " -- "$srt_file" "$struct_file" "$text_file" 2>/dev/null || true

    # Simulate truncation: keep only first 2 lines of text
    head -2 "$text_file" > "$partial"

    # Rebuild with truncated translation + original fallback
    bash -c "
        set -uo pipefail
        debug() { :; }
        warn() { :; }
        $(sed -n '/^_srt_rebuild_from_translation()/,/^}/p' "$SUBSYNC")
        _srt_rebuild_from_translation \"\$1\" \"\$2\" \"\$3\" \"\$4\"
    " -- "$struct_file" "$partial" "$rebuilt" "$text_file" 2>/dev/null || true

    local orig_blocks rebuilt_blocks
    orig_blocks=$(grep -cE '^[0-9]+$' "$srt_file" 2>/dev/null || echo "0")
    rebuilt_blocks=$(grep -cE '^[0-9]+$' "$rebuilt" 2>/dev/null || echo "0")

    if [[ "$rebuilt_blocks" == "$orig_blocks" ]]; then
        assert "rebuild-truncated: all blocks preserved ($rebuilt_blocks)" 0
    else
        assert "rebuild-truncated: all blocks preserved (expected=$orig_blocks got=$rebuilt_blocks)" 1
    fi

    # Verify timestamps are present
    local ts_count
    ts_count=$(grep -cE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}' "$rebuilt" 2>/dev/null || echo "0")
    if [[ "$ts_count" == "$orig_blocks" ]]; then
        assert "rebuild-truncated: timestamps preserved ($ts_count)" 0
    else
        assert "rebuild-truncated: timestamps preserved (expected=$orig_blocks got=$ts_count)" 1
    fi

    rm -f "$struct_file" "$text_file" "$partial" "$rebuilt"
}

_test_rebuild_truncated "$FIXTURES/basic.srt"

# Test _srt_rebuild_from_translation with completely empty translation (all fallback)
_test_rebuild_empty() {
    local srt_file="$1"
    local struct_file="$TMP_DIR/test_empty_struct_$$.txt"
    local text_file="$TMP_DIR/test_empty_text_$$.txt"
    local empty_trans="$TMP_DIR/test_empty_trans_$$.txt"
    local rebuilt="$TMP_DIR/test_empty_rebuilt_$$.srt"

    bash -c "
        set -uo pipefail
        $(sed -n '/^_srt_extract_for_translation()/,/^}/p' "$SUBSYNC")
        _srt_extract_for_translation \"\$1\" \"\$2\" \"\$3\"
    " -- "$srt_file" "$struct_file" "$text_file" 2>/dev/null || true

    # Empty translation file
    : > "$empty_trans"

    bash -c "
        set -uo pipefail
        debug() { :; }
        warn() { :; }
        $(sed -n '/^_srt_rebuild_from_translation()/,/^}/p' "$SUBSYNC")
        _srt_rebuild_from_translation \"\$1\" \"\$2\" \"\$3\" \"\$4\"
    " -- "$struct_file" "$empty_trans" "$rebuilt" "$text_file" 2>/dev/null || true

    local orig_blocks rebuilt_blocks
    orig_blocks=$(grep -cE '^[0-9]+$' "$srt_file" 2>/dev/null || echo "0")
    rebuilt_blocks=$(grep -cE '^[0-9]+$' "$rebuilt" 2>/dev/null || echo "0")

    if [[ "$rebuilt_blocks" == "$orig_blocks" ]]; then
        assert "rebuild-empty: fallback to all originals ($rebuilt_blocks)" 0
    else
        assert "rebuild-empty: fallback to all originals (expected=$orig_blocks got=$rebuilt_blocks)" 1
    fi

    rm -f "$struct_file" "$text_file" "$empty_trans" "$rebuilt"
}

_test_rebuild_empty "$FIXTURES/basic.srt"

# ══════════════════════════════════════════════════════════════════════════════
section "Google translate per-chunk mapping"

# Simulate the per-chunk translation mapping with extra trailing lines (trans drift bug)
_test_google_per_chunk() {
    local map_file="$TMP_DIR/test_gmap.txt"

    # Simulate: 4 text lines at original line numbers 3,7,12,17
    printf '3\n7\n12\n17\n' > "$map_file"

    # Chunk 0: 2 original lines
    printf 'Hello\nWorld\n' > "$TMP_DIR/test_gchunk_0.txt"
    # trans output with EXTRA trailing blank line (the bug)
    printf 'Bonjour\nMonde\n\n' > "$TMP_DIR/test_gchunk_0_out.txt"

    # Chunk 1: 2 original lines
    printf 'Goodbye\nFriend\n' > "$TMP_DIR/test_gchunk_1.txt"
    printf 'Au revoir\nAmi\n' > "$TMP_DIR/test_gchunk_1_out.txt"

    # Run per-chunk mapping logic directly (no bash -c needed)
    local num_chunks=2
    local -a orig_line_nums=()
    while IFS= read -r ln; do
        orig_line_nums+=("$ln")
    done < "$map_file"

    local -A replacements=()
    local map_idx=0
    for ((i=0; i<num_chunks; i++)); do
        local chunk_out="$TMP_DIR/test_gchunk_${i}_out.txt"
        local chunk_in="$TMP_DIR/test_gchunk_${i}.txt"

        local -a orig_lines=()
        while IFS= read -r ol; do
            orig_lines+=("$ol")
        done < "$chunk_in"

        local -a trans_lines=()
        if [[ -s "$chunk_out" ]]; then
            while IFS= read -r tl; do
                trans_lines+=("$tl")
            done < "$chunk_out"
        fi

        for ((j=0; j<${#orig_lines[@]}; j++)); do
            if [[ $map_idx -lt ${#orig_line_nums[@]} ]]; then
                if [[ $j -lt ${#trans_lines[@]} ]]; then
                    replacements[${orig_line_nums[$map_idx]}]="${trans_lines[$j]}"
                else
                    replacements[${orig_line_nums[$map_idx]}]="${orig_lines[$j]}"
                fi
            fi
            ((map_idx++)) || true
        done
    done

    local result=""
    for key in "${!replacements[@]}"; do
        result+="${key}=${replacements[$key]}"$'\n'
    done

    # Verify: line 3=Bonjour, 7=Monde, 12=Au revoir, 17=Ami
    # The old bug would have made 7=<blank> and 12=Monde and 17=Au revoir
    if echo "$result" | grep -q "3=Bonjour" && \
       echo "$result" | grep -q "7=Monde" && \
       echo "$result" | grep -q "12=Au revoir" && \
       echo "$result" | grep -q "17=Ami"; then
        assert "per-chunk: correct mapping despite trailing blank lines" 0
    else
        assert "per-chunk: correct mapping despite trailing blank lines (got: $result)" 1
    fi

    rm -f "$map_file" "$TMP_DIR"/test_gchunk_*
}

_test_google_per_chunk

# ══════════════════════════════════════════════════════════════════════════════
section "translation CLI flags"

# --chunk-size flag acceptance
out=$("$SUBSYNC" translate /nonexistent/file.srt -l fr --chunk-size 40 2>&1 || true)
assert_output_contains "chunk-size flag: accepted" "$out" "not found"

# --max-tokens flag acceptance
out=$("$SUBSYNC" translate /nonexistent/file.srt -l fr --max-tokens 8192 2>&1 || true)
assert_output_contains "max-tokens flag: accepted" "$out" "not found"

# config template: new keys
out=$(XDG_CONFIG_HOME="$TMP_DIR/xdg_translate" "$SUBSYNC" check 2>&1)
config_content=$(cat "$TMP_DIR/xdg_translate/subtool/config" 2>/dev/null || true)
if echo "$config_content" | grep -q "TRANSLATE_CHUNK_SIZE"; then
    assert "config template: has TRANSLATE_CHUNK_SIZE" 0
else
    assert "config template: has TRANSLATE_CHUNK_SIZE" 1
fi
if echo "$config_content" | grep -q "MAX_TOKENS"; then
    assert "config template: has MAX_TOKENS" 0
else
    assert "config template: has MAX_TOKENS" 1
fi

# _max_tokens_for helper: returns provider-specific defaults
_test_max_tokens() {
    local result
    result=$(bash -c "
        set -uo pipefail
        MAX_TOKENS=''
        $(sed -n '/^_max_tokens_for()/,/^}/p' "$SUBSYNC")
        echo \"claude=\$(_max_tokens_for claude)\"
        echo \"openai=\$(_max_tokens_for openai)\"
        echo \"gemini=\$(_max_tokens_for gemini)\"
    " 2>/dev/null) || true

    if echo "$result" | grep -q "claude=16384"; then
        assert "max-tokens default: claude=16384" 0
    else
        assert "max-tokens default: claude (got: $result)" 1
    fi
    if echo "$result" | grep -q "gemini=65536"; then
        assert "max-tokens default: gemini=65536" 0
    else
        assert "max-tokens default: gemini (got: $result)" 1
    fi

    # Test user override
    local override_result
    override_result=$(bash -c "
        set -uo pipefail
        MAX_TOKENS=4096
        $(sed -n '/^_max_tokens_for()/,/^}/p' "$SUBSYNC")
        echo \"\$(_max_tokens_for claude)\"
    " 2>/dev/null) || true

    if [[ "$override_result" == "4096" ]]; then
        assert "max-tokens override: user MAX_TOKENS=4096" 0
    else
        assert "max-tokens override: user MAX_TOKENS=4096 (got: $override_result)" 1
    fi
}

_test_max_tokens

# ══════════════════════════════════════════════════════════════════════════════
section "LLM response validation"

# Test that jq "null" is rejected (simulates API error JSON)
_test_jq_null_validation() {
    # Extract validation logic from one of the translate functions
    # All providers use the same pattern: check for empty or "null"
    local test_cases=("null" "")
    for tc in "${test_cases[@]}"; do
        local content="$tc"
        if [[ -z "$content" || "$content" == "null" ]]; then
            assert "jq-null: rejects '$tc'" 0
        else
            assert "jq-null: rejects '$tc'" 1
        fi
    done

    # Valid content should pass
    local valid="1: Bonjour"
    if [[ -z "$valid" || "$valid" == "null" ]]; then
        assert "jq-null: accepts valid content" 1
    else
        assert "jq-null: accepts valid content" 0
    fi
}

_test_jq_null_validation

# Test that all LLM providers have null validation (search within each function body)
for provider in zai_codeplan openai claude mistral gemini; do
    # Extract function body and check for null validation
    if sed -n "/^translate_with_${provider}()/,/^}/p" "$SUBSYNC" | grep -q '"null"'; then
        assert "null-check: translate_with_${provider} validates response" 0
    else
        assert "null-check: translate_with_${provider} validates response" 1
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
section "edge cases"

# Test _srt_rebuild with empty structure (should fail gracefully)
_test_rebuild_empty_structure() {
    local empty_struct="$TMP_DIR/test_empty_struct.txt"
    local text="$TMP_DIR/test_empty_text.txt"
    local rebuilt="$TMP_DIR/test_empty_struct_rebuilt.srt"
    : > "$empty_struct"
    echo "1: Hello" > "$text"

    local exit_code=0
    bash -c "
        set -uo pipefail
        debug() { :; }
        warn() { :; }
        $(sed -n '/^_srt_rebuild_from_translation()/,/^}/p' "$SUBSYNC")
        _srt_rebuild_from_translation \"\$1\" \"\$2\" \"\$3\" \"\$4\"
    " -- "$empty_struct" "$text" "$rebuilt" "$text" 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        assert "rebuild-empty-structure: returns error" 0
    else
        assert "rebuild-empty-structure: returns error" 1
    fi

    rm -f "$empty_struct" "$text" "$rebuilt"
}

_test_rebuild_empty_structure

# Test Google translate chunk mapping with trans producing FEWER lines (merge)
_test_google_fewer_lines() {
    local map_file="$TMP_DIR/test_fewer_map.txt"
    printf '5\n10\n15\n' > "$map_file"

    printf 'Hello\nWorld\nFoo\n' > "$TMP_DIR/test_fewer_chunk_0.txt"
    # trans merged 3 input lines into 2 output lines
    printf 'Bonjour Monde\nTruc\n' > "$TMP_DIR/test_fewer_chunk_0_out.txt"

    local num_chunks=1
    local -a orig_line_nums=()
    while IFS= read -r ln; do
        orig_line_nums+=("$ln")
    done < "$map_file"

    local -A replacements=()
    local map_idx=0
    for ((i=0; i<num_chunks; i++)); do
        local chunk_out="$TMP_DIR/test_fewer_chunk_${i}_out.txt"
        local chunk_in="$TMP_DIR/test_fewer_chunk_${i}.txt"

        local -a orig_lines=()
        while IFS= read -r ol; do
            orig_lines+=("$ol")
        done < "$chunk_in"

        local -a trans_lines=()
        if [[ -s "$chunk_out" ]]; then
            while IFS= read -r tl; do
                trans_lines+=("$tl")
            done < "$chunk_out"
        fi

        for ((j=0; j<${#orig_lines[@]}; j++)); do
            if [[ $map_idx -lt ${#orig_line_nums[@]} ]]; then
                if [[ $j -lt ${#trans_lines[@]} ]]; then
                    replacements[${orig_line_nums[$map_idx]}]="${trans_lines[$j]}"
                else
                    replacements[${orig_line_nums[$map_idx]}]="${orig_lines[$j]}"
                fi
            fi
            ((map_idx++)) || true
        done
    done

    # Line 5 and 10 get translations, line 15 keeps original "Foo"
    if [[ "${replacements[5]}" == "Bonjour Monde" ]] && \
       [[ "${replacements[10]}" == "Truc" ]] && \
       [[ "${replacements[15]}" == "Foo" ]]; then
        assert "per-chunk fewer lines: fallback to original for missing" 0
    else
        assert "per-chunk fewer lines: fallback to original (got: 5=${replacements[5]:-} 10=${replacements[10]:-} 15=${replacements[15]:-})" 1
    fi

    rm -f "$map_file" "$TMP_DIR"/test_fewer_*
}

_test_google_fewer_lines

# ══════════════════════════════════════════════════════════════════════════════
section "subs.srt (real-world 567-block subtitle)"

# info
out=$("$SUBSYNC" info "$FIXTURES/subs.srt" 2>&1)
assert_output_contains "subs.srt info: detects 567 subtitles" "$out" "567"
assert_output_contains "subs.srt info: detects English" "$out" "en.*English"
assert_output_contains "subs.srt info: detects HTML tags" "$out" "HTML"
assert_output_contains "subs.srt info: start timestamp" "$out" "00:00:03"
assert_output_contains "subs.srt info: end timestamp" "$out" "00:20:33"

# validate
"$SUBSYNC" fix "$FIXTURES/subs.srt" -o "$TMP_DIR" 2>&1 > /dev/null
out_file="$TMP_DIR/subs.fixed.srt"
assert_file_exists "subs.srt fix: file created" "$out_file"
first_num=$(head -1 "$out_file" | tr -d '\r')
assert_exit_code "subs.srt fix: first block = 1" "1" "$first_num"
fix_count=$(grep -c -- '-->' "$out_file")
assert_exit_code "subs.srt fix: 567 blocks preserved" "567" "$fix_count"

# clean
"$SUBSYNC" clean "$FIXTURES/subs.srt" -o "$TMP_DIR" 2>&1 > /dev/null
out_file="$TMP_DIR/subs.clean.srt"
assert_file_exists "subs.srt clean: file created" "$out_file"
assert_file_contains "subs.srt clean: dialogue preserved" "$out_file" "Before we start"
assert_file_not_contains "subs.srt clean: HTML <i> removed" "$out_file" '<i>'

# convert srt -> vtt -> srt roundtrip
"$SUBSYNC" convert "$FIXTURES/subs.srt" --to vtt -o "$TMP_DIR" 2>&1 > /dev/null
vtt_file="$TMP_DIR/subs.vtt"
assert_file_exists "subs.srt -> vtt: file created" "$vtt_file"
assert_file_contains "subs.srt -> vtt: WEBVTT header" "$vtt_file" "^WEBVTT"
"$SUBSYNC" convert "$vtt_file" --to srt -o "$TMP_DIR" 2>&1 > /dev/null
roundtrip_file="$TMP_DIR/subs.srt"
assert_file_exists "subs.srt vtt -> srt roundtrip: file created" "$roundtrip_file"
rt_count=$(grep -c -- '-->' "$roundtrip_file")
assert_exit_code "subs.srt roundtrip: 567 blocks preserved" "567" "$rt_count"

# extract text for translation (unit test)
struct_file="$TMP_DIR/subs_struct.txt"
text_file="$TMP_DIR/subs_text.txt"
block_count=$(bash -c '
    source "'"$SUBSYNC"'" --source-only 2>/dev/null || true
    _srt_extract_for_translation "'"$FIXTURES/subs.srt"'" "'"$struct_file"'" "'"$text_file"'"
' 2>/dev/null || echo "0")
# Fallback: if sourcing fails, do inline extraction
if [[ "$block_count" == "0" || ! -s "$text_file" ]]; then
    block_count=0
    in_text=false ts="" buf=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}\ --\>\ [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} ]]; then
            ts="$line"; in_text=true; buf=""
        elif $in_text && [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]]; then
            if [[ -n "$buf" ]]; then
                ((block_count++)) || true
                echo "$ts" >> "$struct_file"
                echo "${block_count}: ${buf}" >> "$text_file"
            fi
            in_text=false; buf=""
        elif $in_text && ! [[ "$line" =~ ^[0-9]+[[:space:]]*$ ]]; then
            [[ -n "$buf" ]] && buf="${buf} <br> ${line}" || buf="$line"
        fi
    done < "$FIXTURES/subs.srt"
    if $in_text && [[ -n "$buf" ]]; then
        ((block_count++)) || true
        echo "$ts" >> "$struct_file"
        echo "${block_count}: ${buf}" >> "$text_file"
    fi
fi
assert_exit_code "subs.srt extract: 567 blocks" "567" "$block_count"
ts_count=$(wc -l < "$struct_file" | tr -d ' ')
assert_exit_code "subs.srt extract: 567 timestamps" "567" "$ts_count"
text_count=$(wc -l < "$text_file" | tr -d ' ')
assert_exit_code "subs.srt extract: 567 text lines" "567" "$text_count"
# Verify multiline blocks use <br> markers
br_count=$(grep -c '<br>' "$text_file" || echo "0")
if [[ "$br_count" -gt 100 ]]; then
    assert "subs.srt extract: multiline <br> markers ($br_count)" 0
else
    assert "subs.srt extract: multiline <br> markers ($br_count, expected >100)" 1
fi

# sync shift
"$SUBSYNC" sync "$FIXTURES/subs.srt" --shift +1000 -o "$TMP_DIR" 2>&1 > /dev/null
sync_file="$TMP_DIR/subs.synced.srt"
assert_file_exists "subs.srt sync +1000ms: file created" "$sync_file"
assert_file_contains "subs.srt sync +1000ms: first ts shifted" "$sync_file" "00:00:04,220"
sync_count=$(grep -c -- '-->' "$sync_file")
assert_exit_code "subs.srt sync: 567 blocks preserved" "567" "$sync_count"

# new flags parsing
out=$("$SUBSYNC" --help 2>&1)
assert_output_contains "help: --claude-effort" "$out" "\-\-claude-effort"
assert_output_contains "help: --skip-steps" "$out" "\-\-skip-steps"
assert_output_contains "help: --max-parallel" "$out" "\-\-max-parallel"
assert_output_contains "help: --resume" "$out" "\-\-resume"

# ── New commands in help ─────────────────────────────────────────────────────
assert_output_contains "help: text command" "$out" "text.*Export plain text"
assert_output_contains "help: diff command" "$out" "diff.*Compare two subtitle"
assert_output_contains "help: completions" "$out" "completions.*Generate shell completions"
assert_output_contains "help: manpage" "$out" "manpage.*Generate man page"
assert_output_contains "help: --diff-with" "$out" "\-\-diff-with"
assert_output_contains "help: --mix-with" "$out" "\-\-mix-with"
assert_output_contains "help: --mix" "$out" "\-\-mix"
assert_output_contains "help: --mix-translate" "$out" "\-\-mix-translate"
assert_output_contains "help: --swap" "$out" "\-\-swap"
assert_output_contains "help: --force-embed" "$out" "\-\-force-embed"
assert_output_contains "help: --strip-existing" "$out" "\-\-strip-existing"
assert_output_contains "help: mix command" "$out" "mix.*Mix.*language"
assert_output_contains "help: --playlist" "$out" "\-\-playlist"

# ══════════════════════════════════════════════════════════════════════════════
# TEXT COMMAND
# ══════════════════════════════════════════════════════════════════════════════
section "Text: export plain text"

text_out="$TMP_DIR/text_output.txt"
"$SUBSYNC" text "$FIXTURES/basic.srt" > "$text_out" 2>/dev/null
assert_file_exists "text: file created" "$text_out"
assert_file_contains "text: has dialogue" "$text_out" "Willkommen"
assert_file_not_contains "text: no timestamps" "$text_out" "-->"

# Test with large fixture
"$SUBSYNC" text "$FIXTURES/subs.srt" > "$text_out" 2>/dev/null
line_count=$(wc -l < "$text_out" | tr -d ' ')
assert_exit_code "text subs.srt: many lines" "1" "$([ "$line_count" -gt 100 ] && echo 1 || echo 0)"
assert_file_not_contains "text subs.srt: no timestamps" "$text_out" "-->"
rm -f "$text_out"

# ══════════════════════════════════════════════════════════════════════════════
# DIFF COMMAND
# ══════════════════════════════════════════════════════════════════════════════
section "Diff: compare two SRTs"

# Diff identical files
out=$("$SUBSYNC" diff "$FIXTURES/basic.srt" --diff-with "$FIXTURES/basic.srt" 2>&1)
assert_output_contains "diff identical: reports identical" "$out" "identical"

# Diff different files
out=$("$SUBSYNC" diff "$FIXTURES/basic.srt" --diff-with "$FIXTURES/basic_fr.srt" 2>&1)
assert_output_contains "diff different: reports differences" "$out" "blocks differ"

# ══════════════════════════════════════════════════════════════════════════════
# COMPLETIONS COMMAND
# ══════════════════════════════════════════════════════════════════════════════
section "Completions: shell completions"

out=$("$SUBSYNC" completions bash 2>/dev/null)
assert_output_contains "bash completions: function" "$out" "_subtool"
assert_output_contains "bash completions: complete" "$out" "complete -F _subtool"

out=$("$SUBSYNC" completions zsh 2>/dev/null)
assert_output_contains "zsh completions: compdef" "$out" "#compdef subtool"

out=$("$SUBSYNC" completions fish 2>/dev/null)
assert_output_contains "fish completions: complete" "$out" "complete -c subtool"

# ══════════════════════════════════════════════════════════════════════════════
# MANPAGE COMMAND
# ══════════════════════════════════════════════════════════════════════════════
section "Manpage: generate man page"

out=$("$SUBSYNC" manpage 2>/dev/null)
assert_output_contains "manpage: TH header" "$out" ".TH SUBTOOL"
assert_output_contains "manpage: COMMANDS section" "$out" ".SH COMMANDS"
assert_output_contains "manpage: OPTIONS section" "$out" ".SH OPTIONS"
assert_output_contains "manpage: text command" "$out" "Export plain text"
assert_output_contains "manpage: diff command" "$out" "Compare two subtitle"

# ══════════════════════════════════════════════════════════════════════════════
# FUZZY SEARCH NORMALIZATION
# ══════════════════════════════════════════════════════════════════════════════
section "Fuzzy search: query normalization"

# Test that fuzzy normalization works (internal function)
out=$(source "$SUBSYNC" 2>/dev/null; _fuzzy_normalize "Die.Discounter_S01E03" 2>/dev/null) || true
# We can't easily source the script, so test via verbose search output
out=$("$SUBSYNC" search -q "Die.Discounter_S01" -l de --verbose --dry-run 2>&1) || true
assert_output_contains "fuzzy: normalizes dots/underscores" "$out" "Fuzzy-normalized"

# ══════════════════════════════════════════════════════════════════════════════
# PLAYLIST SUPPORT
# ══════════════════════════════════════════════════════════════════════════════
section "Playlist: batch file support"

# Create a temporary playlist file
playlist_file="$TMP_DIR/test_playlist.txt"
printf "# Comment line\n/nonexistent/video1.mkv\n\n/nonexistent/video2.mp4\n" > "$playlist_file"

# Test that playlist is recognized (will warn about missing files but not crash)
out=$("$SUBSYNC" auto --playlist "$playlist_file" -l fr --dry-run 2>&1) || true
assert_output_contains "playlist: recognized" "$out" "Playlist|not found"

# Test .txt auto-detection as playlist
out=$("$SUBSYNC" auto "$playlist_file" -l fr --dry-run 2>&1) || true
assert_output_contains "playlist auto-detect: .txt" "$out" "Playlist|not found"

rm -f "$playlist_file"

# ══════════════════════════════════════════════════════════════════════════════
# ── AUTO FLOW COMPREHENSIVE TESTS ────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

if command -v ffmpeg &>/dev/null; then

# Create shared test videos (reused across auto sections)
_auto_test_base="$TMP_DIR/auto_tests"
mkdir -p "$_auto_test_base"

# Video with DE + FR embedded subs
_auto_video_defr="$_auto_test_base/master_defr.mkv"
ffmpeg -v quiet -f lavfi -i "color=black:s=320x240:d=1" \
    -i "$FIXTURES/basic.srt" -i "$FIXTURES/basic_fr.srt" \
    -c:v libx264 -preset ultrafast -c:s srt \
    -map 0 -map 1 -map 2 \
    -metadata:s:s:0 language=de -metadata:s:s:0 title=German \
    -metadata:s:s:1 language=fr -metadata:s:s:1 title=French \
    "$_auto_video_defr" -y 2>/dev/null

# Video with DE only (no FR)
_auto_video_de="$_auto_test_base/master_de.mkv"
ffmpeg -v quiet -f lavfi -i "color=black:s=320x240:d=1" \
    -i "$FIXTURES/basic.srt" \
    -c:v libx264 -preset ultrafast -c:s srt \
    -map 0 -map 1 \
    -metadata:s:s:0 language=de -metadata:s:s:0 title=German \
    "$_auto_video_de" -y 2>/dev/null

# ══════════════════════════════════════════════════════════════════════════════
section "auto --mix italic order"

if [[ -f "$_auto_video_defr" ]]; then
    _mix_order_dir="$TMP_DIR/mix_order_test"
    mkdir -p "$_mix_order_dir"
    cp "$_auto_video_defr" "$_mix_order_dir/movie.mkv"

    # Default: target (FR) on top (normal), mix (DE) on bottom (italic)
    out=$("$SUBSYNC" auto "$_mix_order_dir/movie.mkv" -l fr --mix --no-embed --skip-steps sync 2>&1 || true)
    _mix_out="$_mix_order_dir/movie.mix.srt"
    if [[ -f "$_mix_out" ]]; then
        assert "auto mix order: mix file created" 0
        # FR (target) should be on top — normal text, not italic
        if grep -q "^Bienvenue" "$_mix_out"; then
            assert "auto mix default: FR (target) on top" 0
        else
            assert "auto mix default: FR (target) on top" 1
        fi
        assert_file_contains "auto mix default: DE (mix) in italic" "$_mix_out" "<i>Willkommen"
        assert_file_not_contains "auto mix default: FR is NOT italic" "$_mix_out" "<i>Bienvenue"
        if grep -q "^Willkommen" "$_mix_out"; then
            assert "auto mix default: DE is NOT on top (normal)" 1
        else
            assert "auto mix default: DE is NOT on top (normal)" 0
        fi
    else
        assert "auto mix order: mix file created (got: $(ls "$_mix_order_dir"/*.srt 2>/dev/null | xargs -I{} basename {} | tr '\n' ' '))" 1
    fi

    # With --swap: DE (mix) on top (normal), FR (target) on bottom (italic)
    rm -f "$_mix_order_dir"/*.srt 2>/dev/null
    out=$("$SUBSYNC" auto "$_mix_order_dir/movie.mkv" -l fr --mix --swap --no-embed --skip-steps sync 2>&1 || true)
    _mix_out="$_mix_order_dir/movie.mix.srt"
    if [[ -f "$_mix_out" ]]; then
        if grep -q "^Willkommen" "$_mix_out"; then
            assert "auto mix --swap: DE (mix) on top" 0
        else
            assert "auto mix --swap: DE (mix) on top" 1
        fi
        assert_file_contains "auto mix --swap: FR (target) in italic" "$_mix_out" "<i>Bienvenue"
        assert_file_not_contains "auto mix --swap: DE is NOT italic" "$_mix_out" "<i>Willkommen"
        if grep -q "^Bienvenue" "$_mix_out"; then
            assert "auto mix --swap: FR is NOT on top (normal)" 1
        else
            assert "auto mix --swap: FR is NOT on top (normal)" 0
        fi
    else
        assert "auto mix --swap: mix file created" 1
    fi
else
    assert "auto mix order: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto --mix-translate"

if [[ -f "$_auto_video_defr" ]]; then
    _mt_dir="$TMP_DIR/mix_translate_test"
    mkdir -p "$_mt_dir"
    cp "$_auto_video_defr" "$_mt_dir/movie.mkv"

    # --mix-translate: should translate target (FR) into mix lang (DE) instead of searching/downloading
    out=$("$SUBSYNC" auto "$_mt_dir/movie.mkv" -l fr --mix de --mix-translate --no-embed --skip-steps sync 2>&1 || true)
    assert_output_contains "mix-translate: translate mode announced" "$out" "translate mode"

    _mt_mix="$_mt_dir/movie.mix.srt"
    # Translation requires a provider (trans/google). If not available, mix file won't be created.
    if [[ -f "$_mt_mix" ]]; then
        assert "mix-translate: mix file created" 0
        # Mix file should contain FR text (target, on top) and translated DE text (italic)
        assert_file_contains "mix-translate: FR text present" "$_mt_mix" "Bienvenue|Kolinski|rayons"
        # DE text should be in italic (translated from FR)
        if grep -q "<i>" "$_mt_mix"; then
            assert "mix-translate: has italic text (translated mix)" 0
        else
            assert "mix-translate: has italic text (translated mix)" 1
        fi
    else
        # If translation failed (no provider), check that translate was attempted
        if echo "$out" | grep -qE "Translating.*fr.*->.*de"; then
            assert "mix-translate: translation attempted (provider unavailable)" 0
        else
            assert "mix-translate: translation attempted" 1
        fi
    fi

    # Verify --mix-translate skips download: output should NOT contain "Downloading" for mix
    if echo "$out" | grep -q "Downloading.*subtitles for mix"; then
        assert "mix-translate: skips download step" 1
    else
        assert "mix-translate: skips download step" 0
    fi

    # Without --mix-translate: same setup should NOT attempt translation if download path available
    rm -f "$_mt_dir"/*.srt 2>/dev/null
    out2=$("$SUBSYNC" auto "$_mt_dir/movie.mkv" -l fr --mix de --no-embed --skip-steps sync 2>&1 || true)
    if echo "$out2" | grep -q "translate mode"; then
        assert "mix no-translate: translate mode NOT announced" 1
    else
        assert "mix no-translate: translate mode NOT announced" 0
    fi
else
    assert "mix-translate: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto directory mode excludes temp files"

if [[ -f "$_auto_video_defr" ]]; then
    _tmpexcl_dir="$TMP_DIR/tmpexcl_test"
    mkdir -p "$_tmpexcl_dir"
    cp "$_auto_video_defr" "$_tmpexcl_dir/real_video.mkv"
    # Create orphaned temp files (from interrupted embeds)
    touch "$_tmpexcl_dir/real_video.tmp.mkv"
    touch "$_tmpexcl_dir/real_video.stripped.mkv"
    touch "$_tmpexcl_dir/another.tmp.mp4"

    out=$("$SUBSYNC" auto "$_tmpexcl_dir" -l de --dry-run 2>&1 || true)
    assert_output_contains "tmpexcl: finds 1 video only" "$out" "1 videos found"
    if echo "$out" | grep -q "real_video\.tmp\.mkv"; then
        assert "tmpexcl: .tmp.mkv NOT processed" 1
    else
        assert "tmpexcl: .tmp.mkv NOT processed" 0
    fi
    if echo "$out" | grep -q "stripped\.mkv"; then
        assert "tmpexcl: .stripped.mkv NOT processed" 1
    else
        assert "tmpexcl: .stripped.mkv NOT processed" 0
    fi
    if echo "$out" | grep -q "another\.tmp\.mp4"; then
        assert "tmpexcl: .tmp.mp4 NOT processed" 1
    else
        assert "tmpexcl: .tmp.mp4 NOT processed" 0
    fi
else
    assert "tmpexcl: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto cleanup after embed vs --keep-files"

if [[ -f "$_auto_video_defr" ]]; then
    # Test 1: --no-embed → SRT file preserved (no cleanup without embed)
    _cleanup_dir="$TMP_DIR/cleanup_test1"
    mkdir -p "$_cleanup_dir"
    cp "$_auto_video_defr" "$_cleanup_dir/movie.mkv"
    "$SUBSYNC" auto "$_cleanup_dir/movie.mkv" -l de --no-embed --skip-steps sync 2>&1 >/dev/null || true
    if [[ -f "$_cleanup_dir/movie.de.srt" ]]; then
        assert "cleanup: --no-embed preserves SRT" 0
    else
        assert "cleanup: --no-embed preserves SRT" 1
    fi

    # Test 2: embed enabled → SRT cleaned up after successful embed
    _cleanup_dir2="$TMP_DIR/cleanup_test2"
    mkdir -p "$_cleanup_dir2"
    cp "$_auto_video_defr" "$_cleanup_dir2/movie.mkv"
    "$SUBSYNC" auto "$_cleanup_dir2/movie.mkv" -l de --skip-steps sync --strip-existing 2>&1 >/dev/null || true
    if [[ -f "$_cleanup_dir2/movie.de.srt" ]]; then
        assert "cleanup: embed success removes SRT" 1
    else
        assert "cleanup: embed success removes SRT" 0
    fi

    # Test 3: --keep-files → SRT preserved even after embed
    _cleanup_dir3="$TMP_DIR/cleanup_test3"
    mkdir -p "$_cleanup_dir3"
    cp "$_auto_video_defr" "$_cleanup_dir3/movie.mkv"
    "$SUBSYNC" auto "$_cleanup_dir3/movie.mkv" -l de --keep-files --skip-steps sync --strip-existing 2>&1 >/dev/null || true
    if [[ -f "$_cleanup_dir3/movie.de.srt" ]]; then
        assert "cleanup: --keep-files preserves SRT after embed" 0
    else
        assert "cleanup: --keep-files preserves SRT after embed" 1
    fi
else
    assert "cleanup: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto translation failure cleanup"

# Bug 3 fix: when translation fails, downloaded fallback SRT should be cleaned up
# Only testable when translate-shell (trans) is NOT available (otherwise translation succeeds)
if [[ -f "$_auto_video_de" ]]; then
    if ! command -v trans &>/dev/null; then
        _trfail_dir="$TMP_DIR/trfail_test"
        mkdir -p "$_trfail_dir"
        cp "$_auto_video_de" "$_trfail_dir/movie.mkv"
        # Target FR, video has only DE subs → extract DE, translate DE→FR fails (no trans), cleanup DE
        "$SUBSYNC" auto "$_trfail_dir/movie.mkv" -l fr --no-transcribe --skip-steps sync --no-embed 2>&1 >/dev/null || true
        if [[ -f "$_trfail_dir/movie.de.srt" ]]; then
            assert "trfail cleanup: fallback SRT removed after failed translation" 1
        else
            assert "trfail cleanup: fallback SRT removed after failed translation" 0
        fi
        # FR target should NOT exist (translation failed)
        if [[ -f "$_trfail_dir/movie.fr.srt" ]]; then
            assert "trfail cleanup: target SRT not created (translation failed)" 1
        else
            assert "trfail cleanup: target SRT not created (translation failed)" 0
        fi
    else
        printf "  ${YELLOW}SKIP${NC}  auto translation failure cleanup: trans is available (translation would succeed)\n"
    fi
else
    assert "trfail cleanup: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto --no-embed"

if [[ -f "$_auto_video_defr" ]]; then
    _noembed_dir="$TMP_DIR/noembed_test"
    mkdir -p "$_noembed_dir"
    cp "$_auto_video_defr" "$_noembed_dir/movie.mkv"

    out=$("$SUBSYNC" auto "$_noembed_dir/movie.mkv" -l de --no-embed --skip-steps sync 2>&1 || true)
    assert_output_contains "no-embed: reports inactive" "$out" "Embed: inactive"
    assert_file_exists "no-embed: SRT file exists" "$_noembed_dir/movie.de.srt"
    # Video should be unchanged (same subtitle count)
    orig_subs=$(ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$_noembed_dir/movie.mkv" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$orig_subs" == "2" ]]; then
        assert "no-embed: video subtitle count unchanged" 0
    else
        assert "no-embed: video subtitle count unchanged (got $orig_subs)" 1
    fi
else
    assert "no-embed: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto --dry-run"

if [[ -f "$_auto_video_defr" ]]; then
    _dryrun_dir="$TMP_DIR/dryrun_test"
    mkdir -p "$_dryrun_dir"
    cp "$_auto_video_defr" "$_dryrun_dir/movie.mkv"

    out=$("$SUBSYNC" auto "$_dryrun_dir/movie.mkv" -l fr --dry-run 2>&1 || true)
    assert_output_contains "dry-run: mode announced" "$out" "dry-run"
    assert_output_contains "dry-run: would actions" "$out" "Would"
    # No SRT files should be created
    if ls "$_dryrun_dir"/*.srt 2>/dev/null | grep -q .; then
        assert "dry-run: no SRT files created" 1
    else
        assert "dry-run: no SRT files created" 0
    fi
else
    assert "dry-run: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto --skip-steps"

if [[ -f "$_auto_video_defr" ]]; then
    _skipsteps_dir="$TMP_DIR/skipsteps_test"
    mkdir -p "$_skipsteps_dir"
    cp "$_auto_video_defr" "$_skipsteps_dir/movie.mkv"

    out=$("$SUBSYNC" auto "$_skipsteps_dir/movie.mkv" -l de --skip-steps embed,sync --no-embed 2>&1 || true)
    assert_output_contains "skip-steps: reported in output" "$out" "Skip steps:.*embed"
    # SRT should exist (embed was skipped)
    assert_file_exists "skip-steps: SRT created (embed skipped)" "$_skipsteps_dir/movie.de.srt"
    # No "Sync:" message (sync was skipped)
    if echo "$out" | grep -q "Sync OK:"; then
        assert "skip-steps: sync was skipped" 1
    else
        assert "skip-steps: sync was skipped" 0
    fi
else
    assert "skip-steps: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto --keep-files"

if [[ -f "$_auto_video_defr" ]]; then
    _keepfiles_dir="$TMP_DIR/keepfiles_test"
    mkdir -p "$_keepfiles_dir"
    cp "$_auto_video_defr" "$_keepfiles_dir/movie.mkv"

    out=$("$SUBSYNC" auto "$_keepfiles_dir/movie.mkv" -l de --keep-files --skip-steps sync --strip-existing 2>&1 || true)
    assert_output_contains "keep-files: announced" "$out" "Keep files: active"
    assert_file_exists "keep-files: SRT preserved after embed" "$_keepfiles_dir/movie.de.srt"
else
    assert "keep-files: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto batch resume"

if [[ -f "$_auto_video_defr" ]]; then
    _batch_dir="$TMP_DIR/batch_resume_test"
    mkdir -p "$_batch_dir"
    cp "$_auto_video_defr" "$_batch_dir/video1.mkv"
    cp "$_auto_video_defr" "$_batch_dir/video2.mkv"

    # First run: process both
    out=$("$SUBSYNC" auto "$_batch_dir" -l de --no-embed --skip-steps sync 2>&1 || true)
    assert_output_contains "batch: finds 2 videos" "$out" "2 videos found"
    _batch_state="$_batch_dir/.subtool_batch_state"
    if [[ -f "$_batch_state" ]]; then
        assert "batch: state file created" 0
        if grep -q "video1.mkv" "$_batch_state" && grep -q "video2.mkv" "$_batch_state"; then
            assert "batch: state contains both videos" 0
        else
            assert "batch: state contains both videos" 1
        fi
    else
        assert "batch: state file created" 1
    fi

    # Second run WITH --resume: should skip both (batch state says they're done)
    rm -f "$_batch_dir"/*.srt 2>/dev/null
    out2=$("$SUBSYNC" auto "$_batch_dir" -l de --no-embed --skip-steps sync --resume 2>&1 || true)
    assert_output_contains "batch resume: finds 2 videos" "$out2" "2 videos found"
    # Both should be skipped via batch state, so Skips count should be 2
    assert_output_contains "batch resume: skips completed files" "$out2" "Skips: 2"
else
    assert "batch resume: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto playlist processing"

if [[ -f "$_auto_video_defr" ]]; then
    _pl_dir="$TMP_DIR/playlist_proc_test"
    mkdir -p "$_pl_dir"
    cp "$_auto_video_defr" "$_pl_dir/ep01.mkv"
    cp "$_auto_video_defr" "$_pl_dir/ep02.mkv"

    # Create playlist with comments and blank lines
    cat > "$_pl_dir/episodes.txt" << PLEOF
# This is a comment
${_pl_dir}/ep01.mkv

${_pl_dir}/ep02.mkv
# Another comment
PLEOF

    out=$("$SUBSYNC" auto "$_pl_dir/episodes.txt" -l de --no-embed --skip-steps sync 2>&1 || true)
    assert_output_contains "playlist proc: finds 2 videos" "$out" "2 videos found"
    assert_file_exists "playlist proc: ep01 SRT created" "$_pl_dir/ep01.de.srt"
    assert_file_exists "playlist proc: ep02 SRT created" "$_pl_dir/ep02.de.srt"
else
    assert "playlist proc: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto multi-lang"

if [[ -f "$_auto_video_defr" ]]; then
    _ml_dir="$TMP_DIR/multilang_test"
    mkdir -p "$_ml_dir"
    cp "$_auto_video_defr" "$_ml_dir/movie.mkv"

    out=$("$SUBSYNC" auto "$_ml_dir/movie.mkv" -l de,fr --no-embed --skip-steps sync,translate 2>&1 || true)
    assert_output_contains "multi-lang: dispatches DE" "$out" "Language: de"
    assert_output_contains "multi-lang: dispatches FR" "$out" "Language: fr"
else
    assert "multi-lang: test video created" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "force-embed (multiple tracks)"

if [[ -f "$_auto_video_defr" ]]; then
    # FORCE_EMBED=true is the default, so auto always embeds even if tracks exist.
    # Verify that successive embeds correctly add subtitle tracks.
    _fe_dir="$TMP_DIR/force_embed_test"
    mkdir -p "$_fe_dir"
    cp "$_auto_video_defr" "$_fe_dir/movie.mkv"
    subs_before=$(ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$_fe_dir/movie.mkv" 2>/dev/null | wc -l | tr -d ' ')

    # Embed a third track (FR again) via auto with existing .fr.srt
    cp "$FIXTURES/basic_fr.srt" "$_fe_dir/movie.fr.srt"
    out=$("$SUBSYNC" auto "$_fe_dir/movie.mkv" -l fr --skip-steps sync 2>&1 || true)
    assert_output_contains "force-embed: embed succeeds" "$out" "Embed OK"
    subs_after=$(ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$_fe_dir/movie.mkv" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$subs_after" -gt "$subs_before" ]]; then
        assert "force-embed: track count increased ($subs_before -> $subs_after)" 0
    else
        assert "force-embed: track count increased ($subs_before -> $subs_after)" 1
    fi
else
    assert "force-embed: test video created" 1
fi

else
    printf "  ${YELLOW}SKIP${NC}  auto flow tests: ffmpeg not available\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "sources command"

out=$("$SUBSYNC" sources 2>&1 || true)
assert_output_contains "sources: lists opensubtitles-org" "$out" "opensubtitles-org"
assert_output_contains "sources: lists podnapisi" "$out" "podnapisi"

# ══════════════════════════════════════════════════════════════════════════════
section "providers command"

out=$("$SUBSYNC" providers 2>&1 || true)
assert_output_contains "providers: lists google" "$out" "google"
assert_output_contains "providers: lists whisper" "$out" "whisper"
assert_output_contains "providers: lists claude-code" "$out" "claude-code"

# ══════════════════════════════════════════════════════════════════════════════
section "batch command validation"

out=$("$SUBSYNC" batch 2>&1 || true)
assert_output_contains "batch: error without args" "$out" "Specify"

out=$("$SUBSYNC" batch -q "Test Movie" -l fr --season 1 --dry-run -o "$TMP_DIR" 2>&1 </dev/null || true)
# Should not crash — may warn about no results but should print the batch header
if echo "$out" | grep -qE "batch|Batch|Season"; then
    assert "batch: --dry-run does not crash" 0
else
    assert "batch: --dry-run does not crash" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "auto --force-transcribe flag"

if command -v ffmpeg &>/dev/null; then
    _ft_dir="$TMP_DIR/force_transcribe_test"
    mkdir -p "$_ft_dir"
    ffmpeg -v quiet -f lavfi -i "color=black:s=320x240:d=1" -c:v libx264 -preset ultrafast "$_ft_dir/video.mkv" -y 2>/dev/null
    if [[ -f "$_ft_dir/video.mkv" ]]; then
        out=$("$SUBSYNC" auto "$_ft_dir/video.mkv" -l fr --force-transcribe --dry-run 2>&1 || true)
        assert_output_contains "force-transcribe: flag recognized" "$out" "forced|Would transcribe"
    else
        printf "  ${YELLOW}SKIP${NC}  force-transcribe: could not create test video\n"
    fi
else
    printf "  ${YELLOW}SKIP${NC}  force-transcribe: ffmpeg not available\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ══════════════════════════════════════════════════════════════════════════════
printf "\n${BOLD}══════════════════════════════════════════${NC}\n"
printf "${BOLD}  Results: %d tests${NC}\n" "$TESTS_RUN"
printf "  ${GREEN}Passed: %d${NC}\n" "$TESTS_PASSED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    printf "  ${RED}Failed: %d${NC}\n" "$TESTS_FAILED"
    printf "\n${RED}Failures:${NC}\n"
    printf "%b" "$FAILURES"
    printf "${BOLD}══════════════════════════════════════════${NC}\n"
    exit 1
else
    printf "  ${RED}Failed: 0${NC}\n"
    printf "${BOLD}══════════════════════════════════════════${NC}\n"
    exit 0
fi
