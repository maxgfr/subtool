#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.1"
SCRIPT_NAME="$(basename "$0")"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/subtool"
CONFIG_FILE="$CONFIG_DIR/config"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/subtool"

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
LANG_TARGET=""
AI_PROVIDER="claude-code"
SEARCH_QUERY=""
IMDB_ID=""
FILE_PATH=""
SEASON=""
EPISODE=""
OUTPUT_DIR="."
FORCE_TRANSLATE=false
SOURCES="opensubtitles,podnapisi,subdl"
FALLBACK_LANGS="en,de,es,pt"
MAX_EPISODE=20
AI_MODEL=""

# ── Modeles par defaut ────────────────────────────────────────────────────────
MODEL_ZAI_CODEPLAN="glm-4.7"
MODEL_OPENAI="gpt-4o"
MODEL_CLAUDE="claude-sonnet-4-20250514"
MODEL_MISTRAL="mistral-large-latest"
MODEL_GEMINI="gemini-2.0-flash"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()   { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()   { printf "${RED}[x]${NC} %s\n" "$*" >&2; }
info()  { printf "${CYAN}[i]${NC} %s\n" "$*"; }
header(){ printf "\n${BOLD}${BLUE}── %s ──${NC}\n" "$*"; }

die() { err "$1"; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
init_config() {
    mkdir -p "$CONFIG_DIR" "$CACHE_DIR"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << 'CONF'
# subtool configuration
# API keys pour les sources de sous-titres
OPENSUBTITLES_API_KEY=""
OPENSUBTITLES_USERNAME=""
OPENSUBTITLES_PASSWORD=""
SUBDL_API_KEY=""

# API keys pour la traduction AI
OPENAI_API_KEY=""
ANTHROPIC_API_KEY=""
MISTRAL_API_KEY=""
GEMINI_API_KEY=""
ZAI_API_KEY=""

# Provider AI par defaut: claude-code, zai-codeplan, openai, claude, mistral, gemini
DEFAULT_AI_PROVIDER="claude-code"

# Modeles par defaut (laisser vide pour utiliser les valeurs par defaut)
MODEL_ZAI_CODEPLAN=""
MODEL_OPENAI=""
MODEL_CLAUDE=""
MODEL_MISTRAL=""
MODEL_GEMINI=""
CONF
        info "Config creee: $CONFIG_FILE"
        info "Edite-la pour ajouter tes cles API"
    fi
}

load_config() {
    init_config
    # Sauvegarder les vars d'env existantes avant source
    local _saved_opensubtitles="${OPENSUBTITLES_API_KEY:-}"
    local _saved_subdl="${SUBDL_API_KEY:-}"
    local _saved_openai="${OPENAI_API_KEY:-}"
    local _saved_anthropic="${ANTHROPIC_API_KEY:-}"
    local _saved_mistral="${MISTRAL_API_KEY:-}"
    local _saved_gemini="${GEMINI_API_KEY:-}"
    local _saved_zai="${ZAI_API_KEY:-}"
    # shellcheck source=/dev/null
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    # Les vars d'env ont priorite sur le fichier config
    [[ -n "$_saved_opensubtitles" ]] && OPENSUBTITLES_API_KEY="$_saved_opensubtitles"
    [[ -n "$_saved_subdl" ]] && SUBDL_API_KEY="$_saved_subdl"
    [[ -n "$_saved_openai" ]] && OPENAI_API_KEY="$_saved_openai"
    [[ -n "$_saved_anthropic" ]] && ANTHROPIC_API_KEY="$_saved_anthropic"
    [[ -n "$_saved_mistral" ]] && MISTRAL_API_KEY="$_saved_mistral"
    [[ -n "$_saved_gemini" ]] && GEMINI_API_KEY="$_saved_gemini"
    [[ -n "$_saved_zai" ]] && ZAI_API_KEY="$_saved_zai"
    AI_PROVIDER="${DEFAULT_AI_PROVIDER:-claude-code}"
}

# ── Hash du fichier pour identification ───────────────────────────────────────
compute_hash() {
    local file="$1"
    # OpenSubtitles utilise un hash custom (premiers et derniers 64KB + taille)
    local filesize
    filesize=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    echo "$filesize"
}

# ── OpenSubtitles API v2 (rest) ──────────────────────────────────────────────
opensubtitles_token=""

opensubtitles_login() {
    [[ -z "${OPENSUBTITLES_API_KEY:-}" ]] && { warn "OPENSUBTITLES_API_KEY non configuree"; return 1; }

    if [[ -n "${OPENSUBTITLES_USERNAME:-}" && -n "${OPENSUBTITLES_PASSWORD:-}" ]]; then
        local resp
        resp=$(curl -sf -X POST "https://api.opensubtitles.com/api/v1/login" \
            -H "Api-Key: $OPENSUBTITLES_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"$OPENSUBTITLES_USERNAME\",\"password\":\"$OPENSUBTITLES_PASSWORD\"}" 2>/dev/null) || return 1
        opensubtitles_token=$(echo "$resp" | jq -r '.token // empty')
    fi
    return 0
}

search_opensubtitles() {
    local query="$1" lang="$2" imdb_id="${3:-}" season="${4:-}" episode="${5:-}"
    [[ -z "${OPENSUBTITLES_API_KEY:-}" ]] && { warn "OpenSubtitles: API key manquante (OPENSUBTITLES_API_KEY)" >&2; return 1; }

    local params="languages=$lang"
    if [[ -n "$imdb_id" ]]; then
        params+="&imdb_id=$imdb_id"
    elif [[ -n "$query" ]]; then
        params+="&query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")"
    fi
    [[ -n "$season" ]] && params+="&season_number=$season"
    [[ -n "$episode" ]] && params+="&episode_number=$episode"

    local headers=(-H "Api-Key: $OPENSUBTITLES_API_KEY" -H "Content-Type: application/json")
    [[ -n "$opensubtitles_token" ]] && headers+=(-H "Authorization: Bearer $opensubtitles_token")

    local resp
    resp=$(curl -sf "https://api.opensubtitles.com/api/v1/subtitles?$params" "${headers[@]}" 2>/dev/null) || return 1

    local count
    count=$(echo "$resp" | jq '.data | length' 2>/dev/null)
    [[ "$count" == "0" || -z "$count" ]] && return 1

    echo "$resp" | jq -c '.data[] | {
        id: .attributes.files[0].file_id,
        name: .attributes.release,
        lang: .attributes.language,
        source: "opensubtitles",
        downloads: .attributes.download_count,
        rating: .attributes.ratings
    }' 2>/dev/null
}

