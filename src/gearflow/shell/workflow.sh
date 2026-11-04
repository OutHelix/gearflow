# shellcheck shell=bash
# SPDX-License-Identifier: MIT

run_saved_update() {
    local rules=.gear/rules spec current_head parent answer tag_commit
    TARGET_BRANCH="$RESUME_BRANCH"
    RELEASE="$RESUME_RELEASE"
    [[ "$(git branch --show-current)" == "$TARGET_BRANCH" ]] \
        || die "Resume requires branch '$TARGET_BRANCH'"
    [[ -z "$(git diff --name-only --diff-filter=U)" ]] \
        || die "Resolve and stage the merge conflicts, finish 'git commit --no-edit', then run --resume."
    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        die "Finish the current merge with 'git commit --no-edit', then run --resume."
    fi
    tag_commit="$(git rev-parse --verify "refs/tags/$RESUME_UPSTREAM_TAG^{commit}")" \
        || die "Saved upstream tag is missing: $RESUME_UPSTREAM_TAG"
    [[ "$tag_commit" == "$RESUME_UPSTREAM_COMMIT" ]] || die "Saved upstream tag has moved"

    log "Resuming update at stage: $RESUME_STAGE"
    info "Package: $RESUME_PACKAGE $RESUME_VERSION-$RESUME_RELEASE"
    info "Upstream tag: $RESUME_UPSTREAM_TAG"

    while true; do
        current_head="$(git rev-parse HEAD)"
        # Allow only the two expected manual/interrupted commits: the upstream
        # merge and the final packaging commit. Other history changes need review.
        if [[ "$current_head" != "$RESUME_HEAD" ]]; then
            case "$RESUME_STAGE" in
                merge)
                    git merge-base --is-ancestor "$RESUME_HEAD" HEAD && \
                        git merge-base --is-ancestor "$RESUME_UPSTREAM_COMMIT" HEAD \
                        || die "HEAD changed without the expected upstream merge"
                    ;;
                commit)
                    parent="$(git rev-parse HEAD^)"
                    [[ "$parent" == "$RESUME_HEAD" ]] && working_tree_clean_except_backups \
                        || die "HEAD changed unexpectedly before the packaging commit checkpoint"
                    spec="$(find_spec "$rules" "$RESUME_PACKAGE")"
                    check_resume_metadata
                    info "Packaging commit already exists; resuming tag creation."
                    advance_resume_stage tag
                    continue
                    ;;
                *) die "HEAD changed since the saved stage. Saved: $RESUME_HEAD; current: $current_head" ;;
            esac
        fi

        case "$RESUME_STAGE" in
            merge)
                if ! git merge-base --is-ancestor "$RESUME_UPSTREAM_COMMIT" HEAD; then
                    log "Merging upstream tag: $RESUME_UPSTREAM_TAG"
                    if ! git merge --no-edit "$RESUME_UPSTREAM_TAG"; then
                        printf '\nResolve conflicts, stage the resolutions, and finish the merge:\n'
                        printf '  git commit --no-edit\n'
                        printf 'Then resume the saved update:\n  %s --resume %q\n' "$SCRIPT_INVOKED_AS" "$(pwd)"
                        return 1
                    fi
                else
                    info "Upstream tag is already merged."
                fi
                advance_resume_stage rules
                ;;
            rules)
                [[ -f "$rules" ]] || die "$rules disappeared after merge"
                spec="$(find_spec "$rules" "$RESUME_PACKAGE")"
                if (( ! LAYOUT_MIGRATION_SKIPPED )); then
                    validate_altlinux_layout "$rules" "$spec" || return 1
                fi
                resolve_gear_source_tag "$rules" "$(resume_spec_name "$spec")" "$RESUME_VERSION"
                if [[ "$RESOLVED_GEAR_SOURCE_TAG" != "$RESUME_UPSTREAM_TAG" ]]; then
                    apply_planned_tag_scheme_change "$rules" "$(resume_spec_name "$spec")" \
                        "$RESUME_VERSION" "$RESUME_UPSTREAM_TAG"
                else
                    info "Gear rules already refer to the selected source tag."
                fi
                advance_resume_stage spec
                ;;
            spec)
                spec="$(find_spec "$rules" "$RESUME_PACKAGE")"
                if (( ! LAYOUT_MIGRATION_SKIPPED )); then
                    validate_altlinux_layout "$rules" "$spec" || return 1
                fi
                if resume_spec_update_is_applied "$spec"; then
                    info "Spec and automatic changelog entry are already updated."
                else
                    need_cmd add_changelog
                    log "Updating spec and changelog"
                    update_spec "$spec" "$RESUME_VERSION"
                fi
                advance_resume_stage tags
                ;;
            tags)
                spec="$(find_spec "$rules" "$RESUME_PACKAGE")"
                check_resume_spec "$spec"
                resolve_gear_source_tag "$rules" "$(resume_spec_name "$spec")" "$RESUME_VERSION"
                [[ "$RESOLVED_GEAR_SOURCE_TAG" == "$RESUME_UPSTREAM_TAG" ]] \
                    || die "Gear rules do not match the saved upstream tag"
                need_cmd gear-store-tags
                log "Updating stored gear tags"
                gear-store-tags -acv
                advance_resume_stage build
                ;;
            build)
                check_resume_metadata
                need_cmd gear
                need_cmd hsh
                spec="$(find_spec "$rules" "$RESUME_PACKAGE")"
                check_resume_spec "$spec"
                if ! run_test_build; then
                    printf '\nChanges and progress are preserved. Fix the package, then run:\n'
                    printf '  %s --resume %q\n' "$SCRIPT_INVOKED_AS" "$(pwd)"
                    return 1
                fi
                advance_resume_stage commit
                ;;
            commit)
                check_resume_metadata
                need_cmd gear-commit
                spec="$(find_spec "$rules" "$RESUME_PACKAGE")"
                check_resume_spec "$spec"
                git diff-index --cached --quiet HEAD -- \
                    && die "No staged packaging changes to commit"
                log "Creating gear commit"
                gear-commit --no-edit
                advance_resume_stage tag
                ;;
            tag)
                RESUME_GEAR_TAG="$RESUME_VERSION-$RESUME_RELEASE"
                if ! git show-ref --verify --quiet "refs/tags/$RESUME_GEAR_TAG"; then
                    need_cmd gear-create-tag
                    log "Creating signed gear tag"
                    gear-create-tag
                fi
                [[ "$(git rev-parse --verify "refs/tags/$RESUME_GEAR_TAG^{commit}")" == "$RESUME_HEAD" ]] \
                    || die "Expected gear tag '$RESUME_GEAR_TAG' does not point to the packaging commit"
                [[ "$(git cat-file -t "refs/tags/$RESUME_GEAR_TAG")" == tag ]] \
                    || die "Gear tag must be an annotated signed tag"
                git cat-file tag "refs/tags/$RESUME_GEAR_TAG" | \
                    grep -Eq '^-----BEGIN (PGP SIGNATURE|SSH SIGNATURE|SIGNED MESSAGE)-----$' \
                    || die "Gear tag has no signature"
                advance_resume_stage push-branch
                ;;
            push-branch|push-tag)
                working_tree_clean_except_backups || die "Uncommitted changes appeared after gear-commit"
                [[ "$(git rev-parse --verify "refs/tags/$RESUME_GEAR_TAG^{commit}")" == "$RESUME_HEAD" ]] \
                    || die "Saved gear tag has moved"
                need_cmd ssh
                ensure_gitery_repo "$RESUME_PACKAGE"
                if git remote get-url origin >/dev/null 2>&1; then
                    git remote set-url origin "gitery:packages/$RESUME_PACKAGE"
                else
                    git remote add origin "gitery:packages/$RESUME_PACKAGE"
                fi
                if [[ "$RESUME_STAGE" == push-branch ]]; then
                    log "Pushing branch: $TARGET_BRANCH"
                    git push -u origin "$TARGET_BRANCH"
                    advance_resume_stage push-tag
                else
                    log "Pushing gear tag: $RESUME_GEAR_TAG"
                    git push origin "$RESUME_GEAR_TAG"
                    advance_resume_stage girar
                fi
                ;;
            girar)
                need_cmd ssh
                # SSH may submit a task and lose its response. Save this marker
                # BEFORE submission so a retry never silently creates a duplicate.
                advance_resume_stage girar-pending
                handle_girar "$RESUME_PACKAGE" "$RESUME_GEAR_TAG"
                advance_resume_stage done
                ;;
            girar-pending)
                warn "The previous Girar step was interrupted; its submission result is unknown."
                info "To reuse an empty task, choose retry, answer no to standalone and enter its task number."
                info "For an existing task with unfinished rebuilds, use --scan-task TASK first."
                while true; do
                    read -r -p "Check Girar, then choose: [d]already submitted, [r]retry submission, [q]uit: " answer
                    case "${answer,,}" in
                        d|done) advance_resume_stage done; break ;;
                        r|retry) advance_resume_stage girar; break ;;
                        q|quit|"") return 1 ;;
                        *) printf 'Please choose d, r or q.\n' ;;
                    esac
                done
                ;;
            done)
                printf '\nDone.\nPackage: %s\nVersion: %s\nTag:     %s\n' \
                    "$RESUME_PACKAGE" "$RESUME_VERSION" "$RESUME_GEAR_TAG"
                git config --local --replace-all gear-update-upstream.last-update \
                    "$(git config --local --get gear-update-upstream.resume)"
                remove_resume_state
                return 0
                ;;
        esac
    done
}

