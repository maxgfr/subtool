#!/usr/bin/env bash
set -euo pipefail

VERSION="1.20.1"
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
SCAN_DIR=""
SEASON=""
EPISODE=""
OUTPUT_DIR="."
FORCE_TRANSLATE=false
KEEP_FILES=false
SOURCES="opensubtitles-org"
FALLBACK_LANGS="en,de,es,pt"
MAX_EPISODE=20
AI_MODEL=""
AUTO_SELECT=false
AUTO_EMBED=false
NO_EMBED=false
FORCE_EMBED=true
DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false
QUIET=false
SUBTITLE_URL=""
TRANSCRIBE_PROVIDER="whisper"
WHISPER_MODEL=""
TRANSLATE_CHUNK_SIZE=""
MAX_TOKENS=""
NO_TRANSCRIBE=false
FORCE_TRANSCRIBE=false
CLAUDE_EFFORT=""
SKIP_STEPS=""
TRANSLATE_MAX_PARALLEL=""
AUTO_SYNC_SHIFT=""
# Set by _auto_sync after each invocation. Lets callers (e.g. _auto_mix) detect
# sub-to-sub sync failure and choose an appropriate fallback.
_LAST_SYNC_OK=false
NO_RESUME=true
PLAYLIST_FILE=""
DIFF_FILE=""
MIX_FILE=""
MIX_MODE=false
MIX_LANG=""
MIX_TRANSLATE=false
SWAP_MIX=false
STRIP_EXISTING=false

# ── Default models ────────────────────────────────────────────────────────────
MODEL_ZAI_CODEPLAN="glm-4.7"
MODEL_OPENAI="gpt-5-mini"
MODEL_CLAUDE="claude-haiku-4-5"
MODEL_MISTRAL="mistral-small-latest"
MODEL_GEMINI="gemini-2.5-flash"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { { $QUIET && return; printf "${GREEN}[+]${NC} %s\n" "$*" >&2; } || true; }
warn()   { { $QUIET && return; printf "${YELLOW}[!]${NC} %s\n" "$*" >&2; } || true; }
err()    { printf "${RED}[x]${NC} %s\n" "$*" >&2; }
info()   { { $QUIET && return; printf "${CYAN}[i]${NC} %s\n" "$*" >&2; } || true; }
debug()  { $VERBOSE && printf "${BLUE}[D]${NC} %s\n" "$*" >&2 || true; }
header() { { $QUIET && return; printf "\n${BOLD}${BLUE}── %s ──${NC}\n" "$*" >&2; } || true; }

die() { err "$1"; exit 1; }

# Progress bar: progress <current> <total> [label]
progress() {
    $QUIET && return || true
    local current="$1" total="$2" label="${3:-}"
    [[ $total -le 0 ]] && return || true
    local pct=$((current * 100 / total))
    local filled=$((pct / 2))
    local empty=$((50 - filled))
    local bar
    bar=$(printf '%*s' "$filled" '' | tr ' ' '█')$(printf '%*s' "$empty" '' | tr ' ' '░')
    printf "\r  %s [%s] %d%% (%d/%d)  " "$label" "$bar" "$pct" "$current" "$total" >&2
    [[ $current -ge $total ]] && printf "\n" >&2 || true
}

# Multi-language dispatch: if LANG_TARGET has commas, loop over each language
# Usage: _multi_lang_dispatch <function_name> && return
_multi_lang_dispatch() {
    local func="$1"
    [[ "$LANG_TARGET" != *,* ]] && return 1
    local saved_lang="$LANG_TARGET"
    IFS=',' read -ra _ml_langs <<< "$saved_lang"
    for _ml_lang in "${_ml_langs[@]}"; do
        _ml_lang=$(echo "$_ml_lang" | tr -d ' ')
        [[ -z "$_ml_lang" ]] && continue
        printf "\n${BOLD}${BLUE}── Language: %s ──${NC}\n" "$_ml_lang" >&2
        LANG_TARGET="$_ml_lang"
        "$func" || warn "Failed for language: $_ml_lang"
    done
    LANG_TARGET="$saved_lang"
    return 0
}

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
    return 0
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

# Separate API key for transcription (falls back to OPENAI_API_KEY if empty)
OPENAI_WHISPER_API_KEY=""

# Default language (e.g., fr, en, de — so you don't need -l every time)
DEFAULT_LANG=""

# Default AI provider: claude-code, zai-codeplan, openai, claude, mistral, gemini
DEFAULT_AI_PROVIDER="google"  # or: claude-code, openai, claude, mistral, gemini

# Default models (leave empty to use defaults)
MODEL_CLAUDE_CODE=""
MODEL_ZAI_CODEPLAN=""
MODEL_OPENAI=""
MODEL_CLAUDE=""
MODEL_MISTRAL=""
MODEL_GEMINI=""

# Default transcription provider: whisper, openai-api
DEFAULT_TRANSCRIBE_PROVIDER=""

# Whisper model (tiny, base, small, medium, large) — leave empty for "small"
WHISPER_MODEL=""

# Translation chunk size (lines per chunk) — leave empty for defaults (80 google, 500 LLM)
TRANSLATE_CHUNK_SIZE=""

# Max output tokens for LLM translation — leave empty for auto (based on provider/model)
MAX_TOKENS=""

# Claude Code effort level (low, medium, high) — leave empty for "low"
CLAUDE_EFFORT=""

# Max parallel translation chunks — leave empty for defaults (3 LLM, 8 google)
TRANSLATE_MAX_PARALLEL=""

# Extra constant shift in ms applied after ffsubsync in auto mode (e.g., -2000)
AUTO_SYNC_SHIFT=""
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
    local _saved_openai_whisper="${OPENAI_WHISPER_API_KEY:-}"
    # shellcheck source=/dev/null
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    # Env vars take priority over config file
    [[ -n "$_saved_openai" ]] && OPENAI_API_KEY="$_saved_openai"
    [[ -n "$_saved_anthropic" ]] && ANTHROPIC_API_KEY="$_saved_anthropic"
    [[ -n "$_saved_mistral" ]] && MISTRAL_API_KEY="$_saved_mistral"
    [[ -n "$_saved_gemini" ]] && GEMINI_API_KEY="$_saved_gemini"
    [[ -n "$_saved_zai" ]] && ZAI_API_KEY="$_saved_zai"
    [[ -n "$_saved_openai_whisper" ]] && OPENAI_WHISPER_API_KEY="$_saved_openai_whisper"
    # Restore default models if config set them empty
    [[ -z "${MODEL_CLAUDE_CODE:-}" ]] && MODEL_CLAUDE_CODE="haiku"
    [[ -z "$MODEL_ZAI_CODEPLAN" ]] && MODEL_ZAI_CODEPLAN="glm-4.7"
    [[ -z "$MODEL_OPENAI" ]] && MODEL_OPENAI="gpt-5-mini"
    [[ -z "$MODEL_CLAUDE" ]] && MODEL_CLAUDE="claude-haiku-4-5"
    [[ -z "$MODEL_MISTRAL" ]] && MODEL_MISTRAL="mistral-small-latest"
    [[ -z "$MODEL_GEMINI" ]] && MODEL_GEMINI="gemini-2.5-flash"
    AI_PROVIDER="${DEFAULT_AI_PROVIDER:-google}"
    TRANSCRIBE_PROVIDER="${DEFAULT_TRANSCRIBE_PROVIDER:-whisper}"
    [[ -z "${WHISPER_MODEL:-}" ]] && WHISPER_MODEL="small"
    [[ -z "${CLAUDE_EFFORT:-}" ]] && CLAUDE_EFFORT="low"
    # Apply default language from config (CLI -l flag overrides later in parse_args)
    [[ -z "$LANG_TARGET" && -n "${DEFAULT_LANG:-}" ]] && LANG_TARGET="$DEFAULT_LANG" || true
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

    # Build URL with path segments in alphabetical order (API requires this)
    local url="https://rest.opensubtitles.org/search/"
    [[ -n "$episode" ]] && url+="episode-${episode}/"
    url+="query-${encoded_query}/"
    [[ -n "$season" ]] && url+="season-${season}/"
    url+="sublanguageid-${lang3}"

    local resp
    resp=$(api_retry curl -sf "$url" -H "User-Agent: subtool v${VERSION}") || return 1

    local count
    count=$(echo "$resp" | jq 'length' 2>/dev/null) || true
    [[ "$count" == "0" || -z "$count" ]] && return 1

    local filtered="$resp"

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

