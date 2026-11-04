# shellcheck shell=bash
# SPDX-License-Identifier: MIT

find_spec() {
    local rules="$1"
    local package="$2"
    local from_rules=""
    local specs=()

    if [[ -f "$rules" ]]; then
        from_rules="$(sed -nE 's/^[[:space:]]*spec[[:space:]]*:[[:space:]]*([^[:space:]]+).*$/\1/p' "$rules" | head -n1 || true)"
        from_rules="$(strip_quotes "$from_rules")"
        if [[ -n "$from_rules" && -f "$from_rules" ]]; then
            printf '%s\n' "$from_rules"
            return 0
        fi
    fi

    if [[ -f "altlinux/${package}.spec" ]]; then
        printf 'altlinux/%s.spec\n' "$package"
        return 0
    fi

    mapfile -t specs < <(find altlinux -type f -name '*.spec' -print 2>/dev/null | sort)
    if (( ${#specs[@]} == 1 )); then
        printf '%s\n' "${specs[0]}"
        return 0
    fi

    mapfile -t specs < <(find . -maxdepth 2 -type f -name '*.spec' -print | sort)
    if (( ${#specs[@]} == 1 )); then
        printf '%s\n' "${specs[0]}"
        return 0
    fi

    (( ${#specs[@]} > 0 )) || die "No spec file found"
    printf 'Several spec files were found:\n' >&2
    printf '  %s\n' "${specs[@]}" >&2
    die "Cannot determine the main spec automatically"
}

read_spec_field() {
    local spec="$1"
    local field="$2"
    sed -nE "s/^[[:space:]]*${field}[[:space:]]*:[[:space:]]*(.*)$/\\1/ip" "$spec" | head -n1
}

read_committed_spec_field() {
    local spec="${1#./}"
    local field="$2"

    git show "HEAD:$spec" 2>/dev/null |
        sed -nE "s/^[[:space:]]*${field}[[:space:]]*:[[:space:]]*(.*)$/\\1/ip" |
        head -n1
}

read_vcs_url() {
    local spec="$1"
    local url

    url="$(read_spec_field "$spec" 'Vcs' || true)"
    url="$(trim "$url")"
    [[ -n "$url" ]] || die "Vcs: field not found in $spec"

    # Common SCM prefixes sometimes used in RPM specs.
    url="${url#scm:git:}"
    url="${url#git+}"
    url="${url%%[[:space:]]*}"

    [[ "$url" != *'%'* ]] || die "Vcs URL contains unresolved RPM macros: $url"
    printf '%s\n' "$url"
}

update_spec() {
    local spec="$1"
    local version="$2"
    local original updated

    grep -Eqi '^[[:space:]]*Version[[:space:]]*:' "$spec" || die "Version: field not found in $spec"
    grep -Eqi '^[[:space:]]*Release[[:space:]]*:' "$spec" || die "Release: field not found in $spec"
    original="$(cat -- "$spec" && printf '\001')" || die "Cannot read $spec"
    updated="$(
        printf '%s' "${original%$'\001'}" |
            sed -E \
                -e "0,/^[[:space:]]*[Vv]ersion[[:space:]]*:/s|^([[:space:]]*[Vv]ersion[[:space:]]*:[[:space:]]*).*$|\\1$version|" \
                -e "0,/^[[:space:]]*[Rr]elease[[:space:]]*:/s|^([[:space:]]*[Rr]elease[[:space:]]*:[[:space:]]*).*$|\\1$RELEASE|" \
            && printf '\001'
    )" || die "Cannot transform $spec"

    printf '%s' "${updated%$'\001'}" > "$spec"
    if ! add_changelog "$spec" -e "- Automatically updated to $version."; then
        printf '%s' "${original%$'\001'}" > "$spec"
        die "Spec update failed; original contents restored"
    fi
}
