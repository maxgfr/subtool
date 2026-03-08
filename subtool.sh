#!/usr/bin/env bash
set -euo pipefail

VERSION="1.7.5"
SCRIPT_NAME="$(basename "$0")"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/subtool"
CONFIG_FILE="$CONFIG_DIR/config"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/subtool"

# ── Colors ────────────────────────────────────────────────────────────────────
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
NO_EMBED=false
DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false
QUIET=false
SUBTITLE_URL=""

# ── Default models ────────────────────────────────────────────────────────────
MODEL_ZAI_CODEPLAN="glm-4.7"
MODEL_OPENAI="gpt-5-mini"
MODEL_CLAUDE="claude-haiku-4-5"
MODEL_MISTRAL="mistral-small-latest"
MODEL_GEMINI="gemini-2.5-flash"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { { $QUIET && return; printf "${GREEN}[+]${NC} %s\n" "$*"; } || true; }
warn()   { { $QUIET && return; printf "${YELLOW}[!]${NC} %s\n" "$*"; } || true; }
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

# Detect language from subtitle text via translate-shell (Google API), with offline fallback
detect_lang() {
    local sample="$1"
    [[ -z "$sample" ]] && return

    # Primary: use translate-shell (Google Translate API, already a required dependency)
    if command -v trans &>/dev/null; then
        local detected=""
        detected=$(trans -id -no-ansi "$sample" 2>/dev/null | grep "^Code" | awk '{print $2}') || true
        if [[ -n "$detected" && "$detected" != "null" ]]; then
            # Normalize regional variants (pt-BR -> pt, zh-CN -> zh, etc.)
            detected="${detected%%-*}"
            echo "$detected"
            return
        fi
    fi

    # Fallback: offline scoring (no network / trans unavailable)
    _detect_lang_offline "$sample"
}

# Offline language detection fallback (scoring-based)
_detect_lang_offline() {
    local sample="$1"
    local all_langs="en fr de es it pt ru pl nl sv da no fi tr"

    # Special characters (weight=3)
    local -A char_patterns=(
        [de]='ß|ü|Ü'
        [fr]='[àâ]|[éèêë]|[ùû]|[îï]|œ|«|»'
        [es]='ñ|¿|¡'
        [pt]='[ãõ]'
        [it]='[ìòù]'
        [pl]='[ąćęłńóśźż]|[ĄĆĘŁŃÓŚŹŻ]'
        [sv]='[åÅ]'
        [da]='[æøÆØ]'
        [no]='[æøåÆØÅ]'
        [fi]='ää|öö'
        [tr]='[şŞğĞıİ]|[çÇ]'
        [ru]='[а-яА-ЯёЁ]'
    )

    # Distinctive words (weight=1)
    local -A word_patterns=(
        [en]='\b(the|you|and|this|that|have|with|what|would|there|been|they|your|just|like|about|know|could|should|where|their|because|which|into|before|after|between|those|these|very|when|will|than|only|other|were|them|then|also|going|really|right|think|want|doesn|didn|can|our|she|his|her)\b'
        [fr]='\b(nous|vous|avec|dans|cette|mais|sont|pour|tout|elle|elles|aussi|comme|fait|avoir|être|même|encore|alors|rien|bien|très|peut|sans|faire|quel|dont|leur|quoi|jamais|toujours|après|avant|parce|depuis|comment|pourquoi|personne|quelque|maintenant|seulement)\b'
        [de]='\b(ich|und|nicht|sich|auch|noch|wir|wenn|aber|dann|schon|wird|haben|kann|mein|dein|hier|dass|jetzt|immer|wieder|diese|keine|doch|sein|nach|beim|einen|einem|einer|alles|warum|nichts|etwas|vielleicht|natürlich|zwischen|müssen|können|werden|wollen|sollen)\b'
        [es]='\b(pero|esto|tiene|muy|todo|están|porque|aquí|ahora|siempre|nunca|también|puede|hacer|ellos|nosotros|ustedes|bueno|cuando|donde|quien|nada|algo|mucho|todos|todas|después|antes|quiero|puedo|tengo|creo|estoy|vamos|verdad|entonces)\b'
        [it]='\b(sono|questo|anche|loro|della|quello|tutto|perché|dove|quando|ancora|sempre|fatto|stato|bene|dopo|prima|adesso|niente|qualcosa|troppo|proprio|siamo|abbiamo|voglio|posso|stai|cosa|allora|grazie|senza|ogni|deve|hanno)\b'
        [pt]='\b(isso|ele|ela|tem|muito|quando|ainda|agora|aqui|todo|todos|porque|depois|antes|sempre|nunca|nada|algo|mesmo|nossa|nosso|vocês|fazer|pode|obrigado|então|também|tudo|onde|quem|estou|tenho|acho|preciso)\b'
        [ru]='\b(что|это|как|так|все|они|мне|его|она|было|уже|мой|тебя|если|нет|вот|тут|есть|был|еще|тоже|только|когда|потому|может|будет|надо|знаю|ничего|очень|сейчас|здесь|почему|хорошо|ладно|давай|пожалуйста|спасибо|никогда|всегда)\b'
        [pl]='\b(jest|nie|tak|ale|jak|się|czy|już|jeszcze|tylko|tutaj|teraz|kiedy|dlaczego|gdzie|zawsze|nigdy|może|muszę|bardzo|dobrze|proszę|dzięki|wszystko|nic|ktoś|coś|trochę|właśnie|naprawdę|chcę|wiem|myślę|przepraszam|zobaczmy)\b'
        [nl]='\b(het|een|van|dat|zijn|niet|met|wat|maar|ook|als|nog|wel|naar|hij|zij|dit|werd|hebben|deze|hun|zou|waar|daar|moet|goed|geen|hier|toen|heel|waarom|alles|niets|altijd|nooit|misschien|kunnen|willen|moeten|omdat)\b'
        [sv]='\b(det|att|och|den|som|har|inte|med|för|var|kan|ska|vill|han|hon|alla|från|efter|bara|här|där|mycket|aldrig|alltid|varför|redan|sedan|kanske|ganska|också|igen|något|ingenting|behöver|gärna|tack)\b'
        [da]='\b(det|og|har|ikke|med|den|som|kan|han|hun|vil|skal|var|fra|her|der|men|alle|efter|bare|hvad|hvor|hvorfor|aldrig|altid|noget|ingenting|måske|også|igen|allerede|fordi|godt|meget|lidt|velkommen|tak)\b'
        [no]='\b(det|og|har|ikke|med|den|som|kan|han|hun|vil|skal|var|fra|her|der|men|alle|etter|bare|hva|hvor|hvorfor|aldri|alltid|kanskje|også|igjen|allerede|fordi|veldig|mye|litt|velkommen|takk|noen|noe|ingenting)\b'
        [fi]='\b(hän|mutta|niin|myös|vain|tämä|nyt|kun|jos|tai|ovat|ole|miksi|missä|sitten|vielä|aina|koskaan|ehkä|hyvin|paljon|kiitos|anteeksi|tiedän|haluan|pitää|minun|sinun|meidän|täällä|siellä|kaikki|mitään|jotain|mikään|olet|olen|emme|eivät|minä|sinä|hyvä|pois|heitä|meillä|heillä|tämän|tuolla|täytyy|tarpeeksi|ymmärrän)\b'
        [tr]='\b(bir|ben|sen|biz|siz|var|yok|ama|için|ile|gibi|daha|çok|kadar|sonra|önce|şimdi|burada|orada|neden|nasıl|nerede|zaman|hiç|hep|belki|tamam|teşekkür|lütfen|evet|hayır|bence|iyi|kötü|güzel)\b'
    )

    local -A scores
    local lang
    for lang in $all_langs; do scores[$lang]=0; done

    local count
    for lang in $all_langs; do
        [[ -z "${char_patterns[$lang]:-}" ]] && continue
        count=$(echo "$sample" | grep -oE "${char_patterns[$lang]}" 2>/dev/null | wc -l) || true
        scores[$lang]=$(( ${scores[$lang]} + (count + 0) * 3 ))
    done

    for lang in $all_langs; do
        count=$(echo "$sample" | grep -oiE "${word_patterns[$lang]}" 2>/dev/null | wc -l) || true
        scores[$lang]=$(( ${scores[$lang]} + (count + 0) ))
    done

    local best_lang="" best_score=0
    for lang in $all_langs; do
        if [[ ${scores[$lang]} -gt $best_score ]]; then
            best_score=${scores[$lang]}
            best_lang="$lang"
        fi
    done

    [[ $best_score -ge 3 ]] && echo "$best_lang"
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

# API keys for AI translation (optional — claude-code works without a key)
OPENAI_API_KEY=""
ANTHROPIC_API_KEY=""
MISTRAL_API_KEY=""
GEMINI_API_KEY=""
ZAI_API_KEY=""

# Default AI provider: claude-code, zai-codeplan, openai, claude, mistral, gemini
DEFAULT_AI_PROVIDER="google"  # or: claude-code, openai, claude, mistral, gemini

# Default models (leave empty to use defaults)
MODEL_CLAUDE_CODE=""
MODEL_ZAI_CODEPLAN=""
MODEL_OPENAI=""
MODEL_CLAUDE=""
MODEL_MISTRAL=""
MODEL_GEMINI=""
CONF
        info "Config created: $CONFIG_FILE"
    fi
}

