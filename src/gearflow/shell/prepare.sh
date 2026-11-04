# shellcheck shell=bash
# SPDX-License-Identifier: MIT

clone_package_for_preparation() {
    local url="$1"
    local directory="$2"

    while true; do
        info "Slow-transfer guard: abort below $((LOW_SPEED_LIMIT / 1024)) KiB/s for ${LOW_SPEED_TIME}s"
        if git_http clone "$url" "$directory"; then
            return 0
        fi

        warn "Clone failed or the HTTP transfer stayed below the configured speed limit."
        rm -rf -- "$directory"
        ask_yes_no "Retry cloning $url" || die "Clone cancelled"
    done
}

commit_preparation_changes() {
    local message="$1"
    local no_changes_message="$2"

    if git diff-index --cached --quiet HEAD --; then
        info "$no_changes_message"
        return 0
    fi

    git commit -m "$message"
}

remove_import_info_metadata() {
    local file
    local -a spec_files=()
    local -a rules_files=()

    log "Removing import.info metadata"

    if [[ -f import.info ]]; then
        git rm -f -- import.info
    fi

    mapfile -d '' -t spec_files < <(
        find . -maxdepth 3 -type f -name '*.spec' \
            ! -path './.git/*' ! -name '*~' -print0
    )
    for file in "${spec_files[@]}"; do
        rewrite_file_in_memory "$file" sed -E \
            '/^[[:space:]]*Source[0-9]*[[:space:]]*:[[:space:]]*import\.info([[:space:]]|$)/d'
        if (( FILE_REWRITE_CHANGED )); then
            git add -- "$file"
        fi
    done

    if [[ -f .gear/rules ]]; then
        rules_files=(".gear/rules")
    else
        mapfile -d '' -t rules_files < <(
            find . -type f -name rules ! -path './.git/*' ! -name '*~' -print0
        )
    fi

    for file in "${rules_files[@]}"; do
        rewrite_file_in_memory "$file" sed -E \
            '/^[[:space:]]*copy[[:space:]]*:[[:space:]]*\*\.info([[:space:]]|$)/d'
        if (( FILE_REWRITE_CHANGED )); then
            git add -- "$file"
        fi
    done

    commit_preparation_changes "Removed import.info" "No import.info changes to commit."
}

ensure_prepare_rules_file() {
    local candidate
    local -a candidates=()

    PREPARE_RULES_OLD_PATH=""
    if [[ -f .gear/rules ]]; then
        return 0
    fi

    mapfile -d '' -t candidates < <(
        find . -type f -name rules ! -path './.git/*' ! -name '*~' -print0
    )

    mkdir -p .gear
    case "${#candidates[@]}" in
        0)
            : > .gear/rules
            ;;
        1)
            candidate="${candidates[0]#./}"
            PREPARE_RULES_OLD_PATH="$candidate"
            mv -- "$candidate" .gear/rules
            info "Rules file: $candidate -> .gear/rules"
            ;;
        *)
            printf 'Several rules files were found:\n' >&2
            printf '  %s\n' "${candidates[@]}" >&2
            die "Cannot choose the main rules file automatically"
            ;;
    esac
}

normalize_prepare_spec_rule() {
    local rules="$1"
    local target_spec="$2"

    rewrite_file_in_memory "$rules" awk -v spec_line="spec: $target_spec" '
        /^[[:space:]]*spec[[:space:]]*:/ {
            next
        }
        {
            print
        }
        !inserted && /^[[:space:]]*tar([.][^:[:space:]]+)?[?]?[[:space:]]*:/ {
            print spec_line
            inserted = 1
        }
        END {
            if (!inserted) {
                print spec_line
            }
        }
    '
}

commit_remaining_layout_changes() {
    local rules="$1"

    git add -A -- "$rules" altlinux
    if [[ -n "$PREPARE_RULES_OLD_PATH" && -n "$(git ls-files -- "$PREPARE_RULES_OLD_PATH")" ]]; then
        git add -A -- "$PREPARE_RULES_OLD_PATH"
    fi
    unstage_backup_files

    if git diff-index --cached --quiet HEAD --; then
        return 0
    fi

    printf '\nLayout commit changes:\n'
    git -c color.status=always --no-pager status --short --untracked-files=no
    git commit -m "$LAYOUT_COMMIT_MESSAGE"
    PREPARE_RULES_OLD_PATH=""
}

