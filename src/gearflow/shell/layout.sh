# shellcheck shell=bash
# SPDX-License-Identifier: MIT

# Split directive arguments using the shell-like quoting supported by
# gear-rules(5), without eval.  The result is returned in RULE_ARGS.
split_rule_arguments() {
    local input="$1"
    local token="" quote="" char
    local escaped=0 token_started=0 i
    RULE_ARGS=()

    for (( i = 0; i < ${#input}; i++ )); do
        char="${input:i:1}"

        if (( escaped )); then
            token+="$char"
            escaped=0
            token_started=1
            continue
        fi

        if [[ -n "$quote" ]]; then
            if [[ "$char" == "$quote" ]]; then
                quote=""
                token_started=1
            elif [[ "$char" == "\\" && "$quote" == '"' ]]; then
                escaped=1
            else
                token+="$char"
                token_started=1
            fi
            continue
        fi

        case "$char" in
            "'"|'"')
                quote="$char"
                token_started=1
                ;;
            "\\")
                escaped=1
                token_started=1
                ;;
            ' '|$'\t')
                if (( token_started )); then
                    RULE_ARGS+=("$token")
                    token=""
                    token_started=0
                fi
                ;;
            *)
                token+="$char"
                token_started=1
                ;;
        esac
    done

    [[ -z "$quote" && $escaped -eq 0 ]] || return 1
    if (( token_started )); then
        RULE_ARGS+=("$token")
    fi
}

declare -a LAYOUT_ERRORS=()

layout_error() {
    LAYOUT_ERRORS+=("$*")
}

