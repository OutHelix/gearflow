# shellcheck shell=bash
# SPDX-License-Identifier: MIT

# Detect whether the current directory is already a clean released gear package.
# A repository is considered safe for in-place update when:
#   * it is on the target branch;
#   * .gear/rules and the main spec are present;
#   * the working tree is clean;
#   * the spec's <Version>-<Release> gear tag exists and points to HEAD.
#
# On success prints: <repo-root>\t<package>\t<spec>\t<version>\t<release>\t<tag>
detect_current_release_repo() {
    local root data

    root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1

    data="$(
        cd "$root" || exit 1

        [[ -f .gear/rules ]] || exit 1
        [[ "$(git branch --show-current)" == "$TARGET_BRANCH" ]] || exit 1
        working_tree_clean_except_backups || exit 1

        local package spec version release expected_tag tag_commit head_commit
        package="$(basename "$root")"
        spec="$(find_spec .gear/rules "$package" 2>/dev/null)" || exit 1

        version="$(read_spec_field "$spec" 'Version' || true)"
        version="$(trim "$version")"
        release="$(read_spec_field "$spec" 'Release' || true)"
        release="$(trim "$release")"

        [[ -n "$version" && -n "$release" ]] || exit 1
        [[ "$version" != *'%'* && "$release" != *'%'* ]] || exit 1

        expected_tag="${version}-${release}"
        git show-ref --verify --quiet "refs/tags/$expected_tag" || exit 1

        tag_commit="$(git rev-list -n1 "$expected_tag")" || exit 1
        head_commit="$(git rev-parse HEAD)" || exit 1
        [[ "$tag_commit" == "$head_commit" ]] || exit 1

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$root" "$package" "$spec" "$version" "$release" "$expected_tag"
    )" || return 1

    [[ -n "$data" ]] || return 1
    printf '%s\n' "$data"
}

check_common_commands() {
    need_cmd git
    need_cmd ssh
    need_cmd gear
    need_cmd hsh
    need_cmd gear-store-tags
    need_cmd gear-commit
    need_cmd gear-create-tag
    need_cmd add_changelog
}

check_continue_commands() {
    need_cmd git
    need_cmd ssh
    need_cmd gear
    need_cmd hsh
    need_cmd gear-commit
    need_cmd gear-create-tag
}

