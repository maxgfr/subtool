#!/usr/bin/env bash
set -euo pipefail

# ── Test framework minimaliste ────────────────────────────────────────────────
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
assert_output_contains "--version affiche la version" "$out" '^[0-9]+\.[0-9]+\.[0-9]+'

out=$("$SUBSYNC" --help 2>&1)
assert_output_contains "--help contient USAGE" "$out" "USAGE"
assert_output_contains "--help contient COMMANDES" "$out" "COMMANDES"
assert_output_contains "--help contient get" "$out" "get"
assert_output_contains "--help contient translate" "$out" "translate"

out=$("$SUBSYNC" providers 2>&1)
assert_output_contains "providers liste claude-code" "$out" "claude-code"
assert_output_contains "providers liste zai-codeplan" "$out" "zai-codeplan"
assert_output_contains "providers liste openai" "$out" "openai"
assert_output_contains "providers liste gemini" "$out" "gemini"

out=$("$SUBSYNC" sources 2>&1)
assert_output_contains "sources liste opensubtitles" "$out" "opensubtitles"
assert_output_contains "sources liste podnapisi" "$out" "podnapisi"
assert_output_contains "sources liste subdl" "$out" "subdl"

# Erreurs attendues
out=$("$SUBSYNC" search 2>&1 || true)
assert_output_contains "search sans args -> erreur" "$out" "Specifie"

out=$("$SUBSYNC" translate 2>&1 || true)
assert_output_contains "translate sans args -> erreur" "$out" "Specifie"

out=$("$SUBSYNC" get 2>&1 || true)
assert_output_contains "get sans args -> erreur" "$out" "Specifie"

out=$("$SUBSYNC" --nonexistent 2>&1 || true)
assert_output_contains "option inconnue -> erreur" "$out" "inconnue"

# ══════════════════════════════════════════════════════════════════════════════
section "info"

out=$("$SUBSYNC" info -f "$FIXTURES/basic.srt" 2>&1)
assert_output_contains "info: detecte 5 sous-titres" "$out" "5"
assert_output_contains "info: detecte debut timestamp" "$out" "00:00:01,000"
assert_output_contains "info: detecte fin timestamp" "$out" "00:00:18,500"
assert_output_contains "info: detecte allemand" "$out" "de.*allemand"

out=$("$SUBSYNC" info -f "$FIXTURES/basic_fr.srt" 2>&1)
assert_output_contains "info: detecte francais" "$out" "fr.*francais"

out=$("$SUBSYNC" info -f "$FIXTURES/clean.srt" 2>&1)
assert_output_contains "info: detecte tags HI/SDH" "$out" "HI/SDH"
assert_output_contains "info: detecte tags HTML" "$out" "HTML"

# ══════════════════════════════════════════════════════════════════════════════
section "clean"

"$SUBSYNC" clean -f "$FIXTURES/clean.srt" -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/clean.clean.srt"
assert_file_exists "clean: fichier cree" "$out_file"
assert_file_not_contains "clean: HTML <i> supprime" "$out_file" '<i>'
assert_file_not_contains "clean: HTML <b> supprime" "$out_file" '<b>'
assert_file_not_contains "clean: HTML <font> supprime" "$out_file" '<font>'
assert_file_not_contains "clean: opensubtitles supprime" "$out_file" 'opensubtitles'
assert_file_not_contains "clean: synced by supprime" "$out_file" '[Ss]ynced by'
assert_file_not_contains "clean: subtitle by supprime" "$out_file" '[Ss]ubtitle by'
assert_file_contains "clean: vrai dialogue conserve" "$out_file" "echte Dialog"

# ══════════════════════════════════════════════════════════════════════════════
section "sync"