load_config() {
    init_config
    # Save existing env vars before source
    local _saved_openai="${OPENAI_API_KEY:-}"
    local _saved_anthropic="${ANTHROPIC_API_KEY:-}"
    local _saved_mistral="${MISTRAL_API_KEY:-}"
    local _saved_gemini="${GEMINI_API_KEY:-}"
    local _saved_zai="${ZAI_API_KEY:-}"
    # shellcheck source=/dev/null
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    # Env vars take priority over config file
    [[ -n "$_saved_openai" ]] && OPENAI_API_KEY="$_saved_openai"
    [[ -n "$_saved_anthropic" ]] && ANTHROPIC_API_KEY="$_saved_anthropic"
    [[ -n "$_saved_mistral" ]] && MISTRAL_API_KEY="$_saved_mistral"
    [[ -n "$_saved_gemini" ]] && GEMINI_API_KEY="$_saved_gemini"
    [[ -n "$_saved_zai" ]] && ZAI_API_KEY="$_saved_zai"
    # Restore default models if config set them empty
    [[ -z "${MODEL_CLAUDE_CODE:-}" ]] && MODEL_CLAUDE_CODE="haiku"
    [[ -z "$MODEL_ZAI_CODEPLAN" ]] && MODEL_ZAI_CODEPLAN="glm-4.7"
    [[ -z "$MODEL_OPENAI" ]] && MODEL_OPENAI="gpt-5-mini"
    [[ -z "$MODEL_CLAUDE" ]] && MODEL_CLAUDE="claude-haiku-4-5"
    [[ -z "$MODEL_MISTRAL" ]] && MODEL_MISTRAL="mistral-small-latest"
    [[ -z "$MODEL_GEMINI" ]] && MODEL_GEMINI="gemini-2.5-flash"
    AI_PROVIDER="${DEFAULT_AI_PROVIDER:-google}"
}

# ── OpenSubtitles.org (free, no API key) ──────────────────────────────────────
search_opensubtitles_org() {
    local query="$1" lang="$2" imdb_id="${3:-}" season="${4:-}" episode="${5:-}"

    # Language -> 3-letter code mapping for OpenSubtitles
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

    # The .org API requires lowercase, otherwise 302 to invalid host
    local lower_query
    lower_query=$(echo "$query" | tr '[:upper:]' '[:lower:]')
    local encoded_query
    encoded_query=$(urlencode "$lower_query")

    # The .org API doesn't support query + season + episode in the same path
    # Search by query + language, then filter client-side
    local url="https://rest.opensubtitles.org/search/query-${encoded_query}/sublanguageid-${lang3}"

    local resp
    resp=$(api_retry curl -sf "$url" -H "User-Agent: subtool v${VERSION}") || return 1

    local count
    count=$(echo "$resp" | jq 'length' 2>/dev/null) || true
    [[ "$count" == "0" || -z "$count" ]] && return 1

    # Filter season/episode client-side if requested
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
        curl -sfL -o "$tmp_file" "$url" -H "User-Agent: subtool v${VERSION}" 2>/dev/null || { err "Download failed: $url"; return 1; }
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
            srt_found=$(find "$tmp_dir" -iname "*.srt" | head -1)
            if [[ -n "$srt_found" ]]; then
                mv "$srt_found" "$output"
            fi
            rm -rf "$tmp_dir" "$tmp_file"
        else
            mv "$tmp_file" "$output"
        fi
        [[ -s "$output" ]] && return 0 || return 1
    else
        err "Unrecognized URL: $url"
        return 1
    fi

    # OpenSubtitles.org subtitle ID download
    if [[ -n "$sub_id" ]]; then
        local dl_url="https://dl.opensubtitles.org/en/download/sub/${sub_id}"
        local tmp_gz="$CACHE_DIR/url_${sub_id}_$$.gz"
        curl -sfL -o "$tmp_gz" "$dl_url" -H "User-Agent: subtool v${VERSION}" 2>/dev/null || { err "Download failed: $dl_url"; return 1; }
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
            srt_found=$(find "$tmp_dir" -iname "*.srt" | head -1)
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
    # Podnapisi uses language-specific codes
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
    resp=$(api_retry curl -sf "https://www.podnapisi.net/subtitles/search/old?keywords=$encoded_query&language=$lang_code&output_type=json") || return 1

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

# ── Multi-source search ───────────────────────────────────────────────────────
search_all_sources() {
    local query="$1" lang="$2" imdb_id="${3:-}" season="${4:-}" episode="${5:-}"
    local results=""
    local found=false

    IFS=',' read -ra source_list <<< "$SOURCES"
    for source in "${source_list[@]}"; do
        source=$(echo "$source" | tr -d ' ')
        info "Searching on ${BOLD}$source${NC}..." >&2
        local result=""
        case "$source" in
            opensubtitles-org)
                result=$(search_opensubtitles_org "$query" "$lang" "$imdb_id" "$season" "$episode") ;;
            podnapisi)
                result=$(search_podnapisi "$query" "$lang") ;;
            *)
                warn "Unknown source: $source" ;;
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