download_opensubtitles() {
    local file_id="$1" output="$2"
    [[ -z "${OPENSUBTITLES_API_KEY:-}" ]] && return 1

    local headers=(-H "Api-Key: $OPENSUBTITLES_API_KEY" -H "Content-Type: application/json")
    [[ -n "$opensubtitles_token" ]] && headers+=(-H "Authorization: Bearer $opensubtitles_token")

    local resp
    resp=$(curl -sf -X POST "https://api.opensubtitles.com/api/v1/download" \
        "${headers[@]}" \
        -d "{\"file_id\":$file_id}" 2>/dev/null) || return 1

    local link
    link=$(echo "$resp" | jq -r '.link // empty' 2>/dev/null)
    [[ -z "$link" ]] && return 1

    curl -sf -o "$output" "$link" 2>/dev/null
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
    encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")

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

    # Extraire le .srt du zip
    local tmp_dir="$CACHE_DIR/podnapisi_extract_$$"
    mkdir -p "$tmp_dir"
    unzip -qo "$tmp_zip" -d "$tmp_dir" 2>/dev/null || return 1
    local srt_file
    srt_file=$(find "$tmp_dir" -name "*.srt" -o -name "*.ass" -o -name "*.sub" | head -1)
    [[ -n "$srt_file" ]] && mv "$srt_file" "$output" && rm -rf "$tmp_dir" "$tmp_zip"
}

# ── SubDL ─────────────────────────────────────────────────────────────────────
search_subdl() {
    local query="$1" lang="$2"
    [[ -z "${SUBDL_API_KEY:-}" ]] && { warn "SubDL: API key manquante (SUBDL_API_KEY)" >&2; return 1; }

    local encoded_query
    encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")

    local resp
    resp=$(curl -sf "https://api.subdl.com/api/v1/subtitles?api_key=${SUBDL_API_KEY}&film_name=$encoded_query&languages=$lang" 2>/dev/null) || return 1

    local count
    count=$(echo "$resp" | jq '.subtitles | length' 2>/dev/null)
    [[ "$count" == "0" || -z "$count" ]] && return 1

    echo "$resp" | jq -c '.subtitles[]? | {
        id: .sd_id,
        name: .release_name,
        lang: .language,
        source: "subdl",
        downloads: 0,
        rating: 0
    }' 2>/dev/null
}