"$SUBSYNC" sync -f "$FIXTURES/basic.srt" --shift +2000 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_exists "sync +2000ms: fichier cree" "$out_file"
assert_file_contains "sync +2000ms: 01,000 -> 03,000" "$out_file" "00:00:03,000"
assert_file_contains "sync +2000ms: 03,500 -> 05,500" "$out_file" "00:00:05,500"
assert_file_not_contains "sync +2000ms: ancien timestamp absent" "$out_file" "00:00:01,000"

"$SUBSYNC" sync -f "$FIXTURES/basic.srt" --shift -500 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_contains "sync -500ms: 01,000 -> 00,500" "$out_file" "00:00:00,500"
assert_file_contains "sync -500ms: 04,000 -> 03,500" "$out_file" "00:00:03,500"

# ══════════════════════════════════════════════════════════════════════════════
section "convert SRT -> VTT"

"$SUBSYNC" convert -f "$FIXTURES/basic.srt" --to vtt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.vtt"
assert_file_exists "srt->vtt: fichier cree" "$out_file"
assert_file_contains "srt->vtt: header WEBVTT" "$out_file" "^WEBVTT"
assert_file_contains "srt->vtt: point au lieu de virgule" "$out_file" '00:00:01\.000'
assert_file_not_contains "srt->vtt: pas de virgule dans timestamp" "$out_file" '00:00:01,000'
assert_file_contains "srt->vtt: texte conserve" "$out_file" "Willkommen"

section "convert SRT -> ASS"

"$SUBSYNC" convert -f "$FIXTURES/basic.srt" --to ass -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.ass"
assert_file_exists "srt->ass: fichier cree" "$out_file"
assert_file_contains "srt->ass: Script Info" "$out_file" "Script Info"
assert_file_contains "srt->ass: V4+ Styles" "$out_file" "V4\+ Styles"
assert_file_contains "srt->ass: Dialogue lines" "$out_file" "^Dialogue:"
assert_file_contains "srt->ass: texte conserve" "$out_file" "Willkommen"
assert_file_contains "srt->ass: multiline \\N" "$out_file" '\\N'

section "convert ASS -> SRT"

"$SUBSYNC" convert -f "$FIXTURES/sample.ass" --to srt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/sample.srt"
assert_file_exists "ass->srt: fichier cree" "$out_file"
assert_file_contains "ass->srt: timestamps SRT" "$out_file" '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> '
assert_file_contains "ass->srt: texte conserve" "$out_file" "Hello world"
assert_file_not_contains "ass->srt: pas de Dialogue:" "$out_file" "^Dialogue:"

section "convert VTT -> SRT"

"$SUBSYNC" convert -f "$TMP_DIR/basic.vtt" --to srt -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.srt"
assert_file_exists "vtt->srt: fichier cree" "$out_file"
assert_file_contains "vtt->srt: virgule dans timestamp" "$out_file" '00:00:01,000'
assert_file_not_contains "vtt->srt: pas de WEBVTT" "$out_file" "WEBVTT"

# ══════════════════════════════════════════════════════════════════════════════
section "merge"

"$SUBSYNC" merge -f "$FIXTURES/basic.srt" --merge-with "$FIXTURES/basic_fr.srt" -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.dual.srt"
assert_file_exists "merge: fichier cree" "$out_file"
assert_file_contains "merge: texte principal (DE)" "$out_file" "Willkommen"
assert_file_contains "merge: texte secondaire (FR) en italique" "$out_file" "<i>Bienvenue"
assert_file_contains "merge: timestamps conserves" "$out_file" "00:00:01,000 --> 00:00:03,500"

# Verifier que chaque bloc a les deux langues
block_count=$(grep -c "Willkommen\|Regale\|Pause\|Discounter\|Angebote" "$out_file" || true)
fr_count=$(grep -c "Bienvenue\|rayons\|pause\|discounter\|offres" "$out_file" || true)
if [[ "$block_count" -gt 0 && "$fr_count" -gt 0 ]]; then
    assert "merge: les deux langues presentes" 0
else
    assert "merge: les deux langues presentes" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "fix"

