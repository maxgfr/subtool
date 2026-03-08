#!/usr/bin/env bash
set -euo pipefail

VERSION="1.7.0"
SCRIPT_NAME="$(basename "$0")"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/subtool"
CONFIG_FILE="$CONFIG_DIR/config"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/subtool"

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
LANG_TARGET=""
AI_PROVIDER="google"
SEARCH_QUERY=""
IMDB_ID=""
FILE_PATH=""
SEASON=""
EPISODE=""
OUTPUT_DIR="."
FORCE_TRANSLATE=false
SOURCES="opensubtitles-org,podnapisi"
FALLBACK_LANGS="en,de,es,pt"
MAX_EPISODE=20
AI_MODEL=""
AUTO_SELECT=false
AUTO_EMBED=false
DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false
QUIET=false
SUBTITLE_URL=""

# ── Modeles par defaut ────────────────────────────────────────────────────────
MODEL_ZAI_CODEPLAN="glm-4.7"
MODEL_OPENAI="gpt-5-mini"
MODEL_CLAUDE="claude-haiku-4-5"
MODEL_MISTRAL="mistral-small-latest"
MODEL_GEMINI="gemini-2.5-flash"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { { $QUIET && return; printf "${GREEN}[+]${NC} %s\n" "$*"; } || true; }
warn()   { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()    { printf "${RED}[x]${NC} %s\n" "$*" >&2; }
info()   { { $QUIET && return; printf "${CYAN}[i]${NC} %s\n" "$*"; } || true; }
debug()  { $VERBOSE && printf "${BLUE}[D]${NC} %s\n" "$*" >&2 || true; }
header() { { $QUIET && return; printf "\n${BOLD}${BLUE}── %s ──${NC}\n" "$*"; } || true; }

die() { err "$1"; exit 1; }

# URL encode (pure bash via jq)
urlencode() { jq -sRr @uri <<< "$1" | sed 's/%0A$//'; }

# Retry wrapper for API calls (handles 429 / transient errors)
# Usage: api_retry curl -sf "https://..."
api_retry() {
    local max_retries=3 retry_delay=2 attempt=0
    local output rc
    while [[ $attempt -lt $max_retries ]]; do
        output=$("$@" 2>&1) && { echo "$output"; return 0; }
        rc=$?
        if echo "$output" | grep -q "429\|rate.limit\|Too Many"; then
            ((attempt++)) || true
            debug "Rate limited, retry $attempt/$max_retries in ${retry_delay}s..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
        else
            echo "$output"
            return $rc
        fi
    done
    echo "$output"
    return 1
}

# Detect language from subtitle text
detect_lang() {
    local sample="$1"
    if echo "$sample" | grep -qiE '\b(the|and|is|are|you|that|this|have|with)\b'; then echo "en"
    elif echo "$sample" | grep -qiE '\b(le|la|les|des|est|une|que|pas|avec|dans)\b'; then echo "fr"
    elif echo "$sample" | grep -qiE '\b(der|die|das|und|ist|ein|nicht|ich|mit|auf)\b'; then echo "de"
    elif echo "$sample" | grep -qiE '\b(el|la|los|las|que|del|una|por|con|para)\b'; then echo "es"
    elif echo "$sample" | grep -qiE '\b(il|la|che|non|per|una|con|sono|del|questo)\b'; then echo "it"
    elif echo "$sample" | grep -qiE '\b(o|que|de|da|em|um|uma|com|para|por)\b'; then echo "pt"
    fi
}

# Validate SRT format (returns 0 if valid, 1 if broken)
validate_srt() {
    local file="$1"
    [[ ! -s "$file" ]] && return 1
    # Must have at least one timestamp line
    grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}[,\.][0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2}[,\.][0-9]{3}' "$file" || return 1
    # Must have at least one numeric index (tolerate BOM and \r)
    grep -qE '^(\xef\xbb\xbf)?[0-9]+\r?$' "$file" || return 1
    return 0
}

# ── Config ────────────────────────────────────────────────────────────────────
init_config() {
    mkdir -p "$CONFIG_DIR" "$CACHE_DIR"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << 'CONF'
# subtool configuration

# API keys pour la traduction AI (optionnel — claude-code fonctionne sans cle)
OPENAI_API_KEY=""
ANTHROPIC_API_KEY=""
MISTRAL_API_KEY=""
GEMINI_API_KEY=""
ZAI_API_KEY=""

# Provider AI par defaut: claude-code, zai-codeplan, openai, claude, mistral, gemini
DEFAULT_AI_PROVIDER="google"  # ou: claude-code, openai, claude, mistral, gemini

# Modeles par defaut (laisser vide pour utiliser les valeurs par defaut)
MODEL_CLAUDE_CODE=""
MODEL_ZAI_CODEPLAN=""
MODEL_OPENAI=""
MODEL_CLAUDE=""
MODEL_MISTRAL=""
MODEL_GEMINI=""
CONF
        info "Config creee: $CONFIG_FILE"
    fi
}

load_config() {
    init_config
    # Sauvegarder les vars d'env existantes avant source
    local _saved_openai="${OPENAI_API_KEY:-}"
    local _saved_anthropic="${ANTHROPIC_API_KEY:-}"
    local _saved_mistral="${MISTRAL_API_KEY:-}"
    local _saved_gemini="${GEMINI_API_KEY:-}"
    local _saved_zai="${ZAI_API_KEY:-}"
    # shellcheck source=/dev/null
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    # Les vars d'env ont priorite sur le fichier config
    [[ -n "$_saved_openai" ]] && OPENAI_API_KEY="$_saved_openai"
    [[ -n "$_saved_anthropic" ]] && ANTHROPIC_API_KEY="$_saved_anthropic"
    [[ -n "$_saved_mistral" ]] && MISTRAL_API_KEY="$_saved_mistral"
    [[ -n "$_saved_gemini" ]] && GEMINI_API_KEY="$_saved_gemini"
    [[ -n "$_saved_zai" ]] && ZAI_API_KEY="$_saved_zai"
    # Restaurer les modeles par defaut si le config les a mis a vide
    [[ -z "${MODEL_CLAUDE_CODE:-}" ]] && MODEL_CLAUDE_CODE="haiku"
    [[ -z "$MODEL_ZAI_CODEPLAN" ]] && MODEL_ZAI_CODEPLAN="glm-4.7"
    [[ -z "$MODEL_OPENAI" ]] && MODEL_OPENAI="gpt-4o"
    [[ -z "$MODEL_CLAUDE" ]] && MODEL_CLAUDE="claude-sonnet-4-20250514"
    [[ -z "$MODEL_MISTRAL" ]] && MODEL_MISTRAL="mistral-large-latest"
    [[ -z "$MODEL_GEMINI" ]] && MODEL_GEMINI="gemini-2.0-flash"
    AI_PROVIDER="${DEFAULT_AI_PROVIDER:-google}"
}

# ── OpenSubtitles.org (gratuit, sans cle API) ─────────────────────────────────
search_opensubtitles_org() {
    local query="$1" lang="$2" imdb_id="${3:-}" season="${4:-}" episode="${5:-}"

    # Mapping langue -> code 3 lettres OpenSubtitles
    local lang3
    case "$lang" in
        fr|fre|fra) lang3="fre" ;; en|eng)     lang3="eng" ;; es|spa)     lang3="spa" ;;
        de|ger|deu) lang3="ger" ;; it|ita)     lang3="ita" ;; pt|por)     lang3="por" ;;
        ru|rus)     lang3="rus" ;; ar|ara)     lang3="ara" ;; ja|jpn)     lang3="jpn" ;;
        ko|kor)     lang3="kor" ;; zh|chi|zho) lang3="chi" ;; nl|dut|nld) lang3="dut" ;;
        pl|pol)     lang3="pol" ;; sv|swe)     lang3="swe" ;; da|dan)     lang3="dan" ;;
        fi|fin)     lang3="fin" ;; no|nor)     lang3="nor" ;; tr|tur)     lang3="tur" ;;
        *)          lang3="$lang" ;;
    esac

    # L'API .org exige du lowercase sinon 302 vers host invalide
    local lower_query
    lower_query=$(echo "$query" | tr '[:upper:]' '[:lower:]')
    local encoded_query
    encoded_query=$(urlencode "$lower_query")

    # L'API .org ne supporte pas query + season + episode dans le meme path
    # On cherche par query + langue, puis on filtre cote client
    local url="https://rest.opensubtitles.org/search/query-${encoded_query}/sublanguageid-${lang3}"

    local resp
    resp=$(curl -sf "$url" -H "User-Agent: subtool v${VERSION}" 2>/dev/null) || return 1

    local count
    count=$(echo "$resp" | jq 'length' 2>/dev/null) || true
    [[ "$count" == "0" || -z "$count" ]] && return 1

    # Filtre saison/episode cote client si demande
    local filtered
    if [[ -n "$season" && -n "$episode" ]]; then
        filtered=$(echo "$resp" | jq -c --arg s "$season" --arg e "$episode" \
            '[.[] | select(.SeriesSeason == $s and .SeriesEpisode == $e)]' 2>/dev/null) || true
    elif [[ -n "$season" ]]; then
        filtered=$(echo "$resp" | jq -c --arg s "$season" \
            '[.[] | select(.SeriesSeason == $s)]' 2>/dev/null) || true
    else
        filtered="$resp"
    fi

    local fcount
    fcount=$(echo "$filtered" | jq 'length' 2>/dev/null) || true
    [[ "$fcount" == "0" || -z "$fcount" ]] && return 1

    echo "$filtered" | jq -c '.[] | {
        id: .SubDownloadLink,
        name: .SubFileName,
        lang: .LanguageName,
        source: "opensubtitles-org",
        downloads: (.SubDownloadsCnt | tonumber),
        rating: (.SubRating | tonumber)
    }' 2>/dev/null || true
}

download_opensubtitles_org() {
    local download_link="$1" output="$2"
    local tmp_gz="$CACHE_DIR/osorg_$$.gz"
    curl -sf -o "$tmp_gz" "$download_link" \
        -H "User-Agent: subtool v${VERSION}" 2>/dev/null || return 1
    gunzip -f "$tmp_gz" 2>/dev/null || return 1
    mv "${tmp_gz%.gz}" "$output" 2>/dev/null || return 1
}

# ── Download from OpenSubtitles.org page URL ──────────────────────────────────
download_from_url() {
    local url="$1" output="$2"

    # Accept various opensubtitles.org URL formats:
    # https://www.opensubtitles.org/en/subtitles/1234567/...
    # https://www.opensubtitles.org/en/subtitleserve/sub/1234567
    # https://dl.opensubtitles.org/en/download/sub/1234567
    local sub_id=""

    if [[ "$url" =~ opensubtitles\.org/[a-z]{2}/subtitles/([0-9]+) ]]; then
        sub_id="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ opensubtitles\.org/[a-z]{2}/subtitleserve/sub/([0-9]+) ]]; then
        sub_id="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ opensubtitles\.org/[a-z]{2}/download/sub/([0-9]+) ]]; then
        sub_id="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ ^https?:// ]]; then
        # Generic URL — try direct download (might be .srt, .gz, .zip)
        local tmp_file="$CACHE_DIR/url_download_$$"
        curl -sfL -o "$tmp_file" "$url" -H "User-Agent: subtool v${VERSION}" 2>/dev/null || { err "Echec telechargement: $url"; return 1; }
        # Detect file type
        local ftype
        ftype=$(file -b "$tmp_file" 2>/dev/null)
        if [[ "$ftype" == *gzip* ]]; then
            mv "$tmp_file" "${tmp_file}.gz"
            gunzip -f "${tmp_file}.gz" 2>/dev/null || { rm -f "${tmp_file}.gz"; return 1; }
            mv "$tmp_file" "$output"
        elif [[ "$ftype" == *Zip* ]]; then
            local tmp_dir="$CACHE_DIR/url_extract_$$"
            mkdir -p "$tmp_dir"
            unzip -qo "$tmp_file" -d "$tmp_dir" 2>/dev/null
            local srt_found
            srt_found=$(/usr/bin/find "$tmp_dir" -iname "*.srt" | head -1)
            if [[ -n "$srt_found" ]]; then
                mv "$srt_found" "$output"
            fi
            rm -rf "$tmp_dir" "$tmp_file"
        else
            mv "$tmp_file" "$output"
        fi
        [[ -s "$output" ]] && return 0 || return 1
    else
        err "URL non reconnue: $url"
        return 1
    fi

    # OpenSubtitles.org subtitle ID download
    if [[ -n "$sub_id" ]]; then
        local dl_url="https://dl.opensubtitles.org/en/download/sub/${sub_id}"
        local tmp_gz="$CACHE_DIR/url_${sub_id}_$$.gz"
        curl -sfL -o "$tmp_gz" "$dl_url" -H "User-Agent: subtool v${VERSION}" 2>/dev/null || { err "Echec telechargement: $dl_url"; return 1; }
        # The response might be a zip file
        local ftype
        ftype=$(file -b "$tmp_gz" 2>/dev/null)
        if [[ "$ftype" == *gzip* ]]; then
            gunzip -f "$tmp_gz" 2>/dev/null || return 1
            mv "${tmp_gz%.gz}" "$output" 2>/dev/null || return 1
        elif [[ "$ftype" == *Zip* ]]; then
            local tmp_dir="$CACHE_DIR/url_extract_$$"
            mkdir -p "$tmp_dir"
            unzip -qo "$tmp_gz" -d "$tmp_dir" 2>/dev/null
            local srt_found
            srt_found=$(/usr/bin/find "$tmp_dir" -iname "*.srt" | head -1)
            if [[ -n "$srt_found" ]]; then
                mv "$srt_found" "$output"
            fi
            rm -rf "$tmp_dir" "$tmp_gz"
            [[ -s "$output" ]] || return 1
        else
            mv "$tmp_gz" "$output" 2>/dev/null || return 1
        fi
    fi
}