download_subdl() {
    local sub_id="$1" output="$2"
    [[ -z "${SUBDL_API_KEY:-}" ]] && return 1

    local tmp_zip="$CACHE_DIR/subdl_${sub_id}.zip"
    curl -sf -o "$tmp_zip" "https://dl.subdl.com/subtitle/${sub_id}" 2>/dev/null || return 1

    local tmp_dir="$CACHE_DIR/subdl_extract_$$"
    mkdir -p "$tmp_dir"
    unzip -qo "$tmp_zip" -d "$tmp_dir" 2>/dev/null || return 1
    local srt_file
    srt_file=$(find "$tmp_dir" -name "*.srt" -o -name "*.ass" -o -name "*.sub" | head -1)
    [[ -n "$srt_file" ]] && mv "$srt_file" "$output" && rm -rf "$tmp_dir" "$tmp_zip"
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
            opensubtitles)
                result=$(search_opensubtitles "$query" "$lang" "$imdb_id" "$season" "$episode") ;;
            podnapisi)
                result=$(search_podnapisi "$query" "$lang") ;;
            subdl)
                result=$(search_subdl "$query" "$lang") ;;
            *)
                warn "Source inconnue: $source" >&2 ;;
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

    header "Sous-titres trouves"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name source downloads
        name=$(echo "$line" | jq -r '.name // "N/A"' 2>/dev/null)
        source=$(echo "$line" | jq -r '.source // "?"' 2>/dev/null)
        downloads=$(echo "$line" | jq -r '.downloads // 0' 2>/dev/null)
        [[ -z "$name" || "$name" == "null" ]] && continue
        printf "  ${BOLD}%2d${NC}) [${CYAN}%-15s${NC}] %s ${YELLOW}(%s DL)${NC}\n" "$i" "$source" "$name" "$downloads"
        entries+=("$line")
        ((i++)) || true
    done <<< "$results"

    if [[ ${#entries[@]} -eq 0 ]]; then
        return 1
    fi

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
        opensubtitles) download_opensubtitles "$id" "$output" ;;
        podnapisi)     download_podnapisi "$id" "$output" ;;
        subdl)         download_subdl "$id" "$output" ;;
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
    local in_block=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        current_chunk+="$line"$'\n'
        ((line_count++))

        # Quand on atteint un bloc vide (separateur SRT) et qu'on a assez de lignes
        if [[ -z "$(echo "$line" | tr -d '[:space:]')" ]] && [[ $line_count -ge $max_lines ]]; then
            echo "$current_chunk" > "$CACHE_DIR/chunk_${chunk_num}.srt"
            ((chunk_num++))
            line_count=0
            current_chunk=""
        fi
    done < "$file"

    # Dernier chunk
    if [[ -n "$current_chunk" ]]; then
        echo "$current_chunk" > "$CACHE_DIR/chunk_${chunk_num}.srt"
        ((chunk_num++))
    fi

    echo "$chunk_num"
}

translate_with_claude_code() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    info "Traduction avec Claude Code (claude CLI)..."

    if ! command -v claude &>/dev/null; then
        err "claude CLI non installe. Installe-le: npm install -g @anthropic-ai/claude-code"
        return 1
    fi

    local prompt="Translate this SRT subtitle file from $src_lang to $target_lang. Keep ALL SRT formatting intact (numbers, timestamps, blank lines). Only translate the text lines. Output ONLY the translated SRT content, nothing else."
    local content
    content=$(<"$input")

    CLAUDECODE= claude -p "$prompt

$content" > "$output" 2>/dev/null
}

