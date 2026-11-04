# shellcheck shell=bash
# SPDX-License-Identifier: MIT

# Print base-tree tag templates used by tar:/diff: rules.
# Example:
#   tar: v@version@:.
# yields:
#   v@version@
extract_rule_tag_templates() {
    local rules="$1"
    local line directive rest
    local -a parts
    local token base

    [[ -f "$rules" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -n "$line" && "${line:0:1}" != "#" ]] || continue

        if [[ "$line" =~ ^([^:[:space:]]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
            directive="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
        else
            continue
        fi

        read -r -a parts <<< "$rest"
        case "$directive" in
            tar|tar.gz|tar.bz2|tar.lzma|tar.xz|tar.zst|zip)
                (( ${#parts[@]} >= 1 )) || continue
                for token in "${parts[0]}"; do
                    token="$(strip_quotes "$token")"
                    [[ "$token" == *:* ]] || continue
                    base="${token%%:*}"
                    [[ "$base" != "." && ! "$base" =~ ^[0-9a-fA-F]{40}$ ]] || continue
                    printf '%s\n' "$base"
                done
                ;;
            diff|diff.gz|diff.bz2|diff.lzma|diff.xz|diff.zst)
                (( ${#parts[@]} >= 2 )) || continue
                for token in "${parts[0]}" "${parts[1]}"; do
                    token="$(strip_quotes "$token")"
                    [[ "$token" == *:* ]] || continue
                    base="${token%%:*}"
                    [[ "$base" != "." && ! "$base" =~ ^[0-9a-fA-F]{40}$ ]] || continue
                    printf '%s\n' "$base"
                done
                ;;
        esac
    done < "$rules" | awk '!seen[$0]++'
}

regex_escape() {
    # Escape a literal string for use inside a bash extended regular expression.
    printf '%s' "$1" | sed -E 's/[][(){}.^$+*?|\\]/\\&/g'
}

template_to_regex() {
    local template="$1"
    local pkg_name="$2"
    local regex
    local escaped_name

    escaped_name="$(regex_escape "$pkg_name")"
    regex="$(regex_escape "$template")"
    regex="${regex//@name@/$escaped_name}"

    # A package version normally begins with a digit.  This is intentionally
    # stricter than '*' so @name@-@version@ does not accidentally match
    # something like docx4j-parent-11.5.2 when Name is just docx4j.
    regex="${regex//@version@/[0-9][0-9A-Za-z._+~:-]*}"
    regex="${regex//@release@/[0-9A-Za-z._+~:-]+}"
    regex="${regex//@date@/[0-9][0-9A-Za-z._+~:-]*}"

    printf '^%s$\n' "$regex"
}

expand_template() {
    local template="$1"
    local pkg_name="$2"
    local version="$3"
    local result="$template"

    result="${result//@name@/$pkg_name}"
    result="${result//@version@/$version}"
    result="${result//@release@/$RELEASE}"
    printf '%s' "$result"
}

expand_version_template() {
    local template="$1"
    local version="$2"
    printf '%s' "${template//@version@/$version}"
}

# Infer the upstream release-tag naming scheme from the package's current
# version.  Example:
#   current Version: 11.5.1
#   upstream tag:    docx4j-parent-11.5.1
# becomes:
#   docx4j-parent-@version@
#
# We only infer automatically when there is exactly one upstream tag ending
# in the current version.  Ambiguity is deliberately not guessed.
infer_upstream_version_template() {
    local current_version="$1"
    shift
    local tag prefix
    local -a candidates=()

    [[ -n "$current_version" ]] || return 1

    for tag in "$@"; do
        [[ "$tag" == *"$current_version" ]] || continue

        prefix="${tag%$current_version}"

        # Avoid matching a version merely embedded in another numeric token.
        if [[ -n "$prefix" && "${prefix: -1}" =~ [0-9] ]]; then
            continue
        fi

        candidates+=("${prefix}@version@")
    done

    if (( ${#candidates[@]} == 0 )); then
        return 1
    fi

    mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++')

    (( ${#candidates[@]} == 1 )) || return 1
    printf '%s\n' "${candidates[0]}"
}

show_recent_tags() {
    local rules="$1"
    local pkg_name="$2"
    local inferred_upstream_template="${3:-}"
    shift 3
    local -a templates=()
    local -a tags=("$@")
    local -a matched=()
    local -a outside=()
    local template regex tag

    mapfile -t templates < <(extract_rule_tag_templates "$rules")
    (( ${#tags[@]} > 0 )) || die "No tags found in upstream repository"

    if (( ${#templates[@]} > 0 )); then
        printf '\nGear source tag templates used by %s:\n' "$rules"
        printf '  %s\n' "${templates[@]}"

        for tag in "${tags[@]}"; do
            for template in "${templates[@]}"; do
                regex="$(template_to_regex "$template" "$pkg_name")"
                if [[ "$tag" =~ $regex ]]; then
                    matched+=("$tag")
                    break
                fi
            done
        done
    fi

    # If upstream uses a different naming scheme from gear rules, show the
    # inferred upstream scheme explicitly instead of pretending it matched
    # @name@ from the spec.
    if (( ${#matched[@]} == 0 )) && [[ -n "$inferred_upstream_template" ]]; then
        printf '\nUpstream tag template inferred from current Version:\n'
        printf '  %s\n' "$inferred_upstream_template"

        regex="$(template_to_regex "$inferred_upstream_template" "$pkg_name")"
        for tag in "${tags[@]}"; do
            if [[ "$tag" =~ $regex ]]; then
                matched+=("$tag")
            fi
        done
    fi

    printf '\nRecent upstream tags'
    if (( ${#matched[@]} > 0 )); then
        printf ' matching the detected release scheme'
    fi
    printf ':\n'

    if (( ${#matched[@]} > 0 )); then
        printf '%s\n' "${matched[@]}" | sort -Vr | awk -v limit="$RECENT_TAGS" 'NR <= limit' | sed 's/^/  /'

        # A project can rename its release tags while the package still uses
        # the old scheme in .gear/rules.  Showing a few non-matching tags makes
        # that change visible before the user enters a version.
        for tag in "${tags[@]}"; do
            if ! printf '%s\n' "${matched[@]}" | grep -Fxq -- "$tag"; then
                outside+=("$tag")
            fi
        done
        if (( ${#outside[@]} > 0 )); then
            printf '\nRecent upstream tags outside the current rules scheme\n'
            printf '(the release-tag naming may have changed):\n'
            printf '%s\n' "${outside[@]}" | sort -Vr | awk -v limit="$RECENT_TAGS" 'NR <= limit' | sed 's/^/  /'
        fi
    else
        warn "Could not identify a unique upstream release-tag scheme; showing recent upstream tags without filtering."
        printf '%s\n' "${tags[@]}" | sort -Vr | awk -v limit="$RECENT_TAGS" 'NR <= limit' | sed 's/^/  /'
    fi
}

tag_exists_upstream() {
    local wanted="$1"
    shift
    local tag

    for tag in "$@"; do
        [[ "$tag" == "$wanted" ]] && return 0
    done
    return 1
}

resolve_gear_source_tag() {
    local rules="$1"
    local pkg_name="$2"
    local version="$3"
    local template expected

    RULE_TEMPLATES=()
    GEAR_SOURCE_TAGS=()
    RESOLVED_GEAR_SOURCE_TAG=""

    mapfile -t RULE_TEMPLATES < <(extract_rule_tag_templates "$rules")
    (( ${#RULE_TEMPLATES[@]} > 0 )) || \
        die "No source tag template was found in $rules. Cannot derive gear source tag from version safely."

    for template in "${RULE_TEMPLATES[@]}"; do
        [[ "$template" == *'@version@'* ]] || continue
        expected="$(expand_template "$template" "$pkg_name" "$version")"
        GEAR_SOURCE_TAGS+=("$expected")
    done
    mapfile -t GEAR_SOURCE_TAGS < <(
        printf '%s\n' "${GEAR_SOURCE_TAGS[@]}" | awk 'NF && !seen[$0]++'
    )

    (( ${#GEAR_SOURCE_TAGS[@]} > 0 )) || \
        die "No @version@ source tag template was found in $rules"

    if (( ${#GEAR_SOURCE_TAGS[@]} != 1 )); then
        printf 'Gear rules expand to multiple source tags for version %s:\n' "$version" >&2
        printf '  %s\n' "${GEAR_SOURCE_TAGS[@]}" >&2
        die "Cannot safely choose one source tag automatically"
    fi

    RESOLVED_GEAR_SOURCE_TAG="${GEAR_SOURCE_TAGS[0]}"
}

# Convert an exact release tag back into a simple @version@ template.
# Examples:
#   jline-3.30.16 -> @name@-@version@
#   v3.30.16     -> v@version@
#   3.30.16      -> @version@
infer_rule_template_from_tag() {
    local tag="$1"
    local pkg_name="$2"
    local version="$3"
    local prefix suffix

    [[ "$tag" == *"$version" ]] || return 1
    prefix="${tag%$version}"
    if [[ -n "$prefix" && "${prefix: -1}" =~ [0-9] ]]; then
        return 1
    fi

    if [[ "$prefix" == "$pkg_name"* ]]; then
        suffix="${prefix#$pkg_name}"
        if [[ -z "$suffix" || "$suffix" == [-_.:+~]* ]]; then
            prefix="@name@${suffix}"
        fi
    fi

    printf '%s@version@\n' "$prefix"
}

rewrite_rule_tag_template() {
    local rules="$1"
    local old_template="$2"
    local new_template="$3"

    rewrite_file_in_memory "$rules" awk -v old="$old_template" -v new="$new_template" '
        function replace_literal(text, old, new,    result, position) {
            result = ""
            while ((position = index(text, old)) != 0) {
                result = result substr(text, 1, position - 1) new
                text = substr(text, position + length(old))
            }
            return result text
        }
        /^[[:space:]]*#/ {
            print
            next
        }
        /^[[:space:]]*(tar([.][^:[:space:]]+)?|zip|diff([.][^:[:space:]]+)?)[?]?[[:space:]]*:/ {
            print replace_literal($0, old, new)
            next
        }
        { print }
    '
    (( FILE_REWRITE_CHANGED ))
}

plan_tag_scheme_change() {
    local rules="$1"
    local pkg_name="$2"
    local version="$3"
    local upstream_tag="$4"
    local old_template="" new_template="" answer

    TAG_SCHEME_CHANGE_MODE="none"
    TAG_SCHEME_OLD_TEMPLATE=""
    TAG_SCHEME_NEW_TEMPLATE=""
    [[ "$upstream_tag" != "$RESOLVED_GEAR_SOURCE_TAG" ]] || return 0

    if (( ${#RULE_TEMPLATES[@]} == 1 )); then
        old_template="${RULE_TEMPLATES[0]}"
        new_template="$(infer_rule_template_from_tag "$upstream_tag" "$pkg_name" "$version" || true)"
        [[ "$new_template" != "$old_template" ]] || new_template=""
    fi

    printf '\nUpstream release-tag naming differs from %s:\n' "$rules"
    printf '  Rules expect:  %s\n' "$RESOLVED_GEAR_SOURCE_TAG"
    printf '  Upstream uses: %s\n' "$upstream_tag"
    if [[ -n "$new_template" ]]; then
        printf '  Detected new template: %s\n' "$new_template"
    fi

    while true; do
        if [[ -n "$new_template" ]]; then
            read -r -p "Choose: [a]uto-update rules, [e]dit rules after merge, [q]uit: " answer
        else
            read -r -p "Choose: [e]dit rules after merge, [q]uit: " answer
        fi

        case "${answer,,}" in
            a|auto)
                [[ -n "$new_template" ]] || {
                    printf 'Automatic template conversion is not available for this tag.\n'
                    continue
                }
                TAG_SCHEME_CHANGE_MODE="auto"
                TAG_SCHEME_OLD_TEMPLATE="$old_template"
                TAG_SCHEME_NEW_TEMPLATE="$new_template"
                return 0
                ;;
            e|edit)
                TAG_SCHEME_CHANGE_MODE="edit"
                return 0
                ;;
            q|quit)
                die "Update cancelled before fetching or merging upstream"
                ;;
            *)
                printf 'Please choose a, e or q.\n'
                ;;
        esac
    done
}

rules_edit_other_changes() {
    local rules="$1" record status path old_path
    git diff --binary HEAD -- . ":(exclude)$rules" ':!**/*~' ':!*~'
    while IFS= read -r -d '' record; do
        status="${record:0:2}"
        path="${record:3}"
        old_path=""
        if [[ "$status" == *R* || "$status" == *C* ]]; then
            IFS= read -r -d '' old_path || true
        fi
        [[ "$path" == "$rules" || "$path" == *~ ]] && continue
        printf '%s\0%s\0' "$record" "$old_path"
        if [[ "$status" == '??' && -f "$path" ]]; then
            git hash-object -- "$path"
        fi
    done < <(git status --porcelain=v1 -z --untracked-files=all)
}

apply_planned_tag_scheme_change() {
    local rules="$1"
    local pkg_name="$2"
    local version="$3"
    local upstream_tag="$4"
    local user_shell="${SHELL:-/bin/sh}"
    local before_other after_other

    case "$TAG_SCHEME_CHANGE_MODE" in
        none)
            ;;
        auto)
            rewrite_rule_tag_template \
                "$rules" "$TAG_SCHEME_OLD_TEMPLATE" "$TAG_SCHEME_NEW_TEMPLATE" \
                || die "Could not replace '$TAG_SCHEME_OLD_TEMPLATE' in $rules"
            printf '\nApplied rules change:\n'
            git --no-pager diff --color=always -- "$rules"
            ;;
        edit)
            while true; do
                printf '\nOpening %s in:\n  %s\n' "$user_shell" "$(pwd)"
                printf 'Edit only %s, then exit the shell.\n' "$rules"
                printf 'Its source tag for version %s must expand to:\n  %s\n\n' \
                    "$version" "$upstream_tag"
                before_other="$(rules_edit_other_changes "$rules" | git hash-object --stdin)"
                "$user_shell"
                after_other="$(rules_edit_other_changes "$rules" | git hash-object --stdin)"

                [[ -f "$rules" ]] || die "$rules was removed"
                [[ "$before_other" == "$after_other" ]] \
                    || die "Manual editing changed files other than $rules; changes were left for inspection"
                git diff --quiet -- "$rules" && {
                    warn "$rules was not changed."
                    continue
                }

                resolve_gear_source_tag "$rules" "$pkg_name" "$version"
                if [[ "$RESOLVED_GEAR_SOURCE_TAG" == "$upstream_tag" ]]; then
                    printf '\nApplied rules change:\n'
                    git --no-pager diff --color=always -- "$rules"
                    break
                fi

                warn "$rules still expands to '$RESOLVED_GEAR_SOURCE_TAG', not '$upstream_tag'."
            done
            ;;
        *)
            die "Internal error: unknown tag-scheme change mode '$TAG_SCHEME_CHANGE_MODE'"
            ;;
    esac

    resolve_gear_source_tag "$rules" "$pkg_name" "$version"
    [[ "$RESOLVED_GEAR_SOURCE_TAG" == "$upstream_tag" ]] || {
        printf 'Updated %s expands to:\n  %s\n' "$rules" "$RESOLVED_GEAR_SOURCE_TAG" >&2
        printf 'Selected upstream tag is:\n  %s\n' "$upstream_tag" >&2
        die "The rules source tag must match the selected upstream tag"
    }
    FINAL_GEAR_SOURCE_TAG="$RESOLVED_GEAR_SOURCE_TAG"

    if [[ "$TAG_SCHEME_CHANGE_MODE" != none ]]; then
        info "$rules will be included in the final gear-commit."
    fi
}

rpm_version_is_valid() {
    local version="$1"
    [[ -n "$version" && "$version" =~ ^[[:alnum:]][[:alnum:]._+~^]*$ ]]
}

extract_rpm_version_from_tag() {
    local tag="$1"
    if [[ "$tag" =~ ([0-9][0-9A-Za-z._+~^]*)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

read_version_or_tag() {
    local input detected_version

    ENTERED_UPSTREAM_TAG=""
    SELECTED_PACKAGE_VERSION=""

    while true; do
        read -r -p "New package version or upstream tag: " input
        input="$(trim "$input")"

        if tag_exists_upstream "$input" "${UPSTREAM_TAGS[@]}"; then
            ENTERED_UPSTREAM_TAG="$input"
            detected_version="$(extract_rpm_version_from_tag "$input" || true)"
            if rpm_version_is_valid "$detected_version"; then
                SELECTED_PACKAGE_VERSION="$detected_version"
                info "Upstream tag entered: $ENTERED_UPSTREAM_TAG"
                info "Detected package version: $SELECTED_PACKAGE_VERSION"
                return 0
            fi

            warn "Could not derive a valid RPM Version from tag '$input'."
            continue
        fi

        if rpm_version_is_valid "$input"; then
            SELECTED_PACKAGE_VERSION="$input"
            return 0
        fi

        printf 'Enter an RPM version without spaces or hyphens (for example 3.30.16),\n'
        printf 'or enter the exact upstream tag shown above.\n'
    done
}

choose_upstream_tag_interactively() {
    local version="$1"
    shift
    local -a candidates=("$@")
    local answer

    if (( ${#candidates[@]} > 0 )); then
        printf '\nSeveral upstream tags correspond to version %s:\n' "$version"
        printf '  %s\n' "${candidates[@]}"
    else
        printf '\nNo upstream tag was matched automatically for version %s.\n' "$version"
        printf 'Recent upstream tags:\n'
        printf '%s\n' "${UPSTREAM_TAGS[@]}" | sort -Vr | awk -v limit="$RECENT_TAGS" 'NR <= limit' | sed 's/^/  /'
    fi

    while true; do
        read -r -p "Upstream tag (exact name, or q to quit): " answer
        answer="$(trim "$answer")"
        [[ "${answer,,}" != q && "${answer,,}" != quit ]] \
            || die "Update cancelled before fetching or merging upstream"
        if tag_exists_upstream "$answer" "${UPSTREAM_TAGS[@]}"; then
            SELECTED_UPSTREAM_TAG="$answer"
            return 0
        fi
        printf "Tag '%s' was not found upstream.\n" "$answer"
    done
}