# ── Podnapisi ─────────────────────────────────────────────────────────────────
search_podnapisi() {
    local query="$1" lang="$2"
    local lang_code
    # Podnapisi utilise des codes langue specifiques
    case "$lang" in
        fr|fre|fra) lang_code="8" ;;
        en|eng)     lang_code="2" ;;
        es|spa)     lang_code="28" ;;
        de|ger|deu) lang_code="5" ;;
        it|ita)     lang_code="9" ;;
        pt|por)     lang_code="23" ;;
        ru|rus)     lang_code="27" ;;
        ar|ara)     lang_code="26" ;;
        ja|jpn)     lang_code="11" ;;
        ko|kor)     lang_code="4" ;;
        zh|chi|zho) lang_code="17" ;;
        *)          lang_code="$lang" ;;
    esac

    local encoded_query
    encoded_query=$(urlencode "$query")

    local resp
    resp=$(curl -sf "https://www.podnapisi.net/subtitles/search/old?keywords=$encoded_query&language=$lang_code&output_type=json" 2>/dev/null) || return 1

    local count
    count=$(echo "$resp" | jq '.subtitles | length' 2>/dev/null)
    [[ "$count" == "0" || -z "$count" ]] && return 1

    echo "$resp" | jq -c '.subtitles[]? | {
        id: .id,
        name: .release,
        lang: .languageName,
        source: "podnapisi",
        downloads: .downloads,
        rating: .rating
    }' 2>/dev/null
}

download_podnapisi() {
    local sub_id="$1" output="$2"
    local tmp_zip="$CACHE_DIR/podnapisi_${sub_id}.zip"
    curl -sf -o "$tmp_zip" "https://www.podnapisi.net/subtitles/${sub_id}/download" 2>/dev/null || return 1

    local tmp_dir="$CACHE_DIR/podnapisi_extract_$$"
    mkdir -p "$tmp_dir"
    unzip -qo "$tmp_zip" -d "$tmp_dir" 2>/dev/null || { rm -rf "$tmp_dir" "$tmp_zip"; return 1; }
    local srt_file
    srt_file=$(find "$tmp_dir" -name "*.srt" -o -name "*.ass" -o -name "*.sub" | head -1)
    if [[ -n "$srt_file" ]]; then
        mv "$srt_file" "$output" && rm -rf "$tmp_dir" "$tmp_zip"
    else
        rm -rf "$tmp_dir" "$tmp_zip"
        return 1
    fi
}

# ── Recherche multi-source ────────────────────────────────────────────────────
search_all_sources() {
    local query="$1" lang="$2" imdb_id="${3:-}" season="${4:-}" episode="${5:-}"
    local results=""
    local found=false

    IFS=',' read -ra source_list <<< "$SOURCES"
    for source in "${source_list[@]}"; do
        source=$(echo "$source" | tr -d ' ')
        info "Recherche sur ${BOLD}$source${NC}..." >&2
        local result=""
        case "$source" in
            opensubtitles-org)
                result=$(search_opensubtitles_org "$query" "$lang" "$imdb_id" "$season" "$episode") ;;
            podnapisi)
                result=$(search_podnapisi "$query" "$lang") ;;
            *)
                warn "Source inconnue: $source" ;;
        esac
        if [[ -n "$result" ]]; then
            found=true
            results+="$result"$'\n'
        fi
    done

    if $found; then
        echo "$results"
    fi
    $found
}

# ── Selection interactive ─────────────────────────────────────────────────────
select_subtitle() {
    local results="$1"
    local entries=()
    local i=1

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name src_name downloads
        name=$(echo "$line" | jq -r '.name // "N/A"' 2>/dev/null)
        src_name=$(echo "$line" | jq -r '.source // "?"' 2>/dev/null)
        downloads=$(echo "$line" | jq -r '.downloads // 0' 2>/dev/null)
        [[ -z "$name" || "$name" == "null" ]] && continue
        entries+=("$line")
        ((i++)) || true
    done <<< "$results"

    if [[ ${#entries[@]} -eq 0 ]]; then
        return 1
    fi

    # JSON output mode
    if $JSON_OUTPUT; then
        printf '['
        for ((j=0; j<${#entries[@]}; j++)); do
            [[ $j -gt 0 ]] && printf ','
            echo "${entries[$j]}"
        done
        printf ']\n'
        return 1  # don't proceed to download in JSON mode
    fi

    # Auto-select first result
    if $AUTO_SELECT; then
        debug "Auto-select: premier resultat"
        echo "${entries[0]}"
        return 0
    fi

    # Dry-run: just display results
    if $DRY_RUN; then
        header "Sous-titres trouves"
        for ((j=0; j<${#entries[@]}; j++)); do
            local name src_name downloads
            name=$(echo "${entries[$j]}" | jq -r '.name // "N/A"' 2>/dev/null)
            src_name=$(echo "${entries[$j]}" | jq -r '.source // "?"' 2>/dev/null)
            downloads=$(echo "${entries[$j]}" | jq -r '.downloads // 0' 2>/dev/null)
            printf "  ${BOLD}%2d${NC}) [${CYAN}%-15s${NC}] %s ${YELLOW}(%s DL)${NC}\n" "$((j+1))" "$src_name" "$name" "$downloads"
        done
        return 1
    fi

    # Interactive selection
    header "Sous-titres trouves"
    for ((j=0; j<${#entries[@]}; j++)); do
        local name src_name downloads
        name=$(echo "${entries[$j]}" | jq -r '.name // "N/A"' 2>/dev/null)
        src_name=$(echo "${entries[$j]}" | jq -r '.source // "?"' 2>/dev/null)
        downloads=$(echo "${entries[$j]}" | jq -r '.downloads // 0' 2>/dev/null)
        printf "  ${BOLD}%2d${NC}) [${CYAN}%-15s${NC}] %s ${YELLOW}(%s DL)${NC}\n" "$((j+1))" "$src_name" "$name" "$downloads"
    done

    printf "\n"
    local choice
    read -rp "$(printf "${BOLD}Choix [1-${#entries[@]}]:${NC} ")" choice
    [[ -z "$choice" ]] && choice=1

    if [[ "$choice" -ge 1 && "$choice" -le ${#entries[@]} ]] 2>/dev/null; then
        echo "${entries[$((choice-1))]}"
    else
        err "Choix invalide"
        return 1
    fi
}

# ── Download dispatcher ──────────────────────────────────────────────────────
download_subtitle() {
    local entry="$1" output="$2"
    local source id
    source=$(echo "$entry" | jq -r '.source')
    id=$(echo "$entry" | jq -r '.id')

    case "$source" in
        opensubtitles-org) download_opensubtitles_org "$id" "$output" ;;
        podnapisi)         download_podnapisi "$id" "$output" ;;
        *) err "Source inconnue: $source"; return 1 ;;
    esac
}

# ── Traduction AI ─────────────────────────────────────────────────────────────

# Decoupe un fichier SRT en chunks pour ne pas depasser les limites d'API
chunk_srt() {
    local file="$1" max_lines="${2:-200}"
    local chunk_num=0
    local line_count=0
    local current_chunk=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        current_chunk+="$line"$'\n'
        ((line_count++))

        # Split on SRT block boundary (blank line) when we have enough lines
        if [[ "$line" =~ ^[[:space:]]*$ ]] && [[ $line_count -ge $max_lines ]]; then
            printf '%s' "$current_chunk" > "$CACHE_DIR/chunk_${chunk_num}.srt"
            ((chunk_num++))
            line_count=0
            current_chunk=""
        fi
    done < "$file"

    # Dernier chunk
    if [[ -n "$current_chunk" ]]; then
        printf '%s' "$current_chunk" > "$CACHE_DIR/chunk_${chunk_num}.srt"
        ((chunk_num++))
    fi

    echo "$chunk_num"
}

_translate_prompt() {
    echo "Translate this SRT subtitle file from $1 to $2. Keep ALL SRT formatting intact (numbers, timestamps, blank lines). Only translate the text lines. Output ONLY the translated SRT content, nothing else."
}

translate_with_google() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"

    if ! command -v trans &>/dev/null; then
        die "translate-shell requis. Installe-le: brew install translate-shell"
    fi

    # Step 1: Extract only text lines from SRT (skip indices, timestamps, blanks)
    # Store line numbers to map back later
    local text_file="$CACHE_DIR/trans_text_$$.txt"
    local map_file="$CACHE_DIR/trans_map_$$.txt"
    : > "$text_file"
    : > "$map_file"

    local lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno++)) || true
        line="${line%$'\r'}"
        # Skip: blank lines, subtitle indices (bare numbers), timestamps
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || [[ "$line" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
            continue
        fi
        echo "$line" >> "$text_file"
        echo "$lineno" >> "$map_file"
    done < "$input"

    local total_text
    total_text=$(wc -l < "$text_file" | tr -d ' ')
    info "Google Translate: $total_text lignes de texte a traduire"

    # Step 2: Split text into chunks and translate in parallel
    local chunk_size=80
    local num_chunks=$(( (total_text + chunk_size - 1) / chunk_size ))
    local max_parallel=8
    info "$num_chunks chunks (max $max_parallel en parallele)"

    # Split text file into chunks
    local i=0
    while ((i < num_chunks)); do
        local start=$((i * chunk_size + 1))
        sed -n "${start},$((start + chunk_size - 1))p" "$text_file" > "$CACHE_DIR/trans_chunk_${i}.txt"
        ((i++)) || true
    done

    # Translate chunks in parallel
    for ((batch=0; batch<num_chunks; batch+=max_parallel)); do
        local pids=()
        local bend=$((batch + max_parallel))
        [[ $bend -gt $num_chunks ]] && bend=$num_chunks

        for ((j=batch; j<bend; j++)); do
            (
                trans -b "${src_lang}:${target_lang}" -i "$CACHE_DIR/trans_chunk_${j}.txt" \
                    > "$CACHE_DIR/trans_chunk_${j}_out.txt" 2>/dev/null
            ) &
            pids+=($!)
        done

        for pid in "${pids[@]}"; do
            wait "$pid" || true
        done

        info "Traduit: $((bend))/$num_chunks chunks"
    done

    # Step 3: Reassemble translated text
    local translated_file="$CACHE_DIR/trans_all_$$.txt"
    : > "$translated_file"
    for ((i=0; i<num_chunks; i++)); do
        local chunk_out="$CACHE_DIR/trans_chunk_${i}_out.txt"
        if [[ -s "$chunk_out" ]]; then
            cat "$chunk_out" >> "$translated_file"
        else
            # Fallback: keep original
            cat "$CACHE_DIR/trans_chunk_${i}.txt" >> "$translated_file"
        fi
        rm -f "$CACHE_DIR/trans_chunk_${i}.txt" "$CACHE_DIR/trans_chunk_${i}_out.txt"
    done

    # Step 4: Replace text lines in original SRT with translations
    # Build associative array: line_number -> translated_text
    local -A replacements=()
    local idx=0
    while IFS= read -r ln; do
        local trans_line=""
        trans_line=$(sed -n "$((idx+1))p" "$translated_file")
        replacements[$ln]="$trans_line"
        ((idx++)) || true
    done < "$map_file"

    # Write output: copy original, replacing text lines
    local lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno++)) || true
        if [[ -n "${replacements[$lineno]+x}" ]]; then
            printf '%s\n' "${replacements[$lineno]}"
        else
            printf '%s\n' "$line"
        fi
    done < "$input" > "$output"

    # Normalize: strip BOM + fix line endings to LF (ffmpeg chokes on mixed CRLF/LF and BOM)
    if [[ -s "$output" ]]; then
        sed -i '' -e '1s/^\xef\xbb\xbf//' -e $'s/\r$//' "$output"
    fi

    # Cleanup
    rm -f "$text_file" "$map_file" "$translated_file"
}

translate_with_claude_code() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    local model="${AI_MODEL:-$MODEL_CLAUDE_CODE}"
    info "Traduction avec Claude Code ($model, effort low)..."

    if ! command -v claude &>/dev/null; then
        err "claude CLI non installe. Installe-le: npm install -g @anthropic-ai/claude-code"
        return 1
    fi

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")
    local content
    content=$(<"$input")

    CLAUDECODE='' claude -p --model "$model" --effort low --tools "" "$prompt

$content" > "$output" 2>/dev/null
}

translate_with_zai_codeplan() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${ZAI_API_KEY:-}" ]] && { err "ZAI_API_KEY non configuree"; return 1; }
    local model="${AI_MODEL:-$MODEL_ZAI_CODEPLAN}"
    info "Traduction avec Z.ai Coding Plan ($model)..."

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")

    local resp
    resp=$(curl -sf "https://api.z.ai/api/coding/paas/v4/chat/completions" \
        -H "Authorization: Bearer $ZAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a professional subtitle translator. Preserve all SRT formatting exactly.\"},
                {\"role\": \"user\", \"content\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}
            ],
            \"temperature\": 0.3
        }" 2>/dev/null) || { err "Erreur API Z.ai"; return 1; }

    echo "$resp" | jq -r '.choices[0].message.content' > "$output"
}

translate_with_openai() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${OPENAI_API_KEY:-}" ]] && { err "OPENAI_API_KEY non configuree"; return 1; }
    local model="${AI_MODEL:-$MODEL_OPENAI}"
    info "Traduction avec OpenAI ($model)..."

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")

    local escaped_content
    escaped_content=$(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)

    local resp
    resp=$(curl -sf "https://api.openai.com/v1/chat/completions" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a professional subtitle translator. Preserve all SRT formatting exactly.\"},
                {\"role\": \"user\", \"content\": $escaped_content}
            ],
            \"temperature\": 0.3
        }" 2>/dev/null) || { err "Erreur API OpenAI"; return 1; }

    echo "$resp" | jq -r '.choices[0].message.content' > "$output"
}

translate_with_claude() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${ANTHROPIC_API_KEY:-}" ]] && { err "ANTHROPIC_API_KEY non configuree"; return 1; }
    local model="${AI_MODEL:-$MODEL_CLAUDE}"
    info "Traduction avec Claude API ($model)..."

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")

    local resp
    resp=$(curl -sf "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"max_tokens\": 8192,
            \"messages\": [
                {\"role\": \"user\", \"content\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}
            ]
        }" 2>/dev/null) || { err "Erreur API Claude"; return 1; }

    echo "$resp" | jq -r '.content[0].text' > "$output"
}

translate_with_mistral() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${MISTRAL_API_KEY:-}" ]] && { err "MISTRAL_API_KEY non configuree"; return 1; }
    local model="${AI_MODEL:-$MODEL_MISTRAL}"
    info "Traduction avec Mistral ($model)..."

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")

    local resp
    resp=$(curl -sf "https://api.mistral.ai/v1/chat/completions" \
        -H "Authorization: Bearer $MISTRAL_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"messages\": [
                {\"role\": \"user\", \"content\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}
            ],
            \"temperature\": 0.3
        }" 2>/dev/null) || { err "Erreur API Mistral"; return 1; }

    echo "$resp" | jq -r '.choices[0].message.content' > "$output"
}

translate_with_gemini() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${GEMINI_API_KEY:-}" ]] && { err "GEMINI_API_KEY non configuree"; return 1; }
    local model="${AI_MODEL:-$MODEL_GEMINI}"
    info "Traduction avec Gemini ($model)..."

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")

    local resp
    resp=$(curl -sf "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=$GEMINI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"contents\": [{
                \"parts\": [{\"text\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}]
            }],
            \"generationConfig\": {\"temperature\": 0.3}
        }" 2>/dev/null) || { err "Erreur API Gemini"; return 1; }

    echo "$resp" | jq -r '.candidates[0].content.parts[0].text' > "$output"
}

# Dispatch translation to the selected provider
_translate_dispatch() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4" provider="$5"
    case "$provider" in
        google)      translate_with_google "$input" "$output" "$src_lang" "$target_lang" ;;
        claude-code) translate_with_claude_code "$input" "$output" "$src_lang" "$target_lang" ;;
        zai-codeplan) translate_with_zai_codeplan "$input" "$output" "$src_lang" "$target_lang" ;;
        openai)      translate_with_openai "$input" "$output" "$src_lang" "$target_lang" ;;
        claude)      translate_with_claude "$input" "$output" "$src_lang" "$target_lang" ;;
        mistral)     translate_with_mistral "$input" "$output" "$src_lang" "$target_lang" ;;
        gemini)      translate_with_gemini "$input" "$output" "$src_lang" "$target_lang" ;;
        *) die "Provider inconnu: $provider" ;;
    esac
}

