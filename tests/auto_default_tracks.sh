#!/usr/bin/env bash
# Exercise the shipped auto command with real muxed subtitle tracks, offline.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBTOOL="$PROJECT_DIR/subtool.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export XDG_CONFIG_HOME="$TEST_DIR/config" XDG_CACHE_HOME="$TEST_DIR/cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

cat > "$TEST_DIR/french.srt" <<'EOF'
1
00:00:00,100 --> 00:00:00,900
Bonjour.

EOF
cat > "$TEST_DIR/german.srt" <<'EOF'
1
00:00:00,100 --> 00:00:00,900
Guten Tag.

EOF

ffmpeg -v error -f lavfi -i 'color=black:s=32x32:d=1' \
    -i "$TEST_DIR/french.srt" -map 0 -map 1 -c:v libx264 -c:s srt \
    -metadata:s:s:0 language=fre -disposition:s:0 default+forced+hearing_impaired \
    "$TEST_DIR/original.mkv"

check_tracks() {
    local file="$1" expected_lang="$2" expected_count="$3"
    ffprobe -v error -select_streams s -show_streams -of json "$file" |
        jq -e --arg lang "$expected_lang" --argjson count "$expected_count" '
            .streams as $s |
            ($s | length) == $count and
            ([$s[] | select(.disposition.default == 1)] | length) == 1 and
            ([$s[] | select(.disposition.default == 1)][0].tags.language == $lang) and
            (all($s[]; .disposition.forced == 0)) and
            ($s[0].disposition.hearing_impaired == 1)
        ' > /dev/null || {
            printf 'FAIL: expected one default %s track and no competing forced tracks in %s\n' "$expected_lang" "$file" >&2
            return 1
        }
}

cp "$TEST_DIR/original.mkv" "$TEST_DIR/movie.mkv"
cp "$TEST_DIR/german.srt" "$TEST_DIR/movie.de.srt"
"$SUBTOOL" auto "$TEST_DIR/movie.mkv" -l de --skip-steps sync --keep-files > "$TEST_DIR/auto.log" 2>&1
check_tracks "$TEST_DIR/movie.mkv" ger 2
grep -q 'Reopen.*player' "$TEST_DIR/auto.log"
# Verify the selected track contains real, unchanged subtitle text and timing.
ffmpeg -v error -i "$TEST_DIR/movie.mkv" -map 0:s:1 "$TEST_DIR/extracted.srt"
cmp "$TEST_DIR/german.srt" "$TEST_DIR/extracted.srt"

# Re-running auto must move the default to the newly added target track.
"$SUBTOOL" auto "$TEST_DIR/movie.mkv" -l de --skip-steps sync --keep-files > "$TEST_DIR/repeat.log" 2>&1
check_tracks "$TEST_DIR/movie.mkv" ger 3
ffprobe -v error -select_streams s -show_streams -of json "$TEST_DIR/movie.mkv" |
    jq -e '.streams[-1].disposition.default == 1' > /dev/null

# Exercise the real mix flow: target, source, then bilingual track.
cp "$TEST_DIR/original.mkv" "$TEST_DIR/mixed.mkv"
cp "$TEST_DIR/german.srt" "$TEST_DIR/mixed.de.srt"
cp "$TEST_DIR/french.srt" "$TEST_DIR/mixed.fr.srt"
"$SUBTOOL" auto "$TEST_DIR/mixed.mkv" -l de --mix fr --skip-steps sync --keep-files > "$TEST_DIR/mix.log" 2>&1
check_tracks "$TEST_DIR/mixed.mkv" mul 4

# --no-embed must leave the original selection flags and bytes untouched.
cp "$TEST_DIR/original.mkv" "$TEST_DIR/untouched.mkv"
cp "$TEST_DIR/german.srt" "$TEST_DIR/untouched.de.srt"
"$SUBTOOL" auto "$TEST_DIR/untouched.mkv" -l de --no-embed --skip-steps sync > "$TEST_DIR/noembed.log" 2>&1
cmp "$TEST_DIR/original.mkv" "$TEST_DIR/untouched.mkv"
printf 'PASS: auto defaults, repeat, mix, subtitle content, and --no-embed\n'