"$SUBSYNC" fix -f "$FIXTURES/broken.srt" -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/broken.fixed.srt"
assert_file_exists "fix: fichier cree" "$out_file"

# Verifier renumerotation sequentielle (1, 2, 3...)
first_num=$(head -1 "$out_file")
assert_exit_code "fix: premier bloc = 1" "1" "$first_num"

# Verifier que les chevauchements sont corriges
overlap_check=$(python3 -c "
import re
with open('$out_file') as f:
    content = f.read()
times = re.findall(r'(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})', content)
def to_ms(ts):
    h,m,rest = ts.split(':')
    s,ms = rest.split(',')
    return int(h)*3600000+int(m)*60000+int(s)*1000+int(ms)
ok = True
for i in range(len(times)-1):
    end = to_ms(times[i][1])
    next_start = to_ms(times[i+1][0])
    if end > next_start:
        ok = False
        break
print('0' if ok else '1')
" 2>/dev/null)
assert "fix: pas de chevauchement apres fix" "$overlap_check"

# Verifier encodage UTF-8
encoding=$(file --mime-encoding "$out_file" 2>/dev/null | awk -F': ' '{print $2}')
if [[ "$encoding" == "utf-8" || "$encoding" == "us-ascii" ]]; then
    assert "fix: encodage UTF-8" 0
else
    assert "fix: encodage UTF-8" 1
fi

# ══════════════════════════════════════════════════════════════════════════════
section "Smart parsing (get)"

# Fonction helper pour tester le parsing sans reseau
test_parse() {
    local query="$1" expected_mode="$2" expected_title="${3:-}" expected_season="${4:-}" expected_ep="${5:-}" expected_ep_end="${6:-}" expected_imdb="${7:-}"
    local out
    out=$("$SUBSYNC" get -q "$query" -l fr --sources "" 2>&1 || true)

    local ok=true desc="parse: \"$query\""

    if ! echo "$out" | grep -qi "Mode:.*$expected_mode"; then
        ok=false; desc+=" [mode=$expected_mode FAIL]"
    fi
    if [[ -n "$expected_title" ]] && ! echo "$out" | grep -q "Titre: $expected_title"; then
        ok=false; desc+=" [titre FAIL]"
    fi
    if [[ -n "$expected_season" ]] && ! echo "$out" | grep -q "Saison: $expected_season"; then
        ok=false; desc+=" [saison FAIL]"
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
test_parse "Die Discounter S01"                           "Saison"   "Die Discounter"     "1"
test_parse "Die Discounter S01E03-E08"                    "Range"    "Die Discounter"     "1"     "3" "8"
test_parse "Die Discounter S2E10"                         "Episode"  "Die Discounter"     "2"     "10"
test_parse "Inception 2010"                               "Film"     "Inception"
test_parse "Die Discounter 1x05"                          "Episode"  "Die Discounter"     "1"     "05"
test_parse "Die Discounter saison 2"                      "Saison"   "Die Discounter"     "2"
test_parse "Die Discounter season 1 ep 5"                 "Episode"  "Die Discounter"     "1"     "5"
test_parse "Breaking Bad S05E14-E16"                      "Range"    "Breaking Bad"       "5"     "14" "16"
test_parse "tt16463942 S01E01"                            "Episode"  ""                   "1"     "1"  ""   "tt16463942"
test_parse "tt16463942"                                   "Film"     ""                   ""      ""   ""   "tt16463942"
test_parse "The Office S03"                               "Saison"   "The Office"         "3"
test_parse "Parasite"                                     "Film"     "Parasite"
test_parse "Dark S01E01-E10"                              "Range"    "Dark"               "1"     "1"  "10"

# ══════════════════════════════════════════════════════════════════════════════
section "extract (ffmpeg)"

if command -v ffmpeg &>/dev/null; then
    # Creer une video de test avec sous-titres embedded
    test_video="$TMP_DIR/test_video.mkv"
    ffmpeg -v quiet -f lavfi -i "color=black:s=320x240:d=5" \
        -i "$FIXTURES/basic.srt" \
        -c:v libx264 -preset ultrafast -c:s srt \
        -metadata:s:s:0 language=de \
        "$test_video" -y 2>/dev/null

    if [[ -f "$test_video" ]]; then
        out=$("$SUBSYNC" extract -f "$test_video" --track 0 -o "$TMP_DIR" 2>&1)
        extract_file=$(find "$TMP_DIR" -name "test_video.*.srt" | head -1)
        assert_file_exists "extract: sous-titres extraits" "${extract_file:-/nonexistent}"
        if [[ -n "$extract_file" ]]; then
            assert_file_contains "extract: contenu correct" "$extract_file" "Willkommen"
        fi
    else
        assert "extract: video de test creee" 1
    fi

    # Test embed
    section "embed (ffmpeg)"
    embed_out="$TMP_DIR/test_video.subbed.mkv"
    "$SUBSYNC" embed -f "$test_video" --sub "$FIXTURES/basic_fr.srt" -l fr -o "$TMP_DIR" 2>&1
    assert_file_exists "embed: video avec subs creee" "$embed_out"

    if [[ -f "$embed_out" ]]; then
        # Verifier que la video a des sous-titres
        sub_count=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$embed_out" 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('streams',[])))" 2>/dev/null || echo 0)
        if [[ "$sub_count" -gt 0 ]]; then
            assert "embed: video contient des sous-titres" 0
        else
            assert "embed: video contient des sous-titres" 1
        fi
    fi
else
    printf "  ${YELLOW}SKIP${NC}  extract/embed: ffmpeg non disponible\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "translate (API - optionnel)"

if [[ -n "${ZAI_API_KEY:-}" ]]; then
    "$SUBSYNC" translate -f "$FIXTURES/basic.srt" -l fr --from de -p zai-codeplan -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.fr.srt"
    assert_file_exists "translate zai-codeplan: fichier cree" "$out_file"
    assert_file_contains "translate zai-codeplan: contient timestamps" "$out_file" '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}'
    # Verifier que c'est bien du francais
    sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$out_file" | head -5 | tr '\n' ' ')
    if echo "$sample" | grep -qiE '\b(le|la|les|des|est|une|que|pas|avec|dans|chez|ici)\b'; then
        assert "translate zai-codeplan: resultat en francais" 0
    else
        assert "translate zai-codeplan: resultat en francais" 1
    fi

    # Verifier que le nombre de blocs est conserve
    src_blocks=$(grep -cE '^[0-9]+$' "$FIXTURES/basic.srt" || true)
    dst_blocks=$(grep -cE '^[0-9]+$' "$out_file" || true)
    if [[ "$src_blocks" -eq "$dst_blocks" ]]; then
        assert "translate zai-codeplan: meme nombre de blocs ($src_blocks)" 0
    else
        assert "translate zai-codeplan: meme nombre de blocs (src=$src_blocks dst=$dst_blocks)" 1
    fi
else
    printf "  ${YELLOW}SKIP${NC}  translate zai-codeplan: ZAI_API_KEY non definie\n"
fi

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    "$SUBSYNC" translate -f "$FIXTURES/basic.srt" -l en --from de -p openai -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate openai: fichier cree" "$out_file"
    assert_file_contains "translate openai: contient timestamps" "$out_file" '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}'
else
    printf "  ${YELLOW}SKIP${NC}  translate openai: OPENAI_API_KEY non definie\n"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    "$SUBSYNC" translate -f "$FIXTURES/basic.srt" -l en --from de -p claude -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate claude: fichier cree" "$out_file"
else
    printf "  ${YELLOW}SKIP${NC}  translate claude: ANTHROPIC_API_KEY non definie\n"
fi

if [[ -n "${MISTRAL_API_KEY:-}" ]]; then
    "$SUBSYNC" translate -f "$FIXTURES/basic.srt" -l en --from de -p mistral -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate mistral: fichier cree" "$out_file"
else
    printf "  ${YELLOW}SKIP${NC}  translate mistral: MISTRAL_API_KEY non definie\n"
fi

if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    "$SUBSYNC" translate -f "$FIXTURES/basic.srt" -l en --from de -p gemini -o "$TMP_DIR" 2>&1
    out_file="$TMP_DIR/basic.en.srt"
    assert_file_exists "translate gemini: fichier cree" "$out_file"
else
    printf "  ${YELLOW}SKIP${NC}  translate gemini: GEMINI_API_KEY non definie\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "search (API - optionnel)"

if [[ -n "${OPENSUBTITLES_API_KEY:-}" ]]; then
    out=$("$SUBSYNC" search -q "Inception" -l en -e 0 2>&1 </dev/null || true)
    assert_output_contains "search opensubtitles: resultats" "$out" "Sous-titres trouves\|Aucun"
else
    printf "  ${YELLOW}SKIP${NC}  search: OPENSUBTITLES_API_KEY non definie\n"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "Cas limites"

# sync avec shift negatif qui irait sous zero
"$SUBSYNC" sync -f "$FIXTURES/basic.srt" --shift -5000 -o "$TMP_DIR" 2>&1
out_file="$TMP_DIR/basic.synced.srt"
assert_file_contains "sync negatif: pas de timestamp negatif" "$out_file" "00:00:00,000"
assert_file_not_contains "sync negatif: pas de timestamp -" "$out_file" "^-"

# convert roundtrip SRT -> VTT -> SRT
"$SUBSYNC" convert -f "$FIXTURES/basic.srt" --to vtt -o "$TMP_DIR" 2>&1
"$SUBSYNC" convert -f "$TMP_DIR/basic.vtt" --to srt -o "$TMP_DIR" 2>&1
roundtrip="$TMP_DIR/basic.srt"
assert_file_contains "roundtrip srt->vtt->srt: timestamps OK" "$roundtrip" "00:00:01,000"
assert_file_contains "roundtrip srt->vtt->srt: texte OK" "$roundtrip" "Willkommen"

# convert roundtrip SRT -> ASS -> SRT
"$SUBSYNC" convert -f "$FIXTURES/basic.srt" --to ass -o "$TMP_DIR" 2>&1
"$SUBSYNC" convert -f "$TMP_DIR/basic.ass" --to srt -o "$TMP_DIR" 2>&1
roundtrip="$TMP_DIR/basic.srt"
assert_file_contains "roundtrip srt->ass->srt: texte OK" "$roundtrip" "Willkommen"

# info sur fichier inexistant
out=$("$SUBSYNC" info -f /nonexistent/file.srt 2>&1 || true)
assert_output_contains "info fichier inexistant: erreur" "$out" "introuvable"

# translate sans --from (defaut en)
# Just test that parse works, don't need actual translation
out=$("$SUBSYNC" translate -f /nonexistent.srt -l fr 2>&1 || true)
assert_output_contains "translate fichier inexistant: erreur" "$out" "introuvable"

# ══════════════════════════════════════════════════════════════════════════════
# RESULTATS
# ══════════════════════════════════════════════════════════════════════════════
printf "\n${BOLD}══════════════════════════════════════════${NC}\n"
printf "${BOLD}  Resultats: %d tests${NC}\n" "$TESTS_RUN"
printf "  ${GREEN}Passed: %d${NC}\n" "$TESTS_PASSED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    printf "  ${RED}Failed: %d${NC}\n" "$TESTS_FAILED"
    printf "\n${RED}Echecs:${NC}\n"
    printf "%b" "$FAILURES"
    printf "${BOLD}══════════════════════════════════════════${NC}\n"
    exit 1
else
    printf "  ${RED}Failed: 0${NC}\n"
    printf "${BOLD}══════════════════════════════════════════${NC}\n"
    exit 0
fi