# ── Interactive selection ─────────────────────────────────────────────────────
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
        return 0  # don't proceed to download in JSON mode
    fi

    # Auto-select first result
    if $AUTO_SELECT; then
        debug "Auto-select: first result"
        echo "${entries[0]}"
        return 0
    fi

    # Dry-run: just display results
    if $DRY_RUN; then
        header "Subtitles found"
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
    header "Subtitles found"
    for ((j=0; j<${#entries[@]}; j++)); do
        local name src_name downloads
        name=$(echo "${entries[$j]}" | jq -r '.name // "N/A"' 2>/dev/null)
        src_name=$(echo "${entries[$j]}" | jq -r '.source // "?"' 2>/dev/null)
        downloads=$(echo "${entries[$j]}" | jq -r '.downloads // 0' 2>/dev/null)
        printf "  ${BOLD}%2d${NC}) [${CYAN}%-15s${NC}] %s ${YELLOW}(%s DL)${NC}\n" "$((j+1))" "$src_name" "$name" "$downloads"
    done

    printf "\n"
    local choice
    read -rp "$(printf "${BOLD}Choice [1-${#entries[@]}]:${NC} ")" choice
    [[ -z "$choice" ]] && choice=1

    if [[ "$choice" -ge 1 && "$choice" -le ${#entries[@]} ]] 2>/dev/null; then
        echo "${entries[$((choice-1))]}"
    else
        err "Invalid choice"
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
        *) err "Unknown source: $source"; return 1 ;;
    esac
}

# ── AI Translation ────────────────────────────────────────────────────────────

# Split an SRT file into chunks to avoid exceeding API limits
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

    # Last chunk
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
        die "translate-shell required. Install it: brew install translate-shell"
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
    info "Google Translate: $total_text text lines to translate"

    # Step 2: Split text into chunks and translate in parallel
    local chunk_size=80
    local num_chunks=$(( (total_text + chunk_size - 1) / chunk_size ))
    local max_parallel=8
    info "$num_chunks chunks (max $max_parallel in parallel)"

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

        info "Translated: $((bend))/$num_chunks chunks"
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
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' -e '1s/^\xef\xbb\xbf//' -e $'s/\r$//' "$output"
        else
            sed -i -e '1s/^\xef\xbb\xbf//' -e $'s/\r$//' "$output"
        fi
    fi

    # Cleanup
    rm -f "$text_file" "$map_file" "$translated_file"
}

translate_with_claude_code() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    local model="${AI_MODEL:-$MODEL_CLAUDE_CODE}"
    info "Translating with Claude Code ($model, effort low)..."

    if ! command -v claude &>/dev/null; then
        err "claude CLI not installed. Install it: npm install -g @anthropic-ai/claude-code"
        return 1
    fi

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")
    local content
    content=$(<"$input")

    local full_input
    full_input=$(printf '%s\n\n%s' "$prompt" "$content")
    CLAUDECODE='' printf '%s' "$full_input" | claude -p --model "$model" --effort low --tools "" > "$output" 2>/dev/null || {
        err "Claude Code translation failed"
        return 1
    }
    [[ -s "$output" ]] || { err "Claude Code produced empty output"; return 1; }
}

translate_with_zai_codeplan() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${ZAI_API_KEY:-}" ]] && { err "ZAI_API_KEY not configured"; return 1; }
    local model="${AI_MODEL:-$MODEL_ZAI_CODEPLAN}"
    info "Translating with Z.ai Coding Plan ($model)..."

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")

    local resp
    resp=$(api_retry curl -sf "https://api.z.ai/api/coding/paas/v4/chat/completions" \
        -H "Authorization: Bearer $ZAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a professional subtitle translator. Preserve all SRT formatting exactly.\"},
                {\"role\": \"user\", \"content\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}
            ],
            \"temperature\": 0.3
        }") || { err "Z.ai API error"; return 1; }

    echo "$resp" | jq -r '.choices[0].message.content' > "$output"
}

translate_with_openai() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${OPENAI_API_KEY:-}" ]] && { err "OPENAI_API_KEY not configured"; return 1; }
    local model="${AI_MODEL:-$MODEL_OPENAI}"
    info "Translating with OpenAI ($model)..."

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")

    local escaped_content
    escaped_content=$(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)

    local resp
    resp=$(api_retry curl -sf "https://api.openai.com/v1/chat/completions" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a professional subtitle translator. Preserve all SRT formatting exactly.\"},
                {\"role\": \"user\", \"content\": $escaped_content}
            ],
            \"temperature\": 0.3
        }") || { err "OpenAI API error"; return 1; }

    echo "$resp" | jq -r '.choices[0].message.content' > "$output"
}

translate_with_claude() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${ANTHROPIC_API_KEY:-}" ]] && { err "ANTHROPIC_API_KEY not configured"; return 1; }
    local model="${AI_MODEL:-$MODEL_CLAUDE}"
    info "Translating with Claude API ($model)..."

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")

    local resp
    resp=$(api_retry curl -sf "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"max_tokens\": 8192,
            \"messages\": [
                {\"role\": \"user\", \"content\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}
            ]
        }") || { err "Claude API error"; return 1; }

    echo "$resp" | jq -r '.content[0].text' > "$output"
}

translate_with_mistral() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${MISTRAL_API_KEY:-}" ]] && { err "MISTRAL_API_KEY not configured"; return 1; }
    local model="${AI_MODEL:-$MODEL_MISTRAL}"
    info "Translating with Mistral ($model)..."

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")

    local resp
    resp=$(api_retry curl -sf "https://api.mistral.ai/v1/chat/completions" \
        -H "Authorization: Bearer $MISTRAL_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$model\",
            \"messages\": [
                {\"role\": \"user\", \"content\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}
            ],
            \"temperature\": 0.3
        }") || { err "Mistral API error"; return 1; }

    echo "$resp" | jq -r '.choices[0].message.content' > "$output"
}

translate_with_gemini() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    [[ -z "${GEMINI_API_KEY:-}" ]] && { err "GEMINI_API_KEY not configured"; return 1; }
    local model="${AI_MODEL:-$MODEL_GEMINI}"
    info "Translating with Gemini ($model)..."

    local prompt
    prompt=$(_translate_prompt "$src_lang" "$target_lang")

    local resp
    resp=$(api_retry curl -sf "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=$GEMINI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"contents\": [{
                \"parts\": [{\"text\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}]
            }],
            \"generationConfig\": {\"temperature\": 0.3}
        }") || { err "Gemini API error"; return 1; }

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
        *) die "Unknown provider: $provider" ;;
    esac
}

# Main translation with chunking
translate_subtitle() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4" provider="$5"

    header "Translation ($provider)"
    info "Source: $src_lang -> Target: $target_lang"

    # Google provider handles its own SRT parsing + batching — no chunking needed
    if [[ "$provider" == "google" ]]; then
        _translate_dispatch "$input" "$output" "$src_lang" "$target_lang" "$provider"
    else
        local total_lines
        total_lines=$(wc -l < "$input" | tr -d ' ')
        if [[ $total_lines -le 300 ]]; then
            _translate_dispatch "$input" "$output" "$src_lang" "$target_lang" "$provider"
        else
            info "Large file ($total_lines lines), splitting into chunks..."
            local num_chunks
            num_chunks=$(chunk_srt "$input" 150)
            local max_parallel=3
            info "$num_chunks chunks to translate (max $max_parallel in parallel)"

            : > "$output"

            # Parallel translation in batches
            for ((batch_start=0; batch_start<num_chunks; batch_start+=max_parallel)); do
                local pids=()
                local batch_end=$((batch_start + max_parallel))
                [[ $batch_end -gt $num_chunks ]] && batch_end=$num_chunks

                for ((i=batch_start; i<batch_end; i++)); do
                    local chunk_in="$CACHE_DIR/chunk_${i}.srt"
                    local chunk_out="$CACHE_DIR/chunk_${i}_translated.srt"
                    info "Chunk $((i+1))/$num_chunks (parallel)..."
                    _translate_dispatch "$chunk_in" "$chunk_out" "$src_lang" "$target_lang" "$provider" &
                    pids+=($!)
                done

                # Wait for batch to finish, track failures
                local chunk_failures=0
                for pid in "${pids[@]}"; do
                    wait "$pid" || ((chunk_failures++)) || true
                done
                [[ $chunk_failures -gt 0 ]] && warn "$chunk_failures chunk(s) failed in this batch"
            done

            # Reassemble in order
            local total_failures=0
            for ((i=0; i<num_chunks; i++)); do
                local chunk_out="$CACHE_DIR/chunk_${i}_translated.srt"
                if [[ -s "$chunk_out" ]]; then
                    cat "$chunk_out" >> "$output"
                else
                    warn "Chunk $((i+1)) empty, skip"
                    ((total_failures++)) || true
                fi
                rm -f "$CACHE_DIR/chunk_${i}.srt" "$chunk_out"
            done
            [[ $total_failures -gt 0 ]] && warn "Total: $total_failures/$num_chunks chunks failed"
        fi
    fi

    if [[ -s "$output" ]]; then
        # Validate that the output is still valid SRT
        if validate_srt "$output"; then
            log "Translation completed: $output"
        else
            warn "Translation completed but SRT format seems broken: $output"
        fi
    else
        err "Translation failed (empty file)"
        return 1
    fi
}