# Traduction principale avec chunking
translate_subtitle() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4" provider="$5"

    header "Traduction ($provider)"
    info "Source: $src_lang -> Cible: $target_lang"

    # Google provider handles its own SRT parsing + batching — no chunking needed
    if [[ "$provider" == "google" ]]; then
        _translate_dispatch "$input" "$output" "$src_lang" "$target_lang" "$provider"
    else
        local total_lines
        total_lines=$(wc -l < "$input" | tr -d ' ')
        if [[ $total_lines -le 300 ]]; then
            _translate_dispatch "$input" "$output" "$src_lang" "$target_lang" "$provider"
        else
            info "Fichier volumineux ($total_lines lignes), decoupage en chunks..."
            local num_chunks
            num_chunks=$(chunk_srt "$input" 150)
            local max_parallel=3
            info "$num_chunks chunks a traduire (max $max_parallel en parallele)"

            : > "$output"

            # Traduction parallele par lots
            for ((batch_start=0; batch_start<num_chunks; batch_start+=max_parallel)); do
                local pids=()
                local batch_end=$((batch_start + max_parallel))
                [[ $batch_end -gt $num_chunks ]] && batch_end=$num_chunks

                for ((i=batch_start; i<batch_end; i++)); do
                    local chunk_in="$CACHE_DIR/chunk_${i}.srt"
                    local chunk_out="$CACHE_DIR/chunk_${i}_translated.srt"
                    info "Chunk $((i+1))/$num_chunks (parallele)..."
                    _translate_dispatch "$chunk_in" "$chunk_out" "$src_lang" "$target_lang" "$provider" &
                    pids+=($!)
                done

                # Attendre la fin du lot
                for pid in "${pids[@]}"; do
                    wait "$pid" || true
                done
            done

            # Reassembler dans l'ordre
            for ((i=0; i<num_chunks; i++)); do
                local chunk_out="$CACHE_DIR/chunk_${i}_translated.srt"
                if [[ -s "$chunk_out" ]]; then
                    cat "$chunk_out" >> "$output"
                else
                    warn "Chunk $((i+1)) vide, skip"
                fi
                rm -f "$CACHE_DIR/chunk_${i}.srt" "$chunk_out"
            done
        fi
    fi

    if [[ -s "$output" ]]; then
        # Validate that the output is still valid SRT
        if validate_srt "$output"; then
            log "Traduction terminee: $output"
        else
            warn "Traduction terminee mais le format SRT semble casse: $output"
        fi
    else
        err "La traduction a echoue (fichier vide)"
        return 1
    fi
}