translate_with_zai_codeplan() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${ZAI_API_KEY:-}" ]] && { err "ZAI_API_KEY non configuree"; return 1; }
    local model="${AI_MODEL:-$MODEL_ZAI_CODEPLAN}"
    info "Traduction avec Z.ai Coding Plan ($model)..."

    local prompt="Translate this SRT subtitle file from $src_lang to $target_lang. Keep ALL SRT formatting intact (numbers, timestamps, blank lines). Only translate the text lines. Output ONLY the translated SRT content, nothing else."

    local resp
    resp=$(curl -sf "https://api.z.ai/api/coding/paas/v4/chat/completions" \
        -H "Authorization: Bearer $ZAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a professional subtitle translator. Preserve all SRT formatting exactly.\"},
                {\"role\": \"user\", \"content\": $(python3 -c "import json; print(json.dumps('$prompt\n\n' + open('$input').read()))")}
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

    local content
    content=$(<"$input")
    local escaped_content
    escaped_content=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$content")

    local prompt="Translate this SRT subtitle file from $src_lang to $target_lang. Keep ALL SRT formatting intact (numbers, timestamps, blank lines). Only translate the text lines. Output ONLY the translated SRT content, nothing else."

    local resp
    resp=$(curl -sf "https://api.openai.com/v1/chat/completions" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a professional subtitle translator. Preserve all SRT formatting exactly.\"},
                {\"role\": \"user\", \"content\": $(python3 -c "import json; print(json.dumps('$prompt\n\n' + open('$input').read()))")}
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

    local prompt="Translate this SRT subtitle file from $src_lang to $target_lang. Keep ALL SRT formatting intact (numbers, timestamps, blank lines). Only translate the text lines. Output ONLY the translated SRT content, nothing else."

    local resp
    resp=$(curl -sf "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"max_tokens\": 8192,
            \"messages\": [
                {\"role\": \"user\", \"content\": $(python3 -c "import json; print(json.dumps('$prompt\n\n' + open('$input').read()))")}
            ]
        }" 2>/dev/null) || { err "Erreur API Claude"; return 1; }

    echo "$resp" | jq -r '.content[0].text' > "$output"
}

translate_with_mistral() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${MISTRAL_API_KEY:-}" ]] && { err "MISTRAL_API_KEY non configuree"; return 1; }
    local model="${AI_MODEL:-$MODEL_MISTRAL}"
    info "Traduction avec Mistral ($model)..."

    local prompt="Translate this SRT subtitle file from $src_lang to $target_lang. Keep ALL SRT formatting intact (numbers, timestamps, blank lines). Only translate the text lines. Output ONLY the translated SRT content, nothing else."

    local resp
    resp=$(curl -sf "https://api.mistral.ai/v1/chat/completions" \
        -H "Authorization: Bearer $MISTRAL_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"messages\": [
                {\"role\": \"user\", \"content\": $(python3 -c "import json; print(json.dumps('$prompt\n\n' + open('$input').read()))")}
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

    local prompt="Translate this SRT subtitle file from $src_lang to $target_lang. Keep ALL SRT formatting intact (numbers, timestamps, blank lines). Only translate the text lines. Output ONLY the translated SRT content, nothing else."

    local resp
    resp=$(curl -sf "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=$GEMINI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"contents\": [{
                \"parts\": [{\"text\": $(python3 -c "import json; print(json.dumps('$prompt\n\n' + open('$input').read()))")}]
            }],
            \"generationConfig\": {\"temperature\": 0.3}
        }" 2>/dev/null) || { err "Erreur API Gemini"; return 1; }

    echo "$resp" | jq -r '.candidates[0].content.parts[0].text' > "$output"
}

# Traduction principale avec chunking
translate_subtitle() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4" provider="$5"

    header "Traduction AI ($provider)"
    info "Source: $src_lang -> Cible: $target_lang"

    local total_lines
    total_lines=$(wc -l < "$input" | tr -d ' ')

    if [[ $total_lines -le 300 ]]; then
        # Fichier assez petit, traduction directe
        case "$provider" in
            claude-code) translate_with_claude_code "$input" "$output" "$src_lang" "$target_lang" ;;
            zai-codeplan) translate_with_zai_codeplan "$input" "$output" "$src_lang" "$target_lang" ;;
            openai)      translate_with_openai "$input" "$output" "$src_lang" "$target_lang" ;;
            claude)      translate_with_claude "$input" "$output" "$src_lang" "$target_lang" ;;
            mistral)     translate_with_mistral "$input" "$output" "$src_lang" "$target_lang" ;;
            gemini)      translate_with_gemini "$input" "$output" "$src_lang" "$target_lang" ;;
            *) die "Provider AI inconnu: $provider" ;;
        esac
    else
        # Fichier gros: on chunk
        info "Fichier volumineux ($total_lines lignes), decoupage en chunks..."
        local num_chunks
        num_chunks=$(chunk_srt "$input" 250)
        info "$num_chunks chunks a traduire"

        > "$output"  # vider le fichier de sortie

        for ((i=0; i<num_chunks; i++)); do
            local chunk_in="$CACHE_DIR/chunk_${i}.srt"
            local chunk_out="$CACHE_DIR/chunk_${i}_translated.srt"
            info "Chunk $((i+1))/$num_chunks..."

            case "$provider" in
                claude-code) translate_with_claude_code "$chunk_in" "$chunk_out" "$src_lang" "$target_lang" ;;
                zai-codeplan) translate_with_zai_codeplan "$chunk_in" "$chunk_out" "$src_lang" "$target_lang" ;;
                openai)      translate_with_openai "$chunk_in" "$chunk_out" "$src_lang" "$target_lang" ;;
                claude)      translate_with_claude "$chunk_in" "$chunk_out" "$src_lang" "$target_lang" ;;
                mistral)     translate_with_mistral "$chunk_in" "$chunk_out" "$src_lang" "$target_lang" ;;
                gemini)      translate_with_gemini "$chunk_in" "$chunk_out" "$src_lang" "$target_lang" ;;
                *) die "Provider AI inconnu: $provider" ;;
            esac

            cat "$chunk_out" >> "$output"
            rm -f "$chunk_in" "$chunk_out"
        done
    fi

    if [[ -s "$output" ]]; then
        log "Traduction terminee: $output"
    else
        err "La traduction a echoue (fichier vide)"
        return 1
    fi
}

