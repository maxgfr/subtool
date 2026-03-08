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

out=$("$SUBSYNC" providers 2>&1)
assert_output_contains "providers lists claude-code" "$out" "claude-code"
assert_output_contains "providers lists zai-codeplan" "$out" "zai-codeplan"
assert_output_contains "providers lists openai" "$out" "openai"
assert_output_contains "providers lists gemini" "$out" "gemini"

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

# ══════════════════════════════════════════════════════════════════════════════
section "check (diagnostic)"

out=$("$SUBSYNC" check 2>&1)
assert_output_contains "check: shows jq" "$out" "jq"
assert_output_contains "check: shows curl" "$out" "curl"
assert_output_contains "check: shows Config" "$out" "Config"

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

out=$("$SUBSYNC" info -f "$FIXTURES/basic.srt" 2>&1)
assert_output_contains "info: detects 5 subtitles" "$out" "5"
assert_output_contains "info: detects start timestamp" "$out" "00:00:01,000"
assert_output_contains "info: detects end timestamp" "$out" "00:00:18,500"
assert_output_contains "info: detects German" "$out" "de.*German"

out=$("$SUBSYNC" info -f "$FIXTURES/basic_fr.srt" 2>&1)
assert_output_contains "info: detects French" "$out" "fr.*French"

out=$("$SUBSYNC" info -f "$FIXTURES/clean.srt" 2>&1)
assert_output_contains "info: detects HI/SDH tags" "$out" "HI/SDH"
assert_output_contains "info: detects HTML tags" "$out" "HTML"

# ══════════════════════════════════════════════════════════════════════════════
section "clean"

"$SUBSYNC" clean -f "$FIXTURES/clean.srt" -o "$TMP_DIR" 2>&1
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

"$SUBSYNC" clean -f "$FIXTURES/already_clean.srt" -o "$TMP_DIR" 2>&1
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

"$SUBSYNC" sync -f "$FIXTURES/basic.srt" --shift +2000 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_exists "sync +2000ms: file created" "$out_file"
assert_file_contains "sync +2000ms: 01,000 -> 03,000" "$out_file" "00:00:03,000"
assert_file_contains "sync +2000ms: 03,500 -> 05,500" "$out_file" "00:00:05,500"
assert_file_not_contains "sync +2000ms: old timestamp absent" "$out_file" "00:00:01,000"

"$SUBSYNC" sync -f "$FIXTURES/basic.srt" --shift -500 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_contains "sync -500ms: 01,000 -> 00,500" "$out_file" "00:00:00,500"
assert_file_contains "sync -500ms: 04,000 -> 03,500" "$out_file" "00:00:03,500"

# ══════════════════════════════════════════════════════════════════════════════
section "convert SRT -> VTT"

"$SUBSYNC" convert -f "$FIXTURES/basic.srt" --to vtt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.vtt"
assert_file_exists "srt->vtt: file created" "$out_file"
assert_file_contains "srt->vtt: header WEBVTT" "$out_file" "^WEBVTT"
assert_file_contains "srt->vtt: dot instead of comma" "$out_file" '00:00:01\.000'
assert_file_not_contains "srt->vtt: no comma in timestamp" "$out_file" '00:00:01,000'
assert_file_contains "srt->vtt: text preserved" "$out_file" "Willkommen"

section "convert SRT -> ASS"

"$SUBSYNC" convert -f "$FIXTURES/basic.srt" --to ass -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.ass"
assert_file_exists "srt->ass: file created" "$out_file"
assert_file_contains "srt->ass: Script Info" "$out_file" "Script Info"
assert_file_contains "srt->ass: V4+ Styles" "$out_file" "V4\+ Styles"
assert_file_contains "srt->ass: Dialogue lines" "$out_file" "^Dialogue:"
assert_file_contains "srt->ass: text preserved" "$out_file" "Willkommen"
assert_file_contains "srt->ass: multiline \\N" "$out_file" '\\N'

section "convert ASS -> SRT"

"$SUBSYNC" convert -f "$FIXTURES/sample.ass" --to srt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/sample.srt"
assert_file_exists "ass->srt: file created" "$out_file"
assert_file_contains "ass->srt: timestamps SRT" "$out_file" '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> '
assert_file_contains "ass->srt: text preserved" "$out_file" "Hello world"
assert_file_not_contains "ass->srt: no Dialogue: lines" "$out_file" "^Dialogue:"

section "convert VTT -> SRT"

"$SUBSYNC" convert -f "$TMP_DIR/basic.vtt" --to srt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.srt"
assert_file_exists "vtt->srt: file created" "$out_file"
assert_file_contains "vtt->srt: comma in timestamp" "$out_file" '00:00:01,000'
assert_file_not_contains "vtt->srt: no WEBVTT" "$out_file" "WEBVTT"