resume_spec_name() {
    local name
    name="$(trim "$(read_spec_field "$1" Name || true)")"
    [[ -n "$name" && "$name" != *'%'* ]] || name="$RESUME_PACKAGE"
    printf '%s\n' "$name"
}

resume_update() {
    open_resume_repository "${1:-.}"
    load_resume_state
    save_resume_state
    run_saved_update
}

# Bootstrap progress for a merge performed manually or with an older script.
resume_after_merge() {
    local package rules=.gear/rules spec tag version detected release stage answer
    open_resume_repository "${1:-.}"
    ! resume_state_exists || die "Saved progress exists; use --resume instead"
    [[ "$(git branch --show-current)" == "$TARGET_BRANCH" ]] || die "Use branch '$TARGET_BRANCH'"
    [[ -z "$(git diff --name-only --diff-filter=U)" ]] || die "Resolve the merge conflicts first"
    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        die "Finish the merge with 'git commit --no-edit' first"
    fi
    package="$(basename "$(pwd)")"
    spec="$(find_spec "$rules" "$package")"
    printf '\nLast commit:\n'
    git --no-pager log -1 --format='%h %s'
    while true; do
        read -r -p "Already merged upstream tag (exact local tag name): " tag
        tag="$(trim "$tag")"
        if git rev-parse --verify "refs/tags/$tag^{commit}" >/dev/null 2>&1 && \
            git merge-base --is-ancestor "refs/tags/$tag^{commit}" HEAD; then
            break
        fi
        printf 'That local tag is missing or has not been merged into HEAD.\n'
    done
    detected="$(extract_rpm_version_from_tag "$tag" || true)"
    while true; do
        read -r -p "New package Version [${detected:-enter explicitly}]: " version
        version="$(trim "${version:-$detected}")"
        rpm_version_is_valid "$version" && break
        printf 'Enter a valid RPM Version.\n'
    done
    if [[ "$(trim "$(read_spec_field "$spec" Version)")" == "$version" ]]; then
        release="$(trim "$(read_spec_field "$spec" Release)")"
    else
        release="$RELEASE"
    fi
    [[ -n "$release" && "$release" != *'%'* ]] || die "Cannot determine Release"
    LAYOUT_MIGRATION_SKIPPED=0
    if ! validate_altlinux_layout "$rules" "$spec"; then
        ask_yes_no "Skip the layout check for this update" || return 1
        LAYOUT_MIGRATION_SKIPPED=1
    fi
    resolve_gear_source_tag "$rules" "$(resume_spec_name_for_package "$spec" "$package")" "$version"
    plan_tag_scheme_change "$rules" "$(resume_spec_name_for_package "$spec" "$package")" "$version" "$tag"
    printf '\nChoose the NEXT step that still needs to run:\n'
    printf '  r: update source tag in rules, then spec/changelog, tags and build\n'
    printf '  s: rules already updated; update spec/changelog, tags and build\n'
    printf '  t: rules and spec/changelog already updated; refresh tags and build\n'
    printf '  b: all metadata already updated; rerun build and finalize\n'
    while true; do
        read -r -p "Next step [r/s/t/b, default r; q to quit]: " answer
        case "${answer,,}" in
            r|rules|"") stage=rules; break ;;
            s|spec) stage=spec; break ;;
            t|tags) stage=tags; break ;;
            b|build) stage=build; break ;;
            q|quit) return 1 ;;
            *) printf 'Please choose r, s, t, b or q.\n' ;;
        esac
    done
    initialize_resume_state "$stage" "$package" "$version" "$release" "$tag"
    run_saved_update
}

resume_spec_name_for_package() {
    local RESUME_PACKAGE="$2"
    resume_spec_name "$1"
}