# ── Traduction d'un fichier local ─────────────────────────────────────────────
translate_local_file() {
    local input="$1" src_lang="$2" target_lang="$3" provider="$4"

    # Auto-detect source language if not specified
    if [[ -z "$src_lang" ]]; then
        local sample
        sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$input" | head -20 | tr '\n' ' ')
        src_lang=$(detect_lang "$sample")
        if [[ -n "$src_lang" ]]; then
            info "Langue source detectee: $src_lang"
        else
            src_lang="en"
            info "Langue source non detectee, defaut: en"
        fi
    fi

    local bname
    bname=$(basename "$input" | sed 's/\.[^.]*$//')
    local ext="${input##*.}"
    local output="${OUTPUT_DIR}/${bname}.${target_lang}.${ext}"

    translate_subtitle "$input" "$output" "$src_lang" "$target_lang" "$provider"
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    printf "%b" "
${BOLD}${BLUE}subtool${NC} v${VERSION}
Recherche et telecharge des sous-titres, avec traduction AI en fallback.

${BOLD}USAGE${NC}
    $SCRIPT_NAME [OPTIONS] <commande>

${BOLD}COMMANDES${NC}
    auto        Tout-en-un: download + traduction + embed (--dir ou --file)
    get         Recherche intelligente (parse auto titre/saison/episode)
    search      Recherche manuelle (avec -q/-s/-e)
    batch       Telecharger une saison entiere (avec -s)
    translate   Traduire un fichier de sous-titres local
    info        Afficher les infos d'un fichier SRT (encodage, langue, stats)
    clean       Nettoyer un SRT (pubs, tags HI/SDH, HTML)
    sync        Decaler les timecodes (+/- millisecondes)
    autosync    Sync auto avec video/audio via ffsubsync
    convert     Convertir entre formats (SRT <-> VTT <-> ASS)
    merge       Fusionner 2 sous-titres en bilingue
    fix         Reparer un SRT (encodage UTF-8, tri, renumerotation, chevauchements)
    extract     Extraire les sous-titres d'une video (MKV, MP4)
    embed       Incruster un SRT dans une video
    config      Afficher/editer la configuration (config set <KEY> <VALUE>)
    check       Diagnostic (deps, cles API, config)
    providers   Lister les providers AI disponibles
    sources     Lister les sources de sous-titres

${BOLD}OPTIONS${NC}
    -q, --query <titre>       Titre du film/serie a chercher
    -l, --lang <code>         Langue cible (fr, en, es, de, it, pt, etc.)
    -i, --imdb <id>           IMDb ID (tt1234567)
    -s, --season <num>        Numero de saison (series)
    -e, --episode <num>       Numero d'episode (series)
    -f, --file <fichier>      Fichier SRT a traduire
    -o, --output <dir>        Dossier de sortie (defaut: .)
    -p, --provider <provider> Provider traduction (google|claude-code|openai|claude|mistral|gemini)
    -m, --model <model>       Modele AI a utiliser (override le modele par defaut du provider)
    --sources <src1,src2>     Sources (opensubtitles-org,podnapisi)
    --from <lang>             Langue source pour traduction
    --fallback-langs <l1,l2>  Langues de fallback (defaut: en,de,es,pt)
    --max-ep <num>            Nombre max d'episodes par saison (defaut: 20)
    --shift <ms>              Decalage en ms pour sync (ex: +1500, -800)
    --to <format>             Format cible pour convert (srt, vtt, ass)
    --merge-with <fichier>    Fichier secondaire pour merge bilingue
    --ref <video|srt>         Reference pour autosync (video ou SRT)
    --sub <fichier>           Fichier SRT pour embed dans une video
    --track <num>             Piste a extraire pour extract
    --url <url>               Telecharger un sous-titre depuis une URL opensubtitles.org
    --embed                   Embed les sous-titres dans la video (auto: actif par defaut)
    --no-embed                Desactiver l'embed automatique
    --force-translate         Forcer la traduction meme si sous-titres trouves
    --auto                    Selectionner automatiquement le premier resultat
    --dry-run                 Afficher les resultats sans telecharger
    --json                    Sortie JSON (pour integration dans d'autres outils)
    --verbose                 Afficher les infos de debug
    --quiet                   Mode silencieux (erreurs uniquement)
    -h, --help                Afficher cette aide
    -v, --version             Afficher la version

${BOLD}EXEMPLES${NC}
    # Auto: download + traduit + embed en une commande
    $SCRIPT_NAME auto --dir ~/Movies/Die.Discounter -l fr
    $SCRIPT_NAME auto --dir ~/Movies/Die.Discounter -l fr --embed
    $SCRIPT_NAME auto -f movie.mkv -l fr

    # Smart get - episode unique
    $SCRIPT_NAME get -q \"Die Discounter S01E03\" -l de

    # Smart get - saison complete
    $SCRIPT_NAME get -q \"Die Discounter S01\" -l de

    # Smart get - range d'episodes
    $SCRIPT_NAME get -q \"Die Discounter S01E03-E08\" -l fr --force-translate -p zai-codeplan

    # Smart get - film
    $SCRIPT_NAME get -q \"Inception 2010\" -l fr

    # Smart get - format alternatif
    $SCRIPT_NAME get -q \"Die Discounter 1x05\" -l de
    $SCRIPT_NAME get -q \"Die Discounter saison 2\" -l de

    # Smart get - par IMDb ID
    $SCRIPT_NAME get -q \"tt16463942 S01E01\" -l de

    # Fallback: pas dispo en FR -> cherche DE/EN et traduit
    $SCRIPT_NAME get -q \"Die Discounter S01E03\" -l fr --force-translate

    # Traduction locale
    $SCRIPT_NAME translate -f episode.de.srt -l fr --from de -p zai-codeplan

    # Outils sous-titres
    $SCRIPT_NAME info -f movie.srt
    $SCRIPT_NAME clean -f movie.srt
    $SCRIPT_NAME sync -f movie.srt --shift -1500
    $SCRIPT_NAME convert -f movie.srt --to vtt
    $SCRIPT_NAME merge -f movie.de.srt --merge-with movie.fr.srt
    $SCRIPT_NAME fix -f broken.srt
    $SCRIPT_NAME extract -f movie.mkv
    $SCRIPT_NAME embed -f movie.mkv --sub movie.fr.srt -l fr

    # Sync auto avec video (ffsubsync)
    $SCRIPT_NAME autosync -f desync.srt --ref movie.mkv
    $SCRIPT_NAME autosync -f desync.srt --ref reference.srt
"
}

# ── Commande: sources ────────────────────────────────────────────────────────
cmd_sources() {
    header "Sources de sous-titres"
    printf "  ${BOLD}%-18s${NC} %-10s %s\n" "Source" "Status" "Description"
    printf "  %-18s %-10s %s\n" "──────────────────" "──────────" "──────────────────────"

    printf "  ${BOLD}%-18s${NC} ${GREEN}OK${NC}       %s\n" "opensubtitles-org" "OpenSubtitles.org REST (gratuit, sans cle)"
    printf "  ${BOLD}%-18s${NC} ${GREEN}OK${NC}       %s\n" "podnapisi" "Podnapisi.net (gratuit, sans cle)"
}

# ── Commande: providers ──────────────────────────────────────────────────────
cmd_providers() {
    header "Providers pour traduction"
    printf "  ${BOLD}%-15s${NC} %-10s %-25s %s\n" "Provider" "Status" "Modele" "Description"
    printf "  %-15s %-10s %-25s %s\n" "───────────────" "──────────" "─────────────────────────" "──────────────────────"

    local status
    if command -v trans &>/dev/null; then status="${GREEN}OK${NC}"; else status="${RED}N/A${NC}"; fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "google" "Google Translate" "Defaut, gratuit, ultra rapide (translate-shell)"

    if command -v claude &>/dev/null; then status="${GREEN}OK${NC}"; else status="${RED}N/A${NC}"; fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "claude-code" "$MODEL_CLAUDE_CODE" "Claude Code CLI (effort low)"

    if [[ -n "${ZAI_API_KEY:-}" ]]; then status="${GREEN}OK${NC}"; else status="${RED}NO KEY${NC}"; fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "zai-codeplan" "$MODEL_ZAI_CODEPLAN" "Z.ai Coding Plan API"

    if [[ -n "${OPENAI_API_KEY:-}" ]]; then status="${GREEN}OK${NC}"; else status="${RED}NO KEY${NC}"; fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "openai" "$MODEL_OPENAI" "OpenAI API"

    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then status="${GREEN}OK${NC}"; else status="${RED}NO KEY${NC}"; fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "claude" "$MODEL_CLAUDE" "Claude API (Anthropic)"

    if [[ -n "${MISTRAL_API_KEY:-}" ]]; then status="${GREEN}OK${NC}"; else status="${RED}NO KEY${NC}"; fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "mistral" "$MODEL_MISTRAL" "Mistral API"

    if [[ -n "${GEMINI_API_KEY:-}" ]]; then status="${GREEN}OK${NC}"; else status="${RED}NO KEY${NC}"; fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "gemini" "$MODEL_GEMINI" "Google Gemini API"
}

# ── Commande: config ──────────────────────────────────────────────────────────
cmd_config() {
    init_config

    # config set <key> <value>
    if [[ "${CONFIG_SUBCMD:-}" == "set" ]]; then
        local key="$CONFIG_KEY" value="$CONFIG_VALUE"
        [[ -z "$key" ]] && die "Usage: subtool config set <KEY> <VALUE>"
        # Update or add the key
        if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i.bak "s|^${key}=.*|${key}=\"${value}\"|" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
        else
            echo "${key}=\"${value}\"" >> "$CONFIG_FILE"
        fi
        log "Config: $key = $value"
        return
    fi

    # config get <key>
    if [[ "${CONFIG_SUBCMD:-}" == "get" ]]; then
        local key="$CONFIG_KEY"
        [[ -z "$key" ]] && die "Usage: subtool config get <KEY>"
        grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo ""
        return
    fi

    # config (edit)
    if [[ -n "${EDITOR:-}" ]]; then
        "$EDITOR" "$CONFIG_FILE"
    elif command -v nano &>/dev/null; then
        nano "$CONFIG_FILE"
    elif command -v vim &>/dev/null; then
        vim "$CONFIG_FILE"
    else
        info "Fichier de config: $CONFIG_FILE"
        printf "\n"
        cat "$CONFIG_FILE"
    fi
}

# ── Commande: check (diagnostic) ─────────────────────────────────────────────
cmd_check() {
    header "Diagnostic subtool"

    local ok=true

    # Required deps
    printf "\n  ${BOLD}Dependances requises:${NC}\n"
    for dep in jq curl; do
        if command -v "$dep" &>/dev/null; then
            printf "  ${GREEN}OK${NC}  %-15s %s\n" "$dep" "$(command -v "$dep")"
        else
            printf "  ${RED}MANQUANT${NC}  %s\n" "$dep"
            ok=false
        fi
    done

    # Optional deps
    printf "\n  ${BOLD}Dependances optionnelles:${NC}\n"
    for dep in ffmpeg ffprobe; do
        if command -v "$dep" &>/dev/null; then
            printf "  ${GREEN}OK${NC}  %-15s %s\n" "$dep" "$(command -v "$dep")"
        else
            printf "  ${YELLOW}N/A${NC}  %-15s (extract/embed/autosync)\n" "$dep"
        fi
    done
    if command -v ffsubsync &>/dev/null; then
        printf "  ${GREEN}OK${NC}  %-15s %s\n" "ffsubsync" "$(command -v ffsubsync)"
    elif command -v uvx &>/dev/null; then
        printf "  ${GREEN}OK${NC}  %-15s %s\n" "ffsubsync" "via uvx (a la volee)"
    else
        printf "  ${YELLOW}N/A${NC}  %-15s (autosync) — uvx ffsubsync ou: uv tool install ffsubsync\n" "ffsubsync"
    fi
    if command -v trans &>/dev/null; then
        printf "  ${GREEN}OK${NC}  %-15s %s\n" "translate-shell" "$(command -v trans) (Google Translate, defaut)"
    else
        printf "  ${YELLOW}N/A${NC}  %-15s brew install translate-shell (provider google)\n" "translate-shell"
    fi
    if command -v claude &>/dev/null; then
        printf "  ${GREEN}OK${NC}  %-15s\n" "claude-code"
    else
        printf "  ${YELLOW}N/A${NC}  %-15s (provider claude-code)\n" "claude CLI"
    fi

    # API keys
    printf "\n  ${BOLD}Cles API:${NC}\n"
    for key_name in ZAI_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY MISTRAL_API_KEY GEMINI_API_KEY; do
        local val="${!key_name:-}"
        if [[ -n "$val" ]]; then
            printf "  ${GREEN}OK${NC}  %-25s %s...%s\n" "$key_name" "${val:0:4}" "${val: -4}"
        else
            printf "  ${YELLOW}N/A${NC}  %s\n" "$key_name"
        fi
    done

    printf "\n  ${BOLD}Config:${NC} %s\n" "$CONFIG_FILE"
    printf "  ${BOLD}Cache:${NC}  %s\n" "$CACHE_DIR"

    if $ok; then
        printf "\n  ${GREEN}Tout est OK!${NC}\n"
    else
        printf "\n  ${RED}Des dependances requises manquent.${NC}\n"
        return 1
    fi
}

# ── Smart parsing ─────────────────────────────────────────────────────────────
# Parse une requete pour extraire titre, saison, episode, range, annee, imdb
# Formats reconnus:
#   "Die Discounter S01E03"        -> saison 1, episode 3
#   "Die Discounter S01E03-E08"    -> saison 1, episodes 3 a 8
#   "Die Discounter S01"           -> saison 1 complete
#   "Die Discounter 1x03"          -> saison 1, episode 3
#   "Die Discounter saison 2"      -> saison 2 complete
#   "Die Discounter season 1 ep 5" -> saison 1, episode 5
#   "Inception 2010"               -> film, annee 2010
#   "Inception"                    -> film
#   "tt16463942"                   -> IMDb ID direct
#   "tt16463942 S01E05"            -> IMDb ID + episode
parse_smart_query() {
    local raw="$1"
    PARSED_TITLE=""
    PARSED_SEASON=""
    PARSED_EPISODE=""
    PARSED_EP_END=""
    PARSED_IMDB=""
    PARSED_YEAR=""
    PARSED_MODE="" # movie | episode | season | range

    local q="$raw"

    # IMDb ID direct (tt1234567)
    if [[ "$q" =~ (tt[0-9]{5,}) ]]; then
        PARSED_IMDB="${BASH_REMATCH[1]}"
        q="${q//${BASH_REMATCH[0]}/}"
    fi

    # S01E03-E08 (range)
    if [[ "$q" =~ [Ss]([0-9]{1,2})[Ee]([0-9]{1,3})-[Ee]?([0-9]{1,3}) ]]; then
        PARSED_SEASON="${BASH_REMATCH[1]#0}"
        PARSED_EPISODE="${BASH_REMATCH[2]#0}"
        PARSED_EP_END="${BASH_REMATCH[3]#0}"
        PARSED_MODE="range"
        q="${q//${BASH_REMATCH[0]}/}"
    # S01E03 (episode unique)
    elif [[ "$q" =~ [Ss]([0-9]{1,2})[Ee]([0-9]{1,3}) ]]; then
        PARSED_SEASON="${BASH_REMATCH[1]#0}"
        PARSED_EPISODE="${BASH_REMATCH[2]#0}"
        PARSED_MODE="episode"
        q="${q//${BASH_REMATCH[0]}/}"
    # S01 seul (saison complete)
    elif [[ "$q" =~ [Ss]([0-9]{1,2})([^0-9Ee]|$) ]]; then
        PARSED_SEASON="${BASH_REMATCH[1]#0}"
        PARSED_MODE="season"
        # Supprimer "S01" du query en reconstruisant sans le match
        q=$(echo "$q" | sed -E 's/[Ss][0-9]{1,2}//g')
    # 1x03 format
    elif [[ "$q" =~ ([0-9]{1,2})[xX]([0-9]{1,3}) ]]; then
        PARSED_SEASON="${BASH_REMATCH[1]}"
        PARSED_EPISODE="${BASH_REMATCH[2]}"
        PARSED_MODE="episode"
        q="${q//${BASH_REMATCH[0]}/}"
    # "saison 2 episode 5" / "season 2 ep 5" / "saison 2"
    elif [[ "$q" =~ [Ss]aison[[:space:]]+([0-9]+) ]] || [[ "$q" =~ [Ss]eason[[:space:]]+([0-9]+) ]]; then
        PARSED_SEASON="${BASH_REMATCH[1]}"
        q="${q//${BASH_REMATCH[0]}/}"
        if [[ "$q" =~ [Ee]p(isode)?[[:space:]]*([0-9]+) ]]; then
            PARSED_EPISODE="${BASH_REMATCH[2]}"
            PARSED_MODE="episode"
            q="${q//${BASH_REMATCH[0]}/}"
        else
            PARSED_MODE="season"
        fi
    fi

    # Annee (2010, 2024...) — seulement si pas deja parse comme saison/episode
    if [[ "$q" =~ (^|[[:space:]])(19[0-9]{2}|20[0-9]{2})($|[[:space:]]) ]]; then
        PARSED_YEAR="${BASH_REMATCH[2]}"
        q="${q//${BASH_REMATCH[2]}/}"
    fi

    # Nettoyer le titre : trim espaces, tirets orphelins, etc.
    PARSED_TITLE=$(echo "$q" | sed 's/[[:space:]]*-[[:space:]]*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\+/ /g')

    # Si pas de mode detecte et pas de saison -> film
    if [[ -z "$PARSED_MODE" ]]; then
        PARSED_MODE="movie"
    fi
}

# Affiche ce qu'on a parse
show_parsed() {
    local icon
    case "$PARSED_MODE" in
        movie)   icon="Film" ;;
        episode) icon="Episode" ;;
        season)  icon="Saison" ;;
        range)   icon="Range" ;;
    esac
    printf "${CYAN}[i]${NC} Mode: ${BOLD}%s${NC}\n" "$icon"
    [[ -n "$PARSED_TITLE" ]] && info "Titre: $PARSED_TITLE"
    [[ -n "$PARSED_IMDB" ]] && info "IMDb: $PARSED_IMDB"
    [[ -n "$PARSED_YEAR" ]] && info "Annee: $PARSED_YEAR"
    [[ -n "$PARSED_SEASON" ]] && info "Saison: $PARSED_SEASON"
    case "$PARSED_MODE" in
        episode) info "Episode: $PARSED_EPISODE" ;;
        range)   info "Episodes: $PARSED_EPISODE-$PARSED_EP_END" ;;
    esac
}

# ── Commande: get (smart) ────────────────────────────────────────────────────
cmd_get() {
    [[ -z "$SEARCH_QUERY" && -z "$IMDB_ID" ]] && die "Specifie --query ou -q <titre>"
    [[ -z "$LANG_TARGET" ]] && die "Specifie --lang ou -l <code>"

    # Si l'utilisateur a deja donne -s/-e, on les utilise
    local raw_query="${SEARCH_QUERY:-}"
    if [[ -n "$SEASON" || -n "$EPISODE" ]]; then
        PARSED_TITLE="$raw_query"
        PARSED_IMDB="$IMDB_ID"
        PARSED_SEASON="$SEASON"
        PARSED_EPISODE="$EPISODE"
        if [[ -n "$SEASON" && -z "$EPISODE" ]]; then
            PARSED_MODE="season"
        elif [[ -n "$EPISODE" ]]; then
            PARSED_MODE="episode"
        else
            PARSED_MODE="movie"
        fi
    else
        parse_smart_query "$raw_query"
        # Si un --imdb a ete passe en plus, il prime
        [[ -n "$IMDB_ID" ]] && PARSED_IMDB="$IMDB_ID"
    fi

    header "subtool get"
    show_parsed
    info "Langue: $LANG_TARGET"
    printf "\n"

    # Router vers le bon mode
    case "$PARSED_MODE" in
        movie|episode)
            SEARCH_QUERY="$PARSED_TITLE"
            IMDB_ID="$PARSED_IMDB"
            SEASON="$PARSED_SEASON"
            EPISODE="$PARSED_EPISODE"
            cmd_search
            ;;
        season)
            SEARCH_QUERY="$PARSED_TITLE"
            IMDB_ID="$PARSED_IMDB"
            SEASON="$PARSED_SEASON"
            cmd_batch
            ;;
        range)
            SEARCH_QUERY="$PARSED_TITLE"
            IMDB_ID="$PARSED_IMDB"
            SEASON="$PARSED_SEASON"

            local start_ep="$PARSED_EPISODE"
            local end_ep="$PARSED_EP_END"

            header "Telechargement S$(printf '%02d' "$PARSED_SEASON")E$(printf '%02d' "$start_ep")-E$(printf '%02d' "$end_ep")"

        
            local success=0 fail=0 translated=0
            local season_dir
            season_dir="${OUTPUT_DIR}/S$(printf '%02d' "$PARSED_SEASON")"
            mkdir -p "$season_dir"

            for ep in $(seq "$start_ep" "$end_ep"); do
                local ep_str
                ep_str=$(printf "S%02dE%02d" "$PARSED_SEASON" "$ep")
                printf "\n${BOLD}── $ep_str ──${NC}\n"

                local results
                if results=$(search_all_sources "$PARSED_TITLE" "$LANG_TARGET" "$PARSED_IMDB" "$PARSED_SEASON" "$ep" 2>/dev/null); then
                    local first
                    first=$(echo "$results" | head -1)
                    [[ -z "$first" ]] && { warn "$ep_str: pas de resultat"; ((fail++)) || true; continue; }

                    local safe_name
                    safe_name=$(echo "${PARSED_TITLE:-imdb}_${ep_str}" | tr ' /' '_' | tr -cd '[:alnum:]._-')
                    local output="${season_dir}/${safe_name}.${LANG_TARGET}.srt"

                    if download_subtitle "$first" "$output" 2>/dev/null; then
                        log "$ep_str: $output"
                        ((success++)) || true
                    else
                        warn "$ep_str: echec telechargement"
                        ((fail++)) || true
                    fi
                elif $FORCE_TRANSLATE; then
                    local fallback_found=false fallback_lang="" fallback_results=""
                    IFS=',' read -ra fb_langs <<< "$FALLBACK_LANGS"
                    for fl in "${fb_langs[@]}"; do
                        fl=$(echo "$fl" | tr -d ' ')
                        [[ "$fl" == "$LANG_TARGET" ]] && continue
                        if fallback_results=$(search_all_sources "$PARSED_TITLE" "$fl" "$PARSED_IMDB" "$PARSED_SEASON" "$ep" 2>/dev/null); then
                            fallback_lang="$fl"
                            fallback_found=true
                            break
                        fi
                    done
                    if $fallback_found; then
                        local first
                        first=$(echo "$fallback_results" | head -1)
                        local safe_name
                        safe_name=$(echo "${PARSED_TITLE:-imdb}_${ep_str}" | tr ' /' '_' | tr -cd '[:alnum:]._-')
                        local tmp_src="${CACHE_DIR}/${safe_name}.${fallback_lang}.srt"
                        local output="${season_dir}/${safe_name}.${LANG_TARGET}.srt"
                        if download_subtitle "$first" "$tmp_src" 2>/dev/null; then
                            if translate_subtitle "$tmp_src" "$output" "$fallback_lang" "$LANG_TARGET" "$AI_PROVIDER" 2>/dev/null; then
                                log "$ep_str: traduit ($fallback_lang->$LANG_TARGET)"
                                ((translated++)) || true
                            else
                                warn "$ep_str: echec traduction"
                                ((fail++)) || true
                            fi
                            rm -f "$tmp_src"
                        else
                            ((fail++)) || true
                        fi
                    else
                        warn "$ep_str: rien trouve"
                        ((fail++)) || true
                    fi
                else
                    warn "$ep_str: pas trouve"
                    ((fail++)) || true
                fi
            done

            header "Resultat"
            log "Telecharges: $success | Traduits: $translated | Echecs: $fail"
            log "Dossier: $season_dir"
            ;;
    esac
}