# ── Fuzzy search normalization ────────────────────────────────────────────────
# Strips accents, common punctuation, normalizes spaces — tolerates typos in queries
_fuzzy_normalize() {
    local q="$1"
    # Strip accents using iconv (transliterate to ASCII)
    if command -v iconv &>/dev/null; then
        q=$(echo "$q" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || echo "$q")
    fi
    # Collapse common separators (dots, underscores, dashes) to spaces
    q=$(echo "$q" | sed -E 's/[._-]+/ /g')
    # Remove non-alphanumeric except spaces
    q=$(echo "$q" | sed -E 's/[^[:alnum:] ]//g')
    # Collapse multiple spaces
    q=$(echo "$q" | tr -s ' ')
    # Trim
    q=$(echo "$q" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    echo "$q"
}

# ── Multi-source search ───────────────────────────────────────────────────────
search_all_sources() {
    local query="$1" lang="$2" imdb_id="${3:-}" season="${4:-}" episode="${5:-}"
    local results=""
    local found=false

    # Normalize query for fuzzy matching
    query=$(_fuzzy_normalize "$query")
    debug "Fuzzy-normalized query: '$query'" || true

    IFS=',' read -ra source_list <<< "$SOURCES"
    for source in "${source_list[@]}"; do
        source=$(echo "$source" | tr -d ' ')
        printf "${CYAN}[i]${NC} Searching on ${BOLD}%s${NC}...\n" "$source" >&2
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

    # Sort entries by downloads (descending) so --auto picks the most downloaded
    local sorted_entries=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        sorted_entries+=("$line")
    done <<< "$(printf '%s\n' "${entries[@]}" | jq -s -c 'sort_by(-.downloads)[]' 2>/dev/null)"
    if [[ ${#sorted_entries[@]} -gt 0 ]]; then
        entries=("${sorted_entries[@]}")
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

    # Dry-run: just display results (to stderr so $() capture doesn't swallow them)
    if $DRY_RUN; then
        header "Subtitles found" >&2
        for ((j=0; j<${#entries[@]}; j++)); do
            local name src_name downloads
            name=$(echo "${entries[$j]}" | jq -r '.name // "N/A"' 2>/dev/null)
            src_name=$(echo "${entries[$j]}" | jq -r '.source // "?"' 2>/dev/null)
            downloads=$(echo "${entries[$j]}" | jq -r '.downloads // 0' 2>/dev/null)
            printf "  ${BOLD}%2d${NC}) [${CYAN}%-15s${NC}] %s ${YELLOW}(%s DL)${NC}\n" "$((j+1))" "$src_name" "$name" "$downloads" >&2
        done
        return 1
    fi

    # Interactive selection (display to stderr so $() capture doesn't swallow them)
    header "Subtitles found" >&2
    for ((j=0; j<${#entries[@]}; j++)); do
        local name src_name downloads
        name=$(echo "${entries[$j]}" | jq -r '.name // "N/A"' 2>/dev/null)
        src_name=$(echo "${entries[$j]}" | jq -r '.source // "?"' 2>/dev/null)
        downloads=$(echo "${entries[$j]}" | jq -r '.downloads // 0' 2>/dev/null)
        printf "  ${BOLD}%2d${NC}) [${CYAN}%-15s${NC}] %s ${YELLOW}(%s DL)${NC}\n" "$((j+1))" "$src_name" "$name" "$downloads" >&2
    done

    printf "\n" >&2
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

# Extract text from SRT for LLM translation (text-only, no timestamps)
# Saves timestamp structure to structure_file, numbered text to text_file
# Returns block count via stdout
_srt_extract_for_translation() {
    local input="$1" structure_file="$2" text_file="$3"
    : > "$structure_file"
    : > "$text_file"

    local in_text=false timestamp="" text_buf="" block_num=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        if [[ "$line" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}\ --\>\ [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} ]]; then
            timestamp="$line"
            in_text=true
            text_buf=""
        elif $in_text && [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]]; then
            if [[ -n "$text_buf" ]]; then
                ((block_num++)) || true
                echo "$timestamp" >> "$structure_file"
                echo "${block_num}: ${text_buf}" >> "$text_file"
            fi
            in_text=false
            text_buf=""
        elif $in_text && ! [[ "$line" =~ ^[0-9]+[[:space:]]*$ ]]; then
            if [[ -n "$text_buf" ]]; then
                text_buf="${text_buf} <br> ${line}"
            else
                text_buf="$line"
            fi
        fi
    done < "$input"

    # Handle last block (no trailing newline)
    if $in_text && [[ -n "$text_buf" ]]; then
        ((block_num++)) || true
        echo "$timestamp" >> "$structure_file"
        echo "${block_num}: ${text_buf}" >> "$text_file"
    fi

    echo "$block_num"
}

# Rebuild SRT from timestamp structure + translated text lines
_srt_rebuild_from_translation() {
    local structure_file="$1" translated_file="$2" output="$3" original_text="${4:-}"
    : > "$output"

    # Read timestamps
    local -a timestamps=()
    while IFS= read -r ts; do
        timestamps+=("$ts")
    done < "$structure_file"

    if [[ ${#timestamps[@]} -eq 0 ]]; then
        warn "No timestamps found — cannot rebuild SRT"
        return 1
    fi

    # Read original text lines (for fallback if translation is incomplete)
    local -a orig_texts=()
    if [[ -n "$original_text" && -f "$original_text" ]]; then
        while IFS= read -r ol; do
            ol="${ol%$'\r'}"
            [[ -z "$ol" ]] && continue
            local ot="$ol"
            if [[ "$ot" =~ ^[0-9]+:[[:space:]](.+)$ ]]; then
                ot="${BASH_REMATCH[1]}"
            fi
            orig_texts+=("$ot")
        done < "$original_text"
    fi

    # Read translated lines, strip number prefix, rebuild SRT
    local idx=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # Skip empty lines and markdown fences
        [[ -z "$line" || "$line" =~ ^\`\`\` ]] && continue
        # Strip "N: " prefix if present
        local text="$line"
        if [[ "$text" =~ ^[0-9]+:[[:space:]](.+)$ ]]; then
            text="${BASH_REMATCH[1]}"
        fi

        if [[ $idx -lt ${#timestamps[@]} ]]; then
            printf '%d\n%s\n' "$((idx+1))" "${timestamps[$idx]}" >> "$output"
            # Restore <br> markers to actual newlines
            echo "$text" | sed 's/ <br> /\n/g' >> "$output"
            printf '\n' >> "$output"
        fi
        ((idx++)) || true
    done < "$translated_file"

    # Fill missing blocks with original text (e.g. LLM truncated output)
    if [[ $idx -lt ${#timestamps[@]} ]]; then
        warn "Translation returned $idx/$((${#timestamps[@]})) blocks — filling missing with original"
        while [[ $idx -lt ${#timestamps[@]} ]]; do
            local fallback_text=""
            if [[ $idx -lt ${#orig_texts[@]} ]]; then
                fallback_text="${orig_texts[$idx]}"
            fi
            printf '%d\n%s\n' "$((idx+1))" "${timestamps[$idx]}" >> "$output"
            if [[ -n "$fallback_text" ]]; then
                echo "$fallback_text" | sed 's/ <br> /\n/g' >> "$output"
            fi
            printf '\n' >> "$output"
            ((idx++)) || true
        done
    fi
    debug "SRT rebuild: $idx/${#timestamps[@]} blocks" || true
}

# Get max_tokens for a provider, respecting user override
_max_tokens_for() {
    local provider="$1"
    # User override takes priority
    [[ -n "${MAX_TOKENS:-}" ]] && { echo "$MAX_TOKENS"; return; }
    # Sensible defaults per provider (output tokens for API calls)
    case "$provider" in
        claude)  echo 16384 ;;
        openai)  echo 16384 ;;
        mistral) echo 16384 ;;
        gemini)  echo 65536 ;;
        *)       echo 16384 ;;
    esac
}

_translate_prompt() {
    cat <<PROMPT
Translate the following numbered subtitle lines from $1 to $2.
Rules:
- Keep the exact numbering format (N: translated text)
- Preserve <br> markers exactly as-is (they are line break markers)
- Translate ONLY the text after the number
- Output one line per input line, nothing else
- Do NOT add any explanation, markdown formatting, or code blocks
PROMPT
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
    local chunk_size="${TRANSLATE_CHUNK_SIZE:-80}"
    local num_chunks=$(( (total_text + chunk_size - 1) / chunk_size ))
    local max_parallel="${TRANSLATE_MAX_PARALLEL:-8}"
    info "$num_chunks chunks (max $max_parallel in parallel)"

    # Split text file into chunks (PID-suffixed to avoid race conditions)
    local chunk_prefix="$CACHE_DIR/trans_chunk_$$"
    local i=0
    while ((i < num_chunks)); do
        local start=$((i * chunk_size + 1))
        sed -n "${start},$((start + chunk_size - 1))p" "$text_file" > "${chunk_prefix}_${i}.txt"
        ((i++)) || true
    done

    # Translate chunks in parallel
    for ((batch=0; batch<num_chunks; batch+=max_parallel)); do
        local pids=()
        local bend=$((batch + max_parallel))
        [[ $bend -gt $num_chunks ]] && bend=$num_chunks

        for ((j=batch; j<bend; j++)); do
            (
                trans -b "${src_lang}:${target_lang}" -i "${chunk_prefix}_${j}.txt" \
                    > "${chunk_prefix}_${j}_out.txt" 2>/dev/null
            ) &
            pids+=($!)
        done

        for pid in "${pids[@]}"; do
            wait "$pid" || true
        done

        progress "$bend" "$num_chunks" "Translating"
    done

    # Step 3+4: Map translations back per-chunk
    # (avoids line-count drift when trans adds/removes trailing blank lines)
    local -a orig_line_nums=()
    while IFS= read -r ln; do
        orig_line_nums+=("$ln")
    done < "$map_file"

    local -A replacements=()
    local map_idx=0
    for ((i=0; i<num_chunks; i++)); do
        local chunk_out="${chunk_prefix}_${i}_out.txt"
        local chunk_in="${chunk_prefix}_${i}.txt"

        if [[ ! -f "$chunk_in" ]]; then
            warn "Chunk $((i+1)) input missing — skipping"
            local chunk_lines="${TRANSLATE_CHUNK_SIZE:-80}"
            ((map_idx += chunk_lines)) || true
            continue
        fi

        # Read original chunk lines
        local -a orig_lines=()
        while IFS= read -r ol; do
            orig_lines+=("$ol")
        done < "$chunk_in"

        # Read translated chunk lines (if available)
        local -a trans_lines=()
        if [[ -s "$chunk_out" ]]; then
            while IFS= read -r tl; do
                trans_lines+=("$tl")
            done < "$chunk_out"
        fi

        # Map each input line to its translation (or keep original if missing)
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

        rm -f "$chunk_in" "$chunk_out"
    done

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
    rm -f "$text_file" "$map_file"
    rm -f "$CACHE_DIR"/trans_chunk_$$_*.txt 2>/dev/null || true
}

translate_with_claude_code() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4"
    local model="${AI_MODEL:-$MODEL_CLAUDE_CODE}"
    local effort="${CLAUDE_EFFORT:-low}"
    info "Translating with Claude Code ($model, effort $effort)..."

    if ! command -v claude &>/dev/null; then
        err "claude CLI not installed. Install it: npm install -g @anthropic-ai/claude-code"
        return 1
    fi

    # Build input file on disk (avoid bash variable limitations with large content)
    local tmp_input="${CACHE_DIR}/claude_input_$$.txt"
    _translate_prompt "$src_lang" "$target_lang" > "$tmp_input"
    printf '\n\n' >> "$tmp_input"
    cat "$input" >> "$tmp_input"

    local claude_err="${output}.claude_err"
    local exit_code=0
    env -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SIMPLE \
        claude -p --model "$model" --effort "$effort" --tools "" --no-session-persistence \
        < "$tmp_input" > "$output" 2>"$claude_err" || exit_code=$?
    rm -f "$tmp_input"

    if [[ $exit_code -ne 0 ]]; then
        [[ -s "$claude_err" ]] && warn "$(head -5 "$claude_err")"
        [[ -s "$output" ]] && warn "$(head -3 "$output")"
        : > "$output"
        rm -f "$claude_err"
        err "Claude Code translation failed (exit code $exit_code)"
        return 1
    fi
    if [[ ! -s "$output" ]]; then
        if [[ -s "$claude_err" ]]; then
            warn "Claude stderr: $(head -5 "$claude_err")"
        fi
        rm -f "$claude_err"
        err "Claude Code produced empty output"
        return 1
    fi
    rm -f "$claude_err"
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
            \"max_tokens\": $(_max_tokens_for zai-codeplan),
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a professional subtitle translator. Preserve all SRT formatting exactly.\"},
                {\"role\": \"user\", \"content\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}
            ],
            \"temperature\": 0.3
        }") || { err "Z.ai API error"; return 1; }

    local content
    content=$(echo "$resp" | jq -r '.choices[0].message.content')
    if [[ -z "$content" || "$content" == "null" ]]; then
        err "Z.ai returned empty/invalid response"
        return 1
    fi
    echo "$content" > "$output"
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
            \"max_tokens\": $(_max_tokens_for openai),
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a professional subtitle translator. Preserve all SRT formatting exactly.\"},
                {\"role\": \"user\", \"content\": $escaped_content}
            ],
            \"temperature\": 0.3
        }") || { err "OpenAI API error"; return 1; }

    local content
    content=$(echo "$resp" | jq -r '.choices[0].message.content')
    if [[ -z "$content" || "$content" == "null" ]]; then
        err "OpenAI returned empty/invalid response"
        return 1
    fi
    echo "$content" > "$output"
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
            \"max_tokens\": $(_max_tokens_for claude),
            \"messages\": [
                {\"role\": \"user\", \"content\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}
            ]
        }") || { err "Claude API error"; return 1; }

    local content
    content=$(echo "$resp" | jq -r '.content[0].text')
    if [[ -z "$content" || "$content" == "null" ]]; then
        err "Claude API returned empty/invalid response"
        return 1
    fi
    echo "$content" > "$output"
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
            \"max_tokens\": $(_max_tokens_for mistral),
            \"messages\": [
                {\"role\": \"user\", \"content\": $(printf '%s\n\n%s' "$prompt" "$(cat "$input")" | jq -sR .)}
            ],
            \"temperature\": 0.3
        }") || { err "Mistral API error"; return 1; }

    local content
    content=$(echo "$resp" | jq -r '.choices[0].message.content')
    if [[ -z "$content" || "$content" == "null" ]]; then
        err "Mistral returned empty/invalid response"
        return 1
    fi
    echo "$content" > "$output"
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
            \"generationConfig\": {\"temperature\": 0.3, \"maxOutputTokens\": $(_max_tokens_for gemini)}
        }") || { err "Gemini API error"; return 1; }

    local content
    content=$(echo "$resp" | jq -r '.candidates[0].content.parts[0].text')
    if [[ -z "$content" || "$content" == "null" ]]; then
        err "Gemini returned empty/invalid response"
        return 1
    fi
    echo "$content" > "$output"
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

# ── Transcription ─────────────────────────────────────────────────────────────

# Extract audio from video file for transcription
# Usage: _extract_audio video output_format [lang]
# output_format: "wav" for local whisper, "mp3" for API (smaller)
_extract_audio() {
    local video="$1" fmt="$2" lang="${3:-}"
    command -v ffmpeg &>/dev/null || { err "ffmpeg required for audio extraction"; return 1; }

    local audio_out="${CACHE_DIR}/transcribe_audio_$$.${fmt}"
    local stream_args=()

    # Try to select audio track matching language hint
    if [[ -n "$lang" ]]; then
        local stream_ref
        if stream_ref=$(_find_audio_stream "$video" "$lang"); then
            local audio_idx="${stream_ref#a:}"
            stream_args=(-map "0:a:${audio_idx}")
            debug "Audio extraction: using track $stream_ref ($lang)" || true
        fi
    fi

    # If no specific track found, use first audio
    [[ ${#stream_args[@]} -eq 0 ]] && stream_args=(-map "0:a:0")

    local codec_args=()
    if [[ "$fmt" == "wav" ]]; then
        codec_args=(-ar 16000 -ac 1 -c:a pcm_s16le)
    else
        # MP3 at 48kbps for API (keeps file small, ~70min fits under 25MB)
        codec_args=(-ar 16000 -ac 1 -b:a 48k)
    fi

    if ffmpeg -v error -i "$video" "${stream_args[@]}" "${codec_args[@]}" "$audio_out" -y 2>/dev/null; then
        if [[ -s "$audio_out" ]]; then
            echo "$audio_out"
            return 0
        fi
    fi
    rm -f "$audio_out"
    err "Audio extraction failed"
    return 1
}

# Transcribe using local whisper CLI
transcribe_with_whisper() {
    local audio="$1" output="$2" lang="${3:-}"

    local whisper_cmd="whisper"
    if ! command -v whisper &>/dev/null; then
        if command -v uvx &>/dev/null; then
            whisper_cmd="uvx --from openai-whisper whisper"
            info "Using uvx openai-whisper"
        else
            die "whisper not available. Install: pip install openai-whisper (or: uvx openai-whisper)"
        fi
    fi

    local args=("$audio" --model "$WHISPER_MODEL" --output_format srt --output_dir "$CACHE_DIR"
        --condition_on_previous_text False)
    [[ -n "$lang" ]] && args+=(--language "$lang")

    info "Transcribing with whisper (model: $WHISPER_MODEL)... this may take a while"
    # Run whisper with output flowing directly to stderr so user sees progress
    if $whisper_cmd "${args[@]}" >&2; then
        # Whisper outputs <basename>.srt in the output dir
        local audio_basename
        audio_basename=$(basename "$audio")
        local whisper_out="${CACHE_DIR}/${audio_basename%.*}.srt"
        if [[ -s "$whisper_out" ]]; then
            mv "$whisper_out" "$output"
            return 0
        fi
        err "Whisper ran but produced no SRT output"
    else
        err "Whisper process exited with error"
    fi
    return 1
}

# Transcribe using OpenAI API (Whisper endpoint)
transcribe_with_openai_api() {
    local audio="$1" output="$2" lang="${3:-}"

    # Use dedicated transcription key, fall back to general OpenAI key
    local api_key="${OPENAI_WHISPER_API_KEY:-${OPENAI_API_KEY:-}}"
    [[ -z "$api_key" ]] && die "OPENAI_WHISPER_API_KEY or OPENAI_API_KEY required for openai-api transcription"

    # Check file size (25MB limit)
    local filesize
    filesize=$(stat -f%z "$audio" 2>/dev/null || stat -c%s "$audio" 2>/dev/null || echo "0")
    if [[ "$filesize" -gt 26214400 ]]; then
        err "Audio file too large for OpenAI API (${filesize} bytes, max 25MB)"
        return 1
    fi

    info "Transcribing via OpenAI API..."
    local curl_args=(-sf "https://api.openai.com/v1/audio/transcriptions"
        -H "Authorization: Bearer $api_key"
        -F "file=@${audio}"
        -F "model=whisper-1"
        -F "response_format=srt")
    [[ -n "$lang" ]] && curl_args+=(-F "language=${lang}")

    local resp
    if resp=$(api_retry curl "${curl_args[@]}"); then
        echo "$resp" > "$output"
        return 0
    fi
    err "OpenAI transcription API error"
    return 1
}

# Dispatch transcription to selected provider
_transcribe_dispatch() {
    local audio="$1" output="$2" lang="$3" provider="$4"
    case "$provider" in
        whisper)     transcribe_with_whisper "$audio" "$output" "$lang" ;;
        openai-api)  transcribe_with_openai_api "$audio" "$output" "$lang" ;;
        *) die "Unknown transcription provider: $provider" ;;
    esac
}

# Orchestrator: video -> SRT via speech-to-text
# Usage: transcribe_video video output [lang] [provider]
transcribe_video() {
    local video="$1" output="$2" lang="${3:-}" provider="${4:-$TRANSCRIBE_PROVIDER}"

    header "Transcription ($provider)"
    info "Video: $(basename "$video")"
    [[ -n "$lang" ]] && info "Language hint: $lang"

    # Choose audio format: WAV for local whisper, MP3 for API
    local audio_fmt="wav"
    [[ "$provider" == "openai-api" ]] && audio_fmt="mp3"

    local audio_file
    audio_file=$(_extract_audio "$video" "$audio_fmt" "$lang") || return 1

    if _transcribe_dispatch "$audio_file" "$output" "$lang" "$provider"; then
        rm -f "$audio_file"
        if validate_srt "$output"; then
            local sub_count
            sub_count=$(tr -d '\r' < "$output" | grep -cE '^[0-9]+$' 2>/dev/null || echo "0")
            log "Transcription OK: $sub_count subtitles generated"
            return 0
        else
            warn "Transcription output is not valid SRT"
            rm -f "$output"
            return 1
        fi
    fi
    rm -f "$audio_file"
    return 1
}

# Main translation
translate_subtitle() {
    local input="$1" output="$2" src_lang="$3" target_lang="$4" provider="$5"

    header "Translation ($provider)"
    info "Source: $src_lang -> Target: $target_lang"

    # Google provider handles its own SRT parsing + batching
    if [[ "$provider" == "google" ]]; then
        _translate_dispatch "$input" "$output" "$src_lang" "$target_lang" "$provider"
    else
        # LLM providers: extract text only (never send timestamps to LLM)
        local structure_file="$CACHE_DIR/translate_structure_$$.txt"
        local text_file="$CACHE_DIR/translate_text_$$.txt"
        local text_translated="$CACHE_DIR/translate_text_out_$$.txt"

        local block_count
        block_count=$(_srt_extract_for_translation "$input" "$structure_file" "$text_file")
        info "$block_count subtitle blocks to translate"

        local total_lines
        total_lines=$(wc -l < "$text_file" | tr -d ' ')

        # Single-call threshold depends on provider output capacity
        # claude-code/claude ~16k output tokens ≈ 1500 subtitle lines safely
        # Google handles its own chunking (separate path above)
        local single_call_threshold
        case "$provider" in
            claude-code|claude|openai|mistral|zai-codeplan) single_call_threshold=1500 ;;
            gemini) single_call_threshold=5000 ;;
            *) single_call_threshold=1500 ;;
        esac
        debug "Single-call mode: $total_lines lines (threshold=$single_call_threshold)" || true

        if [[ $total_lines -le $single_call_threshold ]]; then
            # Single call — translate all text at once
            _translate_dispatch "$text_file" "$text_translated" "$src_lang" "$target_lang" "$provider"

            # If LLM truncated output, retry the missing portion
            if [[ -s "$text_translated" ]]; then
                local translated_count
                translated_count=$(grep -cvE '^[[:space:]]*$|^\`\`\`' "$text_translated" 2>/dev/null || echo "0")
                if [[ $translated_count -gt 0 && $translated_count -lt $block_count ]]; then
                    warn "LLM returned $translated_count/$block_count blocks — retrying missing portion"
                    local remaining_file="$CACHE_DIR/translate_remaining_$$.txt"
                    local remaining_out="$CACHE_DIR/translate_remaining_out_$$.txt"
                    sed -n "$((translated_count + 1)),\$p" "$text_file" > "$remaining_file"
                    if _translate_dispatch "$remaining_file" "$remaining_out" "$src_lang" "$target_lang" "$provider" 2>/dev/null && [[ -s "$remaining_out" ]]; then
                        cat "$remaining_out" >> "$text_translated"
                        local retry_count
                        retry_count=$(grep -cvE '^[[:space:]]*$|^\`\`\`' "$remaining_out" 2>/dev/null || echo "0")
                        info "Retry OK: recovered $retry_count blocks"
                    else
                        warn "Retry failed — missing blocks will use original text"
                    fi
                    rm -f "$remaining_file" "$remaining_out"
                fi
            fi
        else
            # Very large file — chunk text lines and translate in batches
            info "Large file ($total_lines text lines), splitting into chunks..."
            local chunk_size="${TRANSLATE_CHUNK_SIZE:-500}"
            local num_chunks=$(( (total_lines + chunk_size - 1) / chunk_size ))
            local max_parallel="${TRANSLATE_MAX_PARALLEL:-3}"
            info "$num_chunks chunks to translate (max $max_parallel in parallel)"

            : > "$text_translated"
            for ((batch_start=0; batch_start<num_chunks; batch_start+=max_parallel)); do
                local pids=()
                local batch_end=$((batch_start + max_parallel))
                [[ $batch_end -gt $num_chunks ]] && batch_end=$num_chunks

                for ((i=batch_start; i<batch_end; i++)); do
                    local start=$((i * chunk_size + 1))
                    local chunk_in="$CACHE_DIR/text_chunk_$$_${i}.txt"
                    local chunk_out="$CACHE_DIR/text_chunk_$$_${i}_out.txt"
                    sed -n "${start},$((start + chunk_size - 1))p" "$text_file" > "$chunk_in"
                    _translate_dispatch "$chunk_in" "$chunk_out" "$src_lang" "$target_lang" "$provider" &
                    pids+=($!)
                done

                local chunk_failures=0
                for pid in "${pids[@]}"; do
                    wait "$pid" || ((chunk_failures++)) || true
                done
                progress "$batch_end" "$num_chunks" "Translating"
                [[ $chunk_failures -gt 0 ]] && warn "$chunk_failures chunk(s) failed in this batch"
            done

            # Reassemble translated text (retry failed chunks once before fallback)
            for ((i=0; i<num_chunks; i++)); do
                local chunk_out="$CACHE_DIR/text_chunk_$$_${i}_out.txt"
                local chunk_in="$CACHE_DIR/text_chunk_$$_${i}.txt"
                if [[ -s "$chunk_out" ]]; then
                    cat "$chunk_out" >> "$text_translated"
                    # Detect truncated LLM output and pad with original text to maintain alignment
                    local out_count in_count
                    out_count=$(grep -cvE '^[[:space:]]*$|^\`\`\`' "$chunk_out" 2>/dev/null || echo "0")
                    in_count=$(wc -l < "$chunk_in" | tr -d ' ')
                    if [[ $out_count -gt 0 && $out_count -lt $in_count ]]; then
                        warn "Chunk $((i+1)): LLM returned $out_count/$in_count lines — padding with original"
                        tail -n "$((in_count - out_count))" "$chunk_in" >> "$text_translated"
                    fi
                elif [[ -s "$chunk_in" ]]; then
                    warn "Chunk $((i+1)) failed — retrying..."
                    if _translate_dispatch "$chunk_in" "$chunk_out" "$src_lang" "$target_lang" "$provider" 2>/dev/null && [[ -s "$chunk_out" ]]; then
                        cat "$chunk_out" >> "$text_translated"
                        info "Chunk $((i+1)) retry OK"
                    else
                        warn "Chunk $((i+1)) retry failed — keeping original text"
                        cat "$chunk_in" >> "$text_translated"
                    fi
                fi
                rm -f "$chunk_in" "$chunk_out"
            done
        fi

        # Rebuild SRT from original timestamps + translated text
        _srt_rebuild_from_translation "$structure_file" "$text_translated" "$output" "$text_file"

        rm -f "$structure_file" "$text_file" "$text_translated"
    fi

    if [[ -s "$output" ]]; then
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
        sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$input" | head -20 | tr '\n' ' ' || true)
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
    auto        All-in-one: download + translate + embed (file, directory, or playlist)
    transcribe  Generate subtitles from video audio (speech-to-text)
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
    mix         Mix 2 subtitles for language learning (dual-language)
    fix         Repair an SRT (UTF-8 encoding, sorting, renumbering, overlaps)
    extract     Extract subtitles from a video (MKV, MP4)
    embed       Embed an SRT into a video
    strip       Remove all subtitle tracks from a video (replaces original, --keep-files to keep both)
    text        Export plain text from subtitle (no timestamps)
    diff        Compare two subtitle files side by side
    config      Display/edit configuration (config set <KEY> <VALUE>)
    check       Diagnostic (deps, API keys, config)
    providers   List available AI providers
    sources     List subtitle sources
    completions Generate shell completions (bash, zsh, fish)
    manpage     Generate man page

${BOLD}OPTIONS${NC}
    -q, --query <title>       Title of movie/series to search
    -l, --lang <code>         Target language(s): fr, en, or comma-separated: en,fr. Or set DEFAULT_LANG in config
    -i, --imdb <id>           IMDb ID (tt1234567)
    -s, --season <num>        Season number (series)
    -e, --episode <num>       Episode number (series)
    -o, --output <dir>        Output directory (default: .)
    -p, --provider <provider> Translation provider (google|claude-code|openai|claude|mistral|gemini)
    -m, --model <model>       AI model to use (overrides provider default model)
    --sources <src1,src2>     Sources (default: opensubtitles-org. Available: podnapisi)
    --from <lang>             Source language for translation
    --fallback-langs <l1,l2>  Fallback languages (default: en,de,es,pt)
    --max-ep <num>            Max episodes per season (default: 20)
    --shift <ms>              Shift in ms for sync (e.g., +1500, -800)
    --sync-shift <ms>         Constant shift in ms applied after ffsubsync in auto mode (e.g., -2000).
                              Also applied alone when --skip-steps sync is set (manual-only sync). AUTO_SYNC_SHIFT in config.
    --to <format>             Target format for convert (srt, vtt, ass)
    --merge-with <file>       Secondary file for bilingual merge
    --mix-with <file>         Second file for mix (dual-language subtitles)
    --mix [lang]              Enable dual-language mix in auto mode (optional language code, e.g. --mix de)
    --swap                    Swap mix order (reverse which language is on top vs italic)
    --diff-with <file>        Second file for subtitle diff comparison
    --playlist <file>         Text file listing video paths for batch auto
    --ref <video|srt>         Reference for autosync (video or SRT)
    --ref-stream <stream>     Audio stream for autosync (e.g., a:1 for 2nd audio track). Auto-detected from -l
    --sub <file>              SRT file to embed in a video
    --track <num>             Track to extract (single track)
    --all                     Extract all subtitle tracks at once
    --url <url>               Download a subtitle from an opensubtitles.org URL
    --embed                   Embed subtitles in video (auto: active by default)
    --no-embed                Disable automatic embedding
    --force-embed             Force embed even if subtitles already present (adds new track)
    --strip-existing          Strip all existing subtitle tracks before embedding new ones
    --force-translate         Force translation even if subtitles found
    --transcribe-provider <p> Transcription provider (whisper|openai-api)
    --whisper-model <model>   Whisper model (tiny, base, small [default], medium, large)
    --chunk-size <n>          Translation chunk size in lines (default: 80 google, 500 LLM)
    --max-tokens <n>          Max output tokens for LLM translation (default: auto per provider)
    --no-transcribe           Disable transcription fallback in auto mode
    --force-transcribe        Force transcription (skip subtitle download in auto)
    --claude-effort <level>   Claude Code effort (low [default], medium, high)
    --skip-steps <steps>      Skip steps in auto (comma-separated: download,translate,sync,mix,embed)
    --max-parallel <n>        Max parallel translation chunks (default: 3 LLM, 8 google)
    --resume                  Resume batch from previous state (skip already-completed files)
    --keep-files              Keep intermediate subtitle files after auto (default: cleanup)
    --mix-translate           Force mix to translate target subtitle instead of searching/downloading
    --auto                    Automatically select most downloaded result
    --dry-run                 Display results without downloading
    --json                    JSON output (for integration with other tools)
    --verbose                 Display debug info
    --quiet                   Silent mode (errors only)
    -h, --help                Display this help
    -v, --version             Display version

${BOLD}EXAMPLES${NC}
    # Auto: download + translate + embed in one command
    $SCRIPT_NAME auto ~/Movies/Die.Discounter -l fr
    $SCRIPT_NAME auto ~/Movies/Die.Discounter -l fr --embed
    $SCRIPT_NAME auto movie.mkv -l fr
    $SCRIPT_NAME auto movie.mkv -l fr --mix           # dual-language: FR top + source italic
    $SCRIPT_NAME auto movie.mkv -l fr --mix --swap    # dual-language: source top + FR italic
    $SCRIPT_NAME auto movie.mkv -l fr --mix de         # dual-language: FR top + DE italic

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
    $SCRIPT_NAME translate episode.de.srt -l fr --from de -p zai-codeplan

    # Subtitle tools
    $SCRIPT_NAME info movie.srt
    $SCRIPT_NAME clean movie.srt
    $SCRIPT_NAME sync movie.srt --shift -1500
    $SCRIPT_NAME convert movie.srt --to vtt
    $SCRIPT_NAME merge movie.de.srt --merge-with movie.fr.srt
    $SCRIPT_NAME mix movie.de.srt --mix-with movie.fr.srt
    $SCRIPT_NAME mix movie.de.srt -l fr                   # translate + mix
    $SCRIPT_NAME fix broken.srt
    $SCRIPT_NAME extract movie.mkv
    $SCRIPT_NAME extract movie.mkv --all
    $SCRIPT_NAME extract movie.mkv --track 2
    $SCRIPT_NAME embed movie.mkv --sub movie.fr.srt -l fr
    $SCRIPT_NAME strip movie.mkv                            # remove all subs (replaces original)
    $SCRIPT_NAME strip movie.mkv --keep-files               # keep original, output movie.clean.mkv

    # Transcribe (generate subtitles from audio)
    $SCRIPT_NAME transcribe movie.mkv
    $SCRIPT_NAME transcribe movie.mkv --from en
    $SCRIPT_NAME transcribe movie.mkv --transcribe-provider openai-api
    $SCRIPT_NAME transcribe movie.mkv --whisper-model large

    # Export plain text
    $SCRIPT_NAME text movie.srt

    # Compare two subtitles
    $SCRIPT_NAME diff original.srt --diff-with translated.srt

    # Batch from playlist file
    $SCRIPT_NAME auto --playlist videos.txt -l fr

    # Auto sync with video (ffsubsync)
    $SCRIPT_NAME autosync desync.srt --ref movie.mkv
    $SCRIPT_NAME autosync desync.srt --ref reference.srt

    # Shell completions
    eval \"\$($SCRIPT_NAME completions bash)\"
    $SCRIPT_NAME completions fish > ~/.config/fish/completions/subtool.fish

    # Man page
    $SCRIPT_NAME manpage | man -l -
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

    printf "\n"
    header "Transcription providers"
    printf "  ${BOLD}%-15s${NC} %-10s %-25s %s\n" "Provider" "Status" "Model" "Description"
    printf "  %-15s %-10s %-25s %s\n" "───────────────" "──────────" "─────────────────────────" "──────────────────────"

    if command -v whisper &>/dev/null; then
        status="${GREEN}OK${NC}"
    elif command -v uvx &>/dev/null; then
        status="${GREEN}OK${NC} (uvx)"
    else
        status="${RED}N/A${NC}"
    fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "whisper" "$WHISPER_MODEL" "Local Whisper (default, free)"

    if [[ -n "${OPENAI_WHISPER_API_KEY:-}" ]]; then
        status="${GREEN}OK${NC}"
    elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
        status="${GREEN}OK${NC} (via OPENAI_API_KEY)"
    else
        status="${RED}NO KEY${NC}"
    fi
    printf "  ${BOLD}%-15s${NC} ${status}       %-25s %s\n" "openai-api" "whisper-1" "OpenAI Whisper API"
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
    if command -v whisper &>/dev/null; then
        printf "  ${GREEN}OK${NC}  %-15s %s\n" "whisper" "$(command -v whisper)"
    elif command -v uvx &>/dev/null; then
        printf "  ${GREEN}OK${NC}  %-15s %s\n" "whisper" "via uvx (on the fly)"
    else
        printf "  ${YELLOW}N/A${NC}  %-15s (transcription) — pip install openai-whisper or: uvx openai-whisper\n" "whisper"
    fi

    # API keys
    printf "\n  ${BOLD}API Keys:${NC}\n"
    for key_name in ZAI_API_KEY OPENAI_API_KEY OPENAI_WHISPER_API_KEY ANTHROPIC_API_KEY MISTRAL_API_KEY GEMINI_API_KEY; do
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
    _multi_lang_dispatch cmd_get && return
    # Direct URL download mode
    if [[ -n "${SUBTITLE_URL:-}" ]]; then
        [[ -z "$LANG_TARGET" ]] && die "Specify -l <lang> or set DEFAULT_LANG in config"
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
    [[ -z "$LANG_TARGET" ]] && die "Specify -l <lang> or set DEFAULT_LANG in config"

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
            $DRY_RUN || mkdir -p "$season_dir"

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
    _multi_lang_dispatch cmd_search && return
    [[ -z "$SEARCH_QUERY" && -z "$IMDB_ID" ]] && die "Specify --query or --imdb"
    [[ -z "$LANG_TARGET" ]] && die "Specify -l <lang> or set DEFAULT_LANG in config"

    local query="${SEARCH_QUERY:-}"

    header "Subtitle search"
    info "Title: ${query:-IMDB:$IMDB_ID}"
    info "Language: $LANG_TARGET"
    [[ -n "$SEASON" ]] && info "Season: $SEASON, Episode: $EPISODE"

    # Login OpenSubtitles if possible

    local results
    if results=$(search_all_sources "$query" "$LANG_TARGET" "$IMDB_ID" "$SEASON" "$EPISODE"); then
        # JSON mode: just output and exit (no download)
        if $JSON_OUTPUT; then
            select_subtitle "$results"
            return 0
        fi

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
    _multi_lang_dispatch cmd_batch && return
    [[ -z "$SEARCH_QUERY" && -z "$IMDB_ID" ]] && die "Specify --query or --imdb"
    [[ -z "$LANG_TARGET" ]] && die "Specify -l <lang> or set DEFAULT_LANG in config"
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
    $DRY_RUN || mkdir -p "$season_dir"

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
        progress "$ep" "$max_ep" "Batch"
    done

    header "Result"
    log "Downloaded: $success | Translated: $translated | Failed: $fail"
    log "Directory: $season_dir"
}

# ── Command: scan (auto-download from video folder) ──────────────────────────
cmd_scan() {
    _multi_lang_dispatch cmd_scan && return
    # Auto-detect: if FILE_PATH was set (positional arg), treat it as directory for scan
    if [[ -z "$SCAN_DIR" && -n "$FILE_PATH" ]]; then
        SCAN_DIR="$FILE_PATH"
        FILE_PATH=""
    fi
    [[ -z "$SCAN_DIR" ]] && die "Specify a directory to scan"
    [[ ! -d "$SCAN_DIR" ]] && die "Directory not found: $SCAN_DIR"
    [[ -z "$LANG_TARGET" ]] && die "Specify -l <lang> or set DEFAULT_LANG in config"

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
    _multi_lang_dispatch cmd_auto && return
    local target="$LANG_TARGET"
    [[ -z "$target" ]] && die "Specify -l <lang> or set DEFAULT_LANG in config"

    # Single file, directory, or playlist mode (auto-detect)
    local mode=""
    if [[ -n "$PLAYLIST_FILE" ]]; then
        [[ ! -f "$PLAYLIST_FILE" ]] && die "Playlist file not found: $PLAYLIST_FILE"
        mode="playlist"
    elif [[ -n "$SCAN_DIR" ]]; then
        [[ ! -d "$SCAN_DIR" ]] && die "Directory not found: $SCAN_DIR"
        mode="dir"
    elif [[ -n "$FILE_PATH" ]]; then
        if [[ -d "$FILE_PATH" ]]; then
            SCAN_DIR="$FILE_PATH"
            FILE_PATH=""
            mode="dir"
        elif [[ "$FILE_PATH" == *.txt ]]; then
            # Auto-detect .txt files as playlists
            PLAYLIST_FILE="$FILE_PATH"
            FILE_PATH=""
            mode="playlist"
        else
            [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"
            mode="file"
        fi
    else
        die "Specify a video file, directory, or playlist (.txt)"
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

    # Parse skip-steps into a lookup string
    local _skip=",$SKIP_STEPS,"

    header "subtool auto"
    info "Target language: $target"
    $DRY_RUN && info "Mode: dry-run (no changes)"
    $do_embed && info "Embed: active" || info "Embed: inactive (ffmpeg required)"
    $FORCE_TRANSCRIBE && info "Transcription: forced (skipping subtitle search)"
    if $MIX_MODE; then
        [[ -n "$MIX_LANG" ]] && info "Mix: active (bilingual, learning: $MIX_LANG)" || info "Mix: active (bilingual subtitles)"
        $MIX_TRANSLATE && info "Mix: translate mode (skip search/download, translate target)"
    fi
    [[ -n "$SKIP_STEPS" ]] && info "Skip steps: $SKIP_STEPS"
    if $KEEP_FILES; then
        info "Keep files: active (SRT files preserved after embed)"
    elif $do_embed; then
        info "Cleanup: SRT files removed after embed"
    fi

    local success=0 fail=0 skip=0 total=0

    # Batch resume: track completed files in directory/playlist mode
    local batch_state=""
    if [[ "$mode" == "dir" ]]; then
        batch_state="${SCAN_DIR}/.subtool_batch_state"
        if $NO_RESUME && [[ -f "$batch_state" ]]; then
            rm -f "$batch_state"
            info "Batch state cleared (re-processing all)"
        fi
    fi

    # Collect video files
    local video_files=()
    if [[ "$mode" == "file" ]]; then
        video_files=("$FILE_PATH")
    elif [[ "$mode" == "playlist" ]]; then
        info "Playlist: $PLAYLIST_FILE"
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            # Skip empty lines and comments
            [[ -z "$line" || "$line" == \#* ]] && continue
            # Resolve relative paths from playlist file's directory
            if [[ "$line" != /* ]]; then
                line="$(dirname "$PLAYLIST_FILE")/$line"
            fi
            if [[ -f "$line" ]]; then
                video_files+=("$line")
            else
                warn "Playlist: file not found: $line"
            fi
        done < "$PLAYLIST_FILE"
    else
        info "Directory: $SCAN_DIR"
        while IFS= read -r -d '' vf; do
            video_files+=("$vf")
        done < <(find "$SCAN_DIR" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.m4v" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.ts" \) ! -name "*.tmp.*" ! -name "*.stripped.*" -print0 2>/dev/null | sort -z)
    fi

    total=${#video_files[@]}
    info "$total videos found"

    for video_file in "${video_files[@]}"; do
        local dir_name base_name name_no_ext
        dir_name=$(dirname "$video_file")
        base_name=$(basename "$video_file")
        name_no_ext="${base_name%.*}"

        local target_srt="${dir_name}/${name_no_ext}.${target}.srt"

        # Batch resume: skip already-completed files
        if [[ -n "$batch_state" && -f "$batch_state" ]] && grep -qFx "$base_name" "$batch_state" 2>/dev/null; then
            debug "Batch resume: skipping $base_name (already completed)" || true
            ((skip++)) || true
            continue
        fi

        # Already has target language subtitle? (skip only if non-empty)
        if [[ -s "$target_srt" ]]; then
            local mix_file="" mix_embed_title="" mix_source_srt="" mix_source_lang=""
            # Sync target first
            if [[ "$_skip" != *",sync,"* ]]; then
                $DRY_RUN || _auto_sync "$video_file" "$target_srt" "$target"
            else
                $DRY_RUN || _apply_sync_shift_only "$target_srt"
            fi
            if $MIX_MODE && [[ "$_skip" != *",mix,"* ]] && ! $DRY_RUN; then
                local mix_info=""
                mix_info=$(_auto_mix "$video_file" "$target_srt" "$target") && {
                    local _ml="${mix_info%%|*}"
                    local _rest="${mix_info#*|}"
                    mix_file="${_rest%%|*}"
                    mix_source_srt="${_rest#*|}"
                    mix_source_lang="$_ml"
                    [[ "$mix_source_srt" == "$mix_file" ]] && mix_source_srt=""
                    if [[ "$SWAP_MIX" == "true" ]]; then
                        mix_embed_title="Mix $(_lang_title "$_ml")-$(_lang_title "$target")"
                    else
                        mix_embed_title="Mix $(_lang_title "$target")-$(_lang_title "$_ml")"
                    fi
                }
            fi
            if $do_embed && [[ "$_skip" != *",embed,"* ]]; then
                $DRY_RUN || { _auto_embed_with_mix "$video_file" "$target_srt" "$target" "$mix_file" "$mix_embed_title" "$mix_source_srt" "$mix_source_lang" && \
                    _auto_cleanup "$target_srt"; \
                    [[ -n "$mix_file" ]] && _auto_cleanup "$mix_file"; \
                    [[ -n "$mix_source_srt" ]] && _auto_cleanup "$mix_source_srt"; }
            fi
            ((skip++)) || true
            continue
        fi

        printf "\n${BOLD}── %s ──${NC}\n" "$base_name" >&2

        local existing_srt="" existing_lang=""

        if $FORCE_TRANSCRIBE || [[ "$_skip" == *",download,"* ]]; then
            # Skip steps 0-2 (download), go straight to transcription
            $FORCE_TRANSCRIBE && debug "Force transcribe: skipping subtitle search" || true
            [[ "$_skip" == *",download,"* ]] && debug "Skip step: download" || true
        else

        # ── Step 0: Try extracting embedded subtitle in target language ──
        if command -v ffmpeg &>/dev/null && command -v ffprobe &>/dev/null; then
            local embedded_idx
            if embedded_idx=$(_find_subtitle_stream_index "$video_file" "$target"); then
                if $DRY_RUN; then
                    info "Would extract embedded subtitle ($target, stream $embedded_idx)"
                    ((success++)) || true
                    continue
                fi
                if ffmpeg -v error -i "$video_file" -map "0:${embedded_idx}" -c:s srt "$target_srt" -y 2>/dev/null && [[ -s "$target_srt" ]]; then
                    log "Extracted embedded subtitle ($target, stream $embedded_idx): $(basename "$target_srt")"
                    ((success++)) || true
                    local mix_file="" mix_embed_title="" mix_source_srt="" mix_source_lang=""
                    local mix_existing_srt="" mix_existing_lang=""
                    # Sync target first
                    if [[ "$_skip" != *",sync,"* ]]; then
                        _auto_sync "$video_file" "$target_srt" "$target"
                    else
                        _apply_sync_shift_only "$target_srt"
                    fi
                    if $MIX_MODE && [[ "$_skip" != *",mix,"* ]]; then
                        # Extract a second subtitle stream in another language for mixing
                        if [[ -n "$MIX_LANG" ]]; then
                            # --mix <lang> specified: extract that language
                            local _mix_idx
                            if _mix_idx=$(_find_subtitle_stream_index "$video_file" "$MIX_LANG") && [[ "$_mix_idx" != "$embedded_idx" ]]; then
                                mix_existing_srt="${dir_name}/${name_no_ext}.${MIX_LANG}.srt"
                                if ffmpeg -v error -i "$video_file" -map "0:${_mix_idx}" -c:s srt "$mix_existing_srt" -y 2>/dev/null && [[ -s "$mix_existing_srt" ]]; then
                                    mix_existing_lang="$MIX_LANG"
                                    log "Extracted embedded subtitle ($MIX_LANG, stream $_mix_idx): $(basename "$mix_existing_srt")"
                                else
                                    mix_existing_srt=""
                                fi
                            fi
                        else
                            # No --mix <lang>: find any other subtitle stream
                            local _s_idx _s_lang
                            while IFS=',' read -r _s_idx _s_lang; do
                                _s_idx=$(echo "$_s_idx" | tr -d '[:space:]')
                                _s_lang=$(echo "$_s_lang" | tr -d '[:space:]')
                                [[ "$_s_idx" == "$embedded_idx" ]] && continue
                                [[ -z "$_s_lang" || "$_s_lang" == "und" ]] && continue
                                local _s_lang2
                                _s_lang2=$(_iso639_2_to_lang "$_s_lang")
                                [[ "$_s_lang2" == "$target" ]] && continue
                                mix_existing_srt="${dir_name}/${name_no_ext}.${_s_lang2}.srt"
                                if ffmpeg -v error -i "$video_file" -map "0:${_s_idx}" -c:s srt "$mix_existing_srt" -y 2>/dev/null && [[ -s "$mix_existing_srt" ]]; then
                                    mix_existing_lang="$_s_lang2"
                                    log "Extracted embedded subtitle ($_s_lang2, stream $_s_idx): $(basename "$mix_existing_srt")"
                                    break
                                else
                                    mix_existing_srt=""
                                fi
                            done < <(ffprobe -v error -select_streams s -show_entries stream=index:stream_tags=language -of csv=p=0 "$video_file" 2>/dev/null)
                        fi
                        local mix_info=""
                        mix_info=$(_auto_mix "$video_file" "$target_srt" "$target" "$mix_existing_srt" "$mix_existing_lang") && {
                            local _ml="${mix_info%%|*}"
                            local _rest="${mix_info#*|}"
                            mix_file="${_rest%%|*}"
                            mix_source_srt="${_rest#*|}"
                            mix_source_lang="$_ml"
                            [[ "$mix_source_srt" == "$mix_file" ]] && mix_source_srt=""
                            if [[ "$SWAP_MIX" == "true" ]]; then
                                mix_embed_title="Mix $(_lang_title "$_ml")-$(_lang_title "$target")"
                            else
                                mix_embed_title="Mix $(_lang_title "$target")-$(_lang_title "$_ml")"
                            fi
                        }
                    fi
                    if $do_embed && [[ "$_skip" != *",embed,"* ]]; then
                        _auto_embed_with_mix "$video_file" "$target_srt" "$target" "$mix_file" "$mix_embed_title" "$mix_source_srt" "$mix_source_lang" && \
                            _auto_cleanup "$target_srt"
                        [[ -n "$mix_file" ]] && _auto_cleanup "$mix_file"
                        [[ -n "$mix_source_srt" ]] && _auto_cleanup "$mix_source_srt"
                    fi
                    # Clean up extracted mix source if it differs from mix_source_srt (e.g. _auto_mix used download instead)
                    [[ -n "$mix_existing_srt" && -f "$mix_existing_srt" ]] && _auto_cleanup "$mix_existing_srt"
                    [[ -n "$batch_state" ]] && echo "$base_name" >> "$batch_state"
                    continue
                fi
            fi
        fi

        # ── Step 1: Check for existing external subtitle in any language ──
        for srt_file in "${dir_name}/${name_no_ext}".*.srt; do
            [[ -f "$srt_file" ]] || continue
            # Extract lang code from filename (name.XX.srt)
            local srt_base
            srt_base=$(basename "$srt_file")
            local srt_lang="${srt_base%.srt}"
            srt_lang="${srt_lang##*.}"
            # Skip mix/dual outputs from previous runs
            [[ "$srt_lang" == "mix" ]] && continue
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
            fi

          if [[ -n "$PARSED_TITLE" || -n "$PARSED_IMDB" ]]; then
            # Try target language first
            local results=""
            if results=$(search_all_sources "$PARSED_TITLE" "$target" "$PARSED_IMDB" "$PARSED_SEASON" "$PARSED_EPISODE" 2>/dev/null); then
                local first
                first=$(echo "$results" | head -1)
                if [[ -n "$first" ]]; then
                    if $DRY_RUN; then
                        info "Would download ($target): $(basename "$target_srt")"
                        info "Would sync + embed"
                        ((success++)) || true
                        continue
                    fi
                    if download_subtitle "$first" "$target_srt" 2>/dev/null; then
                        log "Downloaded (${target}): $target_srt"
                        ((success++)) || true
                        local mix_file="" mix_embed_title="" mix_source_srt="" mix_source_lang=""
                        # Sync target first
                        if [[ "$_skip" != *",sync,"* ]]; then
                            _auto_sync "$video_file" "$target_srt" "$target"
                        else
                            _apply_sync_shift_only "$target_srt"
                        fi
                        if $MIX_MODE && [[ "$_skip" != *",mix,"* ]]; then
                            local mix_info=""
                            mix_info=$(_auto_mix "$video_file" "$target_srt" "$target") && {
                                local _ml="${mix_info%%|*}"
                                local _rest="${mix_info#*|}"
                                mix_file="${_rest%%|*}"
                                mix_source_srt="${_rest#*|}"
                                mix_source_lang="$_ml"
                                [[ "$mix_source_srt" == "$mix_file" ]] && mix_source_srt=""
                                if [[ "$SWAP_MIX" == "true" ]]; then
                                    mix_embed_title="Mix $(_lang_title "$_ml")-$(_lang_title "$target")"
                                else
                                    mix_embed_title="Mix $(_lang_title "$target")-$(_lang_title "$_ml")"
                                fi
                            }
                        fi
                        if $do_embed && [[ "$_skip" != *",embed,"* ]]; then
                            _auto_embed_with_mix "$video_file" "$target_srt" "$target" "$mix_file" "$mix_embed_title" "$mix_source_srt" "$mix_source_lang" && \
                                _auto_cleanup "$target_srt"
                            [[ -n "$mix_file" ]] && _auto_cleanup "$mix_file"
                            [[ -n "$mix_source_srt" ]] && _auto_cleanup "$mix_source_srt"
                        fi
                        [[ -n "$batch_state" ]] && echo "$base_name" >> "$batch_state"
                        continue
                    fi
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
                    if [[ -n "$first" ]]; then
                        if $DRY_RUN; then
                            info "Would download ($fl) + translate -> $target"
                            existing_srt="${dir_name}/${name_no_ext}.${fl}.srt"
                            existing_lang="$fl"
                            break
                        fi
                        local dl_path="${dir_name}/${name_no_ext}.${fl}.srt"
                        if download_subtitle "$first" "$dl_path" 2>/dev/null; then
                            log "Downloaded ($fl): $(basename "$dl_path")"
                            existing_srt="$dl_path"
                            existing_lang="$fl"
                            break
                        fi
                    fi
                fi
            done

            # Nothing found anywhere — prompt for URL in interactive mode
            if [[ -z "$existing_srt" ]]; then
                if [[ -t 0 ]] && ! $AUTO_SELECT && ! $DRY_RUN; then
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
                            sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$url_srt" | head -20 | tr '\n' ' ' || true)
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
        fi

        fi # end if ! FORCE_TRANSCRIBE

        # ── Step 2b: Transcribe from video audio (fallback or forced) ──
        if { [[ -z "$existing_srt" ]] || $FORCE_TRANSCRIBE; } && ! $NO_TRANSCRIBE; then
            if $DRY_RUN; then
                info "Would transcribe + translate -> $target"
                ((success++)) || true
                continue
            fi
            if command -v ffmpeg &>/dev/null; then
                $FORCE_TRANSCRIBE && info "Forced transcription..." || info "No subtitles found — trying transcription..."
                local transcribed_srt="${CACHE_DIR}/transcribe_auto_$$.srt"
                if transcribe_video "$video_file" "$transcribed_srt" "" "$TRANSCRIBE_PROVIDER"; then
                    # Detect language of transcribed subtitle
                    local tr_sample
                    tr_sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$transcribed_srt" | head -20 | tr '\n' ' ' || true)
                    local tr_lang
                    tr_lang=$(detect_lang "$tr_sample")
                    [[ -z "$tr_lang" ]] && tr_lang="und"
                    info "Transcribed language: $tr_lang"

                    if [[ "$tr_lang" == "$target" ]]; then
                        # Transcribed in target language — use directly
                        mv "$transcribed_srt" "$target_srt"
                        log "Transcribed ($tr_lang): $(basename "$target_srt")"
                        ((success++)) || true
                        local mix_file="" mix_embed_title="" mix_source_srt="" mix_source_lang=""
                        # Sync target first
                        if [[ "$_skip" != *",sync,"* ]]; then
                            _auto_sync "$video_file" "$target_srt" "$target"
                        else
                            _apply_sync_shift_only "$target_srt"
                        fi
                        if $MIX_MODE && [[ "$_skip" != *",mix,"* ]]; then
                            local mix_info=""
                            mix_info=$(_auto_mix "$video_file" "$target_srt" "$target") && {
                                local _ml="${mix_info%%|*}"
                                local _rest="${mix_info#*|}"
                                mix_file="${_rest%%|*}"
                                mix_source_srt="${_rest#*|}"
                                mix_source_lang="$_ml"
                                [[ "$mix_source_srt" == "$mix_file" ]] && mix_source_srt=""
                                if [[ "$SWAP_MIX" == "true" ]]; then
                                    mix_embed_title="Mix $(_lang_title "$_ml")-$(_lang_title "$target")"
                                else
                                    mix_embed_title="Mix $(_lang_title "$target")-$(_lang_title "$_ml")"
                                fi
                            }
                        fi
                        if $do_embed && [[ "$_skip" != *",embed,"* ]]; then
                            _auto_embed_with_mix "$video_file" "$target_srt" "$target" "$mix_file" "$mix_embed_title" "$mix_source_srt" "$mix_source_lang" && \
                                _auto_cleanup "$target_srt"
                            [[ -n "$mix_file" ]] && _auto_cleanup "$mix_file"
                            [[ -n "$mix_source_srt" ]] && _auto_cleanup "$mix_source_srt"
                        fi
                        [[ -n "$batch_state" ]] && echo "$base_name" >> "$batch_state"
                        continue
                    else
                        # Transcribed in different language — pass to translation step
                        local tr_path="${dir_name}/${name_no_ext}.${tr_lang}.srt"
                        mv "$transcribed_srt" "$tr_path"
                        existing_srt="$tr_path"
                        existing_lang="$tr_lang"
                    fi
                else
                    debug "Transcription failed — continuing without subtitles" || true
                fi
            fi
        fi

        # ── Step 3: Translate if we have a subtitle in another language ──
        if [[ -n "$existing_srt" && "$existing_lang" != "$target" ]]; then
            if [[ "$_skip" == *",translate,"* ]]; then
                debug "Skip step: translate" || true
            elif $DRY_RUN; then
                info "Would translate $existing_lang -> $target: $(basename "$existing_srt")"
                $MIX_MODE && info "Would mix: $existing_lang + $target"
                info "Would sync + embed"
                ((success++)) || true
                continue
            elif translate_subtitle "$existing_srt" "$target_srt" "$existing_lang" "$target" "$AI_PROVIDER"; then
                log "Translated: $(basename "$target_srt")"
                ((success++)) || true

                # ── Step 4: Sync target_srt (same as without --mix) ──
                if [[ "$_skip" != *",sync,"* ]]; then
                    _auto_sync "$video_file" "$target_srt" "$target"
                else
                    _apply_sync_shift_only "$target_srt"
                fi
                _normalize_srt_for_mix "$target_srt" || true
                # ── Step 4a: Also sync existing_srt so both drop the same blocks ──
                if $MIX_MODE; then
                    if [[ "$_skip" != *",sync,"* ]]; then
                        _auto_sync "$video_file" "$existing_srt" "$existing_lang"
                    else
                        _apply_sync_shift_only "$existing_srt"
                    fi
                fi
                $MIX_MODE && _normalize_srt_for_mix "$existing_srt" || true
                # ── Step 4b: Mix using SYNCED target_srt timestamps ──
                local mix_file="" mix_embed_title=""
                if $MIX_MODE && [[ "$_skip" != *",mix,"* ]]; then
                    local mix_output="${dir_name}/${name_no_ext}.mix.srt"
                    local src_lang="${existing_lang:-}"
                    # Default: target lang on top (normal), source/learning lang on bottom (italic).
                    local do_swap=false
                    [[ "$SWAP_MIX" == "true" ]] && do_swap=true
                    if [[ "$do_swap" == "true" ]]; then
                        info "Mixing: $src_lang (top) + $target (bottom, italic)"
                    else
                        info "Mixing: $target (top) + $src_lang (bottom, italic)"
                    fi
                    # Choose match mode dynamically: block when counts match, timestamp
                    # when they don't. Translation can drop blocks (empty/whitespace
                    # output), which would silently misalign block-by-index pairing.
                    local _t_blocks _s_blocks _tx_mode="block"
                    _t_blocks=$(_count_srt_blocks "$target_srt")
                    _s_blocks=$(_count_srt_blocks "$existing_srt")
                    if [[ "$_t_blocks" -eq 0 || "$_s_blocks" -eq 0 || "$_t_blocks" -ne "$_s_blocks" ]]; then
                        _tx_mode="timestamp"
                        debug "Mix (translate path): block counts differ ($_t_blocks vs $_s_blocks) — timestamp mode" || true
                    fi
                    _mix_subtitles "$target_srt" "$existing_srt" "$mix_output" "$do_swap" "$_tx_mode"
                    log "Mixed: $(basename "$mix_output")"
                    mix_file="$mix_output"
                    if [[ -n "$src_lang" ]]; then
                        if [[ "$do_swap" == "true" ]]; then
                            mix_embed_title="Mix $(_lang_title "$src_lang")-$(_lang_title "$target")"
                        else
                            mix_embed_title="Mix $(_lang_title "$target")-$(_lang_title "$src_lang")"
                        fi
                    fi
                fi
                # ── Step 5: Embed if requested ──
                if $do_embed && [[ "$_skip" != *",embed,"* ]]; then
                    local _src_srt="" _src_lang=""
                    if [[ -n "$mix_file" && -n "$existing_srt" && -f "$existing_srt" ]]; then
                        _src_srt="$existing_srt"
                        _src_lang="${existing_lang:-}"
                    fi
                    _auto_embed_with_mix "$video_file" "$target_srt" "$target" "$mix_file" "$mix_embed_title" "$_src_srt" "$_src_lang" && \
                        _auto_cleanup "$target_srt" "$existing_srt"
                    [[ -n "$mix_file" ]] && _auto_cleanup "$mix_file"
                fi
                [[ -n "$batch_state" ]] && echo "$base_name" >> "$batch_state"
                continue
            else
                warn "Translation failed: $base_name"
                # Clean up downloaded fallback subtitle on translation failure
                [[ -n "$existing_srt" ]] && _auto_cleanup "$existing_srt"
            fi
        elif [[ -z "$existing_srt" ]]; then
            warn "No subtitles for: $base_name"
        fi

        if [[ ! -f "$target_srt" ]]; then
            ((fail++)) || true
        fi
        [[ "$mode" == "dir" && $total -gt 1 ]] && progress "$((success + fail + skip))" "$total" "Auto"
    done

    printf "\n"
    header "Auto result"
    log "Total: $total | OK: $success | Skips: $skip | Failed: $fail"
}

# Helper for auto-cleanup (remove SRT files after successful embed)
_auto_cleanup() {
    $KEEP_FILES && return 0
    local files_to_remove=("$@")
    for f in "${files_to_remove[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            debug "Cleanup: removed $(basename "$f")" || true
        fi
    done
}

# Helper for auto-mix: find source subtitle + mix with target
# Usage: _auto_mix <video> <target_srt> <target_lang> [existing_srt] [existing_lang]
# Outputs mixed file path to stdout. Returns 0 on success, 1 if no source found.
_auto_mix() {
    local video="$1" target_srt="$2" target="$3"
    local existing_srt="${4:-}" existing_lang="${5:-}"
    local dir_name name_no_ext
    dir_name=$(dirname "$video")
    name_no_ext=$(basename "$video")
    name_no_ext="${name_no_ext%.*}"

    local mix_source="" mix_lang=""

    # Resolve effective mix language (needed for both translate and search paths)
    local _effective_mix_lang="${MIX_LANG:-}"
    if [[ -z "$_effective_mix_lang" ]] && command -v ffprobe &>/dev/null; then
        local _aidx _alang
        while IFS=',' read -r _aidx _alang; do
            _alang=$(echo "$_alang" | tr -d '[:space:]')
            [[ -z "$_alang" || "$_alang" == "und" ]] && continue
            _alang=$(_iso639_2_to_lang "$_alang")
            [[ "$_alang" == "$target" ]] && continue
            _effective_mix_lang="$_alang"
            info "Auto-detected mix language: $_effective_mix_lang"
            break
        done < <(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language -of csv=p=0 "$video" 2>/dev/null)
    fi

    # --mix-translate: skip search/download, translate target subtitle directly
    if ! $MIX_TRANSLATE; then

    # Priority 1: explicit existing_srt from translate path
    if [[ -n "$existing_srt" && -f "$existing_srt" && "$existing_lang" != "$target" ]]; then
        mix_source="$existing_srt"
        mix_lang="$existing_lang"
    fi

    # Priority 2: if --mix <lang> specified, look for that specific language
    if [[ -n "$MIX_LANG" && ( -z "$mix_source" || "$mix_lang" != "$MIX_LANG" ) ]]; then
        local want_srt="${dir_name}/${name_no_ext}.${MIX_LANG}.srt"
        if [[ -f "$want_srt" && "$want_srt" != "$target_srt" ]]; then
            mix_source="$want_srt"
            mix_lang="$MIX_LANG"
        fi
    fi

    # Priority 3: scan for any existing .XX.srt in another language
    if [[ -z "$mix_source" ]]; then
        local srt_file srt_lang
        for srt_file in "${dir_name}/${name_no_ext}".*.srt; do
            [[ -f "$srt_file" ]] || continue
            [[ "$srt_file" == "$target_srt" ]] && continue
            srt_lang=$(basename "$srt_file" .srt)
            srt_lang="${srt_lang##*.}"
            # Skip mix/dual outputs from previous runs
            [[ "$srt_lang" == "mix" ]] && continue
            if [[ -n "$srt_lang" && "$srt_lang" != "$target" && ${#srt_lang} -le 3 ]]; then
                # If --mix <lang> set, only accept that language
                if [[ -n "$MIX_LANG" && "$srt_lang" != "$MIX_LANG" ]]; then
                    continue
                fi
                mix_source="$srt_file"
                mix_lang="$srt_lang"
                break
            fi
        done
    fi

    # Priority 4: try to download subtitles in the mix language
    if [[ -z "$mix_source" && -n "$_effective_mix_lang" ]]; then
        local _mix_clean_name
        _mix_clean_name=$(basename "$video" | sed 's/\.[^.]*$//')
        _mix_clean_name=$(echo "$_mix_clean_name" | sed -E 's/\[[^]]*\]//g; s/\([^)]*\)//g; s/([Ss][0-9]+[Ee][0-9]+)[-. ].*/\1/')
        _mix_clean_name=$(echo "$_mix_clean_name" | tr '.' ' ')
        parse_smart_query "$_mix_clean_name" 2>/dev/null
        if [[ -n "$PARSED_TITLE" || -n "$PARSED_IMDB" ]]; then
            info "Downloading $_effective_mix_lang subtitles for mix..."
            local _mix_results="" _mix_url=""
            if _mix_results=$(search_all_sources "$PARSED_TITLE" "$_effective_mix_lang" "$PARSED_IMDB" "$PARSED_SEASON" "$PARSED_EPISODE" 2>/dev/null); then
                _mix_url=$(echo "$_mix_results" | head -1)
                if [[ -n "$_mix_url" ]]; then
                    local _mix_dl="${dir_name}/${name_no_ext}.${_effective_mix_lang}.srt"
                    if download_subtitle "$_mix_url" "$_mix_dl" 2>/dev/null && [[ -s "$_mix_dl" ]]; then
                        log "Downloaded ($_effective_mix_lang) for mix: $(basename "$_mix_dl")"
                        mix_source="$_mix_dl"
                        mix_lang="$_effective_mix_lang"
                    else
                        debug "Mix: download failed for $_effective_mix_lang" || true
                    fi
                fi
            fi
        fi
    fi

    fi # end if ! $MIX_TRANSLATE

    # Priority 5: translate target subtitle into the mix language (fallback, or forced via --mix-translate)
    if [[ -z "$mix_source" && -n "$_effective_mix_lang" && -f "$target_srt" ]]; then
        local _mix_translated="${dir_name}/${name_no_ext}.${_effective_mix_lang}.srt"
        info "Translating $target -> $_effective_mix_lang for mix..."
        if translate_subtitle "$target_srt" "$_mix_translated" "$target" "$_effective_mix_lang" "$AI_PROVIDER" 2>/dev/null; then
            if [[ -s "$_mix_translated" ]]; then
                log "Translated ($target -> $_effective_mix_lang) for mix: $(basename "$_mix_translated")"
                mix_source="$_mix_translated"
                mix_lang="$_effective_mix_lang"
            else
                debug "Mix: translation produced empty file" || true
                rm -f "$_mix_translated"
            fi
        else
            debug "Mix: translation failed for $_effective_mix_lang" || true
            rm -f "$_mix_translated"
        fi
    fi

    if [[ -z "$mix_source" ]]; then
        debug "Mix: no source subtitle found (need a subtitle in another language)" || true
        return 1
    fi

    # Sync mix_source against target_srt (subtitle-to-subtitle) for block alignment.
    # When sync succeeds, both files share the same timeline (including any
    # AUTO_SYNC_SHIFT already applied to target_srt via the earlier video sync).
    # This sub-to-sub sync is internal mix alignment — not the same thing as the
    # video<->subtitle sync that --skip-steps sync controls — so we run it even
    # in skip-steps-sync mode. On failure, fall back to a direct video sync so
    # mix_source gets ffsubsync's correction + AUTO_SYNC_SHIFT for its standalone
    # track (skip the fallback when the user explicitly opted out of video sync).
    _auto_sync "$target_srt" "$mix_source" "$mix_lang"
    if ! $_LAST_SYNC_OK; then
        local _am_skip=",${SKIP_STEPS:-},"
        if [[ "$_am_skip" != *",sync,"* ]]; then
            debug "Mix: sub-to-sub sync failed — falling back to video sync for mix_source" || true
            _auto_sync "$video" "$mix_source" "$mix_lang"
        else
            debug "Mix: sub-to-sub sync failed — skipping video fallback (--skip-steps sync)" || true
        fi
    fi
    _normalize_srt_for_mix "$target_srt" || true
    _normalize_srt_for_mix "$mix_source" || true

    local mix_output="${dir_name}/${name_no_ext}.mix.srt"
    # Default: target lang on top (normal), mix/learning lang on bottom (italic).
    # --swap reverses.
    local do_swap=false
    [[ "$SWAP_MIX" == "true" ]] && do_swap=true
    if [[ "$do_swap" == "true" ]]; then
        info "Mixing: $mix_lang (top) + $target (bottom, italic)"
    else
        info "Mixing: $target (top) + $mix_lang (bottom, italic)"
    fi
    # Prefer block matching after subtitle-to-subtitle sync to avoid drift on long files.
    # Fall back to timestamp overlap whenever counts diverge — any diff means a block
    # was dropped (e.g. translation produced empty text), which would silently misalign
    # everything from that point onward under block-by-index pairing.
    local _target_blocks _mix_blocks _mix_mode="block"
    _target_blocks=$(_count_srt_blocks "$target_srt")
    _mix_blocks=$(_count_srt_blocks "$mix_source")
    if [[ "$_target_blocks" -eq 0 || "$_mix_blocks" -eq 0 ]]; then
        _mix_mode="timestamp"
    elif [[ "$_target_blocks" -ne "$_mix_blocks" ]]; then
        _mix_mode="timestamp"
        debug "Mix: block counts differ ($_target_blocks vs $_mix_blocks) — using timestamp mode" || true
    fi

    _mix_subtitles "$target_srt" "$mix_source" "$mix_output" "$do_swap" "$_mix_mode"
    log "Mixed: $(basename "$mix_output")"

    # Output lang|mix_path|source_path — caller embeds all three and handles cleanup
    echo "${mix_lang}|${mix_output}|${mix_source}"
    return 0
}

# Helper: map 2-letter lang to 3-letter ISO 639-2 code (used by ffprobe)
_lang_to_iso639_2() {
    case "$1" in
        fr|fre|fra) echo "fre" ;; en|eng)     echo "eng" ;; es|spa)     echo "spa" ;;
        de|ger|deu) echo "ger" ;; it|ita)     echo "ita" ;; pt|por)     echo "por" ;;
        ru|rus)     echo "rus" ;; ar|ara)     echo "ara" ;; ja|jpn)     echo "jpn" ;;
        ko|kor)     echo "kor" ;; zh|chi|zho) echo "chi" ;; nl|dut|nld) echo "dut" ;;
        pl|pol)     echo "pol" ;; sv|swe)     echo "swe" ;; da|dan)     echo "dan" ;;
        fi|fin)     echo "fin" ;; no|nor)     echo "nor" ;; tr|tur)     echo "tur" ;;
        *)          echo "$1" ;;
    esac
}

# Helper: map 3-letter ISO 639-2 code back to 2-letter code
_iso639_2_to_lang() {
    case "$1" in
        fre|fra) echo "fr" ;; eng)     echo "en" ;; spa)     echo "es" ;;
        ger|deu) echo "de" ;; ita)     echo "it" ;; por)     echo "pt" ;;
        rus)     echo "ru" ;; ara)     echo "ar" ;; jpn)     echo "ja" ;;
        kor)     echo "ko" ;; chi|zho) echo "zh" ;; dut|nld) echo "nl" ;;
        pol)     echo "pl" ;; swe)     echo "sv" ;; dan)     echo "da" ;;
        fin)     echo "fi" ;; nor)     echo "no" ;; tur)     echo "tr" ;;
        *)       echo "$1" ;;
    esac
}

# Helper: find the global stream index of an embedded subtitle matching a language
# Returns the global stream index (e.g., "4") for use with ffmpeg -map 0:N
_find_subtitle_stream_index() {
    local video="$1" lang="$2"
    [[ -z "$lang" ]] && return 1
    command -v ffprobe &>/dev/null || return 1
    local lang3
    lang3=$(_lang_to_iso639_2 "$lang")

    while IFS=',' read -r idx stream_lang; do
        idx=$(echo "$idx" | tr -d '[:space:]')
        stream_lang=$(echo "$stream_lang" | tr -d '[:space:]')
        if [[ "$stream_lang" == "$lang" || "$stream_lang" == "$lang3" ]]; then
            echo "$idx"
            return 0
        fi
    done < <(ffprobe -v error -select_streams s -show_entries stream=index:stream_tags=language -of csv=p=0 "$video" 2>/dev/null)

    return 1
}

# Helper: extract an embedded subtitle to a temp file for use as sync reference
# Returns the path to the extracted temp file, or fails
_extract_ref_subtitle() {
    local video="$1" lang="$2"
    command -v ffmpeg &>/dev/null || return 1
    local stream_idx
    stream_idx=$(_find_subtitle_stream_index "$video" "$lang") || return 1

    local ref_tmp="${CACHE_DIR}/sync_ref_${lang}_$$.srt"
    if ffmpeg -v error -i "$video" -map "0:${stream_idx}" -c:s srt "$ref_tmp" -y 2>/dev/null; then
        if [[ -s "$ref_tmp" ]]; then
            echo "$ref_tmp"
            return 0
        fi
    fi
    rm -f "$ref_tmp"
    return 1
}

# Helper: find the audio stream index matching a language in a video file
# Returns ffsubsync-compatible stream reference (e.g., "a:1") or fails
_find_audio_stream() {
    local video="$1" lang="$2"
    [[ -z "$lang" ]] && return 1
    command -v ffprobe &>/dev/null || return 1
    local lang3
    lang3=$(_lang_to_iso639_2 "$lang")

    local audio_idx=0
    while IFS= read -r stream_lang; do
        stream_lang=$(echo "$stream_lang" | tr -d '[:space:]')
        if [[ "$stream_lang" == "$lang" || "$stream_lang" == "$lang3" ]]; then
            echo "a:$audio_idx"
            return 0
        fi
        ((audio_idx++))
    done < <(ffprobe -v error -select_streams a -show_entries stream_tags=language -of csv=p=0 "$video" 2>/dev/null)

    return 1
}

# Apply a constant shift (ms) to an SRT file in place. Negative clamps to 00:00:00,000.
_shift_srt_inplace() {
    local file="$1" shift_ms="$2"
    [[ -z "$shift_ms" || "$shift_ms" == "0" ]] && return 0
    [[ ! -f "$file" ]] && return 1
    local tmp="${file}.shifted.$$"
    awk -v shift="$shift_ms" '
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
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Helper for auto-sync (sync subtitle with video via ffsubsync)
_auto_sync() {
    local video="$1" sub="$2" lang="${3:-}"
    # Reset success indicator at entry — otherwise an early return (e.g. ffsubsync
    # not installed) would leave callers reading a stale value from a previous call.
    _LAST_SYNC_OK=false
    # Determine ffsubsync command
    local ffsubsync_cmd=()
    if command -v ffsubsync &>/dev/null; then
        ffsubsync_cmd=(ffsubsync)
    elif command -v uvx &>/dev/null; then
        ffsubsync_cmd=(uvx --with "setuptools<75" ffsubsync)
        info "Using uvx ffsubsync"
    else
        warn "ffsubsync not available — skip sync. Install: uvx ffsubsync"
        return 0
    fi
    local synced="${sub%.srt}.synced.srt"

    # Find best sync reference for target language:
    # 1. Extract embedded subtitle in same language (fast, accurate subtitle-to-subtitle sync)
    # 2. Fall back to matching audio track via --reference-stream (slower VAD-based sync)
    local sync_ref="$video"
    local ref_stream_args=()
    local ref_tmp=""
    if [[ -n "$lang" ]]; then
        if ref_tmp=$(_extract_ref_subtitle "$video" "$lang"); then
            sync_ref="$ref_tmp"
            info "Sync: using extracted embedded subtitle ($lang)"
        else
            local stream_ref
            if stream_ref=$(_find_audio_stream "$video" "$lang"); then
                ref_stream_args=(--reference-stream "$stream_ref")
                info "Sync: using audio track $stream_ref ($lang)"
            fi
        fi
    fi

    info "Sync: $(basename "$sub") with $(basename "$video") (this may take a few minutes)"
    # Capture ffsubsync output so we can inspect it (dropped blocks signal overshoot)
    # while still streaming to stderr for live progress.
    local sync_log
    sync_log=$(mktemp -t subtool_sync.XXXXXX 2>/dev/null) || sync_log="/dev/null"
    local sync_ok=false
    if "${ffsubsync_cmd[@]}" "$sync_ref" -i "$sub" -o "$synced" "${ref_stream_args[@]}" 2>&1 | tee "$sync_log" >&2; then
        if [[ -s "$synced" ]]; then
            mv "$synced" "$sub"
            log "Sync OK: $(basename "$sub")"
            sync_ok=true
        else
            warn "Sync produced empty file — keeping original"
        fi
    else
        warn "Sync failed — keeping unsynced version"
        rm -f "$synced"
    fi
    # Heuristic warning: when ffsubsync's shift pushes many blocks before time 0,
    # they're silently dropped. That's expected for truncated content but often
    # signals the shift was too aggressive. Surface it so the user can decide.
    if $sync_ok; then
        # ffsubsync wraps lines, so just match the start of the warning string
        local skipped_neg
        skipped_neg=$(grep -c "Skipped subtitle at index" "$sync_log" 2>/dev/null || echo 0)
        skipped_neg="${skipped_neg//[^0-9]/}"
        if [[ -n "$skipped_neg" && "$skipped_neg" -ge 3 ]]; then
            warn "Sync dropped $skipped_neg subtitle block(s). ffsubsync may have over-shifted —"
            warn "  if subs feel offset, try: --sync-shift +<ms> (positive = delay subs)"
        fi
    fi
    rm -f "$sync_log"
    # Expose sync success via global so callers can fall back (e.g. sub-to-sub
    # failure should trigger a video-sync retry, not just a blind shift).
    _LAST_SYNC_OK="$sync_ok"
    # Apply user-configured constant shift on top of ffsubsync result.
    # The shift compensates for video<->subtitle offsets ffsubsync can't detect.
    # Skip in sub-to-sub mode (ref is an SRT): the sub was aligned to a target
    # that already carries the shift, so re-applying would double-shift. On sync
    # failure in sub-ref mode, the caller is responsible for falling back to a
    # video sync — applying just the shift here would give wrong absolute timing.
    if [[ -n "$AUTO_SYNC_SHIFT" && "$AUTO_SYNC_SHIFT" != "0" ]]; then
        local _is_sub_ref=false
        case "$video" in
            *.[Ss][Rr][Tt]|*.[Aa][Ss][Ss]|*.[Ss][Ss][Aa]|*.[Vv][Tt][Tt]|*.[Ss][Uu][Bb])
                _is_sub_ref=true ;;
        esac
        if ! $_is_sub_ref && _shift_srt_inplace "$sub" "$AUTO_SYNC_SHIFT"; then
            log "Sync: applied constant shift ${AUTO_SYNC_SHIFT}ms"
        fi
    fi
    # Clean up extracted reference subtitle
    [[ -n "$ref_tmp" ]] && rm -f "$ref_tmp" || true
}

# Count valid block indexes in an SRT file. Tolerates UTF-8 BOM and CRLF line
# endings so callers don't get a spurious 0 (which would falsely flip mix logic
# into timestamp-mode) for otherwise valid files.
_count_srt_blocks() {
    local file="$1"
    [[ -f "$file" ]] || { echo 0; return 0; }
    sed '1s/^\xef\xbb\xbf//' "$file" 2>/dev/null | tr -d '\r' | grep -cE '^[0-9]+$' 2>/dev/null || echo 0
}

# Apply only the AUTO_SYNC_SHIFT (no ffsubsync). For use when the sync step is
# skipped via --skip-steps sync but the user still wants a manual constant shift.
_apply_sync_shift_only() {
    local sub="$1"
    [[ -n "$AUTO_SYNC_SHIFT" && "$AUTO_SYNC_SHIFT" != "0" ]] || return 0
    [[ -f "$sub" ]] || return 1
    if _shift_srt_inplace "$sub" "$AUTO_SYNC_SHIFT"; then
        log "Sync skipped — applied constant shift ${AUTO_SYNC_SHIFT}ms: $(basename "$sub")"
    fi
}

# Helper: convert language code to human-readable title for subtitle track metadata
_lang_title() {
    local code="$1"
    case "$code" in
        en|eng) echo "English" ;;
        fr|fre|fra) echo "French" ;;
        de|deu|ger) echo "German" ;;
        es|spa) echo "Spanish" ;;
        it|ita) echo "Italian" ;;
        pt|por) echo "Portuguese" ;;
        nl|nld|dut) echo "Dutch" ;;
        ru|rus) echo "Russian" ;;
        ja|jpn) echo "Japanese" ;;
        zh|zho|chi) echo "Chinese" ;;
        ko|kor) echo "Korean" ;;
        ar|ara) echo "Arabic" ;;
        pl|pol) echo "Polish" ;;
        tr|tur) echo "Turkish" ;;
        sv|swe) echo "Swedish" ;;
        da|dan) echo "Danish" ;;
        no|nor|nb|nob) echo "Norwegian" ;;
        fi|fin) echo "Finnish" ;;
        cs|ces|cze) echo "Czech" ;;
        ro|ron|rum) echo "Romanian" ;;
        hu|hun) echo "Hungarian" ;;
        el|ell|gre) echo "Greek" ;;
        he|heb) echo "Hebrew" ;;
        th|tha) echo "Thai" ;;
        vi|vie) echo "Vietnamese" ;;
        id|ind) echo "Indonesian" ;;
        ms|msa|may) echo "Malay" ;;
        hi|hin) echo "Hindi" ;;
        bn|ben) echo "Bengali" ;;
        ta|tam) echo "Tamil" ;;
        te|tel) echo "Telugu" ;;
        mr|mar) echo "Marathi" ;;
        gu|guj) echo "Gujarati" ;;
        kn|kan) echo "Kannada" ;;
        ml|mal) echo "Malayalam" ;;
        pa|pan) echo "Punjabi" ;;
        ur|urd) echo "Urdu" ;;
        ne|nep) echo "Nepali" ;;
        si|sin) echo "Sinhala" ;;
        my|mya|bur) echo "Burmese" ;;
        km|khm) echo "Khmer" ;;
        lo|lao) echo "Lao" ;;
        mn|mon) echo "Mongolian" ;;
        ka|kat|geo) echo "Georgian" ;;
        hy|hye|arm) echo "Armenian" ;;
        az|aze) echo "Azerbaijani" ;;
        uz|uzb) echo "Uzbek" ;;
        kk|kaz) echo "Kazakh" ;;
        tl|tgl|fil) echo "Filipino" ;;
        jv|jav) echo "Javanese" ;;
        su|sun) echo "Sundanese" ;;
        uk|ukr) echo "Ukrainian" ;;
        bg|bul) echo "Bulgarian" ;;
        hr|hrv) echo "Croatian" ;;
        sr|srp) echo "Serbian" ;;
        sk|slk|slo) echo "Slovak" ;;
        sl|slv) echo "Slovenian" ;;
        et|est) echo "Estonian" ;;
        lv|lav) echo "Latvian" ;;
        lt|lit) echo "Lithuanian" ;;
        ca|cat) echo "Catalan" ;;
        gl|glg) echo "Galician" ;;
        eu|eus|baq) echo "Basque" ;;
        # African
        af|afr) echo "Afrikaans" ;;
        sw|swa) echo "Swahili" ;;
        am|amh) echo "Amharic" ;;
        yo|yor) echo "Yoruba" ;;
        zu|zul) echo "Zulu" ;;
        xh|xho) echo "Xhosa" ;;
        ha|hau) echo "Hausa" ;;
        ig|ibo) echo "Igbo" ;;
        so|som) echo "Somali" ;;
        rw|kin) echo "Kinyarwanda" ;;
        mg|mlg) echo "Malagasy" ;;
        # European (missing)
        is|isl|ice) echo "Icelandic" ;;
        ga|gle) echo "Irish" ;;
        cy|cym|wel) echo "Welsh" ;;
        sq|sqi|alb) echo "Albanian" ;;
        mk|mkd|mac) echo "Macedonian" ;;
        bs|bos) echo "Bosnian" ;;
        be|bel) echo "Belarusian" ;;
        mt|mlt) echo "Maltese" ;;
        lb|ltz) echo "Luxembourgish" ;;
        fo|fao) echo "Faroese" ;;
        # Persian / Central Asian
        fa|fas|per) echo "Persian" ;;
        ku|kur) echo "Kurdish" ;;
        ps|pus) echo "Pashto" ;;
        tg|tgk) echo "Tajik" ;;
        tk|tuk) echo "Turkmen" ;;
        ky|kir) echo "Kyrgyz" ;;
        tt|tat) echo "Tatar" ;;
        # South Asian (missing)
        or|ori) echo "Odia" ;;
        as|asm) echo "Assamese" ;;
        sd|snd) echo "Sindhi" ;;
        # East/Southeast Asian (missing)
        bo|bod|tib) echo "Tibetan" ;;
        ug|uig) echo "Uyghur" ;;
        # Caribbean / Creole
        ht|hat) echo "Haitian Creole" ;;
        # Other
        eo|epo) echo "Esperanto" ;;
        la|lat) echo "Latin" ;;
        yi|yid) echo "Yiddish" ;;
        *) echo "$code" ;;
    esac
}

# Helper: detect language of an embedded subtitle stream by extracting a text sample
# Usage: _detect_stream_lang video stream_index
# Returns detected language code, or "und" if detection fails
_detect_stream_lang() {
    local video="$1" stream_idx="$2"
    local tmp_sub="$CACHE_DIR/detect_lang_$$.srt"
    if ffmpeg -v quiet -i "$video" -map "0:s:${stream_idx}" -c:s srt "$tmp_sub" -y 2>/dev/null && [[ -s "$tmp_sub" ]]; then
        local sample
        sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$tmp_sub" | head -20 | tr '\n' ' ' || true)
        rm -f "$tmp_sub"
        if [[ -n "$sample" ]]; then
            local detected
            detected=$(detect_lang "$sample")
            if [[ -n "$detected" && "$detected" != "und" ]]; then
                echo "$detected"
                return 0
            fi
        fi
    fi
    rm -f "$tmp_sub"
    echo "und"
}

# Helper for auto-embed (embed srt into video, replace original)
_auto_embed() {
    local video="$1" sub="$2" lang="$3" title_override="${4:-}"

    # Validate SRT before embedding to prevent video corruption
    if ! validate_srt "$sub"; then
        warn "Invalid SRT format: $(basename "$sub") — skipping embed"
        return 1
    fi

    # Get existing subtitle stream info
    local streams_json
    streams_json=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$video" 2>/dev/null)
    local sub_count
    sub_count=$(echo "$streams_json" | jq '.streams | length' 2>/dev/null || echo "0")

    # Strip existing subtitle tracks if requested
    if [[ "$STRIP_EXISTING" == "true" && "$sub_count" -gt 0 ]]; then
        local vext_strip="${video##*.}"
        local stripped_video="${video%.${vext_strip}}.stripped.${vext_strip}"
        info "Stripping $sub_count existing subtitle track(s): $(basename "$video")"
        if ffmpeg -v quiet -i "$video" -map 0 -map -0:s -c copy "$stripped_video" -y 2>/dev/null && [[ -s "$stripped_video" ]]; then
            mv "$stripped_video" "$video"
            sub_count=0
            streams_json='{"streams":[]}'
        else
            warn "Strip failed, embedding alongside existing tracks"
            rm -f "$stripped_video"
        fi
    fi

    # Skip if video already has a subtitle stream (unless --force-embed)
    if [[ "$sub_count" -gt 0 ]] && ! $FORCE_EMBED; then
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

    local lang_title
    lang_title=${title_override:-$(_lang_title "$lang")}
    # MP4/mov_text silently drops 2-letter ISO 639-1 codes ("fr", "de") — the
    # mov muxer only stores ISO 639-2 (3-letter). Always emit 3-letter so the
    # language tag survives regardless of container.
    local lang_iso
    lang_iso=$(_lang_to_iso639_2 "$lang")

    # Build ffmpeg command with proper metadata for ALL subtitle streams
    local ffmpeg_cmd=(ffmpeg -v quiet -i "$video" -i "$sub"
        -map 0 -map 1:0 -c copy -c:s:"$sub_count" "$sub_codec")

    # Preserve/fix metadata for existing subtitle streams (prevents "piste 1/2" labels)
    local sidx
    for ((sidx=0; sidx<sub_count; sidx++)); do
        local s_lang s_title s_lang_iso
        s_lang=$(echo "$streams_json" | jq -r ".streams[$sidx].tags.language // \"und\"")
        s_title=$(echo "$streams_json" | jq -r ".streams[$sidx].tags.title // \"\"")
        # Auto-detect language if undefined
        if [[ "$s_lang" == "und" || -z "$s_lang" ]]; then
            s_lang=$(_detect_stream_lang "$video" "$sidx")
        fi
        [[ -z "$s_title" ]] && s_title=$(_lang_title "$s_lang")
        s_lang_iso=$(_lang_to_iso639_2 "$s_lang")
        ffmpeg_cmd+=(-metadata:s:s:"$sidx" language="$s_lang_iso" -metadata:s:s:"$sidx" title="$s_title")
    done

    # Set metadata for the new subtitle stream
    ffmpeg_cmd+=(-metadata:s:s:"$sub_count" language="$lang_iso" -metadata:s:s:"$sub_count" title="$lang_title")
    ffmpeg_cmd+=("$tmp_video" -y)

    if "${ffmpeg_cmd[@]}" 2>/dev/null && [[ -s "$tmp_video" ]]; then
        mv "$tmp_video" "$video"
        log "Embed OK: $(basename "$video")"
        return 0
    else
        warn "Embed failed: $(basename "$video")"
        rm -f "$tmp_video"
        return 1
    fi
}

# Helper: embed target subtitle + optional source lang + optional mix as separate tracks
# Usage: _auto_embed_with_mix <video> <target_srt> <target_lang> [mix_srt] [mix_title] [source_srt] [source_lang]
_auto_embed_with_mix() {
    local video="$1" target_srt="$2" target_lang="$3"
    local mix_srt="${4:-}" mix_title="${5:-}"
    local source_srt="${6:-}" source_lang="${7:-}"

    # Embed target subtitle first (handles --strip-existing)
    _auto_embed "$video" "$target_srt" "$target_lang" "" || return 1

    local _save_strip="$STRIP_EXISTING" _save_force="$FORCE_EMBED"
    STRIP_EXISTING=false
    FORCE_EMBED=true

    # Embed mix source language subtitle as additional track if available
    if [[ -n "$source_srt" && -f "$source_srt" && -n "$source_lang" ]]; then
        _auto_embed "$video" "$source_srt" "$source_lang" ""
    fi

    # Embed mix subtitle as additional track if available
    if [[ -n "$mix_srt" && -f "$mix_srt" && -n "$mix_title" ]]; then
        _auto_embed "$video" "$mix_srt" "mul" "$mix_title"
    fi

    STRIP_EXISTING="$_save_strip"
    FORCE_EMBED="$_save_force"
    return 0
}

# ── Command: translate ───────────────────────────────────────────────────────
cmd_translate() {
    _multi_lang_dispatch cmd_translate && return
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool $COMMAND file.srt)"
    [[ -z "$LANG_TARGET" ]] && die "Specify -l <lang> or set DEFAULT_LANG in config"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    local src_lang="${SRC_LANG:-}"
    translate_local_file "$FILE_PATH" "$src_lang" "$LANG_TARGET" "$AI_PROVIDER"
}

# ── Command: transcribe (video -> SRT via speech-to-text) ────────────────────
cmd_transcribe() {
    [[ -z "$FILE_PATH" ]] && die "Specify a video file (e.g., subtool transcribe video.mkv)"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"
    if ! command -v ffmpeg &>/dev/null; then
        die "ffmpeg required for transcription. Install it: brew install ffmpeg"
    fi

    local src_lang="${SRC_LANG:-}"
    local output_srt="${CACHE_DIR}/transcribe_$$.srt"

    if ! transcribe_video "$FILE_PATH" "$output_srt" "$src_lang" "$TRANSCRIBE_PROVIDER"; then
        die "Transcription failed"
    fi

    # Auto-detect language from transcription output
    local detected_lang="$src_lang"
    if [[ -z "$detected_lang" ]]; then
        local sample
        sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$output_srt" | head -20 | tr '\n' ' ' || true)
        detected_lang=$(detect_lang "$sample")
        [[ -z "$detected_lang" ]] && detected_lang="und"
        info "Detected language: $detected_lang"
    fi

    # Build final output path
    local base_name
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    local final_output="${OUTPUT_DIR}/${base_name}.${detected_lang}.srt"
    mv "$output_srt" "$final_output"
    log "Transcription saved: $final_output"

    # Auto-sync with video (ffsubsync)
    _auto_sync "$FILE_PATH" "$final_output" "$detected_lang"
}

# ── Command: info (SRT file stats) ───────────────────────────────────────────
cmd_info() {
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool $COMMAND file.srt)"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    header "Info: $(basename "$FILE_PATH")"

    local filesize line_count sub_count
    filesize=$(stat -f%z "$FILE_PATH" 2>/dev/null || stat -c%s "$FILE_PATH" 2>/dev/null || echo "0")
    local encoding
    encoding=$(file --mime-encoding "$FILE_PATH" 2>/dev/null | awk -F': ' '{print $2}' || echo "unknown")
    line_count=$(wc -l < "$FILE_PATH" | tr -d ' ')
    sub_count=$(sed '1s/^\xef\xbb\xbf//' "$FILE_PATH" | tr -d '\r' | grep -cE '^[0-9]+$' 2>/dev/null || echo "0")

    # First and last timestamp (format: HH:MM:SS,mmm --> HH:MM:SS,mmm)
    local first_ts last_ts
    first_ts=$(grep -m1 -oE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}' "$FILE_PATH" 2>/dev/null | head -1)
    local first_start="${first_ts%% -->*}"
    last_ts=$(grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}' "$FILE_PATH" 2>/dev/null | tail -1)
    local last_end="${last_ts##*--> }"

    # Language detection
    local sample_text
    sample_text=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$FILE_PATH" | head -20 | tr '\n' ' ' || true)
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
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool $COMMAND file.srt)"
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
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool $COMMAND file.srt)"
    [[ -z "$SYNC_SHIFT" ]] && die "Specify --shift <ms> (e.g., +1500, -800)"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    local base_name ext output
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${base_name}.synced.${ext}"

    header "Sync: $(basename "$FILE_PATH") (${SYNC_SHIFT}ms)"

    cp "$FILE_PATH" "$output"
    _shift_srt_inplace "$output" "$SYNC_SHIFT"

    echo "Shift applied: ${SYNC_SHIFT}ms" >&2

    log "Synced file: $output"
}

# ── Command: convert (SRT <-> VTT <-> ASS) ───────────────────────────────────
CONVERT_FORMAT=""

cmd_convert() {
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool $COMMAND file.srt)"
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
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool $COMMAND file.srt)"
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
    local tmp_pri="$CACHE_DIR/_merge_pri_$$.txt"
    local tmp_sec="$CACHE_DIR/_merge_sec_$$.txt"
    mkdir -p "$CACHE_DIR"

    # Parse SRT: output "START|END|TEXT" per block (0x1F as line separator)
    _parse_srt_blocks() {
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
        state == "text" {
            if (txt != "") txt = txt SEP
            txt = txt $0
        }
        END { flush() }
        '
    }

    _parse_srt_blocks "$FILE_PATH" > "$tmp_pri"
    _parse_srt_blocks "$MERGE_FILE" > "$tmp_sec"

    # Read parsed lines into arrays (avoids O(n²) sed per iteration)
    local -a pri_lines=() sec_lines=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        pri_lines+=("$line")
    done < "$tmp_pri"
    while IFS= read -r line || [[ -n "$line" ]]; do
        sec_lines+=("$line")
    done < "$tmp_sec"

    local count_pri=${#pri_lines[@]} count_sec=${#sec_lines[@]} max_count
    max_count=$count_pri
    [[ $count_sec -gt $max_count ]] && max_count=$count_sec

    # Merge the two files
    local idx=0
    : > "$output"
    while [[ $idx -lt $max_count ]]; do
        local pri_line="${pri_lines[$idx]:-}" sec_line="${sec_lines[$idx]:-}"
        ((idx++)) || true

        local start="" end_ts="" text="" sec_text=""

        if [[ -n "$pri_line" ]]; then
            IFS='|' read -r start end_ts text <<< "$pri_line"
        fi

        if [[ -n "$sec_line" ]]; then
            local _sec_start="" _sec_end=""
            IFS='|' read -r _sec_start _sec_end sec_text <<< "$sec_line"
            if [[ -z "$start" ]]; then
                start="$_sec_start"
                end_ts="$_sec_end"
            fi
        fi

        # Convert sentinel back to real newlines
        text="${text//<_NL_>/$'\n'}"
        sec_text="${sec_text//<_NL_>/$'\n'}"

        if [[ -n "$text" && -n "$sec_text" ]]; then
            printf '%d\n%s --> %s\n%s\n<i>%s</i>\n\n' "$idx" "$start" "$end_ts" "$text" "$sec_text" >> "$output"
        elif [[ -n "$text" ]]; then
            printf '%d\n%s --> %s\n%s\n\n' "$idx" "$start" "$end_ts" "$text" >> "$output"
        elif [[ -n "$sec_text" ]]; then
            printf '%d\n%s --> %s\n<i>%s</i>\n\n' "$idx" "$start" "$end_ts" "$sec_text" >> "$output"
        fi
    done

    echo "$idx subtitles merged" >&2
    rm -f "$tmp_pri" "$tmp_sec"

    log "Bilingual file: $output"
}

# ── Shared: mix two SRT files into one bilingual ─────────────────────────────
# Usage: _mix_subtitles <primary> <secondary> <output> [swap] [match_mode]
# Default: primary text on top (white), secondary text in grey. Timestamps from primary.
# swap=true: secondary text on top (white), primary text in grey. Timestamps still from primary.
#   Use swap when primary has synced timestamps but secondary has the learning-language text.
# match_mode: "block" (default) = pair by block index; "timestamp" = pair by time overlap.
#   Use "timestamp" when files come from different sources with different block structures.
_mix_subtitles() {
    local primary="$1" secondary="$2" output="$3" swap="${4:-false}" match_mode="${5:-block}"
    local tmp_pri="$CACHE_DIR/_mix_pri_$$.txt"
    local tmp_sec="$CACHE_DIR/_mix_sec_$$.txt"
    mkdir -p "$CACHE_DIR"

    # Parse SRT: output "START|END|TEXT" per block (text newlines as \n literal).
    # Empty-text blocks are emitted with an empty third field — dropping them here
    # would break block-by-index pairing when one side has more empties than the other
    # (e.g. translation produced whitespace-only text for some blocks).
    _mix_parse_srt() {
        sed '1s/^\xef\xbb\xbf//' "$1" | tr -d '\r' | awk '
        BEGIN { state = "init"; start = ""; end_ts = ""; txt = ""; SEP = "<_NL_>" }
        function flush() {
            if (start == "") { start = ""; end_ts = ""; txt = ""; return }
            printf "%s|%s|%s\n", start, end_ts, txt
            start = ""; end_ts = ""; txt = ""
        }
        /^[0-9]+[[:space:]]*$/ && state != "text" { flush(); state = "index"; next }
        /[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}/ {
            split($0, p, " --> "); start = p[1]; end_ts = p[2]; state = "text"; next
        }
        state == "text" && /^[[:space:]]*$/ { flush(); state = "init"; next }
        state == "text" {
            if (txt != "") txt = txt SEP
            txt = txt $0
        }
        END { flush() }
        '
    }

    _mix_parse_srt "$primary" > "$tmp_pri"
    _mix_parse_srt "$secondary" > "$tmp_sec"

    # Merge primary + secondary. Two modes:
    # - "block": pair by block index (same source, same structure)
    # - "timestamp": pair by time overlap (different sources, different block counts)
    awk -v swap="$swap" -v mode="$match_mode" '
    function ts2ms(ts,   p) {
        split(ts, p, /[:,]/)
        return (p[1] * 3600 + p[2] * 60 + p[3]) * 1000 + p[4]
    }
    function ms2ts(ms,   h, m, s, f) {
        h = int(ms / 3600000); ms -= h * 3600000
        m = int(ms / 60000);   ms -= m * 60000
        s = int(ms / 1000);    f = ms - s * 1000
        return sprintf("%02d:%02d:%02d,%03d", h, m, s, f)
    }
    function mymax(a, b) { return a > b ? a : b }
    function mymin(a, b) { return a < b ? a : b }

    BEGIN { np = 0; ns = 0; n = 0; SEP = "<_NL_>" }

    NR == FNR {
        np++
        split($0, f, "|")
        ps[np] = ts2ms(f[1]); pe[np] = ts2ms(f[2])
        pt[np] = f[3]; prs[np] = f[1]; pre[np] = f[2]
        next
    }
    {
        ns++
        split($0, f, "|")
        ss[ns] = ts2ms(f[1]); se[ns] = ts2ms(f[2])
        st[ns] = f[3]; srs[ns] = f[1]; sre[ns] = f[2]
    }

    END {
        if (mode == "timestamp") {
            # ── Timestamp overlap matching (for files from different sources) ──
            for (j = 1; j <= ns; j++) sec_used[j] = 0
            sptr = 1
            for (i = 1; i <= np; i++) {
                while (sptr <= ns && se[sptr] <= ps[i]) sptr++
                best_ov = 0; best_j = 0
                for (j = sptr; j <= ns; j++) {
                    if (ss[j] >= pe[i]) break
                    ov = mymin(pe[i], se[j]) - mymax(ps[i], ss[j])
                    if (ov > best_ov) { best_ov = ov; best_j = j }
                }
                if (best_j > 0) sec_used[best_j] = 1
                n++
                out_ms[n] = ps[i]; out_rs[n] = prs[i]; out_re[n] = pre[i]
                out_pt[n] = pt[i]; out_st[n] = (best_j > 0) ? st[best_j] : ""
            }
            # Append unmatched secondary blocks
            for (j = 1; j <= ns; j++) {
                if (!sec_used[j]) {
                    n++
                    out_ms[n] = ss[j]; out_rs[n] = srs[j]; out_re[n] = sre[j]
                    out_pt[n] = ""; out_st[n] = st[j]
                }
            }
            # Sort by start timestamp
            for (i = 2; i <= n; i++) {
                km = out_ms[i]; krs = out_rs[i]; kre = out_re[i]; kp = out_pt[i]; ks = out_st[i]
                j = i - 1
                while (j >= 1 && out_ms[j] > km) {
                    out_ms[j+1]=out_ms[j]; out_rs[j+1]=out_rs[j]; out_re[j+1]=out_re[j]
                    out_pt[j+1]=out_pt[j]; out_st[j+1]=out_st[j]; j--
                }
                out_ms[j+1]=km; out_rs[j+1]=krs; out_re[j+1]=kre; out_pt[j+1]=kp; out_st[j+1]=ks
            }
        } else {
            # ── Block-by-block matching (default — same source, same structure) ──
            max_n = (np > ns) ? np : ns
            for (i = 1; i <= max_n; i++) {
                n++
                if (i <= np) { out_rs[n] = prs[i]; out_re[n] = pre[i]; out_pt[n] = pt[i] }
                else         { out_rs[n] = srs[i]; out_re[n] = sre[i]; out_pt[n] = "" }
                if (i <= ns) { out_st[n] = st[i] }
                else         { out_st[n] = "" }
                # If primary block missing, use secondary timestamps
                if (i > np && i <= ns) { out_rs[n] = srs[i]; out_re[n] = sre[i] }
            }
        }

        # Emit output
        for (i = 1; i <= n; i++) {
            text = out_pt[i]; sec_text = out_st[i]
            gsub(SEP, "\n", text)
            gsub(SEP, "\n", sec_text)

            if (swap == "true") { top = sec_text; bot = text }
            else                { top = text; bot = sec_text }

            if (top != "" && bot != "")
                printf "%d\n%s --> %s\n%s\n<i>%s</i>\n\n", i, out_rs[i], out_re[i], top, bot
            else if (top != "")
                printf "%d\n%s --> %s\n%s\n\n", i, out_rs[i], out_re[i], top
            else if (bot != "")
                printf "%d\n%s --> %s\n<i>%s</i>\n\n", i, out_rs[i], out_re[i], bot
        }
    }
    ' "$tmp_pri" "$tmp_sec" > "$output"

    local count
    count=$(grep -c '^[0-9]\+$' "$output" 2>/dev/null || echo 0)
    info "$count subtitles mixed"
    rm -f "$tmp_pri" "$tmp_sec"
}

# Helper: normalize SRT for stable block-by-block operations after ffsubsync/translation.
# Fixes BOM/index glitches and removes structurally empty blocks that can shift bilingual mix.
# Pure awk implementation (no python dependency) — uses paragraph mode (RS="") to read blocks.
_normalize_srt_for_mix() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    local tmp="$CACHE_DIR/_mix_norm_$$.srt"
    mkdir -p "$CACHE_DIR"

    # Detect encoding and convert to UTF-8 (mirrors cmd_fix). Without this step
    # BSD awk crashes on Latin-1 bytes under a UTF-8 locale ("towc: multibyte
    # conversion failure") and bilingual mix downstream sees corrupted text.
    local _enc
    _enc=$(file --mime-encoding "$file" 2>/dev/null | awk -F': ' '{print $2}')
    [[ -z "$_enc" || "$_enc" == "binary" ]] && _enc="utf-8"

    # tr strips CR (CRLF endings); sed empties whitespace-only lines so awk's
    # paragraph mode recognises them as block separators (otherwise a stray
    # "   \n" between blocks would mash every following block into the body of
    # the first one, silently destroying the bilingual mix); LC_ALL=C keeps awk
    # in byte mode so multibyte sequences pass through intact.
    iconv -f "$_enc" -t utf-8 "$file" 2>/dev/null \
        | LC_ALL=C tr -d '\r' \
        | LC_ALL=C sed 's/^[[:space:]]*$//' \
        | LC_ALL=C awk -v BOM=$'\xef\xbb\xbf' '
        BEGIN { RS=""; FS="\n"; idx=1 }
        NR==1 { if (substr($1, 1, 3) == BOM) $1 = substr($1, 4) }
        {
            start = 1
            while (start <= NF && $start ~ /^[[:space:]]*$/) start++
            if (start > NF) next
            numchk = $start
            sub(/^[[:space:]]+/, "", numchk)
            sub(/[[:space:]]+$/, "", numchk)
            if (numchk ~ /^[0-9]+$/) start++
            while (start <= NF && $start ~ /^[[:space:]]*$/) start++
            if (start > NF) next
            ts = $start
            sub(/^[[:space:]]+/, "", ts)
            sub(/[[:space:]]+$/, "", ts)
            if (ts !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9][,.][0-9][0-9][0-9][[:space:]]+-->[[:space:]]+[0-9][0-9]:[0-9][0-9]:[0-9][0-9][,.][0-9][0-9][0-9]$/) next
            body = ""; has = 0
            for (i = start + 1; i <= NF; i++) {
                line = $i
                sub(/[[:space:]]+$/, "", line)
                if (line ~ /^[[:space:]]*$/) continue
                if (has) body = body "\n" line
                else { body = line; has = 1 }
            }
            if (!has) next
            printf "%d\n%s\n%s\n\n", idx, ts, body
            idx++
        }
    ' > "$tmp"

    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$file"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# ── Command: mix (dual-language subtitles for language learning) ──────────────
cmd_mix() {
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool mix movie.de.srt --mix-with movie.fr.srt or subtool mix movie.de.srt -l fr)"
    [[ -z "$MIX_FILE" && -z "$LANG_TARGET" ]] && die "Specify --mix-with <file.srt> or -l <lang> to translate + mix"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"
    [[ -n "$MIX_FILE" && ! -f "$MIX_FILE" ]] && die "File not found: $MIX_FILE"

    local primary="$FILE_PATH"
    local secondary="$MIX_FILE"

    # ── Mode: -l <lang> → translate first, then mix ──
    if [[ -z "$secondary" && -n "$LANG_TARGET" ]]; then
        # Detect source language from filename or content
        local src_lang="${SRC_LANG:-}"
        if [[ -z "$src_lang" ]]; then
            local fname_lang
            fname_lang=$(basename "$FILE_PATH" .srt)
            fname_lang="${fname_lang##*.}"
            if [[ ${#fname_lang} -le 3 && "$fname_lang" != "$(basename "$FILE_PATH" .srt)" ]]; then
                src_lang="$fname_lang"
            fi
        fi
        if [[ -z "$src_lang" ]]; then
            local sample
            sample=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$FILE_PATH" | head -20 | tr '\n' ' ' || true)
            src_lang=$(detect_lang "$sample")
            [[ -z "$src_lang" ]] && src_lang="en"
            info "Source language detected: $src_lang"
        fi
        [[ "$src_lang" == "$LANG_TARGET" ]] && die "Source and target language are the same ($src_lang)"

        # Translate to target language
        local bname
        bname=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
        local translated_srt="${OUTPUT_DIR}/${bname}.${LANG_TARGET}.srt"
        translate_subtitle "$FILE_PATH" "$translated_srt" "$src_lang" "$LANG_TARGET" "$AI_PROVIDER"
        [[ ! -s "$translated_srt" ]] && die "Translation failed"
        secondary="$translated_srt"
    fi

    # Detect languages from filenames (name.XX.srt -> XX)
    local lang1 lang2
    lang1=$(basename "$primary" .srt)
    lang1="${lang1##*.}"
    [[ ${#lang1} -gt 3 ]] && lang1=""
    lang2=$(basename "$secondary" .srt)
    lang2="${lang2##*.}"
    [[ ${#lang2} -gt 3 ]] && lang2=""

    # Fallback: detect from content
    if [[ -z "$lang1" ]]; then
        local sample1
        sample1=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$primary" | head -20 | tr '\n' ' ' || true)
        lang1=$(detect_lang "$sample1")
        [[ -z "$lang1" ]] && lang1="top"
    fi
    if [[ -z "$lang2" ]]; then
        local sample2
        sample2=$(grep -vE '^[0-9]+$|^$|^[0-9]{2}:' "$secondary" | head -20 | tr '\n' ' ' || true)
        lang2=$(detect_lang "$sample2")
        [[ -z "$lang2" ]] && lang2="bottom"
    fi

    # Output: strip lang extension from base, add dual lang code
    local base_name
    base_name=$(basename "$primary" .srt)
    # Strip existing lang code if present
    local stripped="$base_name"
    local last_part="${base_name##*.}"
    if [[ ${#last_part} -le 3 && "$last_part" != "$base_name" ]]; then
        stripped="${base_name%.*}"
    fi
    local output="${OUTPUT_DIR}/${stripped}.mix.srt"

    header "Mix subtitles (language learning)"

    # Default order: --mix-with → primary on top; -l → translated on top. --swap reverses.
    # Note: in _mix_subtitles, swap=false → primary text on top; primary's timestamps
    # always drive the output. Primary = user's first positional file = the "base".
    local do_swap=false
    [[ -n "$LANG_TARGET" ]] && do_swap=true
    [[ "$SWAP_MIX" == "true" ]] && { [[ "$do_swap" == "true" ]] && do_swap=false || do_swap=true; }

    if [[ "$do_swap" == "true" ]]; then
        info "Top (normal):  $(basename "$secondary") [$lang2]"
        info "Bottom (italic): $(basename "$primary") [$lang1]"
    else
        info "Top (normal):  $(basename "$primary") [$lang1]"
        info "Bottom (italic): $(basename "$secondary") [$lang2]"
    fi

    # In --mix-with mode, sync secondary's timing to the user's base file via
    # ffsubsync (subtitle-to-subtitle) on a temp copy. This keeps the bottom
    # text aligned with the top when the two inputs come from different cuts.
    # In -l mode, translation preserves timestamps — sync is unnecessary.
    local sec_for_mix="$secondary"
    local sec_tmp=""
    if [[ -n "$MIX_FILE" ]]; then
        local ffsubsync_cmd=()
        if command -v ffsubsync &>/dev/null; then
            ffsubsync_cmd=(ffsubsync)
        elif command -v uvx &>/dev/null; then
            ffsubsync_cmd=(uvx --with "setuptools<75" ffsubsync)
        fi
        if [[ ${#ffsubsync_cmd[@]} -gt 0 ]]; then
            mkdir -p "$CACHE_DIR"
            sec_tmp="$CACHE_DIR/_mix_sec_synced_$$.srt"
            info "Sync: aligning $(basename "$secondary") to $(basename "$primary")"
            if "${ffsubsync_cmd[@]}" "$primary" -i "$secondary" -o "$sec_tmp" >&2 2>&1 && [[ -s "$sec_tmp" ]]; then
                sec_for_mix="$sec_tmp"
                log "Sync OK: secondary aligned to primary"
            else
                rm -f "$sec_tmp"
                sec_tmp=""
                warn "Sync failed — mixing with original timing"
            fi
        fi
    fi

    # Choose match mode: block-by-index when counts match, timestamp-overlap when
    # they don't. ffsubsync's resync above (or independent sources) can drop blocks
    # asymmetrically — block-by-index would then misalign every block past the gap.
    local _p_blocks _s_blocks _mx_mode="block"
    _p_blocks=$(_count_srt_blocks "$primary")
    _s_blocks=$(_count_srt_blocks "$sec_for_mix")
    if [[ "$_p_blocks" -eq 0 || "$_s_blocks" -eq 0 || "$_p_blocks" -ne "$_s_blocks" ]]; then
        _mx_mode="timestamp"
        debug "cmd_mix: block counts differ ($_p_blocks vs $_s_blocks) — timestamp mode" || true
    fi

    # Primary as primary arg — primary's timestamps drive the output.
    _mix_subtitles "$primary" "$sec_for_mix" "$output" "$do_swap" "$_mx_mode"

    [[ -n "$sec_tmp" && -f "$sec_tmp" ]] && rm -f "$sec_tmp"

    log "Mixed file: $output"
}

# ── Command: text (export plain text) ─────────────────────────────────────────
cmd_text() {
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool $COMMAND file.srt)"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"

    # Extract text lines only: skip indices, timestamps, and blank lines
    sed '1s/^\xef\xbb\xbf//' "$FILE_PATH" | tr -d '\r' | awk '
    /^[[:space:]]*[0-9]+[[:space:]]*$/ { next }
    /^[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> / { next }
    /^[[:space:]]*$/ { next }
    { print }
    '
}

# ── Command: diff (compare two SRTs) ─────────────────────────────────────────
cmd_diff() {
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool diff file1.srt --diff-with file2.srt)"
    [[ -z "$DIFF_FILE" ]] && die "Specify --diff-with <second_file.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"
    [[ ! -f "$DIFF_FILE" ]] && die "File not found: $DIFF_FILE"

    header "Diff: $(basename "$FILE_PATH") vs $(basename "$DIFF_FILE")"

    # Parse SRT blocks into "INDEX|TIMESTAMP|TEXT" lines
    _diff_parse_srt() {
        sed '1s/^\xef\xbb\xbf//' "$1" | tr -d '\r' | awk '
        BEGIN { ts = ""; txt = ""; idx = 0 }
        function flush() {
            if (ts == "" || txt == "") { ts = ""; txt = ""; return }
            idx++
            printf "%d|%s|%s\n", idx, ts, txt
            ts = ""; txt = ""
        }
        /^[[:space:]]*[0-9]+[[:space:]]*$/ && ts == "" { next }
        /^[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}/ {
            flush(); ts = $0; next
        }
        /^[[:space:]]*$/ { flush(); next }
        { if (txt != "") txt = txt " // "; txt = txt $0 }
        END { flush() }
        '
    }

    local tmp_a="$CACHE_DIR/_diff_a_$$.txt"
    local tmp_b="$CACHE_DIR/_diff_b_$$.txt"
    mkdir -p "$CACHE_DIR"

    _diff_parse_srt "$FILE_PATH" > "$tmp_a"
    _diff_parse_srt "$DIFF_FILE" > "$tmp_b"

    local count_a count_b
    count_a=$(wc -l < "$tmp_a" | tr -d ' ')
    count_b=$(wc -l < "$tmp_b" | tr -d ' ')
    local max_count=$count_a
    [[ $count_b -gt $max_count ]] && max_count=$count_b

    info "$(basename "$FILE_PATH"): $count_a blocks | $(basename "$DIFF_FILE"): $count_b blocks"

    local diffs=0
    local i=1
    while [[ $i -le $max_count ]]; do
        local line_a line_b
        line_a=$(sed -n "${i}p" "$tmp_a" 2>/dev/null || echo "")
        line_b=$(sed -n "${i}p" "$tmp_b" 2>/dev/null || echo "")

        local ts_a text_a ts_b text_b
        ts_a=$(echo "$line_a" | cut -d'|' -f2)
        text_a=$(echo "$line_a" | cut -d'|' -f3-)
        ts_b=$(echo "$line_b" | cut -d'|' -f2)
        text_b=$(echo "$line_b" | cut -d'|' -f3-)

        if [[ "$text_a" != "$text_b" ]]; then
            ((diffs++)) || true
            printf "${BOLD}#%d${NC} ${CYAN}%s${NC}\n" "$i" "${ts_a:-$ts_b}" >&2
            if [[ -n "$text_a" ]]; then
                printf "  ${RED}< %s${NC}\n" "$text_a" >&2
            else
                printf "  ${RED}< (missing)${NC}\n" >&2
            fi
            if [[ -n "$text_b" ]]; then
                printf "  ${GREEN}> %s${NC}\n" "$text_b" >&2
            else
                printf "  ${GREEN}> (missing)${NC}\n" >&2
            fi
        fi
        ((i++)) || true
    done

    rm -f "$tmp_a" "$tmp_b"

    if [[ $diffs -eq 0 ]]; then
        log "Files are identical ($count_a blocks)"
    else
        info "$diffs/$max_count blocks differ"
    fi
}

# ── Command: fix (SRT repair) ────────────────────────────────────────────────
cmd_fix() {
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool $COMMAND file.srt)"
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
EXTRACT_ALL=false

cmd_extract() {
    [[ -z "$FILE_PATH" ]] && die "Specify a video file (e.g., subtool $COMMAND video.mkv)"
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

    # Auto-detect language for streams tagged "und"
    local detected_langs=()
    for ((idx=0; idx<count; idx++)); do
        local raw_lang
        raw_lang=$(echo "$streams" | jq -r ".streams[$idx].tags.language // \"und\"")
        if [[ "$raw_lang" == "und" || -z "$raw_lang" ]]; then
            raw_lang=$(_detect_stream_lang "$FILE_PATH" "$idx")
        fi
        detected_langs+=("$raw_lang")
    done

    info "$count subtitle track(s) found:"
    for ((idx=0; idx<count; idx++)); do
        local lang title codec
        lang="${detected_langs[$idx]}"
        title=$(echo "$streams" | jq -r ".streams[$idx].tags.title // \"\"")
        codec=$(echo "$streams" | jq -r ".streams[$idx].codec_name // \"?\"")
        local display="$title"
        [[ -z "$display" ]] && display=$(_lang_title "$lang")
        printf "  ${BOLD}%2d${NC}) [${CYAN}%s${NC}] %s (%s)\n" "$idx" "$lang" "$display" "$codec" >&2
    done

    # Determine which tracks to extract
    local tracks=()
    if $EXTRACT_ALL; then
        for ((idx=0; idx<count; idx++)); do tracks+=("$idx"); done
    elif [[ -n "$EXTRACT_TRACK" ]]; then
        tracks=("$EXTRACT_TRACK")
    elif [[ "$count" -eq 1 ]]; then
        tracks=(0)
    else
        printf "\n" >&2
        read -rp "$(printf "${BOLD}Track to extract (0-$((count-1)), or 'all'):${NC} ")" track_input
        if [[ "$track_input" == "all" || "$track_input" == "a" ]]; then
            for ((idx=0; idx<count; idx++)); do tracks+=("$idx"); done
        else
            [[ -z "$track_input" ]] && track_input=0
            tracks=("$track_input")
        fi
    fi

    local extracted=0
    for track in "${tracks[@]}"; do
        local lang codec ext
        lang="${detected_langs[$track]}"
        codec=$(echo "$streams" | jq -r ".streams[$track].codec_name // \"srt\"")

        case "$codec" in
            subrip|srt)  ext="srt" ;;
            ass|ssa)     ext="ass" ;;
            webvtt)      ext="vtt" ;;
            hdmv_pgs_subtitle|dvd_subtitle)
                warn "Track $track: Bitmap subtitles ($codec) - extracting as .sup"
                ext="sup" ;;
            *)           ext="srt" ;;
        esac

        # Detect duplicate languages to append track index for disambiguation
        local lang_count=0
        for ((j=0; j<count; j++)); do
            local jlang="${detected_langs[$j]}"
            [[ "$jlang" == "$lang" ]] && ((lang_count++)) || true
        done

        local output
        if [[ "$lang_count" -gt 1 ]]; then
            output="${OUTPUT_DIR}/${base_name}.${lang}.${track}.${ext}"
        else
            output="${OUTPUT_DIR}/${base_name}.${lang}.${ext}"
        fi

        ffmpeg -v quiet -i "$FILE_PATH" -map "0:s:${track}" -c:s "$([[ "$ext" == "srt" ]] && echo "srt" || echo "copy")" "$output" -y 2>/dev/null

        if [[ -s "$output" ]]; then
            log "Extracted track $track: $output"
            ((extracted++)) || true
        else
            warn "Track $track: extraction failed"
        fi
    done

    if [[ "$extracted" -eq 0 ]]; then
        err "No tracks extracted"
        return 1
    fi
}

# ── Command: embed (embed subtitles in video) ────────────────────────────────
cmd_embed() {
    [[ -z "$FILE_PATH" ]] && die "Specify a video file (e.g., subtool $COMMAND video.mkv)"
    [[ -z "$EMBED_SUB" ]] && die "Specify --sub <file.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "Video not found: $FILE_PATH"
    [[ ! -f "$EMBED_SUB" ]] && die "Subtitle not found: $EMBED_SUB"

    if ! validate_srt "$EMBED_SUB"; then
        warn "Invalid SRT format: $EMBED_SUB — run 'subtool fix $EMBED_SUB' first"
    fi

    if ! command -v ffmpeg &>/dev/null; then
        die "ffmpeg required. Install it: brew install ffmpeg"
    fi

    local base_name ext output
    base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
    ext="${FILE_PATH##*.}"
    output="${OUTPUT_DIR}/${base_name}.subbed.${ext}"

    local sub_lang="${LANG_TARGET:-und}"

    # MP4/M4V need mov_text codec, MKV/others use srt
    local sub_codec="srt"
    case "$ext" in
        mp4|m4v|mov) sub_codec="mov_text" ;;
    esac

    header "Embed subtitles"
    info "Video: $(basename "$FILE_PATH")"
    info "Subtitle: $(basename "$EMBED_SUB") ($sub_lang)"

    # Get existing subtitle stream info
    local streams_json
    streams_json=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$FILE_PATH" 2>/dev/null)
    local sub_count
    sub_count=$(echo "$streams_json" | jq '.streams | length' 2>/dev/null || echo "0")

    local sub_title sub_lang_iso
    sub_title=$(_lang_title "$sub_lang")
    # MP4/mov_text silently drops 2-letter ISO 639-1 codes — always emit 3-letter.
    sub_lang_iso=$(_lang_to_iso639_2 "$sub_lang")

    # Build ffmpeg command with proper mapping and metadata for ALL subtitle streams
    local ffmpeg_cmd=(ffmpeg -v quiet -i "$FILE_PATH" -i "$EMBED_SUB"
        -map 0 -map 1:0 -c copy -c:s:"$sub_count" "$sub_codec")

    # Preserve/fix metadata for existing subtitle streams
    local sidx
    for ((sidx=0; sidx<sub_count; sidx++)); do
        local s_lang s_title s_lang_iso
        s_lang=$(echo "$streams_json" | jq -r ".streams[$sidx].tags.language // \"und\"")
        s_title=$(echo "$streams_json" | jq -r ".streams[$sidx].tags.title // \"\"")
        # Auto-detect language if undefined
        if [[ "$s_lang" == "und" || -z "$s_lang" ]]; then
            s_lang=$(_detect_stream_lang "$FILE_PATH" "$sidx")
        fi
        [[ -z "$s_title" ]] && s_title=$(_lang_title "$s_lang")
        s_lang_iso=$(_lang_to_iso639_2 "$s_lang")
        ffmpeg_cmd+=(-metadata:s:s:"$sidx" language="$s_lang_iso" -metadata:s:s:"$sidx" title="$s_title")
    done

    # Set metadata for the new subtitle stream
    ffmpeg_cmd+=(-metadata:s:s:"$sub_count" language="$sub_lang_iso" -metadata:s:s:"$sub_count" title="$sub_title")
    ffmpeg_cmd+=("$output" -y)

    if "${ffmpeg_cmd[@]}" 2>/dev/null && [[ -s "$output" ]]; then
        log "Video with subtitles: $output"
    else
        err "Embedding failed"
        return 1
    fi
}

# ── Command: strip (remove subtitle tracks from video) ───────────────────────
cmd_strip() {
    [[ -z "$FILE_PATH" ]] && die "Specify a video file (e.g., subtool $COMMAND video.mkv)"
    [[ ! -f "$FILE_PATH" ]] && die "Video not found: $FILE_PATH"

    if ! command -v ffmpeg &>/dev/null || ! command -v ffprobe &>/dev/null; then
        die "ffmpeg/ffprobe required. Install: brew install ffmpeg"
    fi

    # Verify it's a video file (has video or audio streams)
    local va_count
    va_count=$(ffprobe -v quiet -print_format json -show_streams -select_streams V "$FILE_PATH" 2>/dev/null | jq '.streams | length' 2>/dev/null || echo "0")
    [[ "$va_count" == "0" ]] && die "Not a video file: $(basename "$FILE_PATH")"

    # Check existing subtitle streams
    local streams_json sub_count
    streams_json=$(ffprobe -v quiet -print_format json -show_streams -select_streams s "$FILE_PATH" 2>/dev/null)
    sub_count=$(echo "$streams_json" | jq '.streams | length' 2>/dev/null || echo "0")

    if [[ "$sub_count" == "0" || -z "$sub_count" ]]; then
        info "No subtitle tracks found in $(basename "$FILE_PATH")"
        return 0
    fi

    header "Strip subtitles"
    info "Video: $(basename "$FILE_PATH")"
    info "Removing $sub_count subtitle track(s):"

    local sidx
    for ((sidx=0; sidx<sub_count; sidx++)); do
        local s_lang s_title s_codec
        s_lang=$(echo "$streams_json" | jq -r ".streams[$sidx].tags.language // \"und\"")
        s_title=$(echo "$streams_json" | jq -r ".streams[$sidx].tags.title // \"\"")
        s_codec=$(echo "$streams_json" | jq -r ".streams[$sidx].codec_name // \"?\"")
        local display="$s_title"
        [[ -z "$display" ]] && display=$(_lang_title "$s_lang")
        printf "  ${BOLD}%2d${NC}) [${CYAN}%s${NC}] %s (%s)\n" "$sidx" "$s_lang" "$display" "$s_codec" >&2
    done

    local ext="${FILE_PATH##*.}"

    if $KEEP_FILES; then
        # --keep-files: write to .clean.ext alongside original
        local base_name
        base_name=$(basename "$FILE_PATH" | sed 's/\.[^.]*$//')
        local output="${OUTPUT_DIR}/${base_name}.clean.${ext}"
        if ffmpeg -v quiet -i "$FILE_PATH" -map 0 -map -0:s -c copy "$output" -y 2>/dev/null && [[ -s "$output" ]]; then
            log "Cleaned video: $output (original kept)"
        else
            err "Strip failed"
            return 1
        fi
    else
        # Default: replace original file in-place
        local tmp_output="${FILE_PATH%.${ext}}.strip_tmp.${ext}"
        if ffmpeg -v quiet -i "$FILE_PATH" -map 0 -map -0:s -c copy "$tmp_output" -y 2>/dev/null && [[ -s "$tmp_output" ]]; then
            mv "$tmp_output" "$FILE_PATH"
            log "Stripped subtitles: $(basename "$FILE_PATH")"
        else
            rm -f "$tmp_output"
            err "Strip failed"
            return 1
        fi
    fi
}

# ── Command: autosync (ffsubsync - auto sync with video/audio) ───────────────
AUTOSYNC_REF=""
AUTOSYNC_REF_STREAM=""

cmd_autosync() {
    [[ -z "$FILE_PATH" ]] && die "Specify a file (e.g., subtool $COMMAND file.srt)"
    [[ -z "$AUTOSYNC_REF" ]] && die "Specify --ref <video.mkv or reference.srt>"
    [[ ! -f "$FILE_PATH" ]] && die "File not found: $FILE_PATH"
    [[ ! -f "$AUTOSYNC_REF" ]] && die "Reference not found: $AUTOSYNC_REF"

    # Determine ffsubsync command
    local ffsubsync_cmd=()
    if command -v ffsubsync &>/dev/null; then
        ffsubsync_cmd=(ffsubsync)
    elif command -v uvx &>/dev/null; then
        ffsubsync_cmd=(uvx --with "setuptools<75" ffsubsync)
        info "Using uvx ffsubsync (no local install)"
    else
        die "ffsubsync not available. Install it: uvx ffsubsync (or: uv tool install ffsubsync)"
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
    local sync_ref="$AUTOSYNC_REF"
    local ref_tmp=""

    # If reference is SRT/ASS, use subtitle-to-subtitle mode directly
    case "$ref_ext" in
        srt|ass|ssa|vtt|sub)
            info "Mode: subtitle <-> subtitle"
            ;;
        *)
            info "Mode: video <-> subtitle"
            # Auto-detect reference from -l/--lang if --ref-stream not set
            # Prefer extracting embedded subtitle (accurate), fall back to audio (VAD)
            if [[ -z "$AUTOSYNC_REF_STREAM" && -n "$LANG_TARGET" ]]; then
                if ref_tmp=$(_extract_ref_subtitle "$AUTOSYNC_REF" "$LANG_TARGET"); then
                    sync_ref="$ref_tmp"
                    info "Extracted embedded subtitle ($LANG_TARGET) as reference"
                else
                    local stream_ref
                    if stream_ref=$(_find_audio_stream "$AUTOSYNC_REF" "$LANG_TARGET"); then
                        AUTOSYNC_REF_STREAM="$stream_ref"
                        info "Auto-detected audio track: $stream_ref ($LANG_TARGET)"
                    fi
                fi
            fi
            # Add --reference-stream if specified (manual or audio fallback)
            if [[ -n "$AUTOSYNC_REF_STREAM" ]]; then
                ffsubsync_args+=(--reference-stream "$AUTOSYNC_REF_STREAM")
                info "Reference stream: $AUTOSYNC_REF_STREAM"
            fi
            ;;
    esac

    ffsubsync_args+=("$sync_ref")
    ffsubsync_args+=(-i "$FILE_PATH")
    ffsubsync_args+=(-o "$output")

    if "${ffsubsync_cmd[@]}" "${ffsubsync_args[@]}" >&2; then
        log "Auto sync: $output"
    else
        err "ffsubsync failed"
        [[ -n "$ref_tmp" ]] && rm -f "$ref_tmp"
        return 1
    fi
    [[ -n "$ref_tmp" ]] && rm -f "$ref_tmp" || true
}

# ── Command: completions (generate shell completions) ─────────────────────────
COMPLETIONS_SHELL=""

cmd_completions() {
    local shell="${COMPLETIONS_SHELL:-bash}"
    local commands="auto transcribe get search batch translate info clean sync autosync convert merge mix fix extract embed strip text diff config check providers sources completions manpage"
    local opts="-q --query -l --lang -i --imdb -s --season -e --episode -o --output -p --provider -m --model --sources --from --fallback-langs --max-ep --shift --sync-shift --to --merge-with --mix-with --diff-with --playlist --ref --ref-stream --sub --track --all --url --embed --no-embed --force-embed --strip-existing --force-translate --transcribe-provider --whisper-model --chunk-size --max-tokens --no-transcribe --force-transcribe --claude-effort --skip-steps --max-parallel --resume --keep-files --mix --mix-translate --swap --auto --dry-run --json --verbose --quiet -h --help -v --version"

    case "$shell" in
        bash)
            cat <<BASH_EOF
# subtool bash completions — add to ~/.bashrc:
#   eval "\$(subtool completions bash)" OR source <(subtool completions bash)
_subtool() {
    local cur prev commands opts
    COMPREPLY=()
    cur="\${COMP_WORDS[COMP_CWORD]}"
    prev="\${COMP_WORDS[COMP_CWORD-1]}"
    commands="$commands"
    opts="$opts"

    case "\$prev" in
        -p|--provider)  COMPREPLY=(\$(compgen -W "google claude-code openai claude mistral gemini zai-codeplan" -- "\$cur")); return ;;
        --to)           COMPREPLY=(\$(compgen -W "srt vtt ass" -- "\$cur")); return ;;
        --sources)      COMPREPLY=(\$(compgen -W "opensubtitles-org podnapisi" -- "\$cur")); return ;;
        --transcribe-provider) COMPREPLY=(\$(compgen -W "whisper openai-api" -- "\$cur")); return ;;
        --whisper-model) COMPREPLY=(\$(compgen -W "tiny base small medium large" -- "\$cur")); return ;;
        --claude-effort) COMPREPLY=(\$(compgen -W "low medium high" -- "\$cur")); return ;;
        --skip-steps)   COMPREPLY=(\$(compgen -W "download translate sync mix embed" -- "\$cur")); return ;;
        completions)    COMPREPLY=(\$(compgen -W "bash zsh fish" -- "\$cur")); return ;;
        -o|--output|-q|--query|-l|--lang|-i|--imdb|-s|--season|-e|--episode|-m|--model|--shift|--sync-shift|--chunk-size|--max-tokens|--max-parallel|--max-ep|--fallback-langs)
            return ;;
        --sub|--ref|--merge-with|--mix-with|--diff-with|--playlist)
            COMPREPLY=(\$(compgen -f -- "\$cur")); return ;;
    esac

    if [[ "\$cur" == -* ]]; then
        COMPREPLY=(\$(compgen -W "\$opts" -- "\$cur"))
    elif [[ \$COMP_CWORD -eq 1 ]]; then
        COMPREPLY=(\$(compgen -W "\$commands" -- "\$cur"))
    else
        COMPREPLY=(\$(compgen -f -- "\$cur"))
    fi
}
complete -F _subtool subtool
BASH_EOF
            ;;
        zsh)
            cat <<ZSH_EOF
# subtool zsh completions — add to ~/.zshrc:
#   eval "\$(subtool completions zsh)" OR source <(subtool completions zsh)
#compdef subtool

_subtool() {
    local -a commands=(
        'auto:All-in-one\: download + translate + embed'
        'transcribe:Generate subtitles from video audio'
        'get:Smart search (auto-parse title/season/episode)'
        'search:Manual search'
        'batch:Download a full season'
        'translate:Translate a local subtitle file'
        'info:Display SRT file info'
        'clean:Clean an SRT (ads, HI/SDH, HTML)'
        'sync:Shift timecodes'
        'autosync:Auto sync with video via ffsubsync'
        'convert:Convert between formats'
        'merge:Merge 2 subtitles into bilingual'
        'mix:Mix 2 subtitles for language learning'
        'fix:Repair an SRT'
        'extract:Extract subtitles from video'
        'embed:Embed an SRT into video'
        'strip:Remove all subtitle tracks from video'
        'text:Export plain text from subtitle'
        'diff:Compare two subtitle files'
        'config:Display/edit configuration'
        'check:Diagnostic'
        'providers:List AI providers'
        'sources:List subtitle sources'
        'completions:Generate shell completions'
        'manpage:Generate man page'
    )

    _arguments -C \\
        '1:command:->cmds' \\
        '*::arg:->args' && return

    case "\$state" in
        cmds) _describe 'command' commands ;;
        args)
            case "\$words[1]" in
                auto|get|search|batch|translate|transcribe|info|clean|sync|autosync|convert|merge|mix|fix|extract|embed|text|diff)
                    _arguments \\
                        '-q[Search query]:query:' \\
                        '--query[Search query]:query:' \\
                        '-l[Target language]:lang:' \\
                        '--lang[Target language]:lang:' \\
                        '-i[IMDb ID]:imdb:' \\
                        '--imdb[IMDb ID]:imdb:' \\
                        '-s[Season]:season:' \\
                        '--season[Season]:season:' \\
                        '-e[Episode]:episode:' \\
                        '--episode[Episode]:episode:' \\
                        '-o[Output directory]:dir:_files -/' \\
                        '--output[Output directory]:dir:_files -/' \\
                        '-p[Translation provider]:provider:(google claude-code openai claude mistral gemini zai-codeplan)' \\
                        '--provider[Translation provider]:provider:(google claude-code openai claude mistral gemini zai-codeplan)' \\
                        '-m[AI model]:model:' \\
                        '--model[AI model]:model:' \\
                        '--sources[Subtitle sources]:sources:(opensubtitles-org podnapisi)' \\
                        '--from[Source language]:lang:' \\
                        '--to[Target format]:format:(srt vtt ass)' \\
                        '--shift[Shift in ms]:ms:' \\
                        '--sync-shift[Constant shift in ms applied after ffsubsync in auto]:ms:' \\
                        '--merge-with[Secondary file]:file:_files' \\
                        '--mix-with[Second file for mix]:file:_files' \\
                        '--mix[Enable dual-language mix in auto (optional lang)]' \\
                        '--mix-translate[Translate target subtitle for mix]' \\
                        '--swap[Swap mix display order]' \\
                        '--diff-with[File to diff]:file:_files' \\
                        '--playlist[Playlist file]:file:_files' \\
                        '--ref[Reference file]:file:_files' \\
                        '--sub[SRT file to embed]:file:_files' \\
                        '--track[Track number]:track:' \\
                        '--all[Extract all tracks]' \\
                        '--url[Subtitle URL]:url:' \\
                        '--embed[Enable embedding]' \\
                        '--no-embed[Disable embedding]' \\
                        '--force-embed[Force embed alongside existing]' \\
                        '--strip-existing[Strip existing subtitles before embed]' \\
                        '--force-translate[Force translation]' \\
                        '--transcribe-provider[Transcription provider]:provider:(whisper openai-api)' \\
                        '--whisper-model[Whisper model]:model:(tiny base small medium large)' \\
                        '--chunk-size[Chunk size]:size:' \\
                        '--max-tokens[Max tokens]:tokens:' \\
                        '--claude-effort[Claude effort]:effort:(low medium high)' \\
                        '--skip-steps[Skip steps]:steps:(download translate sync mix embed)' \\
                        '--max-parallel[Max parallel]:n:' \\
                        '--no-transcribe[Disable transcription]' \\
                        '--force-transcribe[Force transcription]' \\
                        '--resume[Resume batch from previous state]' \\
                        '--keep-files[Keep intermediate files]' \\
                        '--auto[Auto-select result]' \\
                        '--dry-run[Preview only]' \\
                        '--json[JSON output]' \\
                        '--verbose[Debug output]' \\
                        '--quiet[Silent mode]' \\
                        '*:file:_files' ;;
                completions) _arguments '1:shell:(bash zsh fish)' ;;
            esac ;;
    esac
}

_subtool "\$@"
ZSH_EOF
            ;;
        fish)
            cat <<FISH_EOF
# subtool fish completions — add to ~/.config/fish/completions/subtool.fish:
#   subtool completions fish > ~/.config/fish/completions/subtool.fish

# Commands
complete -c subtool -n __fish_use_subcommand -a auto -d 'All-in-one: download + translate + embed'
complete -c subtool -n __fish_use_subcommand -a transcribe -d 'Generate subtitles from video audio'
complete -c subtool -n __fish_use_subcommand -a get -d 'Smart search'
complete -c subtool -n __fish_use_subcommand -a search -d 'Manual search'
complete -c subtool -n __fish_use_subcommand -a batch -d 'Download a full season'
complete -c subtool -n __fish_use_subcommand -a translate -d 'Translate a subtitle file'
complete -c subtool -n __fish_use_subcommand -a info -d 'Display SRT info'
complete -c subtool -n __fish_use_subcommand -a clean -d 'Clean an SRT'
complete -c subtool -n __fish_use_subcommand -a sync -d 'Shift timecodes'
complete -c subtool -n __fish_use_subcommand -a autosync -d 'Auto sync with video'
complete -c subtool -n __fish_use_subcommand -a convert -d 'Convert between formats'
complete -c subtool -n __fish_use_subcommand -a merge -d 'Merge subtitles'
complete -c subtool -n __fish_use_subcommand -a mix -d 'Mix subtitles for language learning'
complete -c subtool -n __fish_use_subcommand -a fix -d 'Repair an SRT'
complete -c subtool -n __fish_use_subcommand -a extract -d 'Extract subtitles from video'
complete -c subtool -n __fish_use_subcommand -a embed -d 'Embed subtitles in video'
complete -c subtool -n __fish_use_subcommand -a strip -d 'Remove all subtitle tracks from video'
complete -c subtool -n __fish_use_subcommand -a text -d 'Export plain text'
complete -c subtool -n __fish_use_subcommand -a diff -d 'Compare two subtitles'
complete -c subtool -n __fish_use_subcommand -a config -d 'Display/edit config'
complete -c subtool -n __fish_use_subcommand -a check -d 'Diagnostic'
complete -c subtool -n __fish_use_subcommand -a providers -d 'List AI providers'
complete -c subtool -n __fish_use_subcommand -a sources -d 'List subtitle sources'
complete -c subtool -n __fish_use_subcommand -a completions -d 'Generate shell completions'
complete -c subtool -n __fish_use_subcommand -a manpage -d 'Generate man page'

# Options
complete -c subtool -s q -l query -d 'Search query' -x
complete -c subtool -s l -l lang -d 'Target language' -x
complete -c subtool -s i -l imdb -d 'IMDb ID' -x
complete -c subtool -s s -l season -d 'Season number' -x
complete -c subtool -s e -l episode -d 'Episode number' -x
complete -c subtool -s o -l output -d 'Output directory' -r -F
complete -c subtool -s p -l provider -d 'Translation provider' -x -a 'google claude-code openai claude mistral gemini zai-codeplan'
complete -c subtool -s m -l model -d 'AI model' -x
complete -c subtool -l sources -d 'Subtitle sources' -x -a 'opensubtitles-org podnapisi'
complete -c subtool -l from -d 'Source language' -x
complete -c subtool -l to -d 'Target format' -x -a 'srt vtt ass'
complete -c subtool -l shift -d 'Shift in ms' -x
complete -c subtool -l sync-shift -d 'Constant shift in ms applied after ffsubsync in auto' -x
complete -c subtool -l merge-with -d 'Secondary file' -r -F
complete -c subtool -l mix-with -d 'Second file for mix' -r -F
complete -c subtool -l mix -d 'Enable dual-language mix in auto (optional lang)'
complete -c subtool -l mix-translate -d 'Translate target subtitle for mix'
complete -c subtool -l swap -d 'Swap mix display order'
complete -c subtool -l diff-with -d 'File to diff' -r -F
complete -c subtool -l playlist -d 'Playlist file' -r -F
complete -c subtool -l ref -d 'Reference file' -r -F
complete -c subtool -l sub -d 'SRT file to embed' -r -F
complete -c subtool -l track -d 'Track number' -x
complete -c subtool -l all -d 'Extract all tracks'
complete -c subtool -l url -d 'Subtitle URL' -x
complete -c subtool -l embed -d 'Enable embedding'
complete -c subtool -l no-embed -d 'Disable embedding'
complete -c subtool -l force-embed -d 'Force embed alongside existing'
complete -c subtool -l strip-existing -d 'Strip existing subtitles before embed'
complete -c subtool -l force-translate -d 'Force translation'
complete -c subtool -l transcribe-provider -d 'Transcription provider' -x -a 'whisper openai-api'
complete -c subtool -l whisper-model -d 'Whisper model' -x -a 'tiny base small medium large'
complete -c subtool -l chunk-size -d 'Chunk size' -x
complete -c subtool -l max-tokens -d 'Max tokens' -x
complete -c subtool -l claude-effort -d 'Claude effort' -x -a 'low medium high'
complete -c subtool -l skip-steps -d 'Skip steps' -x -a 'download translate sync mix embed'
complete -c subtool -l max-parallel -d 'Max parallel' -x
complete -c subtool -l no-transcribe -d 'Disable transcription'
complete -c subtool -l force-transcribe -d 'Force transcription'
complete -c subtool -l resume -d 'Resume batch from previous state'
complete -c subtool -l keep-files -d 'Keep intermediate files'
complete -c subtool -l auto -d 'Auto-select result'
complete -c subtool -l dry-run -d 'Preview only'
complete -c subtool -l json -d 'JSON output'
complete -c subtool -l verbose -d 'Debug output'
complete -c subtool -l quiet -d 'Silent mode'
complete -c subtool -s h -l help -d 'Show help'
complete -c subtool -s v -l version -d 'Show version'
FISH_EOF
            ;;
        *)
            die "Unsupported shell: $shell (use bash, zsh, or fish)"
            ;;
    esac
}

# ── Command: manpage (generate man page) ──────────────────────────────────────
cmd_manpage() {
    cat <<'MANPAGE_HEADER'
.TH SUBTOOL 1 "2025" "subtool" "User Commands"
.SH NAME
subtool \- All-in-one subtitle CLI: download, translate, transcribe, convert, sync, clean, merge, fix, extract, embed
.SH SYNOPSIS
.B subtool
[\fIOPTIONS\fR] \fICOMMAND\fR [\fIFILE\fR|\fIDIRECTORY\fR]
.SH DESCRIPTION
\fBsubtool\fR is a comprehensive command-line tool for subtitle management.
It can download subtitles from multiple sources, translate them using AI providers,
transcribe audio to subtitles, and perform various subtitle operations.
MANPAGE_HEADER

    cat <<MANPAGE_COMMANDS
.SH COMMANDS
.TP
.B auto
All-in-one: download + translate + sync + embed (file, directory, or playlist)
.TP
.B transcribe
Generate subtitles from video audio (speech-to-text)
.TP
.B get
Smart search (auto-parse title/season/episode from query)
.TP
.B search
Manual search with explicit query/season/episode
.TP
.B batch
Download subtitles for a full season
.TP
.B translate
Translate a local subtitle file
.TP
.B info
Display SRT file info (encoding, language, stats)
.TP
.B clean
Clean an SRT (remove ads, HI/SDH tags, HTML)
.TP
.B sync
Shift timecodes (+/\- milliseconds)
.TP
.B autosync
Auto sync with video/audio via ffsubsync
.TP
.B convert
Convert between formats (SRT <-> VTT <-> ASS)
.TP
.B merge
Merge 2 subtitles into bilingual
.TP
.B mix
Mix 2 subtitles for language learning (dual-language)
.TP
.B fix
Repair an SRT (UTF-8 encoding, sorting, renumbering, overlaps)
.TP
.B extract
Extract subtitles from a video (MKV, MP4)
.TP
.B embed
Embed an SRT into a video
.TP
.B strip
Remove all subtitle tracks from a video
.TP
.B text
Export plain text from subtitle (no timestamps)
.TP
.B diff
Compare two subtitle files side by side
.TP
.B config
Display/edit configuration (config set <KEY> <VALUE>)
.TP
.B check
Diagnostic (dependencies, API keys, config)
.TP
.B providers
List available AI providers
.TP
.B sources
List subtitle sources
.TP
.B completions
Generate shell completions (bash, zsh, fish)
.TP
.B manpage
Generate this man page
MANPAGE_COMMANDS

    cat <<'MANPAGE_OPTIONS'
.SH OPTIONS
.TP
\fB\-q\fR, \fB\-\-query\fR \fItitle\fR
Title of movie/series to search
.TP
\fB\-l\fR, \fB\-\-lang\fR \fIcode\fR
Target language(s): fr, en, or comma-separated: en,fr
.TP
\fB\-i\fR, \fB\-\-imdb\fR \fIid\fR
IMDb ID (tt1234567)
.TP
\fB\-s\fR, \fB\-\-season\fR \fInum\fR
Season number
.TP
\fB\-e\fR, \fB\-\-episode\fR \fInum\fR
Episode number
.TP
\fB\-o\fR, \fB\-\-output\fR \fIdir\fR
Output directory (default: .)
.TP
\fB\-p\fR, \fB\-\-provider\fR \fIprovider\fR
Translation provider (google|claude-code|openai|claude|mistral|gemini|zai-codeplan)
.TP
\fB\-m\fR, \fB\-\-model\fR \fImodel\fR
AI model to use
.TP
\fB\-\-sources\fR \fIsrc1,src2\fR
Subtitle sources (default: opensubtitles-org)
.TP
\fB\-\-from\fR \fIlang\fR
Source language for translation
.TP
\fB\-\-to\fR \fIformat\fR
Target format for convert (srt, vtt, ass)
.TP
\fB\-\-shift\fR \fIms\fR
Shift in ms for sync (e.g., +1500, -800)
.TP
\fB\-\-sync\-shift\fR \fIms\fR
Constant shift in ms applied after ffsubsync in auto mode (e.g., -2000). Persist via AUTO_SYNC_SHIFT config key.
.TP
\fB\-\-merge\-with\fR \fIfile\fR
Secondary file for bilingual merge
.TP
\fB\-\-diff\-with\fR \fIfile\fR
Second file for subtitle diff comparison
.TP
\fB\-\-playlist\fR \fIfile\fR
Text file listing video paths (one per line) for batch auto
.TP
\fB\-\-ref\fR \fIvideo|srt\fR
Reference for autosync
.TP
\fB\-\-sub\fR \fIfile\fR
SRT file to embed in a video
.TP
\fB\-\-track\fR \fInum\fR
Track to extract
.TP
\fB\-\-all\fR
Extract all subtitle tracks
.TP
\fB\-\-url\fR \fIurl\fR
Download a subtitle from an opensubtitles.org URL
.TP
\fB\-\-embed\fR
Enable subtitle embedding
.TP
\fB\-\-no\-embed\fR
Disable automatic embedding
.TP
\fB\-\-force\-embed\fR
Force embed even if subtitles already present (adds new track)
.TP
\fB\-\-strip\-existing\fR
Strip all existing subtitle tracks before embedding new ones
.TP
\fB\-\-force\-translate\fR
Force translation even if subtitles found
.TP
\fB\-\-transcribe\-provider\fR \fIp\fR
Transcription provider (whisper|openai-api)
.TP
\fB\-\-whisper\-model\fR \fImodel\fR
Whisper model (tiny, base, small, medium, large)
.TP
\fB\-\-chunk\-size\fR \fIn\fR
Translation chunk size in lines
.TP
\fB\-\-max\-tokens\fR \fIn\fR
Max output tokens for LLM translation
.TP
\fB\-\-max\-parallel\fR \fIn\fR
Max parallel translation chunks
.TP
\fB\-\-no\-transcribe\fR
Disable transcription fallback in auto mode
.TP
\fB\-\-force\-transcribe\fR
Force transcription (skip subtitle download)
.TP
\fB\-\-skip\-steps\fR \fIsteps\fR
Skip steps in auto (comma-separated: download,translate,sync,mix,embed)
.TP
\fB\-\-mix\-with\fR \fIfile\fR
Second file for mix (dual-language subtitles)
.TP
\fB\-\-mix\fR
Enable dual-language mix in auto mode
.TP
\fB\-\-mix\-lang\fR \fIlang\fR
Learning language for mix top (implies \-\-mix)
.TP
\fB\-\-resume\fR
Resume batch from previous state (skip already-completed files)
.TP
\fB\-\-keep\-files\fR
Keep intermediate subtitle files
.TP
\fB\-\-auto\fR
Automatically select most downloaded result
.TP
\fB\-\-dry\-run\fR
Display results without downloading
.TP
\fB\-\-json\fR
JSON output
.TP
\fB\-\-verbose\fR
Display debug info
.TP
\fB\-\-quiet\fR
Silent mode (errors only)
MANPAGE_OPTIONS

    cat <<MANPAGE_FOOTER
.SH EXAMPLES
.nf
# Auto: download + translate + embed
subtool auto ~/Movies/Die.Discounter -l fr

# Smart get
subtool get -q "Die Discounter S01E03" -l de

# Export plain text
subtool text movie.srt

# Compare two subtitles
subtool diff original.srt translated.srt --diff-with translated.srt

# Batch from playlist
subtool auto --playlist videos.txt -l fr

# Transcribe
subtool transcribe movie.mkv --from en

# Install completions
eval "\\\$(subtool completions bash)"
subtool completions fish > ~/.config/fish/completions/subtool.fish
.fi
.SH FILES
.TP
\fI~/.config/subtool/config\fR
Configuration file (API keys, defaults)
.TP
\fI~/.cache/subtool/\fR
Cache directory (temporary files)
.SH ENVIRONMENT
.TP
\fBOPENAI_API_KEY\fR
OpenAI API key for translation/transcription
.TP
\fBANTHROPIC_API_KEY\fR
Anthropic API key for Claude translation
.TP
\fBMISTRAL_API_KEY\fR
Mistral API key
.TP
\fBGEMINI_API_KEY\fR
Google Gemini API key
.SH SEE ALSO
.BR ffmpeg (1),
.BR ffsubsync (1),
.BR trans (1)
.SH VERSION
$VERSION
.SH AUTHOR
maxgfr
MANPAGE_FOOTER
}

# ── Parse args ────────────────────────────────────────────────────────────────
SRC_LANG=""
COMMAND=""
EMBED_SUB=""
CONFIG_SUBCMD=""
CONFIG_KEY=""
CONFIG_VALUE=""

# shellcheck disable=SC2034
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            get|search|translate|transcribe|batch|scan|auto|info|clean|sync|autosync|convert|merge|mix|fix|extract|embed|strip|text|diff|providers|sources|check|manpage)
                COMMAND="$1"; shift ;;
            completions)
                COMMAND="completions"; shift
                if [[ $# -gt 0 && "$1" =~ ^(bash|zsh|fish)$ ]]; then
                    COMPLETIONS_SHELL="$1"; shift
                fi
                ;;
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
            -o|--output)   OUTPUT_DIR="$2"; shift 2 ;;
            -p|--provider) AI_PROVIDER="$2"; shift 2 ;;
            -m|--model)    AI_MODEL="$2"; shift 2 ;;
            --sources)     SOURCES="$2"; shift 2 ;;
            --from)        SRC_LANG="$2"; shift 2 ;;
            --fallback-langs) FALLBACK_LANGS="$2"; shift 2 ;;
            --max-ep)      MAX_EPISODE="$2"; shift 2 ;;
            --shift)       SYNC_SHIFT="$2"; shift 2 ;;
            --sync-shift)  AUTO_SYNC_SHIFT="$2"; shift 2 ;;
            --to)          CONVERT_FORMAT="$2"; shift 2 ;;
            --merge-with)  MERGE_FILE="$2"; shift 2 ;;
            --diff-with)   DIFF_FILE="$2"; shift 2 ;;
            --mix-with)    MIX_FILE="$2"; shift 2 ;;
            --mix)
                MIX_MODE=true
                # --mix [lang] — optional language code (2-3 chars, not a flag)
                if [[ -n "${2:-}" && "${2:0:1}" != "-" && ${#2} -le 3 ]]; then
                    MIX_LANG="$2"; shift 2
                else
                    shift
                fi
                ;;
            --mix-translate) MIX_TRANSLATE=true; MIX_MODE=true; shift ;;
            --swap)        SWAP_MIX=true; shift ;;
            --playlist)    PLAYLIST_FILE="$2"; shift 2 ;;
            --sub)         EMBED_SUB="$2"; shift 2 ;;
            --track)       EXTRACT_TRACK="$2"; shift 2 ;;
            --all)         EXTRACT_ALL=true; shift ;;
            --ref)         AUTOSYNC_REF="$2"; shift 2 ;;
            --ref-stream)  AUTOSYNC_REF_STREAM="$2"; shift 2 ;;
            --force-translate) FORCE_TRANSLATE=true; shift ;;
            --transcribe-provider) TRANSCRIBE_PROVIDER="$2"; shift 2 ;;
            --whisper-model) WHISPER_MODEL="$2"; shift 2 ;;
            --chunk-size) TRANSLATE_CHUNK_SIZE="$2"; shift 2 ;;
            --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
            --no-transcribe) NO_TRANSCRIBE=true; shift ;;
            --force-transcribe) FORCE_TRANSCRIBE=true; shift ;;
            --claude-effort) CLAUDE_EFFORT="$2"; shift 2 ;;
            --skip-steps) SKIP_STEPS="$2"; shift 2 ;;
            --max-parallel) TRANSLATE_MAX_PARALLEL="$2"; shift 2 ;;
            --resume) NO_RESUME=false; shift ;;
            --no-resume) shift ;;
            --keep-files)  KEEP_FILES=true; shift ;;
            --auto)        AUTO_SELECT=true; shift ;;
            --embed)       AUTO_EMBED=true; shift ;;
            --no-embed)    NO_EMBED=true; shift ;;
            --force-embed) FORCE_EMBED=true; AUTO_EMBED=true; shift ;;
            --strip-existing) STRIP_EXISTING=true; FORCE_EMBED=true; AUTO_EMBED=true; NO_RESUME=true; shift ;;
            --url)         SUBTITLE_URL="$2"; shift 2 ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --json)        JSON_OUTPUT=true; QUIET=true; shift ;;
            --verbose)     VERBOSE=true; shift ;;
            --quiet)       QUIET=true; shift ;;
            -h|--help)     usage; exit 0 ;;
            -v|--version)  echo "$VERSION"; exit 0 ;;
            *)
                # Positional argument: auto-detect file or directory
                if [[ -n "$COMMAND" && -z "$FILE_PATH" && -z "$SCAN_DIR" ]]; then
                    if [[ -d "$1" ]]; then
                        SCAN_DIR="$1"
                    else
                        FILE_PATH="$1"
                    fi
                    shift
                else
                    die "Unknown option: $1. Use --help"
                fi
                ;;
        esac
    done
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    # Kill child processes (background translation chunks, claude -p, etc.)
    pkill -P $$ 2>/dev/null || true
    local pids
    pids=$(jobs -p 2>/dev/null) || true
    [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
    wait 2>/dev/null || true
    # Remove temp files on exit
    rm -f "$CACHE_DIR"/chunk_*.srt 2>/dev/null || true
    rm -f "$CACHE_DIR"/text_chunk_$$_*.txt 2>/dev/null || true
    rm -f "$CACHE_DIR"/translate_*.txt 2>/dev/null || true
    rm -f "$CACHE_DIR"/claude_err_*.txt "$CACHE_DIR"/*.claude_err 2>/dev/null || true
    rm -f "$CACHE_DIR"/trans_chunk_$$_*.txt 2>/dev/null || true
    rm -f "$CACHE_DIR"/trans_text_$$.txt "$CACHE_DIR"/trans_map_$$.txt 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    load_config
    parse_args "$@"

    [[ -z "$COMMAND" ]] && { usage; exit 0; }

    mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    trap cleanup EXIT

    case "$COMMAND" in
        get)       cmd_get ;;
        search)    cmd_search ;;
        translate) cmd_translate ;;
        transcribe) cmd_transcribe ;;
        batch)     cmd_batch ;;
        scan)      cmd_scan ;;
        auto)      cmd_auto ;;
        info)      cmd_info ;;
        clean)     cmd_clean ;;
        sync)      cmd_sync ;;
        convert)   cmd_convert ;;
        merge)     cmd_merge ;;
        mix)       cmd_mix ;;
        fix)       cmd_fix ;;
        autosync)  cmd_autosync ;;
        extract)   cmd_extract ;;
        embed)     cmd_embed ;;
        strip)     cmd_strip ;;
        text)      cmd_text ;;
        diff)      cmd_diff ;;
        config)    cmd_config ;;
        check)     cmd_check ;;
        providers) cmd_providers ;;
        sources)   cmd_sources ;;
        completions) cmd_completions ;;
        manpage)   cmd_manpage ;;
        *)         die "Unknown command: $COMMAND" ;;
    esac
}

main "$@"