# ── Traduction d'un fichier local ─────────────────────────────────────────────
translate_local_file() {
    local input="$1" src_lang="$2" target_lang="$3" provider="$4"
    local basename
    basename=$(basename "$input" | sed 's/\.[^.]*$//')
    local ext="${input##*.}"
    local output="${OUTPUT_DIR}/${basename}.${target_lang}.${ext}"

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
    fix         Reparer un SRT (encodage UTF-8, renumerotation, chevauchements)
    extract     Extraire les sous-titres d'une video (MKV, MP4)
    embed       Incruster un SRT dans une video
    config      Afficher/editer la configuration
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
    -p, --provider <provider> Provider AI (claude-code|zai-codeplan|openai|claude|mistral|gemini)
    -m, --model <model>       Modele AI a utiliser (override le modele par defaut du provider)
    --sources <src1,src2>     Sources (opensubtitles,podnapisi,subdl)
    --from <lang>             Langue source pour traduction
    --fallback-langs <l1,l2>  Langues de fallback (defaut: en,de,es,pt)
    --max-ep <num>            Nombre max d'episodes par saison (defaut: 20)
    --shift <ms>              Decalage en ms pour sync (ex: +1500, -800)
    --to <format>             Format cible pour convert (srt, vtt, ass)
    --merge-with <fichier>    Fichier secondaire pour merge bilingue
    --ref <video|srt>         Reference pour autosync (video ou SRT)
    --sub <fichier>           Fichier SRT pour embed dans une video
    --track <num>             Piste a extraire pour extract
    --force-translate         Forcer la traduction meme si sous-titres trouves
    -h, --help                Afficher cette aide
    -v, --version             Afficher la version

${BOLD}EXEMPLES${NC}
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

    local status
    if [[ -n "${OPENSUBTITLES_API_KEY:-}" ]]; then status="${GREEN}OK${NC}"; else status="${RED}NO KEY${NC}"; fi
    printf "  ${BOLD}%-18s${NC} ${status}       %s\n" "opensubtitles" "OpenSubtitles.com API v1 (gratuit avec inscription)"

    printf "  ${BOLD}%-18s${NC} ${GREEN}OK${NC}       %s\n" "podnapisi" "Podnapisi.net (pas de cle requise)"

    if [[ -n "${SUBDL_API_KEY:-}" ]]; then status="${GREEN}OK${NC}"; else status="${RED}NO KEY${NC}"; fi
    printf "  ${BOLD}%-18s${NC} ${status}       %s\n" "subdl" "SubDL.com API (gratuit avec inscription)"
}