# ── Local file translation ────────────────────────────────────────────────────
translate_local_file() {
    local input="$1" src_lang="$2" target_lang="$3" provider="$4"

    # Auto-detect source language if not specified
    if [[ -z "$src_lang" ]]; then
        local sample
        sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$input" | head -20 | tr '\n' ' ')
        src_lang=$(detect_lang "$sample")
        if [[ -n "$src_lang" ]]; then
            info "Source language detected: $src_lang"
        else
            src_lang="en"
            info "Source language not detected, default: en"
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
Search and download subtitles, with AI translation as fallback.

${BOLD}USAGE${NC}
    $SCRIPT_NAME [OPTIONS] <command>

${BOLD}COMMANDS${NC}
    auto        All-in-one: download + translate + embed (--dir or --file)
    get         Smart search (auto-parse title/season/episode)
    search      Manual search (with -q/-s/-e)
    batch       Download a full season (with -s)
    translate   Translate a local subtitle file
    info        Display SRT file info (encoding, language, stats)
    clean       Clean an SRT (ads, HI/SDH tags, HTML)
    sync        Shift timecodes (+/- milliseconds)
    autosync    Auto sync with video/audio via ffsubsync
    convert     Convert between formats (SRT <-> VTT <-> ASS)
    merge       Merge 2 subtitles into bilingual
    fix         Repair an SRT (UTF-8 encoding, sorting, renumbering, overlaps)
    extract     Extract subtitles from a video (MKV, MP4)
    embed       Embed an SRT into a video
    config      Display/edit configuration (config set <KEY> <VALUE>)
    check       Diagnostic (deps, API keys, config)
    providers   List available AI providers
    sources     List subtitle sources

${BOLD}OPTIONS${NC}
    -q, --query <title>       Title of movie/series to search
    -l, --lang <code>         Target language (fr, en, es, de, it, pt, etc.)
    -i, --imdb <id>           IMDb ID (tt1234567)
    -s, --season <num>        Season number (series)
    -e, --episode <num>       Episode number (series)
    -f, --file <file>         SRT file to translate
    -o, --output <dir>        Output directory (default: .)
    -p, --provider <provider> Translation provider (google|claude-code|openai|claude|mistral|gemini)
    -m, --model <model>       AI model to use (overrides provider default model)
    --sources <src1,src2>     Sources (opensubtitles-org,podnapisi)
    --from <lang>             Source language for translation
    --fallback-langs <l1,l2>  Fallback languages (default: en,de,es,pt)
    --max-ep <num>            Max episodes per season (default: 20)
    --shift <ms>              Shift in ms for sync (e.g., +1500, -800)
    --to <format>             Target format for convert (srt, vtt, ass)
    --merge-with <file>       Secondary file for bilingual merge
    --ref <video|srt>         Reference for autosync (video or SRT)
    --sub <file>              SRT file to embed in a video
    --track <num>             Track to extract
    --url <url>               Download a subtitle from an opensubtitles.org URL
    --embed                   Embed subtitles in video (auto: active by default)
    --no-embed                Disable automatic embedding
    --force-translate         Force translation even if subtitles found
    --auto                    Automatically select first result
    --dry-run                 Display results without downloading
    --json                    JSON output (for integration with other tools)
    --verbose                 Display debug info
    --quiet                   Silent mode (errors only)
    -h, --help                Display this help
    -v, --version             Display version

${BOLD}EXAMPLES${NC}
    # Auto: download + translate + embed in one command
    $SCRIPT_NAME auto --dir ~/Movies/Die.Discounter -l fr
    $SCRIPT_NAME auto --dir ~/Movies/Die.Discounter -l fr --embed
    $SCRIPT_NAME auto -f movie.mkv -l fr

    # Smart get - single episode
    $SCRIPT_NAME get -q \"Die Discounter S01E03\" -l de

    # Smart get - full season
    $SCRIPT_NAME get -q \"Die Discounter S01\" -l de

    # Smart get - episode range
    $SCRIPT_NAME get -q \"Die Discounter S01E03-E08\" -l fr --force-translate -p zai-codeplan

    # Smart get - movie
    $SCRIPT_NAME get -q \"Inception 2010\" -l fr

    # Smart get - alternative format
    $SCRIPT_NAME get -q \"Die Discounter 1x05\" -l de
    $SCRIPT_NAME get -q \"Die Discounter saison 2\" -l de

    # Smart get - by IMDb ID
    $SCRIPT_NAME get -q \"tt16463942 S01E01\" -l de

    # Fallback: not available in FR -> search DE/EN and translate
    $SCRIPT_NAME get -q \"Die Discounter S01E03\" -l fr --force-translate

    # Local translation
    $SCRIPT_NAME translate -f episode.de.srt -l fr --from de -p zai-codeplan

    # Subtitle tools
    $SCRIPT_NAME info -f movie.srt
    $SCRIPT_NAME clean -f movie.srt
    $SCRIPT_NAME sync -f movie.srt --shift -1500
    $SCRIPT_NAME convert -f movie.srt --to vtt
    $SCRIPT_NAME merge -f movie.de.srt --merge-with movie.fr.srt
    $SCRIPT_NAME fix -f broken.srt
    $SCRIPT_NAME extract -f movie.mkv
    $SCRIPT_NAME embed -f movie.mkv --sub movie.fr.srt -l fr

    # Auto sync with video (ffsubsync)
    $SCRIPT_NAME autosync -f desync.srt --ref movie.mkv
    $SCRIPT_NAME autosync -f desync.srt --ref reference.srt
"
}

# ── Command: sources ─────────────────────────────────────────────────────────
cmd_sources() {
    header "Subtitle sources"
    printf "  ${BOLD}%-18s${NC} %-10s %s\n" "Source" "Status" "Description"
    printf "  %-18s %-10s %s\n" "──────────────────" "──────────" "──────────────────────"

    printf "  ${BOLD}%-18s${NC} ${GREEN}OK${NC}       %s\n" "opensubtitles-org" "OpenSubtitles.org REST (free, no key)"
    printf "  ${BOLD}%-18s${NC} ${GREEN}OK${NC}       %s\n" "podnapisi" "Podnapisi.net (free, no key)"
}