run_test_build() {
    local build_rc=0

    log "Staging current changes"

    # Stage everything first.  Then remove editor backup files from the
    # index by their exact paths.  This also fixes backup files that may have
    # been staged by an older version of this script.
    git add -A

    local backup
    local -a ignored_backups=()

    while IFS= read -r -d '' backup; do
        [[ "$backup" == *~ ]] || continue
        ignored_backups+=("$backup")
        # `git reset HEAD -- <path>` removes both newly-added and modified
        # backup files from the index while keeping the file on disk.
        git reset -q HEAD -- "$backup" 2>/dev/null || true
    done < <(git diff --cached --name-only -z)

    # Also report untracked backup files which never entered the index.
    while IFS= read -r -d '' backup; do
        backup="${backup#./}"
        [[ " ${ignored_backups[*]-} " == *" $backup "* ]] || ignored_backups+=("$backup")
    done < <(find . -type f -name '*~' -print0 2>/dev/null)

    if (( ${#ignored_backups[@]} > 0 )); then
        printf '\nIgnored editor backup files:\n'
        printf '  %s\n' "${ignored_backups[@]}"
    fi

    printf '\nStaged changes:\n'
    # Colorize like normal `git status`, but do not show untracked backup
    # files.  --no-pager guarantees that no `less` screen is opened.
    git -c color.status=always --no-pager status --short --untracked-files=no

    log "Test build"
    info "gear --commit --hasher -- hsh --no-sisyphus-check=gpg -v --mountpoints=/proc"
    set +e
    gear --commit --hasher -- hsh --no-sisyphus-check=gpg -v --mountpoints=/proc
    build_rc=$?
    set -e

    printf '\nBuild command exit code: %d\n' "$build_rc"
    if (( build_rc == 0 )); then
        info "Build command completed successfully."
    else
        warn "Build command failed. Fix the package manually if needed."
    fi

    ask_yes_no "Did the package build successfully; continue"
}

finish_update() {
    local package="$1"
    local version="$2"
    local release="${3:-$RELEASE}"
    local gear_tag expected_gear_tag tag
    local -a before_tags=() new_tags=()

    # gear-commit needs something staged to commit.  This also catches the case
    # where the user accidentally committed the update manually before --continue.
    if git diff-index --cached --quiet HEAD --; then
        die "There are no staged changes for gear-commit. --continue expects the update/fixes to remain uncommitted."
    fi

    log "Creating gear commit"
    gear-commit --no-edit

    mapfile -t before_tags < <(git tag)

    log "Creating signed gear tag"
    gear-create-tag

    expected_gear_tag="${version}-${release}"
    if git show-ref --verify --quiet "refs/tags/$expected_gear_tag"; then
        gear_tag="$expected_gear_tag"
    else
        while IFS= read -r tag; do
            array_contains "$tag" "${before_tags[@]}" || new_tags+=("$tag")
        done < <(git tag)
        if (( ${#new_tags[@]} == 1 )); then
            gear_tag="${new_tags[0]}"
        else
            printf 'Tags created by gear-create-tag:\n' >&2
            printf '  %s\n' "${new_tags[@]:-<none>}" >&2
            die "Cannot determine newly created gear tag"
        fi
    fi
    info "Gear tag: $gear_tag"

    ensure_gitery_repo "$package"

    log "Switching origin to Gitery"
    if git remote get-url origin >/dev/null 2>&1; then
        git remote set-url origin "gitery:packages/$package"
    else
        git remote add origin "gitery:packages/$package"
    fi
    info "origin -> gitery:packages/$package"

    log "Pushing sisyphus branch and gear tag"
    git push -u origin "$TARGET_BRANCH"
    git push origin "$gear_tag"

    handle_girar "$package" "$gear_tag"

    printf '\nDone.\n'
    printf 'Package: %s\n' "$package"
    printf 'Version: %s\n' "$version"
    printf 'Tag:     %s\n' "$gear_tag"
}

continue_update() {
    need_cmd git
    local repo_path="${1:-.}"
    local requested_mode="${2:-auto}"
    local root package rules spec version release committed_version branch continuation_mode

    [[ -d "$repo_path" ]] || die "Repository directory not found: $repo_path"
    root="$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null)" \
        || die "Not a Git repository: $repo_path"
    cd "$root"

    if resume_state_exists; then
        info "Saved upstream-update progress found; continuing from its saved stage."
        load_resume_state
        save_resume_state
        run_saved_update
        return
    fi
    check_continue_commands

    package="$(basename "$root")"
    rules=".gear/rules"
    [[ -f "$rules" ]] || die "$rules not found in $root"
    spec="$(find_spec "$rules" "$package")"

    log "Checking ALT Linux packaging layout"
    if validate_altlinux_layout "$rules" "$spec"; then
        info "Layout is valid."
    else
        while true; do
            read -r -p "Choose: [s]kip layout check and continue, [q]uit: " answer
            case "${answer,,}" in
                s|skip)
                    warn "Continuing with the legacy packaging layout."
                    break
                    ;;
                q|quit|"")
                    exit 1
                    ;;
                *)
                    printf 'Please choose s or q.\n'
                    ;;
            esac
        done
    fi

    version="$(read_spec_field "$spec" 'Version' || true)"
    version="$(trim "$version")"
    [[ -n "$version" ]] || die "Cannot read Version from $spec"

    release="$(read_spec_field "$spec" 'Release' || true)"
    release="$(trim "$release")"
    [[ -n "$release" ]] || die "Cannot read Release from $spec"

    case "$requested_mode" in
        auto)
            committed_version="$(read_committed_spec_field "$spec" 'Version' || true)"
            committed_version="$(trim "$committed_version")"
            if [[ -n "$committed_version" && "$committed_version" != "$version" ]]; then
                continuation_mode=update
            else
                continuation_mode=fix
            fi
            ;;
        update|fix)
            continuation_mode="$requested_mode"
            ;;
        *)
            die "Unknown continuation mode: $requested_mode"
            ;;
    esac

    branch="$(git branch --show-current)"
    [[ "$branch" == "$TARGET_BRANCH" ]] \
        || die "--continue must be run on branch '$TARGET_BRANCH' (current: ${branch:-detached HEAD})"

    if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
        die "Unresolved merge conflicts remain. Resolve and stage them before --continue."
    fi

    # If a merge conflict was resolved manually but MERGE_HEAD still exists,
    # Git has not finished the upstream merge yet.  Do not hide that state.
    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        die "A merge is still in progress. Finish it with 'git commit --no-edit' first, then run --continue again."
    fi

    if [[ "$continuation_mode" == update ]]; then
        log "Continuing upstream update"
        info "Mode:       upstream update"
        [[ "$requested_mode" != auto ]] || info "Detected:   Version ${committed_version:-unknown} -> $version"
    else
        log "Finalizing package fix"
        info "Mode:       package fix"
        [[ "$requested_mode" != auto ]] || info "Detected:   Version unchanged (${committed_version:-$version})"
    fi
    info "Repository: $root"
    info "Package:    $package"
    info "Spec:       $spec"
    info "Version:    $version"
    info "Release:    $release"

    if [[ "$continuation_mode" == update ]]; then
        need_cmd gear-store-tags
        log "Refreshing stored gear tags"
        gear-store-tags -acv
    else
        info "Stored gear tags are unchanged in package-fix mode."
    fi

    if ! run_test_build; then
        printf '\nStopped before gear-commit. Your repository and fixes are preserved at:\n  %s\n' "$root"
        printf '\nFix the package and run the same stage again:\n'
        printf '  %s --continue %q\n' "$SCRIPT_INVOKED_AS" "$root"
        exit 1
    fi

    finish_update "$package" "$version" "$release"
}
