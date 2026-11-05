# shellcheck shell=bash
# SPDX-License-Identifier: MIT

# Progress is one value in the repository's existing local Git configuration.
# The legacy path is read/removed only to migrate progress from the prior version.
legacy_resume_state_path() {
    git rev-parse --git-path gear-update-upstream.state
}

resume_state_exists() {
    git config --local --get gear-update-upstream.resume >/dev/null 2>&1 || \
        [[ -f "$(legacy_resume_state_path)" ]]
}

remove_resume_state() {
    if git config --local --get gear-update-upstream.resume >/dev/null 2>&1; then
        git config --local --unset-all gear-update-upstream.resume
    fi
    rm -f -- "$(legacy_resume_state_path)"
    clear_gitery_only_intent
}

clear_gitery_only_intent() {
    if git config --local --get gearflow.gitery-only >/dev/null 2>&1; then
        git config --local --unset-all gearflow.gitery-only
    fi
}

resume_fields() {
    printf '%s\n' stage package version release upstream-tag upstream-commit branch \
        head tag-mode old-template new-template layout-skipped gear-tag
}

resume_variables() {
    printf '%s\n' RESUME_STAGE RESUME_PACKAGE RESUME_VERSION RESUME_RELEASE \
        RESUME_UPSTREAM_TAG RESUME_UPSTREAM_COMMIT RESUME_BRANCH RESUME_HEAD \
        TAG_SCHEME_CHANGE_MODE TAG_SCHEME_OLD_TEMPLATE TAG_SCHEME_NEW_TEMPLATE \
        LAYOUT_MIGRATION_SKIPPED RESUME_GEAR_TAG
}

save_resume_state() {
    local LC_ALL=C
    local payload='v1;' variable value
    while IFS= read -r variable; do
        value="${!variable}"
        payload+="${#value}:$value"
    done < <(resume_variables)
    git config --local --replace-all gear-update-upstream.resume "$payload"
    # Remove a previous-version checkpoint only after saving it successfully.
    rm -f -- "$(legacy_resume_state_path)"
}

