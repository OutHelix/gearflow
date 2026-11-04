# shellcheck shell=bash
# SPDX-License-Identifier: MIT

TARGET_BRANCH="${TARGET_BRANCH:-sisyphus}"
GITERY_HOST="${GITERY_HOST:-gitery}"
GYLE_HOST="${GYLE_HOST:-gyle}"
RDB_API_URL="${RDB_API_URL:-https://rdb.altlinux.org/api}"
REBUILD_DEPTH="${REBUILD_DEPTH:-1}"
REBUILD_DPTYPE="${REBUILD_DPTYPE:-both}"
RELEASE="${RELEASE:-alt1}"
RECENT_TAGS="${RECENT_TAGS:-15}"
LAYOUT_COMMIT_MESSAGE="${LAYOUT_COMMIT_MESSAGE:-Moved packaging files to altlinux directory}"

# Abort an HTTP Git transfer if it stays below this speed for this long.
# Defaults: below 64 KiB/s for 60 seconds.
LOW_SPEED_LIMIT="${LOW_SPEED_LIMIT:-65536}"
LOW_SPEED_TIME="${LOW_SPEED_TIME:-60}"

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ask_yes_no() {
    local prompt="$1"
    local answer
    while true; do
        read -r -p "$prompt [y/N]: " answer
        case "${answer,,}" in
            y|yes|д|да) return 0 ;;
            ""|n|no|н|нет) return 1 ;;
            *) printf 'Please answer y or n.\n' ;;
        esac
    done
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

strip_quotes() {
    local s="$1"
    if [[ "$s" == \"*\" && "$s" == *\" ]] || [[ "$s" == \'*\' && "$s" == *\' ]]; then
        s="${s:1:${#s}-2}"
    fi
    printf '%s' "$s"
}

array_contains() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

sed_escape_regex() {
    printf '%s' "$1" | sed -E 's/[][(){}.^$+*?|#\\]/\\&/g'
}

sed_escape_replacement() {
    printf '%s' "$1" | sed -E 's/[\\&#]/\\&/g'
}

# Keep transformed text in memory, including its exact trailing newlines.
# The final sentinel prevents command substitution from trimming newlines.
rewrite_file_in_memory() {
    local file="$1" original updated
    shift
    FILE_REWRITE_CHANGED=0
    original="$(cat -- "$file" && printf '\001')" || return 1
    updated="$("$@" "$file" && printf '\001')" || return 1
    [[ "$original" != "$updated" ]] || return 0
    printf '%s' "${updated%$'\001'}" > "$file"
    FILE_REWRITE_CHANGED=1
}