# ── Commande: search ─────────────────────────────────────────────────────────
cmd_search() {
    [[ -z "$SEARCH_QUERY" && -z "$IMDB_ID" ]] && die "Specifie --query ou --imdb"
    [[ -z "$LANG_TARGET" ]] && die "Specifie --lang (ex: fr, en, es)"

    local query="${SEARCH_QUERY:-}"

    header "Recherche de sous-titres"
    info "Titre: ${query:-IMDB:$IMDB_ID}"
    info "Langue: $LANG_TARGET"
    [[ -n "$SEASON" ]] && info "Saison: $SEASON, Episode: $EPISODE"

    # Login OpenSubtitles si possible

    local results
    if results=$(search_all_sources "$query" "$LANG_TARGET" "$IMDB_ID" "$SEASON" "$EPISODE"); then
        local selected
        if selected=$(select_subtitle "$results"); then
            local name
            name=$(echo "$selected" | jq -r '.name // "subtitle"')
            local safe_name
            safe_name=$(echo "$name" | tr ' /' '_' | tr -cd '[:alnum:]._-')
            local output="${OUTPUT_DIR}/${safe_name}.${LANG_TARGET}.srt"

            log "Telechargement..."
            if download_subtitle "$selected" "$output"; then
                log "Sauvegarde: $output"
            else
                err "Echec du telechargement"
                return 1
            fi
        fi
    else
        warn "Aucun sous-titre trouve pour '$query' en '$LANG_TARGET'"

        if $FORCE_TRANSLATE; then
            info "Tentative de fallback: recherche dans d'autres langues puis traduction AI..."
            local fallback_found=false
            local fallback_lang=""
            local fallback_results=""

            IFS=',' read -ra fb_langs <<< "$FALLBACK_LANGS"
            for fl in "${fb_langs[@]}"; do
                fl=$(echo "$fl" | tr -d ' ')
                [[ "$fl" == "$LANG_TARGET" ]] && continue
                info "Essai en '$fl'..."
                if fallback_results=$(search_all_sources "$query" "$fl" "$IMDB_ID" "$SEASON" "$EPISODE" 2>/dev/null); then
                    fallback_lang="$fl"
                    fallback_found=true
                    log "Sous-titres trouves en '$fl'!"
                    break
                fi
            done

            if $fallback_found; then
                local selected
                if selected=$(select_subtitle "$fallback_results"); then
                    local name
                    name=$(echo "$selected" | jq -r '.name // "subtitle"')
                    local safe_name
                    safe_name=$(echo "$name" | tr ' /' '_' | tr -cd '[:alnum:]._-')
                    local tmp_src="${CACHE_DIR}/${safe_name}.${fallback_lang}.srt"
                    local output="${OUTPUT_DIR}/${safe_name}.${LANG_TARGET}.srt"

                    log "Telechargement des sous-titres ($fallback_lang)..."
                    if download_subtitle "$selected" "$tmp_src"; then
                        translate_subtitle "$tmp_src" "$output" "$fallback_lang" "$LANG_TARGET" "$AI_PROVIDER"
                        rm -f "$tmp_src"
                    else
                        err "Echec du telechargement"
                        return 1
                    fi
                fi
            else
                err "Aucun sous-titre trouve dans aucune langue ($FALLBACK_LANGS)"
                return 1
            fi
        else
            info "Utilise --force-translate pour chercher en anglais et traduire avec AI"
        fi
    fi
}

# ── Commande: batch (saison entiere) ─────────────────────────────────────────
cmd_batch() {
    [[ -z "$SEARCH_QUERY" && -z "$IMDB_ID" ]] && die "Specifie --query ou --imdb"
    [[ -z "$LANG_TARGET" ]] && die "Specifie --lang"
    [[ -z "$SEASON" ]] && die "Specifie --season"

    local query="${SEARCH_QUERY:-}"
    local max_ep="${MAX_EPISODE:-20}"

    header "Telechargement saison $SEASON"
    info "Titre: ${query:-IMDB:$IMDB_ID}"
    info "Langue: $LANG_TARGET | Episodes: 1-$max_ep"
    info "Provider AI (si fallback): $AI_PROVIDER"


    local success=0 fail=0 translated=0
    local season_dir
    season_dir="${OUTPUT_DIR}/S$(printf '%02d' "$SEASON")"
    mkdir -p "$season_dir"

    for ep in $(seq 1 "$max_ep"); do
        local ep_str
        ep_str=$(printf "S%02dE%02d" "$SEASON" "$ep")
        printf "\n${BOLD}── $ep_str ──${NC}\n"

        local results
        if results=$(search_all_sources "$query" "$LANG_TARGET" "$IMDB_ID" "$SEASON" "$ep" 2>/dev/null); then
            # Prendre le premier resultat automatiquement en batch
            local first
            first=$(echo "$results" | head -1)
            [[ -z "$first" ]] && { warn "$ep_str: pas de resultat exploitable"; ((fail++)) || true; continue; }

            local name
            name=$(echo "$first" | jq -r '.name // "subtitle"' 2>/dev/null)
            local safe_name
            safe_name=$(echo "${query:-imdb}_${ep_str}" | tr ' /' '_' | tr -cd '[:alnum:]._-')
            local output="${season_dir}/${safe_name}.${LANG_TARGET}.srt"

            if download_subtitle "$first" "$output" 2>/dev/null; then
                log "$ep_str: $output"
                ((success++)) || true
            else
                warn "$ep_str: echec telechargement"
                ((fail++)) || true
            fi
        elif $FORCE_TRANSLATE; then
            # Fallback: chercher dans d'autres langues et traduire
            local fallback_found=false fallback_lang="" fallback_results=""
            IFS=',' read -ra fb_langs <<< "$FALLBACK_LANGS"
            for fl in "${fb_langs[@]}"; do
                fl=$(echo "$fl" | tr -d ' ')
                [[ "$fl" == "$LANG_TARGET" ]] && continue
                if fallback_results=$(search_all_sources "$query" "$fl" "$IMDB_ID" "$SEASON" "$ep" 2>/dev/null); then
                    fallback_lang="$fl"
                    fallback_found=true
                    break
                fi
            done

            if $fallback_found; then
                local first
                first=$(echo "$fallback_results" | head -1)
                local safe_name
                safe_name=$(echo "${query:-imdb}_${ep_str}" | tr ' /' '_' | tr -cd '[:alnum:]._-')
                local tmp_src="${CACHE_DIR}/${safe_name}.${fallback_lang}.srt"
                local output="${season_dir}/${safe_name}.${LANG_TARGET}.srt"

                if download_subtitle "$first" "$tmp_src" 2>/dev/null; then
                    if translate_subtitle "$tmp_src" "$output" "$fallback_lang" "$LANG_TARGET" "$AI_PROVIDER" 2>/dev/null; then
                        log "$ep_str: traduit ($fallback_lang->$LANG_TARGET)"
                        ((translated++)) || true
                    else
                        warn "$ep_str: echec traduction"
                        ((fail++)) || true
                    fi
                    rm -f "$tmp_src"
                else
                    warn "$ep_str: echec telechargement fallback"
                    ((fail++)) || true
                fi
            else
                warn "$ep_str: rien trouve dans aucune langue"
                ((fail++)) || true
            fi
        else
            # Episode non trouve = fin de saison probable
            if [[ $success -eq 0 && $ep -le 3 ]]; then
                warn "$ep_str: pas trouve"
                ((fail++)) || true
            else
                info "$ep_str: pas trouve (fin de saison probable)"
                break
            fi
        fi
    done

    header "Resultat"
    log "Telecharges: $success | Traduits: $translated | Echecs: $fail"
    log "Dossier: $season_dir"
}

# ── Commande: scan (auto-download depuis un dossier de videos) ───────────────
cmd_scan() {
    [[ -z "$SCAN_DIR" ]] && die "Specifie --dir <dossier_videos>"
    [[ ! -d "$SCAN_DIR" ]] && die "Dossier introuvable: $SCAN_DIR"
    [[ -z "$LANG_TARGET" ]] && die "Specifie --lang (ex: fr, en, de)"

    local title_override="${SEARCH_QUERY:-}"
    local imdb_override="${IMDB_ID:-}"

    header "subtool scan"
    info "Dossier: $SCAN_DIR"
    info "Langue: $LANG_TARGET"
    [[ -n "$title_override" ]] && info "Titre force: $title_override"
    [[ -n "$imdb_override" ]] && info "IMDb force: $imdb_override"
    $DRY_RUN && info "Mode: dry-run (aucun telechargement)"
    $FORCE_TRANSLATE && info "Fallback traduction: actif ($FALLBACK_LANGS)"


    local success=0 fail=0 skip=0 translated=0 total=0

    while IFS= read -r -d '' video_file; do
        ((total++)) || true
        local dir_name base_name name_no_ext
        dir_name=$(dirname "$video_file")
        base_name=$(basename "$video_file")
        name_no_ext="${base_name%.*}"

        # Check if subtitle already exists next to the video
        local srt_path="${dir_name}/${name_no_ext}.${LANG_TARGET}.srt"
        if [[ -f "$srt_path" ]] || [[ -f "${dir_name}/${name_no_ext}.srt" ]]; then
            info "Skip (existe deja): $base_name"
            ((skip++)) || true
            continue
        fi

        printf "\n${BOLD}── %s ──${NC}\n" "$base_name" >&2

        # Clean filename for parsing: strip bracket codes, resolution tags, and episode descriptions
        local clean_name="$name_no_ext"
        clean_name=$(echo "$clean_name" | sed -E 's/\[[^]]*\]//g')                        # remove [xxx]
        clean_name=$(echo "$clean_name" | sed -E 's/\([^)]*\)//g')                        # remove (xxx)
        clean_name=$(echo "$clean_name" | sed -E 's/([Ss][0-9]+[Ee][0-9]+)[-. ].*/\1/')   # keep only up to SxxExx
        clean_name=$(echo "$clean_name" | tr '.' ' ')                                      # dots to spaces

        # Parse filename to extract season/episode
        parse_smart_query "$clean_name"

        # Override title/imdb if user provided --query or --imdb
        [[ -n "$title_override" ]] && PARSED_TITLE="$title_override"
        [[ -n "$imdb_override" ]] && PARSED_IMDB="$imdb_override"

        if [[ -z "$PARSED_TITLE" && -z "$PARSED_IMDB" ]]; then
            warn "Impossible de parser: $base_name"
            ((fail++)) || true
            continue
        fi

        debug "Parsed: title='$PARSED_TITLE' S=$PARSED_SEASON E=$PARSED_EPISODE mode=$PARSED_MODE"

        # Dry-run: just show what would be done
        if $DRY_RUN; then
            info "[dry-run] $PARSED_TITLE S$(printf '%02d' "${PARSED_SEASON:-0}")E$(printf '%02d' "${PARSED_EPISODE:-0}") -> $srt_path"
            continue
        fi

        local results=""
        local found=false

        # Try to find subtitles in target language
        if results=$(search_all_sources "$PARSED_TITLE" "$LANG_TARGET" "$PARSED_IMDB" "$PARSED_SEASON" "$PARSED_EPISODE" 2>/dev/null); then
            local first
            first=$(echo "$results" | head -1)
            if [[ -n "$first" ]]; then
                if download_subtitle "$first" "$srt_path" 2>/dev/null; then
                    log "OK: $srt_path"
                    ((success++)) || true
                    found=true
                else
                    warn "Echec telechargement: $base_name"
                fi
            fi
        fi

        # Fallback: try other languages + translate
        if ! $found && $FORCE_TRANSLATE; then
            local fallback_found=false fallback_lang="" fallback_results=""
            IFS=',' read -ra fb_langs <<< "$FALLBACK_LANGS"
            for fl in "${fb_langs[@]}"; do
                fl=$(echo "$fl" | tr -d ' ')
                [[ "$fl" == "$LANG_TARGET" ]] && continue
                if fallback_results=$(search_all_sources "$PARSED_TITLE" "$fl" "$PARSED_IMDB" "$PARSED_SEASON" "$PARSED_EPISODE" 2>/dev/null); then
                    fallback_lang="$fl"
                    fallback_found=true
                    break
                fi
            done

            if $fallback_found; then
                local first
                first=$(echo "$fallback_results" | head -1)
                local tmp_src="${CACHE_DIR}/scan_tmp.${fallback_lang}.srt"
                if download_subtitle "$first" "$tmp_src" 2>/dev/null; then
                    if translate_subtitle "$tmp_src" "$srt_path" "$fallback_lang" "$LANG_TARGET" "$AI_PROVIDER" 2>/dev/null; then
                        log "Traduit ($fallback_lang->$LANG_TARGET): $srt_path"
                        ((translated++)) || true
                        found=true
                    else
                        warn "Echec traduction: $base_name"
                    fi
                    rm -f "$tmp_src"
                fi
            fi
        fi

        if ! $found; then
            ((fail++)) || true
        fi

    done < <(find "$SCAN_DIR" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.m4v" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.ts" \) -print0 2>/dev/null | sort -z)

    printf "\n"
    header "Resultat scan"
    if $DRY_RUN; then
        log "Total: $total | Skips: $skip | A traiter: $((total - skip))"
    else
        log "Total: $total | Telecharges: $success | Traduits: $translated | Skips: $skip | Echecs: $fail"
    fi
}