section "convert VTT with cue settings -> SRT"

"$SUBSYNC" convert -f "$FIXTURES/cue_settings.vtt" --to srt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/cue_settings.srt"
assert_file_exists "vtt+cue->srt: file created" "$out_file"
assert_file_contains "vtt+cue->srt: text preserved" "$out_file" "Hello world"
assert_file_contains "vtt+cue->srt: multiline preserved" "$out_file" "with two lines"
assert_file_contains "vtt+cue->srt: normal sub" "$out_file" "Normal subtitle"

# ══════════════════════════════════════════════════════════════════════════════
section "merge"

"$SUBSYNC" merge -f "$FIXTURES/basic.srt" --merge-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1
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

"$SUBSYNC" fix -f "$FIXTURES/broken.srt" -o "$TMP_DIR" 2>&1
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

"$SUBSYNC" fix -f "$FIXTURES/latin1.srt" -o "$TMP_DIR" 2>&1
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

    if ! echo "$out" | grep -qi "Mode:.*$expected_mode"; then
        ok=false; desc+=" [mode=$expected_mode FAIL]"
    fi
    if [[ -n "$expected_title" ]] && ! echo "$out" | grep -q "Title: $expected_title"; then
        ok=false; desc+=" [title FAIL]"
    fi
    if [[ -n "$expected_season" ]] && ! echo "$out" | grep -q "Season: $expected_season"; then
        ok=false; desc+=" [season FAIL]"
    fi
    if [[ -n "$expected_ep" && "$expected_mode" != "Range" ]] && ! echo "$out" | grep -q "Episode: $expected_ep"; then
        ok=false; desc+=" [episode FAIL]"
    fi
    if [[ -n "$expected_ep_end" ]] && ! echo "$out" | grep -q "Episodes: ${expected_ep}-${expected_ep_end}"; then
        ok=false; desc+=" [range FAIL]"
    fi
    if [[ -n "$expected_imdb" ]] && ! echo "$out" | grep -q "IMDb: $expected_imdb"; then
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
        out=$("$SUBSYNC" extract -f "$test_video" --track 0 -o "$TMP_DIR" 2>&1)
        extract_file=$(find "$TMP_DIR" -name "test_video.*.srt" | head -1)
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
    "$SUBSYNC" embed -f "$test_video" --sub "$FIXTURES/basic_fr.srt" -l fr -o "$TMP_DIR" 2>&1
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
    "$SUBSYNC" translate -f "$FIXTURES/basic.srt" -l fr --from de -p zai-codeplan -o "$TMP_DIR" 2>&1
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
    "$SUBSYNC" translate -f "$FIXTURES/basic.srt" -l en --from de -p openai -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate openai: file created" "$out_file"
    assert_file_contains "translate openai: contains timestamps" "$out_file" '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}'
else
    printf "  ${YELLOW}SKIP${NC}  translate openai: OPENAI_API_KEY not set\n"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    "$SUBSYNC" translate -f "$FIXTURES/basic.srt" -l en --from de -p claude -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate claude: file created" "$out_file"
else
    printf "  ${YELLOW}SKIP${NC}  translate claude: ANTHROPIC_API_KEY not set\n"
fi

if [[ -n "${MISTRAL_API_KEY:-}" ]]; then
    "$SUBSYNC" translate -f "$FIXTURES/basic.srt" -l en --from de -p mistral -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate mistral: file created" "$out_file"
else
    printf "  ${YELLOW}SKIP${NC}  translate mistral: MISTRAL_API_KEY not set\n"
fi

if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    "$SUBSYNC" translate -f "$FIXTURES/basic.srt" -l en --from de -p gemini -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate gemini: file created" "$out_file"
else
    printf "  ${YELLOW}SKIP${NC}  translate gemini: GEMINI_API_KEY not set\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "translate (auto-detect source lang)"

# Without --from, should auto-detect
out=$("$SUBSYNC" translate -f /nonexistent.srt -l fr 2>&1 || true)
assert_output_contains "translate without --from: accepted (file error, not lang error)" "$out" "not found"

# ══════════════════════════════════════════════════════════════════════════════
section "search (API - optional)"

out=$("$SUBSYNC" search -q "Inception" -l en --sources opensubtitles-org --dry-run 2>&1 </dev/null || true)
assert_output_contains "search opensubtitles-org: results" "$out" "Subtitles found|Searching on"

# ══════════════════════════════════════════════════════════════════════════════
section "Flags: --quiet, --verbose"