# ── Command: providers ───────────────────────────────────────────────────────
cmd_providers() {
    header "Translation providers"
    printf "  ${BOLD}%-15s${NC} %-10s %-25s %s\n" "Provider" "Status" "Model" "Description"
    printf "  %-15s %-10s %-25s %s\n" "───────────────" "──────────" "─────────────────────────" "──────────────────────"

    local status
    if command -v trans &>/dev/null; then status="${GREEN}OK${NC}"; else status="${RED}N/A${NC}"; fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "google" "Google Translate" "Default, free, ultra fast (translate-shell)"

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

# ── Command: config ───────────────────────────────────────────────────────────
cmd_config() {
    init_config

    # config set <key> <value>
    if [[ "${CONFIG_SUBCMD:-}" == "set" ]]; then
        local key="$CONFIG_KEY" value="$CONFIG_VALUE"
        [[ -z "$key" ]] && die "Usage: subtool config set <KEY> <VALUE>"
        # Update or add the key
        # Escape key and value for safe sed replacement (handle |, \, &, /)
        local escaped_key escaped_value
        escaped_key=$(printf '%s\n' "$key" | sed -e 's/[].[\\/^$*|]/\\&/g')
        escaped_value=$(printf '%s\n' "$value" | sed -e 's/[|\\&/]/\\&/g')
        if grep -q "^${escaped_key}=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i.bak "s|^${escaped_key}=.*|${key}=\"${escaped_value}\"|" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
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
        info "Config file: $CONFIG_FILE"
        printf "\n"
        cat "$CONFIG_FILE"
    fi
}

# ── Command: check (diagnostic) ──────────────────────────────────────────────
cmd_check() {
    header "Diagnostic subtool"

    local ok=true

    # Required deps
    printf "\n  ${BOLD}Required dependencies:${NC}\n"
    for dep in jq curl; do
        if command -v "$dep" &>/dev/null; then
            printf "  ${GREEN}OK${NC}  %-15s %s\n" "$dep" "$(command -v "$dep")"
        else
            printf "  ${RED}MISSING${NC}  %s\n" "$dep"
            ok=false
        fi
    done

    # Optional deps
    printf "\n  ${BOLD}Optional dependencies:${NC}\n"
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
        printf "  ${GREEN}OK${NC}  %-15s %s\n" "ffsubsync" "via uvx (on the fly)"
    else
        printf "  ${YELLOW}N/A${NC}  %-15s (autosync) — uvx ffsubsync or: uv tool install ffsubsync\n" "ffsubsync"
    fi
    if command -v trans &>/dev/null; then
        printf "  ${GREEN}OK${NC}  %-15s %s\n" "translate-shell" "$(command -v trans) (Google Translate, default)"
    else
        printf "  ${YELLOW}N/A${NC}  %-15s brew install translate-shell (provider google)\n" "translate-shell"
    fi
    if command -v claude &>/dev/null; then
        printf "  ${GREEN}OK${NC}  %-15s\n" "claude-code"
    else
        printf "  ${YELLOW}N/A${NC}  %-15s (provider claude-code)\n" "claude CLI"
    fi

    # API keys
    printf "\n  ${BOLD}API Keys:${NC}\n"
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
        printf "\n  ${GREEN}All good!${NC}\n"
    else
        printf "\n  ${RED}Required dependencies are missing.${NC}\n"
        return 1
    fi
}

# ── Smart parsing ─────────────────────────────────────────────────────────────
# Parse a query to extract title, season, episode, range, year, imdb
# Recognized formats:
#   "Die Discounter S01E03"        -> season 1, episode 3
#   "Die Discounter S01E03-E08"    -> season 1, episodes 3 to 8
#   "Die Discounter S01"           -> season 1 complete
#   "Die Discounter 1x03"          -> season 1, episode 3
#   "Die Discounter saison 2"      -> season 2 complete
#   "Die Discounter season 1 ep 5" -> season 1, episode 5
#   "Inception 2010"               -> movie, year 2010
#   "Inception"                    -> movie
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
    # S01E03 (single episode)
    elif [[ "$q" =~ [Ss]([0-9]{1,2})[Ee]([0-9]{1,3}) ]]; then
        PARSED_SEASON="${BASH_REMATCH[1]#0}"
        PARSED_EPISODE="${BASH_REMATCH[2]#0}"
        PARSED_MODE="episode"
        q="${q//${BASH_REMATCH[0]}/}"
    # S01 alone (full season)
    elif [[ "$q" =~ [Ss]([0-9]{1,2})([^0-9Ee]|$) ]]; then
        PARSED_SEASON="${BASH_REMATCH[1]#0}"
        PARSED_MODE="season"
        # Remove "S01" from query by rebuilding without the match
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

    # Year (2010, 2024...) — only if not already parsed as season/episode
    if [[ "$q" =~ (^|[[:space:]])(19[0-9]{2}|20[0-9]{2})($|[[:space:]]) ]]; then
        PARSED_YEAR="${BASH_REMATCH[2]}"
        q="${q//${BASH_REMATCH[2]}/}"
    fi

    # Clean title: trim spaces, orphan dashes, etc.
    PARSED_TITLE=$(echo "$q" | sed 's/[[:space:]]*-[[:space:]]*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\+/ /g')

    # If no mode detected and no season -> movie
    if [[ -z "$PARSED_MODE" ]]; then
        PARSED_MODE="movie"
    fi
}

# Display parsed info
show_parsed() {
    local icon
    case "$PARSED_MODE" in
        movie)   icon="Movie" ;;
        episode) icon="Episode" ;;
        season)  icon="Season" ;;
        range)   icon="Range" ;;
    esac
    printf "${CYAN}[i]${NC} Mode: ${BOLD}%s${NC}\n" "$icon"
    [[ -n "$PARSED_TITLE" ]] && info "Title: $PARSED_TITLE"
    [[ -n "$PARSED_IMDB" ]] && info "IMDb: $PARSED_IMDB"
    [[ -n "$PARSED_YEAR" ]] && info "Year: $PARSED_YEAR"
    [[ -n "$PARSED_SEASON" ]] && info "Season: $PARSED_SEASON"
    case "$PARSED_MODE" in
        episode) info "Episode: $PARSED_EPISODE" ;;
        range)   info "Episodes: $PARSED_EPISODE-$PARSED_EP_END" ;;
    esac
}

# ── Command: get (smart) ─────────────────────────────────────────────────────
cmd_get() {
    # Direct URL download mode
    if [[ -n "${SUBTITLE_URL:-}" ]]; then
        [[ -z "$LANG_TARGET" ]] && die "Specify --lang or -l <code>"
        local safe_name="subtitle_url_$$"
        local output="${OUTPUT_DIR}/${safe_name}.${LANG_TARGET}.srt"
        header "subtool get (URL)"
        info "URL: $SUBTITLE_URL"
        if download_from_url "$SUBTITLE_URL" "$output"; then
            log "Saved: $output"
            return 0
        else
            die "Download failed from URL: $SUBTITLE_URL"
        fi
    fi

    [[ -z "$SEARCH_QUERY" && -z "$IMDB_ID" ]] && die "Specify --query or -q <title>"
    [[ -z "$LANG_TARGET" ]] && die "Specify --lang or -l <code>"

    # If user already provided -s/-e, use them
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
        # If --imdb was also passed, it takes priority
        [[ -n "$IMDB_ID" ]] && PARSED_IMDB="$IMDB_ID"
    fi

    header "subtool get"
    show_parsed
    info "Language: $LANG_TARGET"
    printf "\n"

    # Sync parsed values back to globals (used by cmd_search/cmd_batch)
    SEARCH_QUERY="$PARSED_TITLE"
    IMDB_ID="$PARSED_IMDB"
    SEASON="$PARSED_SEASON"
    EPISODE="$PARSED_EPISODE"

    # Route to the correct mode
    case "$PARSED_MODE" in
        movie|episode)
            cmd_search
            ;;
        season)
            cmd_batch
            ;;
        range)

            local start_ep="$PARSED_EPISODE"
            local end_ep="$PARSED_EP_END"

            header "Downloading S$(printf '%02d' "$PARSED_SEASON")E$(printf '%02d' "$start_ep")-E$(printf '%02d' "$end_ep")"

        
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
                    [[ -z "$first" ]] && { warn "$ep_str: no results"; ((fail++)) || true; continue; }

                    local safe_name
                    safe_name=$(echo "${PARSED_TITLE:-imdb}_${ep_str}" | tr ' /' '_' | tr -cd '[:alnum:]._-')
                    local output="${season_dir}/${safe_name}.${LANG_TARGET}.srt"

                    if download_subtitle "$first" "$output" 2>/dev/null; then
                        log "$ep_str: $output"
                        ((success++)) || true
                    else
                        warn "$ep_str: download failed"
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
                                log "$ep_str: translated ($fallback_lang->$LANG_TARGET)"
                                ((translated++)) || true
                            else
                                warn "$ep_str: translation failed"
                                ((fail++)) || true
                            fi
                            rm -f "$tmp_src"
                        else
                            ((fail++)) || true
                        fi
                    else
                        warn "$ep_str: nothing found"
                        ((fail++)) || true
                    fi
                else
                    warn "$ep_str: not found"
                    ((fail++)) || true
                fi
            done

            header "Result"
            log "Downloaded: $success | Translated: $translated | Failed: $fail"
            log "Directory: $season_dir"
            ;;
    esac
}