# ── Commande: auto (tout-en-un: download + translate + embed) ─────────────────
cmd_auto() {
    local target="$LANG_TARGET"
    [[ -z "$target" ]] && die "Specifie --lang <langue_cible> (ex: fr)"

    # Mode fichier unique ou dossier
    local mode=""
    if [[ -n "$FILE_PATH" ]]; then
        [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"
        mode="file"
    elif [[ -n "$SCAN_DIR" ]]; then
        [[ ! -d "$SCAN_DIR" ]] && die "Dossier introuvable: $SCAN_DIR"
        mode="dir"
    else
        die "Specifie --file <video> ou --dir <dossier>"
    fi

    local title_override="${SEARCH_QUERY:-}"
    local imdb_override="${IMDB_ID:-}"
    # Embed par defaut si ffmpeg est dispo (--no-embed pour desactiver)
    local do_embed=true
    if ! command -v ffmpeg &>/dev/null; then
        do_embed=false
    fi
    # Override explicite
    $AUTO_EMBED && do_embed=true
    ${NO_EMBED:-false} && do_embed=false

    header "subtool auto"
    info "Langue cible: $target"
    $do_embed && info "Embed: actif" || info "Embed: inactif (ffmpeg requis)"

    local success=0 fail=0 skip=0 total=0

    # Collect video files
    local video_files=()
    if [[ "$mode" == "file" ]]; then
        video_files=("$FILE_PATH")
    else
        info "Dossier: $SCAN_DIR"
        while IFS= read -r -d '' vf; do
            video_files+=("$vf")
        done < <(/usr/bin/find "$SCAN_DIR" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.m4v" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.ts" \) -print0 2>/dev/null | sort -z)
    fi

    total=${#video_files[@]}
    info "$total videos trouvees"

    for video_file in "${video_files[@]}"; do
        local dir_name base_name name_no_ext
        dir_name=$(dirname "$video_file")
        base_name=$(basename "$video_file")
        name_no_ext="${base_name%.*}"

        local target_srt="${dir_name}/${name_no_ext}.${target}.srt"

        # Already has target language subtitle? (skip only if non-empty)
        if [[ -s "$target_srt" ]]; then
            # Sync + embed even if subtitle already exists
            _auto_sync "$video_file" "$target_srt"
            if $do_embed; then
                _auto_embed "$video_file" "$target_srt" "$target"
            fi
            ((skip++)) || true
            continue
        fi

        printf "\n${BOLD}── %s ──${NC}\n" "$base_name" >&2

        # ── Step 1: Check for existing subtitle in any language ──
        local existing_srt="" existing_lang=""
        for srt_file in "${dir_name}/${name_no_ext}".*.srt; do
            [[ -f "$srt_file" ]] || continue
            # Extract lang code from filename (name.XX.srt)
            local srt_base
            srt_base=$(basename "$srt_file")
            local srt_lang="${srt_base%.srt}"
            srt_lang="${srt_lang##*.}"
            if [[ -n "$srt_lang" && "$srt_lang" != "$target" && ${#srt_lang} -le 3 ]]; then
                existing_srt="$srt_file"
                existing_lang="$srt_lang"
                break
            fi
        done

        # ── Step 2: If no existing subtitle, try to download ──
        if [[ -z "$existing_srt" ]]; then
            # Parse filename for search
            local clean_name="$name_no_ext"
            clean_name=$(echo "$clean_name" | sed -E 's/\[[^]]*\]//g')
            clean_name=$(echo "$clean_name" | sed -E 's/\([^)]*\)//g')
            clean_name=$(echo "$clean_name" | sed -E 's/([Ss][0-9]+[Ee][0-9]+)[-. ].*/\1/')
            clean_name=$(echo "$clean_name" | tr '.' ' ')
            parse_smart_query "$clean_name"
            [[ -n "$title_override" ]] && PARSED_TITLE="$title_override"
            [[ -n "$imdb_override" ]] && PARSED_IMDB="$imdb_override"

            if [[ -z "$PARSED_TITLE" && -z "$PARSED_IMDB" ]]; then
                warn "Impossible de parser: $base_name"
                ((fail++)) || true
                continue
            fi

            # Try target language first
            local results=""
            if results=$(search_all_sources "$PARSED_TITLE" "$target" "$PARSED_IMDB" "$PARSED_SEASON" "$PARSED_EPISODE" 2>/dev/null); then
                local first
                first=$(echo "$results" | head -1)
                if [[ -n "$first" ]] && download_subtitle "$first" "$target_srt" 2>/dev/null; then
                    log "Telecharge (${target}): $target_srt"
                    ((success++)) || true
                    # No translation needed, already in target language
                    _auto_sync "$video_file" "$target_srt"
                    if $do_embed; then
                        _auto_embed "$video_file" "$target_srt" "$target"
                    fi
                    continue
                fi
            fi

            # Try all fallback languages
            local fb_downloaded=false
            IFS=',' read -ra fb_langs <<< "$FALLBACK_LANGS"
            for fl in "${fb_langs[@]}"; do
                fl=$(echo "$fl" | tr -d ' ')
                [[ "$fl" == "$target" ]] && continue
                local fb_results=""
                if fb_results=$(search_all_sources "$PARSED_TITLE" "$fl" "$PARSED_IMDB" "$PARSED_SEASON" "$PARSED_EPISODE" 2>/dev/null); then
                    local first
                    first=$(echo "$fb_results" | head -1)
                    local dl_path="${dir_name}/${name_no_ext}.${fl}.srt"
                    if [[ -n "$first" ]] && download_subtitle "$first" "$dl_path" 2>/dev/null; then
                        log "Telecharge ($fl): $(basename "$dl_path")"
                        existing_srt="$dl_path"
                        existing_lang="$fl"
                        fb_downloaded=true
                        break
                    fi
                fi
            done

            # Nothing found anywhere — prompt for URL in interactive mode
            if [[ -z "$existing_srt" ]]; then
                if [[ -t 0 ]] && ! $AUTO_SELECT; then
                    warn "Aucun sous-titre trouve pour: $base_name"
                    printf "  ${CYAN}Colle une URL opensubtitles.org (ou Enter pour skip):${NC} " >&2
                    local user_url=""
                    read -r user_url </dev/tty 2>/dev/null || true
                    if [[ -n "$user_url" ]]; then
                        local url_srt="${dir_name}/${name_no_ext}.dl.srt"
                        if download_from_url "$user_url" "$url_srt"; then
                            # Detect language of downloaded subtitle
                            local detected_lang
                            local sample
                            sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$url_srt" | head -20 | tr '\n' ' ')
                            detected_lang=$(detect_lang "$sample")
                            [[ -z "$detected_lang" ]] && detected_lang="und"
                            # Rename with detected language
                            local proper_path="${dir_name}/${name_no_ext}.${detected_lang}.srt"
                            mv "$url_srt" "$proper_path"
                            existing_srt="$proper_path"
                            existing_lang="$detected_lang"
                            log "Telecharge via URL ($detected_lang): $(basename "$proper_path")"
                        else
                            warn "Echec telechargement URL"
                        fi
                    fi
                fi
            fi
        fi

        # ── Step 3: Translate if we have a subtitle in another language ──
        if [[ -n "$existing_srt" && "$existing_lang" != "$target" ]]; then
            info "Traduction: $existing_lang -> $target"
            if translate_subtitle "$existing_srt" "$target_srt" "$existing_lang" "$target" "$AI_PROVIDER"; then
                log "Traduit: $(basename "$target_srt")"
                ((success++)) || true

                # ── Step 4: Sync with video ──
                _auto_sync "$video_file" "$target_srt"
                # ── Step 5: Embed if requested ──
                if $do_embed; then
                    _auto_embed "$video_file" "$target_srt" "$target"
                fi
                continue
            else
                warn "Echec traduction: $base_name"
            fi
        elif [[ -z "$existing_srt" ]]; then
            warn "Aucun sous-titre pour: $base_name"
        fi

        if [[ ! -f "$target_srt" ]]; then
            ((fail++)) || true
        fi
    done

    printf "\n"
    header "Resultat auto"
    log "Total: $total | OK: $success | Skips: $skip | Echecs: $fail"
}

# Helper for auto-sync (sync subtitle with video via ffsubsync)
_auto_sync() {
    local video="$1" sub="$2"
    # Determine ffsubsync command
    local ffsubsync_cmd="ffsubsync"
    if ! command -v ffsubsync &>/dev/null; then
        if command -v uvx &>/dev/null; then
            ffsubsync_cmd="uvx ffsubsync"
            info "Utilisation de uvx ffsubsync"
        else
            warn "ffsubsync non disponible — skip sync. Installe: uvx ffsubsync"
            return 0
        fi
    fi
    local synced="${sub%.srt}.synced.srt"
    info "Sync: $(basename "$sub") avec $(basename "$video")"
    if $ffsubsync_cmd "$video" -i "$sub" -o "$synced" 2>/dev/null; then
        if [[ -s "$synced" ]]; then
            mv "$synced" "$sub"
            log "Sync OK: $(basename "$sub")"
        else
            warn "Echec sync — fichier vide, on garde l'original"
        fi
    else
        warn "Echec sync — on garde la version non-syncee"
        rm -f "$synced"
    fi
}

# Helper for auto-embed (embed srt into video, replace original)
_auto_embed() {
    local video="$1" sub="$2" lang="$3"
    # Skip if video already has a subtitle stream
    local existing_subs
    existing_subs=$(ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$video" 2>/dev/null || true)
    if [[ -n "$existing_subs" ]]; then
        info "Embed skip (sous-titres deja presents): $(basename "$video")"
        return 0
    fi
    local vext="${video##*.}"
    local tmp_video="${video%.${vext}}.tmp.${vext}"
    # MP4/M4V need mov_text codec, MKV/others use srt
    local sub_codec="srt"
    case "$vext" in
        mp4|m4v|mov) sub_codec="mov_text" ;;
    esac
    info "Embed: $(basename "$sub") -> $(basename "$video") (codec: $sub_codec)"
    if ffmpeg -v quiet -i "$video" -i "$sub" \
        -c copy -c:s "$sub_codec" \
        -metadata:s:s:0 language="$lang" \
        "$tmp_video" -y 2>/dev/null && [[ -s "$tmp_video" ]]; then
        mv "$tmp_video" "$video"
        log "Embed OK: $(basename "$video")"
    else
        warn "Echec embed: $(basename "$video")"
        rm -f "$tmp_video"
    fi
}

# ── Commande: translate ──────────────────────────────────────────────────────
cmd_translate() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <fichier.srt>"
    [[ -z "$LANG_TARGET" ]] && die "Specifie --lang <code_langue_cible>"
    [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"

    local src_lang="${SRC_LANG:-}"
    translate_local_file "$FILE_PATH" "$src_lang" "$LANG_TARGET" "$AI_PROVIDER"
}

# ── Commande: info (stats d'un fichier SRT) ──────────────────────────────────
cmd_info() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <fichier.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"

    header "Info: $(basename "$FILE_PATH")"

    local filesize line_count sub_count
    filesize=$(stat -f%z "$FILE_PATH" 2>/dev/null || stat -c%s "$FILE_PATH" 2>/dev/null)
    local encoding
    encoding=$(file --mime-encoding "$FILE_PATH" 2>/dev/null | awk -F': ' '{print $2}' || echo "unknown")
    line_count=$(wc -l < "$FILE_PATH" | tr -d ' ')
    sub_count=$(grep -cE '^[0-9]+$' "$FILE_PATH" 2>/dev/null || echo "0")

    # Premier et dernier timestamp (format: HH:MM:SS,mmm --> HH:MM:SS,mmm)
    local first_ts last_ts
    first_ts=$(grep -m1 -oE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}' "$FILE_PATH" 2>/dev/null | head -1)
    local first_start="${first_ts%% -->*}"
    last_ts=$(grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}' "$FILE_PATH" 2>/dev/null | tail -1)
    local last_end="${last_ts##*--> }"

    # Detection de langue
    local sample_text
    sample_text=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$FILE_PATH" | head -20 | tr '\n' ' ')
    local detected_lang="?"
    if echo "$sample_text" | grep -qiE '\b(the|and|is|are|you|that|this|have|with)\b'; then
        detected_lang="en (anglais)"
    elif echo "$sample_text" | grep -qiE '\b(le|la|les|des|est|une|que|pas|avec|dans)\b'; then
        detected_lang="fr (francais)"
    elif echo "$sample_text" | grep -qiE '\b(der|die|das|und|ist|ein|nicht|ich|mit|auf)\b'; then
        detected_lang="de (allemand)"
    elif echo "$sample_text" | grep -qiE '\b(el|la|los|las|que|del|una|por|con|para)\b'; then
        detected_lang="es (espagnol)"
    elif echo "$sample_text" | grep -qiE '\b(il|la|che|non|per|una|con|sono|del|questo)\b'; then
        detected_lang="it (italien)"
    elif echo "$sample_text" | grep -qiE '\b(o|que|de|da|em|um|uma|com|para|por)\b'; then
        detected_lang="pt (portugais)"
    fi

    # Tags HI / SDH
    local hi_count
    hi_count=$(grep -cE '\[.*\]|\(.*\)' "$FILE_PATH" || true)

    # Tags HTML
    local html_count
    html_count=$(grep -cE '<[^>]+>' "$FILE_PATH" || true)

    # Taille human-readable
    local size_human
    if [[ "$filesize" -gt 1048576 ]]; then
        size_human="$((filesize / 1048576)) MB"
    elif [[ "$filesize" -gt 1024 ]]; then
        size_human="$((filesize / 1024)) KB"
    else
        size_human="${filesize} B"
    fi

    printf "  ${BOLD}%-20s${NC} %s\n" "Taille" "$size_human"
    printf "  ${BOLD}%-20s${NC} %s\n" "Encodage" "$encoding"
    printf "  ${BOLD}%-20s${NC} %s\n" "Lignes" "$line_count"
    printf "  ${BOLD}%-20s${NC} %s\n" "Sous-titres" "$sub_count"
    printf "  ${BOLD}%-20s${NC} %s\n" "Debut" "${first_start:-N/A}"
    printf "  ${BOLD}%-20s${NC} %s\n" "Fin" "${last_end:-N/A}"
    printf "  ${BOLD}%-20s${NC} %s\n" "Langue detectee" "$detected_lang"
    if [[ "$hi_count" -gt 0 ]]; then printf "  ${BOLD}%-20s${NC} ${YELLOW}%s tags HI/SDH${NC}\n" "Accessibilite" "$hi_count"; fi
    if [[ "$html_count" -gt 0 ]]; then printf "  ${BOLD}%-20s${NC} ${YELLOW}%s tags HTML${NC}\n" "Formatage" "$html_count"; fi
}

# ── Commande: clean (nettoyage SRT) ──────────────────────────────────────────
cmd_clean() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <fichier.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"

    local basename ext output
    basename=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${basename}.clean.${ext}"

    header "Nettoyage: $(basename "$FILE_PATH")"

    local html_count hi_count
    html_count=$(grep -cE '<[^>]+>' "$FILE_PATH" || true)
    hi_count=$(grep -cE '^\s*[\[\(].*[\]\)]' "$FILE_PATH" || true)

    [[ "$html_count" -gt 0 ]] && echo "  Tags HTML supprimes: $html_count" >&2
    [[ "$hi_count" -gt 0 ]] && echo "  Tags HI/SDH supprimes: $hi_count" >&2

    # Clean via sed pipeline
    sed -E \
        -e 's/<[^>]+>//g' \
        -e '/^\s*[\[\(].*[\]\)]\s*$/d' \
        -e '/^\s*♪.*♪\s*$/d' \
        -e '/^\s*#.*#\s*$/d' \
        -e '/[Ss]ubscene/Id' \
        -e '/[Oo]pen[Ss]ubtitles/Id' \
        -e '/[Aa]ddic7ed/Id' \
        -e '/[Ss]ynced.*[Bb]y/Id' \
        -e '/[Ss]ubtitle.*[Bb]y/Id' \
        -e '/[Rr]ipped.*[Bb]y/Id' \
        -e '/[Dd]ownloaded.*[Ff]rom/Id' \
        -e '/www\..*\.(com|net|org)/Id' \
        "$FILE_PATH" | \
    awk '
    # Remove empty SRT blocks (number + timestamp with no text)
    BEGIN { RS=""; ORS="\n\n" }
    {
        # Split block into lines
        n = split($0, lines, "\n")
        # Check if block has text content (not just number + timestamp)
        has_text = 0
        for (i = 1; i <= n; i++) {
            if (lines[i] !~ /^[0-9]+$/ && lines[i] !~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}/ && lines[i] !~ /^\s*$/) {
                has_text = 1
                break
            }
        }
        if (has_text) print $0
    }' | sed '/^$/N;/^\n$/d' > "$output"

    echo "  Total modifications: $((html_count + hi_count))+" >&2

    log "Fichier nettoye: $output"
}

# ── Commande: sync (decalage temporel) ───────────────────────────────────────
SYNC_SHIFT=""

cmd_sync() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <fichier.srt>"
    [[ -z "$SYNC_SHIFT" ]] && die "Specifie --shift <ms> (ex: +1500, -800)"
    [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"

    local basename ext output
    basename=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${basename}.synced.${ext}"

    header "Sync: $(basename "$FILE_PATH") (${SYNC_SHIFT}ms)"

    local shift_val="${SYNC_SHIFT}"

    awk -v shift="$shift_val" '
    function ts2ms(ts,    a, b) {
        split(ts, a, ":")
        split(a[3], b, ",")
        return a[1]*3600000 + a[2]*60000 + b[1]*1000 + b[2]
    }
    function ms2ts(ms,    h, m, s) {
        if (ms < 0) ms = 0
        h = int(ms / 3600000); ms = ms % 3600000
        m = int(ms / 60000); ms = ms % 60000
        s = int(ms / 1000); ms = ms % 1000
        return sprintf("%02d:%02d:%02d,%03d", h, m, s, ms)
    }
    /^[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}/ {
        split($0, parts, " --> ")
        start = ts2ms(parts[1]) + shift
        end = ts2ms(parts[2]) + shift
        print ms2ts(start) " --> " ms2ts(end)
        next
    }
    { print }
    ' "$FILE_PATH" > "$output"

    echo "Decalage applique: ${shift_val}ms" >&2

    log "Fichier synced: $output"
}

# ── Commande: convert (SRT <-> VTT <-> ASS) ─────────────────────────────────
CONVERT_FORMAT=""

cmd_convert() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <fichier>"
    [[ -z "$CONVERT_FORMAT" ]] && die "Specifie --to <format> (srt, vtt, ass)"
    [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"

    local basename src_ext
    basename=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    src_ext="${FILE_PATH##*.}"
    local output="${OUTPUT_DIR}/${basename}.${CONVERT_FORMAT}"

    header "Conversion: ${src_ext} -> ${CONVERT_FORMAT}"

    awk -v src="$src_ext" -v tgt="$CONVERT_FORMAT" -v outfile="$output" '
    function srt_ts_to_vtt(ts) { gsub(",", ".", ts); return ts }
    function srt_ts_to_ass(ts,    a, b) {
        split(ts, a, ":")
        split(a[3], b, ",")
        return int(a[1]) ":" a[2] ":" b[1] "." substr(b[2], 1, 2)
    }
    function ass_ts_to_srt(ts,    a, b) {
        split(ts, a, ":")
        split(a[3], b, ".")
        return sprintf("%02d:%s:%s,%03d", int(a[1]), a[2], b[1], int(b[2]) * 10)
    }
    function flush_block() {
        if (cur_start == "") return
        count++
        starts[count] = cur_start
        ends[count] = cur_end
        texts[count] = cur_text
        cur_start = ""; cur_end = ""; cur_text = ""
    }
    function write_srt() {
        for (i = 1; i <= count; i++)
            printf "%d\n%s --> %s\n%s\n\n", i, starts[i], ends[i], texts[i] > outfile
    }
    function write_vtt() {
        printf "WEBVTT\n\n" > outfile
        for (i = 1; i <= count; i++)
            printf "%d\n%s --> %s\n%s\n\n", i, srt_ts_to_vtt(starts[i]), srt_ts_to_vtt(ends[i]), texts[i] > outfile
    }
    function write_ass() {
        printf "[Script Info]\nTitle: Converted by subtool\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080\n\n" > outfile
        printf "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n" > outfile
        printf "Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,1,2,10,10,40,1\n\n" > outfile
        printf "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" > outfile
        for (i = 1; i <= count; i++) {
            t = texts[i]; gsub(/\n/, "\\N", t)
            printf "Dialogue: 0,%s,%s,Default,,0,0,0,,%s\n", srt_ts_to_ass(starts[i]), srt_ts_to_ass(ends[i]), t > outfile
        }
    }
    BEGIN { count = 0; state = "init"; cur_start = ""; cur_end = ""; cur_text = "" }

    # Skip VTT header
    src == "vtt" && /^WEBVTT/ { next }

    # ASS parsing
    src == "ass" || src == "ssa" {
        if (/^Dialogue:/) {
            line = $0
            sub(/^Dialogue: *[0-9]+,/, "", line)
            # Extract start,end and text (field 9+)
            n = split(line, flds, ",")
            s = flds[1]; e = flds[2]
            # Text is everything from field 9 onwards (fields: Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text...)
            txt = ""
            for (j = 9; j <= n; j++) {
                if (j > 9) txt = txt ","
                txt = txt flds[j]
            }
            # Remove ASS override tags
            gsub(/\{[^}]*\}/, "", txt)
            # Convert \N to newline
            gsub(/\\N/, "\n", txt)
            # Remove leading/trailing whitespace
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", txt)
            count++
            starts[count] = ass_ts_to_srt(s)
            ends[count] = ass_ts_to_srt(e)
            texts[count] = txt
        }
        next
    }

    # SRT/VTT parsing
    /^[0-9]+[[:space:]]*$/ && state != "text" {
        flush_block()
        state = "index"
        next
    }
    /[0-9]{2}:[0-9]{2}:[0-9]{2}[,\.][0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2}[,\.][0-9]{3}/ {
        split($0, ts_parts, " --> ")
        cur_start = ts_parts[1]; cur_end = ts_parts[2]
        gsub(/\./, ",", cur_start); gsub(/\./, ",", cur_end)
        state = "text"
        next
    }
    state == "text" && /^[[:space:]]*$/ {
        flush_block()
        state = "init"
        next
    }
    state == "text" {
        if (cur_text != "") cur_text = cur_text "\n"
        cur_text = cur_text $0
    }
    END {
        flush_block()
        if (tgt == "srt") write_srt()
        else if (tgt == "vtt") write_vtt()
        else if (tgt == "ass") write_ass()
        printf "%d sous-titres convertis\n", count > "/dev/stderr"
    }
    ' "$FILE_PATH" 2>&1

    log "Fichier converti: $output"
}