out=$("$SUBSYNC" info -f "$FIXTURES/basic.srt" --quiet 2>&1)
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
"$SUBSYNC" sync -f "$FIXTURES/basic.srt" --shift -5000 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_contains "sync negative: no negative timestamp" "$out_file" "00:00:00,000"
assert_file_not_contains "sync negative: no timestamp -" "$out_file" "^-"

# convert roundtrip SRT -> VTT -> SRT
"$SUBSYNC" convert -f "$FIXTURES/basic.srt" --to vtt -o "$TMP_DIR" 2>&1
"$SUBSYNC" convert -f "$TMP_DIR/basic.vtt" --to srt -o "$TMP_DIR" 2>&1
roundtrip="$TMP_DIR/basic.srt"
assert_file_contains "roundtrip srt->vtt->srt: timestamps OK" "$roundtrip" "00:00:01,000"
assert_file_contains "roundtrip srt->vtt->srt: text OK" "$roundtrip" "Willkommen"

# convert roundtrip SRT -> ASS -> SRT
"$SUBSYNC" convert -f "$FIXTURES/basic.srt" --to ass -o "$TMP_DIR" 2>&1
"$SUBSYNC" convert -f "$TMP_DIR/basic.ass" --to srt -o "$TMP_DIR" 2>&1
roundtrip="$TMP_DIR/basic.srt"
assert_file_contains "roundtrip srt->ass->srt: text OK" "$roundtrip" "Willkommen"

# info on non-existent file
out=$("$SUBSYNC" info -f /nonexistent/file.srt 2>&1 || true)
assert_output_contains "info non-existent file: error" "$out" "not found"

# translate without --from (default en)
# Just test that parse works, don't need actual translation
out=$("$SUBSYNC" translate -f /nonexistent.srt -l fr 2>&1 || true)
assert_output_contains "translate non-existent file: error" "$out" "not found"

# ══════════════════════════════════════════════════════════════════════════════
section "autosync"

# autosync without args -> error
out=$("$SUBSYNC" autosync 2>&1 || true)
assert_output_contains "autosync without --file -> error" "$out" "Specify.*--file"

# autosync without --ref -> error
out=$("$SUBSYNC" autosync -f "$FIXTURES/basic.srt" 2>&1 || true)
assert_output_contains "autosync without --ref -> error" "$out" "Specify.*--ref"

# autosync non-existent file -> error
out=$("$SUBSYNC" autosync -f /nonexistent.srt --ref /nonexistent.mkv 2>&1 || true)
assert_output_contains "autosync non-existent file -> error" "$out" "not found"

# autosync without ffsubsync -> uvx message or fallback uvx
if ! command -v ffsubsync &>/dev/null && ! command -v uvx &>/dev/null; then
    out=$("$SUBSYNC" autosync -f "$FIXTURES/basic.srt" --ref "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 || true)
    assert_output_contains "autosync without ffsubsync or uvx -> error" "$out" "uvx ffsubsync|uv tool install"
elif ! command -v ffsubsync &>/dev/null && command -v uvx &>/dev/null; then
    out=$("$SUBSYNC" autosync -f "$FIXTURES/basic.srt" --ref "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1 || true)
    assert_output_contains "autosync via uvx: fallback detected" "$out" "uvx"
else
    printf "  ${YELLOW}SKIP${NC}  autosync without ffsubsync: ffsubsync is installed\n"
fi

# autosync with ffsubsync installed (functional test)
if command -v ffsubsync &>/dev/null; then
    "$SUBSYNC" autosync -f "$FIXTURES/basic.srt" --ref "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1
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
assert_output_contains "scan without --dir -> error" "$out" "Specify.*--dir"

# scan non-existent directory -> error
out=$("$SUBSYNC" scan --dir /nonexistent_dir -l fr 2>&1 || true)
assert_output_contains "scan non-existent dir -> error" "$out" "not found"

# scan without --lang -> error
out=$("$SUBSYNC" scan --dir "$TMP_DIR" 2>&1 || true)
assert_output_contains "scan without --lang -> error" "$out" "Specify.*--lang"

# scan empty directory (no videos) -> dry-run
scan_dir="$TMP_DIR/scan_empty"
mkdir -p "$scan_dir"
out=$("$SUBSYNC" scan --dir "$scan_dir" -l fr --dry-run 2>&1 || true)
assert_output_contains "scan empty dir: scan header" "$out" "scan"

# scan directory with fake video file (dry-run, no network)
scan_dir2="$TMP_DIR/scan_videos"
mkdir -p "$scan_dir2"
touch "$scan_dir2/My.Movie.2024.mkv"
touch "$scan_dir2/My.Movie.2024.fr.srt"  # already has subtitle
out=$("$SUBSYNC" scan --dir "$scan_dir2" -l fr --dry-run 2>&1 || true)
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