layout_path_is_altlinux() {
    local path="$1"
    path="${path#./}"
    [[ "$path" == altlinux/* ]]
}

# Files below .gear/upstream are gear metadata (for example filter-tag and
# transform-tag), not package sources.  They must stay in .gear even when a
# rules directive names them explicitly.
layout_path_is_gear_upstream() {
    local path="$1"
    path="${path#./}"
    [[ "$path" == .gear/upstream/* ]]
}

require_altlinux_rule_path() {
    local path="$1"
    local source="$2"

    if ! layout_path_is_altlinux "$path" && ! layout_path_is_gear_upstream "$path"; then
        layout_error "$source: '$path' must be located under altlinux/"
    fi
}

# Enforce the packaging layout used by ALT packages maintained by this script:
#   .gear/rules
#   .gear/tags/
#   .gear/upstream/remotes (optional)
#   altlinux/<specs, patches, scripts, units and other packaging files>
#
# Source-tree paths used by tar:/diff: are deliberately not required to be
# under altlinux/: they describe upstream Git trees, not packaging files.
validate_altlinux_layout() {
    local rules="$1"
    local spec="$2"
    local entry line directive rest token path
    local line_number=0 after_separator

    LAYOUT_ERRORS=()

    [[ -d altlinux ]] || layout_error "missing packaging directory: altlinux/"
    require_altlinux_rule_path "$spec" "main spec"

    [[ ! -e .gear/tags || -d .gear/tags ]] || \
        layout_error ".gear/tags must be a directory"
    [[ ! -e .gear/upstream || -d .gear/upstream ]] || \
        layout_error ".gear/upstream must be a directory"
    [[ ! -e .gear/upstream/remotes || -f .gear/upstream/remotes ]] || \
        layout_error ".gear/upstream/remotes must be a regular file"

    # .gear may contain only the rules file, stored tags and saved upstream
    # remote configuration.  Ignore local editor backup files because they are
    # also deliberately excluded from staging later.
    while IFS= read -r -d '' entry; do
        [[ "$entry" == *~ ]] && continue
        case "$entry" in
            .gear/rules|.gear/tags|.gear/upstream) ;;
            *) layout_error "unexpected entry in .gear/: ${entry#.gear/}" ;;
        esac
    done < <(find .gear -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_number += 1 ))
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -n "$line" && "${line:0:1}" != "#" ]] || continue

        if [[ "$line" =~ ^([^:[:space:]]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
            directive="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
        else
            continue
        fi

        if ! split_rule_arguments "$rest"; then
            layout_error "$rules line $line_number: cannot parse shell-like quoting"
            continue
        fi

        case "$directive" in
            spec)
                if (( ${#RULE_ARGS[@]} >= 1 )); then
                    require_altlinux_rule_path "${RULE_ARGS[0]}" "$rules line $line_number (spec)"
                fi
                ;;
            tags)
                if (( ${#RULE_ARGS[@]} >= 1 )); then
                    path="${RULE_ARGS[0]%/}"
                    path="${path#./}"
                    [[ "$path" == ".gear/tags" ]] || \
                        layout_error "$rules line $line_number (tags): '${RULE_ARGS[0]}' must be .gear/tags"
                fi
                ;;
            copy|copy\?|gzip|gzip\?|bzip2|bzip2\?|lzma|lzma\?|xz|xz\?|zstd|zstd\?)
                for token in "${RULE_ARGS[@]}"; do
                    require_altlinux_rule_path "$token" "$rules line $line_number ($directive)"
                done
                ;;
            compress|compress\?)
                after_separator=0
                for token in "${RULE_ARGS[@]}"; do
                    if (( after_separator )); then
                        require_altlinux_rule_path "$token" "$rules line $line_number ($directive)"
                    elif [[ "$token" == "--" ]]; then
                        after_separator=1
                    fi
                done
                ;;
            tar|tar\?|tar.gz|tar.gz\?|tar.bz2|tar.bz2\?|tar.lzma|tar.lzma\?|tar.xz|tar.xz\?|tar.zst|tar.zst\?|zip|zip\?|diff|diff\?|diff.gz|diff.gz\?|diff.bz2|diff.bz2\?|diff.lzma|diff.lzma\?|diff.xz|diff.xz\?|diff.zst|diff.zst\?)
                # tree_path arguments are upstream source trees.  Only spec=
                # options on these directives name packaging files.
                for token in "${RULE_ARGS[@]}"; do
                    if [[ "$token" == spec=* ]]; then
                        require_altlinux_rule_path "${token#spec=}" "$rules line $line_number ($directive spec=)"
                    fi
                done
                ;;
        esac
    done < "$rules"

    if (( ${#LAYOUT_ERRORS[@]} > 0 )); then
        printf 'ALT Linux packaging layout check failed:\n' >&2
        printf '  - %s\n' "${LAYOUT_ERRORS[@]}" >&2
        printf '\nExpected layout:\n' >&2
        printf '  .gear/rules\n' >&2
        printf '  .gear/tags/\n' >&2
        printf '  .gear/upstream/remotes (optional)\n' >&2
        printf '  altlinux/<specs, patches, scripts, service files, ...>\n' >&2
        return 1
    fi

    return 0
}

declare -a MIGRATION_RULE_OLD=()
declare -a MIGRATION_RULE_NEW=()
declare -a MIGRATION_MOVE_SOURCE=()
declare -a MIGRATION_MOVE_DEST=()
declare -a MIGRATION_MISSING=()
declare -a MIGRATION_ERRORS=()
PREPARE_RULES_OLD_PATH=""

layout_destination_for_path() {
    local path="$1"

    path="${path#./}"
    if [[ "$path" == .gear/* ]]; then
        path="${path#.gear/}"
    fi
    printf 'altlinux/%s' "$path"
}

expand_layout_keywords() {
    local path="$1"

    path="${path//@name@/$MIGRATION_SPEC_NAME}"
    path="${path//@version@/$MIGRATION_SPEC_VERSION}"
    path="${path//@release@/$MIGRATION_SPEC_RELEASE}"
    printf '%s' "$path"
}

add_rule_rewrite() {
    local old_path="$1"
    local new_path="$2"
    local i

    [[ "$old_path" != "$new_path" ]] || return 0
    for (( i = 0; i < ${#MIGRATION_RULE_OLD[@]}; i++ )); do
        if [[ "${MIGRATION_RULE_OLD[i]}" == "$old_path" ]]; then
            if [[ "${MIGRATION_RULE_NEW[i]}" != "$new_path" ]]; then
                MIGRATION_ERRORS+=("rule path '$old_path' has conflicting destinations: '${MIGRATION_RULE_NEW[i]}' and '$new_path'")
            fi
            return 0
        fi
    done

    MIGRATION_RULE_OLD+=("$old_path")
    MIGRATION_RULE_NEW+=("$new_path")
}

add_move_to_plan() {
    local source="${1#./}"
    local destination="${2#./}"
    local i

    [[ "$source" != "$destination" ]] || return 0
    for (( i = 0; i < ${#MIGRATION_MOVE_SOURCE[@]}; i++ )); do
        if [[ "${MIGRATION_MOVE_SOURCE[i]}" == "$source" ]]; then
            if [[ "${MIGRATION_MOVE_DEST[i]}" != "$destination" ]]; then
                MIGRATION_ERRORS+=("'$source' has conflicting destinations: '${MIGRATION_MOVE_DEST[i]}' and '$destination'")
            fi
            return 0
        fi
        if [[ "${MIGRATION_MOVE_DEST[i]}" == "$destination" && "${MIGRATION_MOVE_SOURCE[i]}" != "$source" ]]; then
            MIGRATION_ERRORS+=("both '${MIGRATION_MOVE_SOURCE[i]}' and '$source' would be moved to '$destination'")
            return 0
        fi
    done

    MIGRATION_MOVE_SOURCE+=("$source")
    MIGRATION_MOVE_DEST+=("$destination")
}

path_has_glob() {
    case "$1" in
        *'*'*|*'?'*|*'['*) return 0 ;;
        *) return 1 ;;
    esac
}

# Add one local path or glob from .gear/rules to the migration plan.  The rule
# spelling is preserved (including @name@/@version@), while concrete files are
# resolved for the actual move.
plan_local_rule_path() {
    local rule_path="$1"
    local source_description="$2"
    local optional="${3:-0}"
    local normalized destination_rule expanded match child destination
    local -a matches=()

    normalized="${rule_path#./}"
    [[ -n "$normalized" ]] || return 0
    layout_path_is_altlinux "$normalized" && return 0
    layout_path_is_gear_upstream "$normalized" && return 0

    if [[ "$normalized" == /* || "$normalized" == .. || "$normalized" == ../* ]]; then
        MIGRATION_ERRORS+=("$source_description: unsafe path '$rule_path' cannot be migrated automatically")
        return 0
    fi

    destination_rule="$(layout_destination_for_path "$normalized")"
    add_rule_rewrite "$normalized" "$destination_rule"

    expanded="$(expand_layout_keywords "$normalized")"
    if path_has_glob "$expanded"; then
        mapfile -t matches < <(compgen -G "$expanded" || true)
    elif [[ -e "$expanded" || -L "$expanded" ]]; then
        matches=("$expanded")
    fi

    if (( ${#matches[@]} == 0 )); then
        if (( ! optional )); then
            MIGRATION_MISSING+=("$source_description: '$rule_path' does not match an existing file")
        fi
        return 0
    fi

    for match in "${matches[@]}"; do
        match="${match#./}"
        if [[ -d "$match" && ! -L "$match" ]]; then
            while IFS= read -r -d '' child; do
                child="${child#./}"
                destination="$(layout_destination_for_path "$child")"
                add_move_to_plan "$child" "$destination"
            done < <(find "$match" \( -type f -o -type l \) -print0)
        else
            destination="$(layout_destination_for_path "$match")"
            add_move_to_plan "$match" "$destination"
        fi
    done
}

plan_tags_directory() {
    local rule_path="$1"
    local source_description="$2"
    local normalized="${rule_path%/}"

    normalized="${normalized#./}"
    [[ "$normalized" == .gear/tags ]] && return 0

    if [[ "$normalized" == /* || "$normalized" == .. || "$normalized" == ../* ]]; then
        MIGRATION_ERRORS+=("$source_description: unsafe tags path '$rule_path' cannot be migrated automatically")
        return 0
    fi

    add_rule_rewrite "$normalized" ".gear/tags"
    if [[ -e "$normalized" || -L "$normalized" ]]; then
        add_move_to_plan "$normalized" ".gear/tags"
    else
        MIGRATION_MISSING+=("$source_description: tags directory '$rule_path' does not exist")
    fi
}

collect_extra_gear_files() {
    local entry destination

    # Anything below .gear except rules, stored tags and all upstream metadata
    # is a packaging file and is moved below altlinux/ as well.  This catches
    # files that are not currently mentioned by rules, such as a newly added
    # patch or service unit that the user wants to wire in before retrying the
    # plan.
    while IFS= read -r -d '' entry; do
        entry="${entry#./}"
        [[ "$entry" == *~ ]] && continue
        destination="$(layout_destination_for_path "$entry")"
        add_move_to_plan "$entry" "$destination"
    done < <(
        find .gear -mindepth 1 \
            \( -path .gear/rules -o -path .gear/tags -o -path '.gear/tags/*' \
               -o -path .gear/upstream \) -prune -o \
            \( -type f -o -type l \) -print0 2>/dev/null
    )
}

collect_layout_migration_plan() {
    local rules="$1"
    local spec="$2"
    local package="$3"
    local line directive rest token path optional after_separator
    local line_number=0

    MIGRATION_RULE_OLD=()
    MIGRATION_RULE_NEW=()
    MIGRATION_MOVE_SOURCE=()
    MIGRATION_MOVE_DEST=()
    MIGRATION_MISSING=()
    MIGRATION_ERRORS=()

    MIGRATION_SPEC_NAME="$(read_spec_field "$spec" 'Name' || true)"
    MIGRATION_SPEC_NAME="$(trim "$MIGRATION_SPEC_NAME")"
    [[ -n "$MIGRATION_SPEC_NAME" && "$MIGRATION_SPEC_NAME" != *'%'* ]] || MIGRATION_SPEC_NAME="$package"
    MIGRATION_SPEC_VERSION="$(read_spec_field "$spec" 'Version' || true)"
    MIGRATION_SPEC_VERSION="$(trim "$MIGRATION_SPEC_VERSION")"
    MIGRATION_SPEC_RELEASE="$(read_spec_field "$spec" 'Release' || true)"
    MIGRATION_SPEC_RELEASE="$(trim "$MIGRATION_SPEC_RELEASE")"

    # The main spec must be migrated even when .gear/rules has no explicit
    # spec: directive.  This is common in freshly imported gear repositories.
    if ! layout_path_is_altlinux "$spec"; then
        plan_local_rule_path "$spec" "main spec" 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_number += 1 ))
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -n "$line" && "${line:0:1}" != "#" ]] || continue

        if [[ "$line" =~ ^([^:[:space:]]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
            directive="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
        else
            continue
        fi

        if ! split_rule_arguments "$rest"; then
            MIGRATION_ERRORS+=("$rules line $line_number: cannot parse shell-like quoting")
            continue
        fi

        optional=0
        [[ "$directive" == *'?' ]] && optional=1

        case "$directive" in
            spec)
                if (( ${#RULE_ARGS[@]} >= 1 )); then
                    plan_local_rule_path "${RULE_ARGS[0]}" "$rules line $line_number (spec)" 0
                fi
                ;;
            tags)
                if (( ${#RULE_ARGS[@]} >= 1 )); then
                    plan_tags_directory "${RULE_ARGS[0]}" "$rules line $line_number (tags)"
                fi
                ;;
            copy|copy\?|gzip|gzip\?|bzip2|bzip2\?|lzma|lzma\?|xz|xz\?|zstd|zstd\?)
                for token in "${RULE_ARGS[@]}"; do
                    plan_local_rule_path "$token" "$rules line $line_number ($directive)" "$optional"
                done
                ;;
            compress|compress\?)
                after_separator=0
                for token in "${RULE_ARGS[@]}"; do
                    if (( after_separator )); then
                        plan_local_rule_path "$token" "$rules line $line_number ($directive)" "$optional"
                    elif [[ "$token" == "--" ]]; then
                        after_separator=1
                    fi
                done
                ;;
            tar|tar\?|tar.gz|tar.gz\?|tar.bz2|tar.bz2\?|tar.lzma|tar.lzma\?|tar.xz|tar.xz\?|tar.zst|tar.zst\?|zip|zip\?|diff|diff\?|diff.gz|diff.gz\?|diff.bz2|diff.bz2\?|diff.lzma|diff.lzma\?|diff.xz|diff.xz\?|diff.zst|diff.zst\?)
                for token in "${RULE_ARGS[@]}"; do
                    if [[ "$token" == spec=* ]]; then
                        path="${token#spec=}"
                        plan_local_rule_path "$path" "$rules line $line_number ($directive spec=)" "$optional"
                    fi
                done
                ;;
        esac
    done < "$rules"

    # Migrate the legacy default tag directory even if rules does not contain
    # an explicit tags: directive.
    if [[ -e .gear-tags && ! -e .gear/tags ]]; then
        add_move_to_plan ".gear-tags" ".gear/tags"
    elif [[ -e .gear-tags && -e .gear/tags ]]; then
        MIGRATION_ERRORS+=("both .gear-tags and .gear/tags exist; merge them manually")
    fi

    collect_extra_gear_files
}

show_layout_migration_plan() {
    local i

    printf '\nALT Linux packaging layout migration is required.\n'

    if (( ${#MIGRATION_RULE_OLD[@]} > 0 )); then
        printf '\nRules path changes:\n'
        for (( i = 0; i < ${#MIGRATION_RULE_OLD[@]}; i++ )); do
            printf '  %s -> %s\n' "${MIGRATION_RULE_OLD[i]}" "${MIGRATION_RULE_NEW[i]}"
        done
    fi

    if (( ${#MIGRATION_MOVE_SOURCE[@]} > 0 )); then
        printf '\nFiles to move:\n'
        for (( i = 0; i < ${#MIGRATION_MOVE_SOURCE[@]}; i++ )); do
            printf '  %s -> %s\n' "${MIGRATION_MOVE_SOURCE[i]}" "${MIGRATION_MOVE_DEST[i]}"
        done
    fi

    if (( ${#MIGRATION_MISSING[@]} > 0 )); then
        printf '\nMissing required files:\n'
        printf '  - %s\n' "${MIGRATION_MISSING[@]}"
    fi

    if (( ${#MIGRATION_ERRORS[@]} > 0 )); then
        printf '\nItems that require manual resolution:\n'
        printf '  - %s\n' "${MIGRATION_ERRORS[@]}"
    fi

    printf '\nThe migration will be committed separately as:\n'
    printf '  %s\n' "$LAYOUT_COMMIT_MESSAGE"
}

rewrite_rules_paths() {
    local rules="$1"
    local i old_regex new_replacement

    for (( i = 0; i < ${#MIGRATION_RULE_OLD[@]}; i++ )); do
        old_regex="$(sed_escape_regex "${MIGRATION_RULE_OLD[i]}")"
        new_replacement="$(sed_escape_replacement "${MIGRATION_RULE_NEW[i]}")"

        # Replace complete shell-like arguments only.  This preserves comments,
        # indentation, quoting and all unrelated formatting in .gear/rules.
        rewrite_file_in_memory "$rules" sed -E \
            "s#(^|[[:space:]='\"])${old_regex}([[:space:]'\"]|$)#\\1${new_replacement}\\2#g"
    done
}

unstage_backup_files() {
    local backup

    while IFS= read -r -d '' backup; do
        [[ "$backup" == *~ ]] || continue
        git reset -q HEAD -- "$backup" 2>/dev/null || true
    done < <(git diff --cached --name-only -z)
}

add_unique_path() {
    local path="$1"
    local existing

    for existing in "${LAYOUT_COMMIT_PATHS[@]}"; do
        [[ "$existing" == "$path" ]] && return 0
    done
    LAYOUT_COMMIT_PATHS+=("$path")
}

add_layout_move_commit_paths() {
    local source="$1"
    local destination="$2"
    local child relative

    if [[ -d "$source" && ! -L "$source" ]]; then
        while IFS= read -r -d '' child; do
            [[ "$child" == *~ ]] && continue
            relative="${child#"$source"/}"
            if [[ -n "$(git ls-files -- "$child")" ]]; then
                add_unique_path "$child"
            fi
            add_unique_path "$destination/$relative"
        done < <(find "$source" \( -type f -o -type l \) -print0)
    else
        if [[ -n "$(git ls-files -- "$source")" ]]; then
            add_unique_path "$source"
        fi
        add_unique_path "$destination"
    fi
}

protect_existing_layout_changes() {
    local rules="$1"
    local path
    local -a protected_paths=()
    local -a conflicts=()

    if (( ${#MIGRATION_RULE_OLD[@]} > 0 )); then
        protected_paths+=("$rules")
    fi
    protected_paths+=("${MIGRATION_MOVE_SOURCE[@]}")

    for path in "${protected_paths[@]}"; do
        # Untracked migration sources are intentional packaging inputs.  Only
        # protect paths that already belong to the current Git revision/index.
        if [[ -z "$(git ls-files -- "$path")" ]]; then
            continue
        fi
        if ! git diff --quiet -- "$path" || ! git diff --cached --quiet -- "$path"; then
            conflicts+=("$path")
        fi
    done

    if (( ${#conflicts[@]} > 0 )); then
        printf '\nThe following migration paths already contain staged or unstaged changes:\n' >&2
        printf '  - %s\n' "${conflicts[@]}" >&2
        die "Commit, stash or restore only these paths before running --migrate-layout"
    fi
}

apply_layout_migration() {
    local rules="$1"
    local package="$2"
    local i source destination spec
    LAYOUT_COMMIT_PATHS=()

    if [[ -n "$PREPARE_RULES_OLD_PATH" && -n "$(git ls-files -- "$PREPARE_RULES_OLD_PATH")" ]]; then
        add_unique_path "$PREPARE_RULES_OLD_PATH"
        add_unique_path "$rules"
    elif (( ${#MIGRATION_RULE_OLD[@]} > 0 )); then
        add_unique_path "$rules"
    fi

    (( ${#MIGRATION_MISSING[@]} == 0 )) || die "Add the missing files and recheck the migration plan"
    (( ${#MIGRATION_ERRORS[@]} == 0 )) || die "Resolve the reported layout conflicts before migration"
    (( ${#MIGRATION_MOVE_SOURCE[@]} > 0 || ${#MIGRATION_RULE_OLD[@]} > 0 )) \
        || die "No automatic layout changes were found"

    if (( ${PROTECT_LAYOUT_COMMIT:-0} )); then
        protect_existing_layout_changes "$rules"
    fi

    # Preflight every move before touching the working tree.
    for (( i = 0; i < ${#MIGRATION_MOVE_SOURCE[@]}; i++ )); do
        source="${MIGRATION_MOVE_SOURCE[i]}"
        destination="${MIGRATION_MOVE_DEST[i]}"
        [[ -e "$source" || -L "$source" ]] \
            || die "Migration source disappeared: $source"
        if [[ -e "$destination" || -L "$destination" ]]; then
            die "Migration destination already exists: $destination"
        fi
        add_layout_move_commit_paths "$source" "$destination"
    done

    mkdir -p altlinux
    for (( i = 0; i < ${#MIGRATION_MOVE_SOURCE[@]}; i++ )); do
        source="${MIGRATION_MOVE_SOURCE[i]}"
        destination="${MIGRATION_MOVE_DEST[i]}"
        mkdir -p "$(dirname "$destination")"
        mv -- "$source" "$destination"
    done

    rewrite_rules_paths "$rules"

    # Remove only now-empty obsolete directories.  Keep the three allowed
    # metadata locations even when they are temporarily empty.
    find .gear -depth -type d -empty \
        ! -path .gear ! -path .gear/tags ! -path .gear/upstream \
        -delete 2>/dev/null || true

    spec="$(find_spec "$rules" "$package")"
    if ! validate_altlinux_layout "$rules" "$spec"; then
        die "The generated layout is still invalid; changes were left uncommitted for inspection"
    fi

    (( ${#LAYOUT_COMMIT_PATHS[@]} > 0 )) \
        || die "Layout migration produced no paths to commit"

    # Stage and commit only paths changed by the migration.  Existing staged
    # changes outside this list remain staged and cannot leak into the layout
    # commit.
    git add -A -- "${LAYOUT_COMMIT_PATHS[@]}"

    if git diff-index --cached --quiet HEAD -- "${LAYOUT_COMMIT_PATHS[@]}"; then
        die "Layout migration produced no staged changes"
    fi

    printf '\nLayout commit changes:\n'
    git -c color.status=always --no-pager status --short --untracked-files=no -- \
        "${LAYOUT_COMMIT_PATHS[@]}"

    log "Creating separate layout commit"
    git commit --only -m "$LAYOUT_COMMIT_MESSAGE" -- "${LAYOUT_COMMIT_PATHS[@]}"
    info "Layout migration commit: $(git rev-parse --short HEAD)"

    PREPARE_RULES_OLD_PATH=""
    RESOLVED_SPEC="$(find_spec "$rules" "$package")"
}

open_layout_fix_shell() {
    local user_shell="${SHELL:-/bin/sh}"

    printf '\nOpening %s in:\n  %s\n' "$user_shell" "$(pwd)"
    printf 'Add or fix packaging files and .gear/rules, then exit the shell.\n\n'
    "$user_shell"
}

ensure_altlinux_layout_interactive() {
    local rules="$1"
    local package="$2"
    local allow_skip="${3:-0}"
    local spec answer

    while true; do
        spec="$(find_spec "$rules" "$package")"
        if validate_altlinux_layout "$rules" "$spec" >/dev/null 2>&1; then
            RESOLVED_SPEC="$spec"
            info "Layout is valid."
            return 0
        fi

        collect_layout_migration_plan "$rules" "$spec" "$package"
        show_layout_migration_plan

        if (( ${#MIGRATION_MISSING[@]} == 0 && ${#MIGRATION_ERRORS[@]} == 0 )); then
            if (( allow_skip )); then
                read -r -p "Choose: [m]ove and commit, [e]dit files in a shell, [r]echeck, [s]kip, [q]uit: " answer
            else
                read -r -p "Choose: [m]ove and commit, [e]dit files in a shell, [r]echeck, [q]uit: " answer
            fi
        else
            if (( allow_skip )); then
                read -r -p "Choose: [e]dit files in a shell, [r]echeck, [s]kip, [q]uit: " answer
            else
                read -r -p "Choose: [e]dit files in a shell, [r]echeck, [q]uit: " answer
            fi
        fi

        case "${answer,,}" in
            m|move)
                if (( ${#MIGRATION_MISSING[@]} > 0 || ${#MIGRATION_ERRORS[@]} > 0 )); then
                    warn "The plan still has unresolved items."
                    continue
                fi
                apply_layout_migration "$rules" "$package"
                return 0
                ;;
            e|edit)
                open_layout_fix_shell
                ;;
            r|recheck|"")
                ;;
            s|skip)
                if (( ! allow_skip )); then
                    printf 'Layout migration cannot be skipped in this mode.\n'
                    continue
                fi
                RESOLVED_SPEC="$spec"
                LAYOUT_MIGRATION_SKIPPED=1
                warn "Skipping packaging layout migration for this update."
                return 0
                ;;
            q|quit)
                printf 'Layout migration cancelled. No automatic moves were made.\n'
                return 1
                ;;
            *)
                if (( allow_skip )); then
                    printf 'Please choose m, e, r, s or q.\n'
                else
                    printf 'Please choose m, e, r or q.\n'
                fi
                ;;
        esac
    done
}

migrate_altlinux_layout() {
    local repo_path="${1:-.}"
    local root package rules

    [[ -d "$repo_path" ]] || die "Repository directory not found: $repo_path"
    root="$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null)" \
        || die "Not a Git repository: $repo_path"
    cd "$root"

    package="$(basename "$root")"
    rules=".gear/rules"
    [[ -f "$rules" ]] || die "$rules not found in $root"

    log "Checking ALT Linux packaging layout"
    PROTECT_LAYOUT_COMMIT=1
    if ! ensure_altlinux_layout_interactive "$rules" "$package"; then
        exit 1
    fi

    info "Spec: $RESOLVED_SPEC"
}

check_altlinux_layout() {
    local repo_path="${1:-.}"
    local root package rules spec

    [[ -d "$repo_path" ]] || die "Repository directory not found: $repo_path"
    root="$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null)" \
        || die "Not a Git repository: $repo_path"
    cd "$root"

    package="$(basename "$root")"
    rules=".gear/rules"
    [[ -f "$rules" ]] || die "$rules not found in $root"
    spec="$(find_spec "$rules" "$package")"

    log "Checking ALT Linux packaging layout"
    validate_altlinux_layout "$rules" "$spec" || exit 1
    info "Layout is valid."
    info "Spec: $spec"
}