# ── Commande: merge (sous-titres bilingues) ──────────────────────────────────
MERGE_FILE=""

cmd_merge() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <fichier_principal.srt>"
    [[ -z "$MERGE_FILE" ]] && die "Specifie --merge-with <fichier_secondaire.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"
    [[ ! -f "$MERGE_FILE" ]] && die "Fichier introuvable: $MERGE_FILE"

    local basename ext output
    basename=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${basename}.dual.${ext}"

    header "Merge bilingue"
    info "Principal: $(basename "$FILE_PATH")"
    info "Secondaire: $(basename "$MERGE_FILE")"

    # Parse SRT into temp files, then merge
    local tmp_pri="$CACHE_DIR/_merge_pri.txt"
    local tmp_sec="$CACHE_DIR/_merge_sec.txt"
    mkdir -p "$CACHE_DIR"

    # Parse SRT: output "START|END|TEXT" per block (text newlines as \n literal)
    _parse_srt_blocks() {
        awk '
        BEGIN { state = "init"; start = ""; end_ts = ""; txt = "" }
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
        state == "text" {
            if (txt != "") txt = txt "\\n"
            txt = txt $0
        }
        END { flush() }
        ' "$1"
    }

    _parse_srt_blocks "$FILE_PATH" > "$tmp_pri"
    _parse_srt_blocks "$MERGE_FILE" > "$tmp_sec"

    # Merge the two files
    local idx=0
    : > "$output"
    while IFS='|' read -r start end_ts text; do
        ((idx++)) || true
        local sec_text=""
        sec_text=$(sed -n "${idx}p" "$tmp_sec" 2>/dev/null | cut -d'|' -f3-)
        # Convert \n back to real newlines
        text=$(echo -e "$text")
        sec_text=$(echo -e "$sec_text")
        printf '%d\n%s --> %s\n%s\n<i>%s</i>\n\n' "$idx" "$start" "$end_ts" "$text" "$sec_text" >> "$output"
    done < "$tmp_pri"

    echo "$idx sous-titres fusionnes" >&2
    rm -f "$tmp_pri" "$tmp_sec"

    log "Fichier bilingue: $output"
}