remove_old_source_directories() {
    local directory
    local -a directories=()

    mapfile -d '' -t directories < <(
        find . -mindepth 1 -maxdepth 1 -type d \
            ! -name .git ! -name .gear ! -name altlinux -print0 |
            sort -z
    )

    if (( ${#directories[@]} == 0 )); then
        info "No old source directories found."
        return 0
    fi

    printf '\nOld source directories found:\n'
    printf '  %s\n' "${directories[@]#./}"

    for directory in "${directories[@]}"; do
        directory="${directory#./}"
        if ask_yes_no "Delete '$directory'"; then
            if [[ -n "$(git ls-files -- "$directory")" ]]; then
                git rm -r -f -- "$directory"
            else
                rm -rf -- "$directory"
            fi
        else
            info "Skipped '$directory'"
        fi
    done

    commit_preparation_changes "Removed old sources" "No old source changes to commit."
}

prepare_package() {
    local repo_url="${1:-}"
    local repo_dir root package rules spec spec_name target_spec

    if [[ -z "$repo_url" ]] && git rev-parse --show-toplevel >/dev/null 2>&1; then
        repo_url=.
    elif [[ -z "$repo_url" ]]; then
        read -r -p "Gear repository URL: " repo_url
    fi
    repo_url="$(trim "$repo_url")"
    [[ -n "$repo_url" ]] || die "Repository URL is empty"

    if [[ -d "$repo_url" ]]; then
        root="$(git -C "$repo_url" rev-parse --show-toplevel 2>/dev/null)" \
            || die "Not a Git working directory: $repo_url"
        cd "$root"
        log "Preparing existing repository: $root"
    else
    case "$repo_url" in
        *://*|*:* ) ;;
        *) die "Repository directory not found: $repo_url" ;;
    esac
    repo_url="${repo_url%/}"
    repo_dir="$(basename "$repo_url" .git)"
    [[ -n "$repo_dir" && "$repo_dir" != "." && "$repo_dir" != "/" ]] \
        || die "Cannot determine repository directory name"
    [[ ! -e "$repo_dir" ]] || die "Directory '$repo_dir' already exists"

    log "Cloning gear repository for preparation"
    clone_package_for_preparation "$repo_url" "$repo_dir"
    cd "$repo_dir"
    fi
    package="$(basename "$(pwd)")"

    # Preparation creates several commits; reject unsafe local states before
    # deleting import.info or modifying any packaging files.
    [[ -n "$(git branch --show-current)" ]] \
        || die "Detached HEAD: create a branch first (for example: git switch -c prepare-package), then rerun --prepare-package"
    git rev-parse --verify HEAD >/dev/null 2>&1 \
        || die "Package preparation requires an existing commit"
    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        die "Finish or abort the current merge before --prepare-package"
    fi
    working_tree_clean_except_backups \
        || die "--prepare-package requires a clean working tree and index; commit or stash existing changes first"
    spec="$(find_spec .gear/rules "$package")"

    remove_import_info_metadata
    ensure_prepare_rules_file

    rules=".gear/rules"
    spec="$(find_spec "$rules" "$package")"
    spec_name="$(basename "$spec")"
    target_spec="altlinux/$spec_name"
    normalize_prepare_spec_rule "$rules" "$target_spec"

    log "Moving packaging files to altlinux/"
    if ! ensure_altlinux_layout_interactive "$rules" "$package"; then
        die "Package preparation stopped during layout migration"
    fi
    commit_remaining_layout_changes "$rules"

    working_tree_clean_except_backups \
        || die "Unexpected changes remain after layout migration: $(pwd)"

    log "Removing old source directories"
    remove_old_source_directories

    printf '\nPackage preparation completed.\n'
    info "Repository: $(pwd)"
    info "Spec:       $(find_spec "$rules" "$package")"
}