# ── Command: search ──────────────────────────────────────────────────────────
cmd_search() {
    [[ -z "$SEARCH_QUERY" && -z "$IMDB_ID" ]] && die "Specify --query or --imdb"
    [[ -z "$LANG_TARGET" ]] && die "Specify --lang (e.g., fr, en, es)"

    local query="${SEARCH_QUERY:-}"

    header "Subtitle search"
    info "Title: ${query:-IMDB:$IMDB_ID}"
    info "Language: $LANG_TARGET"
    [[ -n "$SEASON" ]] && info "Season: $SEASON, Episode: $EPISODE"

    # Login OpenSubtitles if possible

    local results
    if results=$(search_all_sources "$query" "$LANG_TARGET" "$IMDB_ID" "$SEASON" "$EPISODE"); then
        local selected
        if selected=$(select_subtitle "$results"); then
            local name
            name=$(echo "$selected" | jq -r '.name // "subtitle"')
            local safe_name
            safe_name=$(echo "$name" | tr ' /' '_' | tr -cd '[:alnum:]._-')
            local output="${OUTPUT_DIR}/${safe_name}.${LANG_TARGET}.srt"

            log "Downloading..."
            if download_subtitle "$selected" "$output"; then
                log "Saved: $output"
            else
                err "Download failed"
                return 1
            fi
        fi
    else
        warn "No subtitles found for '$query' in '$LANG_TARGET'"

        if $FORCE_TRANSLATE; then
            info "Attempting fallback: searching in other languages then AI translation..."
            local fallback_found=false
            local fallback_lang=""
            local fallback_results=""

            IFS=',' read -ra fb_langs <<< "$FALLBACK_LANGS"
            for fl in "${fb_langs[@]}"; do
                fl=$(echo "$fl" | tr -d ' ')
                [[ "$fl" == "$LANG_TARGET" ]] && continue
                info "Trying '$fl'..."
                if fallback_results=$(search_all_sources "$query" "$fl" "$IMDB_ID" "$SEASON" "$EPISODE" 2>/dev/null); then
                    fallback_lang="$fl"
                    fallback_found=true
                    log "Subtitles found in '$fl'!"
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

                    log "Downloading subtitles ($fallback_lang)..."
                    if download_subtitle "$selected" "$tmp_src"; then
                        translate_subtitle "$tmp_src" "$output" "$fallback_lang" "$LANG_TARGET" "$AI_PROVIDER"
                        rm -f "$tmp_src"
                    else
                        err "Download failed"
                        return 1
                    fi
                fi
            else
                err "No subtitles found in any language ($FALLBACK_LANGS)"
                return 1
            fi
        else
            info "Use --force-translate to search in English and translate with AI"
        fi
    fi
}

# ── Command: batch (full season) ─────────────────────────────────────────────
cmd_batch() {
    [[ -z "$SEARCH_QUERY" && -z "$IMDB_ID" ]] && die "Specify --query or --imdb"
    [[ -z "$LANG_TARGET" ]] && die "Specify --lang"
    [[ -z "$SEASON" ]] && die "Specify --season"

    local query="${SEARCH_QUERY:-}"
    local max_ep="${MAX_EPISODE:-20}"

    header "Downloading season $SEASON"
    info "Title: ${query:-IMDB:$IMDB_ID}"
    info "Language: $LANG_TARGET | Episodes: 1-$max_ep"
    info "AI provider (if fallback): $AI_PROVIDER"


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
            # Take the first result automatically in batch
            local first
            first=$(echo "$results" | head -1)
            [[ -z "$first" ]] && { warn "$ep_str: no usable results"; ((fail++)) || true; continue; }

            local name
            name=$(echo "$first" | jq -r '.name // "subtitle"' 2>/dev/null)
            local safe_name
            safe_name=$(echo "${query:-imdb}_${ep_str}" | tr ' /' '_' | tr -cd '[:alnum:]._-')
            local output="${season_dir}/${safe_name}.${LANG_TARGET}.srt"

            if download_subtitle "$first" "$output" 2>/dev/null; then
                log "$ep_str: $output"
                ((success++)) || true
            else
                warn "$ep_str: download failed"
                ((fail++)) || true
            fi
        elif $FORCE_TRANSLATE; then
            # Fallback: search in other languages and translate
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
                        log "$ep_str: translated ($fallback_lang->$LANG_TARGET)"
                        ((translated++)) || true
                    else
                        warn "$ep_str: translation failed"
                        ((fail++)) || true
                    fi
                    rm -f "$tmp_src"
                else
                    warn "$ep_str: fallback download failed"
                    ((fail++)) || true
                fi
            else
                warn "$ep_str: nothing found in any language"
                ((fail++)) || true
            fi
        else
            # Episode not found = probable end of season
            if [[ $success -eq 0 && $ep -le 3 ]]; then
                warn "$ep_str: not found"
                ((fail++)) || true
            else
                info "$ep_str: not found (probable end of season)"
                break
            fi
        fi
    done

    header "Result"
    log "Downloaded: $success | Translated: $translated | Failed: $fail"
    log "Directory: $season_dir"
}

# ── Command: scan (auto-download from video folder) ──────────────────────────
cmd_scan() {
    [[ -z "$SCAN_DIR" ]] && die "Specify --dir <video_folder>"
    [[ ! -d "$SCAN_DIR" ]] && die "Directory not found: $SCAN_DIR"
    [[ -z "$LANG_TARGET" ]] && die "Specify --lang (e.g., fr, en, de)"

    local title_override="${SEARCH_QUERY:-}"
    local imdb_override="${IMDB_ID:-}"

    header "subtool scan"
    info "Directory: $SCAN_DIR"
    info "Language: $LANG_TARGET"
    [[ -n "$title_override" ]] && info "Title override: $title_override"
    [[ -n "$imdb_override" ]] && info "IMDb override: $imdb_override"
    $DRY_RUN && info "Mode: dry-run (no downloads)"
    $FORCE_TRANSLATE && info "Fallback translation: active ($FALLBACK_LANGS)"


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
            info "Skip (already exists): $base_name"
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
            warn "Unable to parse: $base_name"
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
                    warn "Download failed: $base_name"
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
                        log "Translated ($fallback_lang->$LANG_TARGET): $srt_path"
                        ((translated++)) || true
                        found=true
                    else
                        warn "Translation failed: $base_name"
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
    header "Scan result"
    if $DRY_RUN; then
        log "Total: $total | Skips: $skip | To process: $((total - skip))"
    else
        log "Total: $total | Downloaded: $success | Translated: $translated | Skips: $skip | Failed: $fail"
    fi
}