load_resume_state() {
    local LC_ALL=C
    local payload value variable length state i
    local config_key="${1:-gear-update-upstream.resume}"
    local -a fields=() variables=()
    mapfile -t variables < <(resume_variables)
    if payload="$(git config --local --get "$config_key")"; then
        [[ "$payload" == 'v1;'* ]] || die "Unsupported resume-state format in Git config"
        payload="${payload#v1;}"
        for variable in "${variables[@]}"; do
            [[ "$payload" == *:* ]] || die "Incomplete resume state: $variable"
            length="${payload%%:*}"
            [[ "$length" =~ ^(0|[1-9][0-9]{0,7})$ ]] || die "Invalid resume-state length"
            payload="${payload#*:}"
            (( ${#payload} >= length )) || die "Truncated resume state: $variable"
            value="${payload:0:length}"
            payload="${payload:length}"
            printf -v "$variable" '%s' "$value"
        done
        [[ -z "$payload" ]] || die "Unexpected trailing resume-state data"
    else
        state="$(legacy_resume_state_path)"
        [[ -f "$state" ]] || die "No saved update. For an already merged tag, use --resume-after-merge."
        [[ "$(git config --file "$state" --get resume.schema)" == 1 ]] \
            || die "Unsupported legacy resume-state format"
        mapfile -t fields < <(resume_fields)
        for (( i = 0; i < ${#fields[@]}; i++ )); do
            value="$(git config --file "$state" --get "resume.${fields[i]}")" \
                || die "Incomplete legacy resume state: ${fields[i]}"
            printf -v "${variables[i]}" '%s' "$value"
        done
    fi
    case "$RESUME_STAGE" in
        merge|rules|spec|tags|build|commit|tag|push-branch|push-tag|girar|girar-pending|gitery-done|done) ;;
        *) die "Unknown saved stage: $RESUME_STAGE" ;;
    esac
    case "$TAG_SCHEME_CHANGE_MODE" in none|auto|edit) ;; *) die "Invalid saved tag mode" ;; esac
    [[ "$LAYOUT_MIGRATION_SKIPPED" == 0 || "$LAYOUT_MIGRATION_SKIPPED" == 1 ]] \
        || die "Invalid saved layout setting"
    rpm_version_is_valid "$RESUME_VERSION" || die "Invalid saved Version"
    [[ -n "$RESUME_RELEASE" && "$RESUME_RELEASE" != *'%'* ]] || die "Invalid saved Release"
    [[ "$RESUME_HEAD" =~ ^[0-9a-f]{40,64}$ && "$RESUME_UPSTREAM_COMMIT" =~ ^[0-9a-f]{40,64}$ ]] \
        || die "Invalid saved commit IDs"
    # Status remains read-only; migration is done when the update actually resumes.
}

advance_resume_stage() {
    RESUME_STAGE="$1"
    RESUME_HEAD="$(git rev-parse HEAD)"
    save_resume_state
}

open_resume_repository() {
    local repo_path="${1:-.}" root
    need_cmd git
    root="$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null)" \
        || die "Not a Git repository: $repo_path"
    cd "$root"
}

declare -ar UPDATE_PROGRESS_STAGES=(
    merge rules spec tags build commit tag push-branch push-tag girar
)
declare -ar UPDATE_PROGRESS_LABELS=(
    "Merge upstream tag"
    "Update source tag in gear rules"
    "Update spec and changelog"
    "Refresh stored gear tags"
    "Test build and user confirmation"
    "Create packaging commit"
    "Create signed gear tag"
    "Push branch to Gitery"
    "Push gear tag to Gitery"
    "Submit package to Girar"
)

update_progress_index() {
    local stage="${RESUME_STAGE}" i
    if [[ "$stage" == done ]]; then
        printf '%d\n' "${#UPDATE_PROGRESS_STAGES[@]}"
        return
    fi
    if [[ "$stage" == gitery-done ]]; then
        printf '9\n'
        return
    fi
    [[ "$stage" != girar-pending ]] || stage=girar
    for (( i = 0; i < ${#UPDATE_PROGRESS_STAGES[@]}; i++ )); do
        if [[ "${UPDATE_PROGRESS_STAGES[i]}" == "$stage" ]]; then
            printf '%d\n' "$i"
            return
        fi
    done
    die "Unknown progress stage: $stage"
}

show_update_progress() {
    local index total i status last_update=0
    open_resume_repository "${1:-.}"
    if resume_state_exists; then
        load_resume_state
    elif git config --local --get gear-update-upstream.last-update >/dev/null 2>&1; then
        load_resume_state gear-update-upstream.last-update
        last_update=1
    else
        info "No saved update progress in this repository."
        info "For an already completed upstream merge, use --resume-after-merge."
        return 0
    fi
    index="$(update_progress_index)"
    total="${#UPDATE_PROGRESS_STAGES[@]}"
    [[ "$RESUME_STAGE" != gitery-done ]] || total=9
    (( ! last_update )) || printf 'Last update:\n'
    printf 'Repository: %s\nPackage:    %s\nVersion:    %s-%s\nUpstream:   %s\n' \
        "$(pwd)" "$RESUME_PACKAGE" "$RESUME_VERSION" "$RESUME_RELEASE" "$RESUME_UPSTREAM_TAG"
    printf '\nProgress: %d/%d\n\n' "$index" "$total"
    for (( i = 0; i < total; i++ )); do
        if (( i < index )); then
            status=done
        elif (( i == index )); then
            if [[ "$RESUME_STAGE" == girar-pending ]]; then
                status=check
            else
                status=current
            fi
        else
            status=pending
        fi
        printf '  %2d. [%-7s] %s\n' "$((i + 1))" "$status" "${UPDATE_PROGRESS_LABELS[i]}"
    done
    if [[ "$RESUME_STAGE" == gitery-done ]]; then
        printf '\nPublished to Gitery only. Girar submission was not requested.\n'
    elif [[ "$RESUME_STAGE" == girar-pending ]]; then
        printf '\nGirar submission result is unknown. Check Girar before retrying.\n'
    elif (( index < total )); then
        printf '\nContinue with: %s --resume %q\n' "$SCRIPT_INVOKED_AS" "$(pwd)"
    fi
}

show_resume_status() {
    open_resume_repository "${1:-.}"
    load_resume_state
    printf 'Repository: %s\nPackage:    %s\nVersion:    %s-%s\nUpstream:   %s\nNext stage: %s\n' \
        "$(pwd)" "$RESUME_PACKAGE" "$RESUME_VERSION" "$RESUME_RELEASE" \
        "$RESUME_UPSTREAM_TAG" "$RESUME_STAGE"
}

clear_resume_state() {
    open_resume_repository "${1:-.}"
    if ! resume_state_exists; then
        info "No saved update."
        return 0
    fi
    if ask_yes_no "Forget saved progress (keep all repository changes)"; then
        remove_resume_state
        info "Saved progress removed."
    fi
}

initialize_resume_state() {
    clear_gitery_only_intent
    RESUME_STAGE="$1"
    RESUME_PACKAGE="$2"
    RESUME_VERSION="$3"
    RESUME_RELEASE="$4"
    RESUME_UPSTREAM_TAG="$5"
    RESUME_UPSTREAM_COMMIT="$(git rev-parse --verify "refs/tags/$RESUME_UPSTREAM_TAG^{commit}")"
    RESUME_BRANCH="$TARGET_BRANCH"
    RESUME_HEAD="$(git rev-parse HEAD)"
    RESUME_GEAR_TAG=""
    save_resume_state
}

# A spec update can complete just before its checkpoint is written.
# Inspect only the newest changelog entry to avoid duplicating that entry.
resume_spec_update_is_applied() {
    local spec="$1"
    [[ "$(trim "$(read_spec_field "$spec" Version)")" == "$RESUME_VERSION" ]] || return 1
    [[ "$(trim "$(read_spec_field "$spec" Release)")" == "$RESUME_RELEASE" ]] || return 1
    awk -v vr="$RESUME_VERSION-$RESUME_RELEASE" \
        -v message="- Automatically updated to $RESUME_VERSION." '
        /^[[:space:]]*%changelog([[:space:]]|$)/ { changelog = 1; next }
        changelog && /^\*/ {
            if (entry++) exit
            header_ok = substr($0, length($0) - length(vr) + 1) == vr
            next
        }
        changelog && entry && header_ok && $0 == message { found = 1 }
        END { exit !found }
    ' "$spec"
}

check_resume_spec() {
    local spec="$1"
    [[ "$(trim "$(read_spec_field "$spec" Version)")" == "$RESUME_VERSION" && \
       "$(trim "$(read_spec_field "$spec" Release)")" == "$RESUME_RELEASE" ]] \
        || die "Spec Version/Release differs from saved $RESUME_VERSION-$RESUME_RELEASE. Fix it before --resume."
}

check_resume_metadata() {
    local rules=.gear/rules spec
    spec="$(find_spec "$rules" "$RESUME_PACKAGE")"
    check_resume_spec "$spec"
    if (( ! LAYOUT_MIGRATION_SKIPPED )); then
        validate_altlinux_layout "$rules" "$spec" || return 1
    fi
    # A standalone publication can use gear rules without an upstream tag.
    [[ -n "$RESUME_UPSTREAM_TAG" ]] || return 0
    resolve_gear_source_tag "$rules" "$(resume_spec_name "$spec")" "$RESUME_VERSION"
    [[ "$RESOLVED_GEAR_SOURCE_TAG" == "$RESUME_UPSTREAM_TAG" ]] \
        || die "Gear rules do not match the saved upstream tag. Update rules before continuing this stage."
}