# ── Commande: fix (reparation SRT) ───────────────────────────────────────────
cmd_fix() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <fichier.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"

    local basename ext output
    basename=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${basename}.fixed.${ext}"

    header "Reparation: $(basename "$FILE_PATH")"

    # Detect encoding
    local encoding
    encoding=$(file --mime-encoding "$FILE_PATH" 2>/dev/null | awk -F': ' '{print $2}')
    if [[ "$encoding" != "utf-8" && "$encoding" != "us-ascii" ]]; then
        echo "  Encodage detecte: ${encoding} -> UTF-8" >&2
    fi

    # Convert to UTF-8, normalize line endings, parse and fix
    iconv -f "${encoding:-utf-8}" -t utf-8 "$FILE_PATH" 2>/dev/null | tr -d '\r' | \
    awk '
    function ts2ms(ts,    a, b) {
        gsub(/\./, ",", ts)
        split(ts, a, ":")
        split(a[3], b, ",")
        return a[1]*3600000 + a[2]*60000 + b[1]*1000 + b[2]
    }
    function ms2ts(ms,    h, m, s) {
        if (ms < 0) ms = 0
        h = int(ms / 3600000); ms = ms % 3600000
        m = int(ms / 60000); ms = ms % 60000
        s = int(ms / 1000); ms = ms % 1000
        return sprintf("%02d:%02d:%02d,%03d", h, m, s, ms)
    }
    function flush() {
        if (cur_start == "" || cur_text == "") { cur_start = ""; cur_end = ""; cur_text = ""; return }
        count++
        starts[count] = cur_start
        ends[count] = cur_end
        texts[count] = cur_text
        cur_start = ""; cur_end = ""; cur_text = ""
    }
    BEGIN { count = 0; state = "init"; cur_start = ""; cur_end = ""; cur_text = "" }

    /^[0-9]+[[:space:]]*$/ && state != "text" {
        flush()
        state = "index"
        next
    }
    /[0-9]{2}:[0-9]{2}:[0-9]{2}[,\.][0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2}[,\.][0-9]{3}/ {
        split($0, ts_parts, " --> ")
        s = ts_parts[1]; e = ts_parts[2]
        gsub(/\./, ",", s); gsub(/\./, ",", e)
        cur_start = s; cur_end = e
        state = "text"
        next
    }
    state == "text" && /^[[:space:]]*$/ {
        flush()
        state = "init"
        next
    }
    state == "text" {
        if (cur_text != "") cur_text = cur_text "\n"
        cur_text = cur_text $0
    }
    END {
        flush()

        # Sort blocks by start timestamp
        sorted = 0
        for (i = 1; i < count; i++) {
            for (j = i + 1; j <= count; j++) {
                if (ts2ms(starts[i]) > ts2ms(starts[j])) {
                    tmp = starts[i]; starts[i] = starts[j]; starts[j] = tmp
                    tmp = ends[i]; ends[i] = ends[j]; ends[j] = tmp
                    tmp = texts[i]; texts[i] = texts[j]; texts[j] = tmp
                    sorted++
                }
            }
        }
        if (sorted > 0)
            printf "  Blocs reordonnes: %d swaps\n", sorted > "/dev/stderr"

        # Fix overlaps
        fixes = 0
        for (i = 1; i < count; i++) {
            end_ms = ts2ms(ends[i])
            next_start_ms = ts2ms(starts[i+1])
            if (end_ms > next_start_ms) {
                ends[i] = ms2ts(next_start_ms - 1)
                fixes++
            }
        }
        if (fixes > 0)
            printf "  Chevauchements corriges: %d\n", fixes > "/dev/stderr"

        # Write output with proper numbering
        for (i = 1; i <= count; i++)
            printf "%d\n%s --> %s\n%s\n\n", i, starts[i], ends[i], texts[i]

        printf "  %d sous-titres, renumerotes en UTF-8\n", count > "/dev/stderr"
    }
    ' > "$output"

    log "Fichier repare: $output"
}

# ── Commande: extract (extraire sous-titres d'une video) ─────────────────────
EXTRACT_TRACK=""

cmd_extract() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <video.mkv>"
    [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"

    if ! command -v ffmpeg &>/dev/null; then
        die "ffmpeg requis pour l'extraction. Installe-le: brew install ffmpeg"
    fi

    local basename
    basename=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')

    header "Extraction sous-titres: $(basename "$FILE_PATH")"

    # Lister les pistes de sous-titres
    local streams
    streams=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$FILE_PATH" 2>/dev/null)
    local count
    count=$(echo "$streams" | jq '.streams | length' 2>/dev/null)

    if [[ "$count" == "0" || -z "$count" ]]; then
        err "Aucune piste de sous-titres trouvee"
        return 1
    fi

    info "Pistes trouvees:"
    for ((idx=0; idx<count; idx++)); do
        local lang title codec
        lang=$(echo "$streams" | jq -r ".streams[$idx].tags.language // \"und\"")
        title=$(echo "$streams" | jq -r ".streams[$idx].tags.title // \"\"")
        codec=$(echo "$streams" | jq -r ".streams[$idx].codec_name // \"?\"")
        printf "  ${BOLD}%2d${NC}) [${CYAN}%s${NC}] %s (%s)\n" "$((idx))" "$lang" "$title" "$codec"
    done

    if [[ -n "$EXTRACT_TRACK" ]]; then
        local track="$EXTRACT_TRACK"
    else
        printf "\n"
        local track
        read -rp "$(printf "${BOLD}Piste a extraire [0-$((count-1))]:${NC} ")" track
        [[ -z "$track" ]] && track=0
    fi

    local lang codec ext
    lang=$(echo "$streams" | jq -r ".streams[$track].tags.language // \"und\"")
    codec=$(echo "$streams" | jq -r ".streams[$track].codec_name // \"srt\"")

    case "$codec" in
        subrip|srt)  ext="srt" ;;
        ass|ssa)     ext="ass" ;;
        webvtt)      ext="vtt" ;;
        hdmv_pgs_subtitle|dvd_subtitle)
            warn "Sous-titres bitmap ($codec) - extraction en .sup"
            ext="sup" ;;
        *)           ext="srt" ;;
    esac

    local output="${OUTPUT_DIR}/${basename}.${lang}.${ext}"
    ffmpeg -v quiet -i "$FILE_PATH" -map "0:s:${track}" -c:s "$([[ "$ext" == "srt" ]] && echo "srt" || echo "copy")" "$output" -y 2>/dev/null

    if [[ -s "$output" ]]; then
        log "Extrait: $output"
    else
        err "Echec de l'extraction"
        return 1
    fi
}

# ── Commande: embed (incruster sous-titres dans une video) ───────────────────
cmd_embed() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <video.mkv>"
    [[ -z "$EMBED_SUB" ]] && die "Specifie --sub <fichier.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "Video introuvable: $FILE_PATH"
    [[ ! -f "$EMBED_SUB" ]] && die "Sous-titre introuvable: $EMBED_SUB"

    if ! command -v ffmpeg &>/dev/null; then
        die "ffmpeg requis. Installe-le: brew install ffmpeg"
    fi

    local basename ext output
    basename=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${basename}.subbed.${ext}"

    local sub_lang="${LANG_TARGET:-und}"

    header "Embed sous-titres"
    info "Video: $(basename "$FILE_PATH")"
    info "Sous-titre: $(basename "$EMBED_SUB") ($sub_lang)"

    ffmpeg -v quiet -i "$FILE_PATH" -i "$EMBED_SUB" \
        -c copy -c:s srt \
        -metadata:s:s:0 language="$sub_lang" \
        "$output" -y 2>/dev/null

    if [[ -s "$output" ]]; then
        log "Video avec sous-titres: $output"
    else
        err "Echec de l'incrustation"
        return 1
    fi
}

# ── Commande: autosync (ffsubsync - sync auto avec video/audio) ──────────────
AUTOSYNC_REF=""

cmd_autosync() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <sous-titre.srt>"
    [[ -z "$AUTOSYNC_REF" ]] && die "Specifie --ref <video.mkv ou reference.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"
    [[ ! -f "$AUTOSYNC_REF" ]] && die "Reference introuvable: $AUTOSYNC_REF"

    # Determiner la commande ffsubsync
    local ffsubsync_cmd="ffsubsync"
    if ! command -v ffsubsync &>/dev/null; then
        if command -v uvx &>/dev/null; then
            ffsubsync_cmd="uvx ffsubsync"
            info "Utilisation de uvx ffsubsync (pas d'installation locale)"
        else
            die "ffsubsync non disponible. Installe-le: uvx ffsubsync (ou: uv tool install ffsubsync)"
        fi
    fi

    local basename ext output
    basename=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${basename}.synced.${ext}"

    local ref_ext="${AUTOSYNC_REF##*.}"

    header "Auto-sync (ffsubsync)"
    info "Sous-titre: $(basename "$FILE_PATH")"
    info "Reference: $(basename "$AUTOSYNC_REF")"

    local ffsubsync_args=()
    ffsubsync_args+=("$AUTOSYNC_REF")
    ffsubsync_args+=(-i "$FILE_PATH")
    ffsubsync_args+=(-o "$output")

    # Si la reference est un SRT/ASS, utiliser le mode subtitle-to-subtitle
    case "$ref_ext" in
        srt|ass|ssa|vtt|sub)
            info "Mode: subtitle <-> subtitle"
            ;;
        *)
            info "Mode: video <-> subtitle (extraction audio)"
            ;;
    esac

    if $ffsubsync_cmd "${ffsubsync_args[@]}" 2>&1; then
        log "Sync automatique: $output"
    else
        err "Echec ffsubsync"
        return 1
    fi
}

# ── Parse args ────────────────────────────────────────────────────────────────
SRC_LANG=""
SCAN_DIR=""
COMMAND=""
EMBED_SUB=""
CONFIG_SUBCMD=""
CONFIG_KEY=""
CONFIG_VALUE=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            get|search|translate|batch|scan|auto|info|clean|sync|autosync|convert|merge|fix|extract|embed|providers|sources|check)
                COMMAND="$1"; shift ;;
            config)
                COMMAND="config"; shift
                # Parse config sub-commands: config set KEY VALUE / config get KEY
                if [[ $# -gt 0 && ("$1" == "set" || "$1" == "get") ]]; then
                    CONFIG_SUBCMD="$1"; shift
                    if [[ $# -gt 0 ]]; then CONFIG_KEY="$1"; shift; fi
                    if [[ $# -gt 0 && "$CONFIG_SUBCMD" == "set" ]]; then CONFIG_VALUE="$1"; shift; fi
                fi
                ;;
            -q|--query)    SEARCH_QUERY="$2"; shift 2 ;;
            -l|--lang)     LANG_TARGET="$2"; shift 2 ;;
            -i|--imdb)     IMDB_ID="$2"; shift 2 ;;
            -s|--season)   SEASON="$2"; shift 2 ;;
            -e|--episode)  EPISODE="$2"; shift 2 ;;
            -f|--file)     FILE_PATH="$2"; shift 2 ;;
            -o|--output)   OUTPUT_DIR="$2"; shift 2 ;;
            -p|--provider) AI_PROVIDER="$2"; shift 2 ;;
            -m|--model)    AI_MODEL="$2"; shift 2 ;;
            --sources)     SOURCES="$2"; shift 2 ;;
            --from)        SRC_LANG="$2"; shift 2 ;;
            --fallback-langs) FALLBACK_LANGS="$2"; shift 2 ;;
            --max-ep)      MAX_EPISODE="$2"; shift 2 ;;
            --shift)       SYNC_SHIFT="$2"; shift 2 ;;
            --to)          CONVERT_FORMAT="$2"; shift 2 ;;
            --merge-with)  MERGE_FILE="$2"; shift 2 ;;
            --sub)         EMBED_SUB="$2"; shift 2 ;;
            --track)       EXTRACT_TRACK="$2"; shift 2 ;;
            --ref)         AUTOSYNC_REF="$2"; shift 2 ;;
            --force-translate) FORCE_TRANSLATE=true; shift ;;
            --auto)        AUTO_SELECT=true; shift ;;
            --embed)       AUTO_EMBED=true; shift ;;
            --no-embed)    NO_EMBED=true; shift ;;
            --url)         SUBTITLE_URL="$2"; shift 2 ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --json)        JSON_OUTPUT=true; QUIET=true; shift ;;
            --verbose)     VERBOSE=true; shift ;;
            --quiet)       QUIET=true; shift ;;
            --dir)         SCAN_DIR="$2"; shift 2 ;;
            -h|--help)     usage; exit 0 ;;
            -v|--version)  echo "$VERSION"; exit 0 ;;
            *)             die "Option inconnue: $1. Utilise --help" ;;
        esac
    done
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    # Remove temp chunk files on exit
    rm -f "$CACHE_DIR"/chunk_*.srt 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    load_config
    parse_args "$@"

    [[ -z "$COMMAND" ]] && { usage; exit 0; }

    mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"
    trap cleanup EXIT

    case "$COMMAND" in
        get)       cmd_get ;;
        search)    cmd_search ;;
        translate) cmd_translate ;;
        batch)     cmd_batch ;;
        scan)      cmd_scan ;;
        auto)      cmd_auto ;;
        info)      cmd_info ;;
        clean)     cmd_clean ;;
        sync)      cmd_sync ;;
        convert)   cmd_convert ;;
        merge)     cmd_merge ;;
        fix)       cmd_fix ;;
        autosync)  cmd_autosync ;;
        extract)   cmd_extract ;;
        embed)     cmd_embed ;;
        config)    cmd_config ;;
        check)     cmd_check ;;
        providers) cmd_providers ;;
        sources)   cmd_sources ;;
        *)         die "Commande inconnue: $COMMAND" ;;
    esac
}

main "$@"