# ── Command: auto (all-in-one: download + translate + embed) ──────────────────
cmd_auto() {
    local target="$LANG_TARGET"
    [[ -z "$target" ]] && die "Specify --lang <target_language> (e.g., fr)"

    # Single file or directory mode
    local mode=""
    if [[ -n "$FILE_PATH" ]]; then
        [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"
        mode="file"
    elif [[ -n "$SCAN_DIR" ]]; then
        [[ ! -d "$SCAN_DIR" ]] && die "Directory not found: $SCAN_DIR"
        mode="dir"
    else
        die "Specify --file <video> or --dir <directory>"
    fi

    local title_override="${SEARCH_QUERY:-}"
    local imdb_override="${IMDB_ID:-}"
    # Embed by default if ffmpeg is available (--no-embed to disable)
    local do_embed=true
    if ! command -v ffmpeg &>/dev/null; then
        do_embed=false
    fi
    # Explicit override
    $AUTO_EMBED && do_embed=true
    [[ "${NO_EMBED:-false}" == "true" ]] && do_embed=false

    header "subtool auto"
    info "Target language: $target"
    $do_embed && info "Embed: active" || info "Embed: inactive (ffmpeg required)"

    local success=0 fail=0 skip=0 total=0

    # Collect video files
    local video_files=()
    if [[ "$mode" == "file" ]]; then
        video_files=("$FILE_PATH")
    else
        info "Directory: $SCAN_DIR"
        while IFS= read -r -d '' vf; do
            video_files+=("$vf")
        done < <(find "$SCAN_DIR" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.m4v" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.ts" \) -print0 2>/dev/null | sort -z)
    fi

    total=${#video_files[@]}
    info "$total videos found"

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
                warn "Unable to parse: $base_name"
                ((fail++)) || true
                continue
            fi

            # Try target language first
            local results=""
            if results=$(search_all_sources "$PARSED_TITLE" "$target" "$PARSED_IMDB" "$PARSED_SEASON" "$PARSED_EPISODE" 2>/dev/null); then
                local first
                first=$(echo "$results" | head -1)
                if [[ -n "$first" ]] && download_subtitle "$first" "$target_srt" 2>/dev/null; then
                    log "Downloaded (${target}): $target_srt"
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
                        log "Downloaded ($fl): $(basename "$dl_path")"
                        existing_srt="$dl_path"
                        existing_lang="$fl"
                        break
                    fi
                fi
            done

            # Nothing found anywhere — prompt for URL in interactive mode
            if [[ -z "$existing_srt" ]]; then
                if [[ -t 0 ]] && ! $AUTO_SELECT; then
                    warn "No subtitles found for: $base_name"
                    printf "  ${CYAN}Paste an opensubtitles.org URL (or Enter to skip):${NC} " >&2
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
                            log "Downloaded via URL ($detected_lang): $(basename "$proper_path")"
                        else
                            warn "URL download failed"
                        fi
                    fi
                fi
            fi
        fi

        # ── Step 3: Translate if we have a subtitle in another language ──
        if [[ -n "$existing_srt" && "$existing_lang" != "$target" ]]; then
            info "Translation: $existing_lang -> $target"
            if translate_subtitle "$existing_srt" "$target_srt" "$existing_lang" "$target" "$AI_PROVIDER"; then
                log "Translated: $(basename "$target_srt")"
                ((success++)) || true

                # ── Step 4: Sync with video ──
                _auto_sync "$video_file" "$target_srt"
                # ── Step 5: Embed if requested ──
                if $do_embed; then
                    _auto_embed "$video_file" "$target_srt" "$target"
                fi
                continue
            else
                warn "Translation failed: $base_name"
            fi
        elif [[ -z "$existing_srt" ]]; then
            warn "No subtitles for: $base_name"
        fi

        if [[ ! -f "$target_srt" ]]; then
            ((fail++)) || true
        fi
    done

    printf "\n"
    header "Auto result"
    log "Total: $total | OK: $success | Skips: $skip | Failed: $fail"
}

# Helper for auto-sync (sync subtitle with video via ffsubsync)
_auto_sync() {
    local video="$1" sub="$2"
    # Determine ffsubsync command
    local ffsubsync_cmd="ffsubsync"
    if ! command -v ffsubsync &>/dev/null; then
        if command -v uvx &>/dev/null; then
            ffsubsync_cmd="uvx ffsubsync"
            info "Using uvx ffsubsync"
        else
            warn "ffsubsync not available — skip sync. Install: uvx ffsubsync"
            return 0
        fi
    fi
    local synced="${sub%.srt}.synced.srt"
    info "Sync: $(basename "$sub") with $(basename "$video")"
    if $ffsubsync_cmd "$video" -i "$sub" -o "$synced" 2>/dev/null; then
        if [[ -s "$synced" ]]; then
            mv "$synced" "$sub"
            log "Sync OK: $(basename "$sub")"
        else
            warn "Sync failed — empty file, keeping original"
        fi
    else
        warn "Sync failed — keeping unsynced version"
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
        info "Embed skip (subtitles already present): $(basename "$video")"
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
        warn "Embed failed: $(basename "$video")"
        rm -f "$tmp_video"
    fi
}

# ── Command: translate ───────────────────────────────────────────────────────
cmd_translate() {
    [[ -z "$FILE_PATH" ]] && die "Specify --file <file.srt>"
    [[ -z "$LANG_TARGET" ]] && die "Specify --lang <target_language_code>"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    local src_lang="${SRC_LANG:-}"
    translate_local_file "$FILE_PATH" "$src_lang" "$LANG_TARGET" "$AI_PROVIDER"
}

# ── Command: info (SRT file stats) ───────────────────────────────────────────
cmd_info() {
    [[ -z "$FILE_PATH" ]] && die "Specify --file <file.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    header "Info: $(basename "$FILE_PATH")"

    local filesize line_count sub_count
    filesize=$(stat -f%z "$FILE_PATH" 2>/dev/null || stat -c%s "$FILE_PATH" 2>/dev/null)
    local encoding
    encoding=$(file --mime-encoding "$FILE_PATH" 2>/dev/null | awk -F': ' '{print $2}' || echo "unknown")
    line_count=$(wc -l < "$FILE_PATH" | tr -d ' ')
    sub_count=$(grep -cE '^[0-9]+$' "$FILE_PATH" 2>/dev/null || echo "0")

    # First and last timestamp (format: HH:MM:SS,mmm --> HH:MM:SS,mmm)
    local first_ts last_ts
    first_ts=$(grep -m1 -oE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}' "$FILE_PATH" 2>/dev/null | head -1)
    local first_start="${first_ts%% -->*}"
    last_ts=$(grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}' "$FILE_PATH" 2>/dev/null | tail -1)
    local last_end="${last_ts##*--> }"

    # Language detection
    local sample_text
    sample_text=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$FILE_PATH" | head -20 | tr '\n' ' ')
    local detected_lang="?"
    if echo "$sample_text" | grep -qiE '\b(the|and|is|are|you|that|this|have|with)\b'; then
        detected_lang="en (English)"
    elif echo "$sample_text" | grep -qiE '\b(le|la|les|des|est|une|que|pas|avec|dans)\b'; then
        detected_lang="fr (French)"
    elif echo "$sample_text" | grep -qiE '\b(der|die|das|und|ist|ein|nicht|ich|mit|auf)\b'; then
        detected_lang="de (German)"
    elif echo "$sample_text" | grep -qiE '\b(el|la|los|las|que|del|una|por|con|para)\b'; then
        detected_lang="es (Spanish)"
    elif echo "$sample_text" | grep -qiE '\b(il|la|che|non|per|una|con|sono|del|questo)\b'; then
        detected_lang="it (Italian)"
    elif echo "$sample_text" | grep -qiE '\b(o|que|de|da|em|um|uma|com|para|por)\b'; then
        detected_lang="pt (Portuguese)"
    fi

    # Tags HI / SDH
    local hi_count
    hi_count=$(grep -cE '\[.*\]|\(.*\)' "$FILE_PATH" || true)

    # Tags HTML
    local html_count
    html_count=$(grep -cE '<[^>]+>' "$FILE_PATH" || true)

    # Human-readable size
    local size_human
    if [[ "$filesize" -gt 1048576 ]]; then
        size_human="$((filesize / 1048576)) MB"
    elif [[ "$filesize" -gt 1024 ]]; then
        size_human="$((filesize / 1024)) KB"
    else
        size_human="${filesize} B"
    fi

    printf "  ${BOLD}%-20s${NC} %s\n" "Size" "$size_human"
    printf "  ${BOLD}%-20s${NC} %s\n" "Encoding" "$encoding"
    printf "  ${BOLD}%-20s${NC} %s\n" "Lines" "$line_count"
    printf "  ${BOLD}%-20s${NC} %s\n" "Subtitles" "$sub_count"
    printf "  ${BOLD}%-20s${NC} %s\n" "Start" "${first_start:-N/A}"
    printf "  ${BOLD}%-20s${NC} %s\n" "End" "${last_end:-N/A}"
    printf "  ${BOLD}%-20s${NC} %s\n" "Detected language" "$detected_lang"
    if [[ "$hi_count" -gt 0 ]]; then printf "  ${BOLD}%-20s${NC} ${YELLOW}%s HI/SDH tags${NC}\n" "Accessibility" "$hi_count"; fi
    if [[ "$html_count" -gt 0 ]]; then printf "  ${BOLD}%-20s${NC} ${YELLOW}%s HTML tags${NC}\n" "Formatting" "$html_count"; fi
}

# ── Command: clean (SRT cleanup) ─────────────────────────────────────────────
cmd_clean() {
    [[ -z "$FILE_PATH" ]] && die "Specify --file <file.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    local base_name ext output
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${base_name}.clean.${ext}"

    header "Cleaning: $(basename "$FILE_PATH")"

    local html_count hi_count
    html_count=$(grep -cE '<[^>]+>' "$FILE_PATH" || true)
    hi_count=$(grep -cE '^\s*[\[\(].*[\]\)]' "$FILE_PATH" || true)

    [[ "$html_count" -gt 0 ]] && echo "  HTML tags removed: $html_count" >&2
    [[ "$hi_count" -gt 0 ]] && echo "  HI/SDH tags removed: $hi_count" >&2

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

    echo "  Total changes: $((html_count + hi_count))+" >&2

    log "Cleaned file: $output"
}

# ── Command: sync (time shift) ────────────────────────────────────────────────
SYNC_SHIFT=""

cmd_sync() {
    [[ -z "$FILE_PATH" ]] && die "Specify --file <file.srt>"
    [[ -z "$SYNC_SHIFT" ]] && die "Specify --shift <ms> (e.g., +1500, -800)"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    local base_name ext output
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${base_name}.synced.${ext}"

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

    echo "Shift applied: ${shift_val}ms" >&2

    log "Synced file: $output"
}

# ── Command: convert (SRT <-> VTT <-> ASS) ───────────────────────────────────
CONVERT_FORMAT=""

cmd_convert() {
    [[ -z "$FILE_PATH" ]] && die "Specify --file <file>"
    [[ -z "$CONVERT_FORMAT" ]] && die "Specify --to <format> (srt, vtt, ass)"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    local base_name src_ext
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    src_ext="${FILE_PATH##*.}"
    local output="${OUTPUT_DIR}/${base_name}.${CONVERT_FORMAT}"

    header "Convert: ${src_ext} -> ${CONVERT_FORMAT}"

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
        printf "%d subtitles converted\n", count > "/dev/stderr"
    }
    ' "$FILE_PATH" 2>&1

    log "Converted file: $output"
}