# ── Commande: providers ──────────────────────────────────────────────────────
cmd_providers() {
    header "Providers AI pour traduction"
    printf "  ${BOLD}%-15s${NC} %-10s %-25s %s\n" "Provider" "Status" "Modele" "Description"
    printf "  %-15s %-10s %-25s %s\n" "───────────────" "──────────" "─────────────────────────" "──────────────────────"

    local status
    if command -v claude &>/dev/null; then status="${GREEN}OK${NC}"; else status="${RED}N/A${NC}"; fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "claude-code" "(Claude Code CLI)" "Defaut, pas de cle API requise"

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

            opensubtitles_login 2>/dev/null || true

            local success=0 fail=0 translated=0
            local season_dir="${OUTPUT_DIR}/S$(printf '%02d' "$PARSED_SEASON")"
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
    opensubtitles_login 2>/dev/null || true

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

    opensubtitles_login 2>/dev/null || true

    local success=0 fail=0 translated=0
    local season_dir="${OUTPUT_DIR}/S$(printf '%02d' "$SEASON")"
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

# ── Commande: translate ──────────────────────────────────────────────────────
cmd_translate() {
    [[ -z "$FILE_PATH" ]] && die "Specifie --file <fichier.srt>"
    [[ -z "$LANG_TARGET" ]] && die "Specifie --lang <code_langue_cible>"
    [[ ! -f "$FILE_PATH" ]] && die "Fichier introuvable: $FILE_PATH"

    local src_lang="${SRC_LANG:-en}"
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

    local removed=0

    python3 -c "
import re, sys

with open('$FILE_PATH', 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

original = content
removed = 0

# Supprimer tags HTML (<i>, <b>, <font>, etc.)
cleaned = re.sub(r'<[^>]+>', '', content)
if cleaned != content:
    diff = len(re.findall(r'<[^>]+>', content))
    removed += diff
    print(f'  Tags HTML supprimes: {diff}', file=sys.stderr)
content = cleaned

# Supprimer tags HI/SDH: [musique], (rires), ♪ lignes musicales ♪
cleaned = re.sub(r'^\s*[\[\(].*?[\]\)]\s*$', '', content, flags=re.MULTILINE)
diff = content.count('\n') - cleaned.count('\n')
if diff > 0:
    removed += diff
    print(f'  Tags HI/SDH supprimes: {diff}', file=sys.stderr)
content = cleaned

# Supprimer lignes musicales ♪...♪
cleaned = re.sub(r'^\s*♪.*?♪\s*$', '', content, flags=re.MULTILINE)
cleaned = re.sub(r'^\s*#.*?#\s*$', '', cleaned, flags=re.MULTILINE)

# Supprimer pubs/watermarks courants
ad_patterns = [
    r'(?i)^.*subscene.*$',
    r'(?i)^.*opensubtitles.*$',
    r'(?i)^.*addic7ed.*$',
    r'(?i)^.*synced.*by.*$',
    r'(?i)^.*subtitle.*by.*$',
    r'(?i)^.*ripped.*by.*$',
    r'(?i)^.*downloaded.*from.*$',
    r'(?i)^.*www\..*\.(com|net|org).*$',
]
for pat in ad_patterns:
    cleaned = re.sub(pat, '', cleaned, flags=re.MULTILINE)

# Supprimer les blocs SRT vides (numero + timestamp sans texte)
cleaned = re.sub(r'\d+\r?\n\d{2}:\d{2}:\d{2},\d{3}\s*-->\s*\d{2}:\d{2}:\d{2},\d{3}\r?\n\s*\r?\n', '', cleaned)

# Supprimer lignes vides multiples
cleaned = re.sub(r'\n{3,}', '\n\n', cleaned)

with open('$output', 'w', encoding='utf-8') as f:
    f.write(cleaned.strip() + '\n')

print(f'  Total modifications: {removed}+', file=sys.stderr)
" 2>&1

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

    python3 -c "
import re, sys

shift_ms = int('${SYNC_SHIFT}')

def ts_to_ms(ts):
    h, m, s_ms = ts.split(':')
    s, ms = s_ms.split(',')
    return int(h)*3600000 + int(m)*60000 + int(s)*1000 + int(ms)

def ms_to_ts(ms):
    if ms < 0: ms = 0
    h = ms // 3600000
    ms %= 3600000
    m = ms // 60000
    ms %= 60000
    s = ms // 1000
    ms %= 1000
    return f'{h:02d}:{m:02d}:{s:02d},{ms:03d}'

with open('$FILE_PATH', 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

def shift_timestamp(match):
    start = ts_to_ms(match.group(1)) + shift_ms
    end = ts_to_ms(match.group(2)) + shift_ms
    return f'{ms_to_ts(start)} --> {ms_to_ts(end)}'

result = re.sub(
    r'(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})',
    shift_timestamp,
    content
)

with open('$output', 'w', encoding='utf-8') as f:
    f.write(result)

print(f'Decalage applique: {shift_ms:+d}ms', file=sys.stderr)
" 2>&1

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

    python3 -c "
import re, sys

src_ext = '${src_ext}'.lower()
target = '${CONVERT_FORMAT}'.lower()
input_file = '$FILE_PATH'
output_file = '$output'

with open(input_file, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

def parse_srt(text):
    blocks = []
    pattern = re.compile(
        r'(\d+)\s*\n(\d{2}:\d{2}:\d{2}[,\.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,\.]\d{3})\s*\n((?:(?!\d+\s*\n\d{2}:\d{2}).+\n?)*)',
        re.MULTILINE
    )
    for m in pattern.finditer(text):
        blocks.append({
            'index': int(m.group(1)),
            'start': m.group(2).replace('.', ','),
            'end': m.group(3).replace('.', ','),
            'text': m.group(4).strip()
        })
    return blocks

def parse_vtt(text):
    text = re.sub(r'^WEBVTT.*?\n\n', '', text, flags=re.DOTALL)
    return parse_srt(text)

blocks = []
if src_ext in ('srt',):
    blocks = parse_srt(content)
elif src_ext in ('vtt',):
    blocks = parse_vtt(content)
elif src_ext in ('ass', 'ssa'):
    pattern = re.compile(r'Dialogue:\s*\d+,(\d+:\d{2}:\d{2}\.\d{2}),(\d+:\d{2}:\d{2}\.\d{2}),[^,]*,[^,]*,\d+,\d+,\d+,[^,]*,(.*)')
    def ass_to_srt_ts(ts):
        # 0:00:01.00 -> 00:00:01,000
        h, m, rest = ts.split(':')
        s, cs = rest.split('.')
        return f'{int(h):02d}:{m}:{s},{int(cs)*10:03d}'
    for i, m in enumerate(pattern.finditer(content), 1):
        start = ass_to_srt_ts(m.group(1))
        end = ass_to_srt_ts(m.group(2))
        text = re.sub(r'\{[^}]*\}', '', m.group(3)).replace(r'\N', '\n').strip()
        blocks.append({'index': i, 'start': start, 'end': end, 'text': text})

if not blocks:
    print(f'Erreur: aucun sous-titre parse depuis {src_ext}', file=sys.stderr)
    sys.exit(1)

def ts_srt_to_vtt(ts):
    return ts.replace(',', '.')

def ts_srt_to_ass(ts):
    h, m, rest = ts.split(':')
    s, ms = rest.split(',')
    return f'{int(h)}:{m}:{s}.{ms[:2]}'

with open(output_file, 'w', encoding='utf-8') as f:
    if target == 'srt':
        for i, b in enumerate(blocks, 1):
            f.write(f\"{i}\n{b['start']} --> {b['end']}\n{b['text']}\n\n\")
    elif target == 'vtt':
        f.write('WEBVTT\n\n')
        for i, b in enumerate(blocks, 1):
            f.write(f\"{i}\n{ts_srt_to_vtt(b['start'])} --> {ts_srt_to_vtt(b['end'])}\n{b['text']}\n\n\")
    elif target == 'ass':
        f.write('[Script Info]\nTitle: Converted by subtool\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080\n\n')
        f.write('[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n')
        f.write('Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,1,2,10,10,40,1\n\n')
        f.write('[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n')
        for b in blocks:
            text = b['text'].replace('\n', r'\N')
            f.write(f\"Dialogue: 0,{ts_srt_to_ass(b['start'])},{ts_srt_to_ass(b['end'])},Default,,0,0,0,,{text}\n\")

print(f'{len(blocks)} sous-titres convertis', file=sys.stderr)
" 2>&1

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

    python3 -c "
import re

def parse_srt(path):
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
    blocks = []
    pattern = re.compile(
        r'(\d+)\s*\n(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})\s*\n((?:(?!\d+\s*\n\d{2}:\d{2}).+\n?)*)',
        re.MULTILINE
    )
    for m in pattern.finditer(content):
        blocks.append({
            'start': m.group(2),
            'end': m.group(3),
            'text': m.group(4).strip()
        })
    return blocks

primary = parse_srt('$FILE_PATH')
secondary = parse_srt('$MERGE_FILE')

# Match par index (meme nombre de blocs)
with open('$output', 'w', encoding='utf-8') as f:
    for i, p in enumerate(primary):
        s_text = secondary[i]['text'] if i < len(secondary) else ''
        f.write(f\"{i+1}\n{p['start']} --> {p['end']}\n{p['text']}\n<i>{s_text}</i>\n\n\")

print(f'{len(primary)} sous-titres fusionnes')
" 2>&1

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

    python3 -c "
import re, sys

with open('$FILE_PATH', 'rb') as f:
    raw = f.read()

# Detection et conversion encodage -> UTF-8
for enc in ('utf-8-sig', 'utf-8', 'latin-1', 'cp1252', 'iso-8859-1', 'cp1250'):
    try:
        content = raw.decode(enc)
        if enc != 'utf-8':
            print(f'  Encodage detecte: {enc} -> UTF-8', file=sys.stderr)
        break
    except (UnicodeDecodeError, UnicodeError):
        continue
else:
    content = raw.decode('utf-8', errors='replace')
    print('  Encodage: force UTF-8 avec remplacement', file=sys.stderr)

# Normaliser les fins de ligne
content = content.replace('\r\n', '\n').replace('\r', '\n')

# Parser les blocs
pattern = re.compile(
    r'(\d+)\s*\n(\d{2}:\d{2}:\d{2}[,\.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,\.]\d{3})\s*\n((?:(?!\d+\s*\n\d{2}:\d{2}).+\n?)*)',
    re.MULTILINE
)

blocks = []
for m in pattern.finditer(content):
    start = m.group(2).replace('.', ',')
    end = m.group(3).replace('.', ',')
    text = m.group(4).strip()
    if text:
        blocks.append({'start': start, 'end': end, 'text': text})

# Corriger les chevauchements de timing
fixes = 0
for i in range(len(blocks) - 1):
    def ts_to_ms(ts):
        h, m, rest = ts.split(':')
        s, ms = rest.split(',')
        return int(h)*3600000 + int(m)*60000 + int(s)*1000 + int(ms)
    def ms_to_ts(ms):
        if ms < 0: ms = 0
        h = ms // 3600000; ms %= 3600000
        m = ms // 60000; ms %= 60000
        s = ms // 1000; ms %= 1000
        return f'{h:02d}:{m:02d}:{s:02d},{ms:03d}'

    end_ms = ts_to_ms(blocks[i]['end'])
    next_start_ms = ts_to_ms(blocks[i+1]['start'])
    if end_ms > next_start_ms:
        blocks[i]['end'] = ms_to_ts(next_start_ms - 1)
        fixes += 1

if fixes:
    print(f'  Chevauchements corriges: {fixes}', file=sys.stderr)

# Reecrire avec numerotation propre
with open('$output', 'w', encoding='utf-8') as f:
    for i, b in enumerate(blocks, 1):
        f.write(f\"{i}\n{b['start']} --> {b['end']}\n{b['text']}\n\n\")

print(f'  {len(blocks)} sous-titres, renumerotes en UTF-8', file=sys.stderr)
" 2>&1

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

    # Verifier ffsubsync
    if ! python3 -c "import ffsubsync" 2>/dev/null; then
        warn "ffsubsync non installe. Installation..."
        pip3 install ffsubsync || die "Echec installation ffsubsync. Installe-le: pip3 install ffsubsync"
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
            ffsubsync_args+=(--reference-stream "")
            ;;
        *)
            info "Mode: video <-> subtitle (extraction audio)"
            ;;
    esac

    if python3 -m ffsubsync "${ffsubsync_args[@]}" 2>&1; then
        log "Sync automatique: $output"
    else
        err "Echec ffsubsync"
        return 1
    fi
}

# ── Parse args ────────────────────────────────────────────────────────────────
SRC_LANG=""
COMMAND=""
EMBED_SUB=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            get|search|translate|batch|info|clean|sync|autosync|convert|merge|fix|extract|embed|config|providers|sources)
                COMMAND="$1"; shift ;;
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
            -h|--help)     usage; exit 0 ;;
            -v|--version)  echo "$VERSION"; exit 0 ;;
            *)             die "Option inconnue: $1. Utilise --help" ;;
        esac
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    load_config
    parse_args "$@"

    [[ -z "$COMMAND" ]] && { usage; exit 0; }

    mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"

    case "$COMMAND" in
        get)       cmd_get ;;
        search)    cmd_search ;;
        translate) cmd_translate ;;
        batch)     cmd_batch ;;
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
        providers) cmd_providers ;;
        sources)   cmd_sources ;;
        *)         die "Commande inconnue: $COMMAND" ;;
    esac
}

main "$@"