# ── Command: merge (bilingual subtitles) ─────────────────────────────────────
MERGE_FILE=""

cmd_merge() {
    [[ -z "$FILE_PATH" ]] && die "Specify --file <primary_file.srt>"
    [[ -z "$MERGE_FILE" ]] && die "Specify --merge-with <secondary_file.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"
    [[ ! -f "$MERGE_FILE" ]] && die "File not found: $MERGE_FILE"

    local base_name ext output
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${base_name}.dual.${ext}"

    header "Bilingual merge"
    info "Primary: $(basename "$FILE_PATH")"
    info "Secondary: $(basename "$MERGE_FILE")"

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
        text=$(printf '%b' "$text")
        sec_text=$(printf '%b' "$sec_text")
        printf '%d\n%s --> %s\n%s\n<i>%s</i>\n\n' "$idx" "$start" "$end_ts" "$text" "$sec_text" >> "$output"
    done < "$tmp_pri"

    echo "$idx subtitles merged" >&2
    rm -f "$tmp_pri" "$tmp_sec"

    log "Bilingual file: $output"
}

# ── Command: fix (SRT repair) ────────────────────────────────────────────────
cmd_fix() {
    [[ -z "$FILE_PATH" ]] && die "Specify --file <file.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    local base_name ext output
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${base_name}.fixed.${ext}"

    header "Repair: $(basename "$FILE_PATH")"

    # Detect encoding
    local encoding
    encoding=$(file --mime-encoding "$FILE_PATH" 2>/dev/null | awk -F': ' '{print $2}')
    if [[ "$encoding" != "utf-8" && "$encoding" != "us-ascii" ]]; then
        echo "  Detected encoding: ${encoding} -> UTF-8" >&2
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
            printf "  Reordered blocks: %d swaps\n", sorted > "/dev/stderr"

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
            printf "  Fixed overlaps: %d\n", fixes > "/dev/stderr"

        # Write output with proper numbering
        for (i = 1; i <= count; i++)
            printf "%d\n%s --> %s\n%s\n\n", i, starts[i], ends[i], texts[i]

        printf "  %d subtitles, renumbered in UTF-8\n", count > "/dev/stderr"
    }
    ' > "$output"

    log "Repaired file: $output"
}

# ── Command: extract (extract subtitles from video) ──────────────────────────
EXTRACT_TRACK=""

cmd_extract() {
    [[ -z "$FILE_PATH" ]] && die "Specify --file <video.mkv>"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    if ! command -v ffmpeg &>/dev/null; then
        die "ffmpeg required for extraction. Install it: brew install ffmpeg"
    fi

    local base_name
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')

    header "Extract subtitles: $(basename "$FILE_PATH")"

    # List subtitle tracks
    local streams
    streams=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$FILE_PATH" 2>/dev/null)
    local count
    count=$(echo "$streams" | jq '.streams | length' 2>/dev/null)

    if [[ "$count" == "0" || -z "$count" ]]; then
        err "No subtitle tracks found"
        return 1
    fi

    info "Tracks found:"
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
        read -rp "$(printf "${BOLD}Track to extract [0-$((count-1))]:${NC} ")" track
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
            warn "Bitmap subtitles ($codec) - extracting as .sup"
            ext="sup" ;;
        *)           ext="srt" ;;
    esac

    local output="${OUTPUT_DIR}/${base_name}.${lang}.${ext}"
    ffmpeg -v quiet -i "$FILE_PATH" -map "0:s:${track}" -c:s "$([[ "$ext" == "srt" ]] && echo "srt" || echo "copy")" "$output" -y 2>/dev/null

    if [[ -s "$output" ]]; then
        log "Extracted: $output"
    else
        err "Extraction failed"
        return 1
    fi
}

# ── Command: embed (embed subtitles in video) ────────────────────────────────
cmd_embed() {
    [[ -z "$FILE_PATH" ]] && die "Specify --file <video.mkv>"
    [[ -z "$EMBED_SUB" ]] && die "Specify --sub <file.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "Video not found: $FILE_PATH"
    [[ ! -f "$EMBED_SUB" ]] && die "Subtitle not found: $EMBED_SUB"

    if ! command -v ffmpeg &>/dev/null; then
        die "ffmpeg required. Install it: brew install ffmpeg"
    fi

    local base_name ext output
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${base_name}.subbed.${ext}"

    local sub_lang="${LANG_TARGET:-und}"

    header "Embed subtitles"
    info "Video: $(basename "$FILE_PATH")"
    info "Subtitle: $(basename "$EMBED_SUB") ($sub_lang)"

    ffmpeg -v quiet -i "$FILE_PATH" -i "$EMBED_SUB" \
        -c copy -c:s srt \
        -metadata:s:s:0 language="$sub_lang" \
        "$output" -y 2>/dev/null

    if [[ -s "$output" ]]; then
        log "Video with subtitles: $output"
    else
        err "Embedding failed"
        return 1
    fi
}

# ── Command: autosync (ffsubsync - auto sync with video/audio) ───────────────
AUTOSYNC_REF=""

cmd_autosync() {
    [[ -z "$FILE_PATH" ]] && die "Specify --file <subtitle.srt>"
    [[ -z "$AUTOSYNC_REF" ]] && die "Specify --ref <video.mkv or reference.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"
    [[ ! -f "$AUTOSYNC_REF" ]] && die "Reference not found: $AUTOSYNC_REF"

    # Determine ffsubsync command
    local ffsubsync_cmd="ffsubsync"
    if ! command -v ffsubsync &>/dev/null; then
        if command -v uvx &>/dev/null; then
            ffsubsync_cmd="uvx ffsubsync"
            info "Using uvx ffsubsync (no local install)"
        else
            die "ffsubsync not available. Install it: uvx ffsubsync (or: uv tool install ffsubsync)"
        fi
    fi

    local base_name ext output
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${base_name}.synced.${ext}"

    local ref_ext="${AUTOSYNC_REF##*.}"

    header "Auto-sync (ffsubsync)"
    info "Subtitle: $(basename "$FILE_PATH")"
    info "Reference: $(basename "$AUTOSYNC_REF")"

    local ffsubsync_args=()
    ffsubsync_args+=("$AUTOSYNC_REF")
    ffsubsync_args+=(-i "$FILE_PATH")
    ffsubsync_args+=(-o "$output")

    # If reference is SRT/ASS, use subtitle-to-subtitle mode
    case "$ref_ext" in
        srt|ass|ssa|vtt|sub)
            info "Mode: subtitle <-> subtitle"
            ;;
        *)
            info "Mode: video <-> subtitle (audio extraction)"
            ;;
    esac

    if $ffsubsync_cmd "${ffsubsync_args[@]}" 2>&1; then
        log "Auto sync: $output"
    else
        err "ffsubsync failed"
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

# shellcheck disable=SC2034
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
            *)             die "Unknown option: $1. Use --help" ;;
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
        *)         die "Unknown command: $COMMAND" ;;
    esac
}

main "$@"
