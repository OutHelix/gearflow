# shellcheck shell=bash
# SPDX-License-Identifier: MIT

publish_gitery_only() {
    local repo_path="${1:-.}" root package spec version release head name
    need_cmd git
    root="$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null)" \
        || die "Not a Git repository: $repo_path"
    cd "$root"
    [[ -z "$(git diff --name-only --diff-filter=U)" ]] || die "Resolve merge conflicts before publishing"
    ! git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
        || die "Finish the upstream merge before publishing"

    if resume_state_exists; then
        load_resume_state
        TARGET_BRANCH="$RESUME_BRANCH"
        case "$RESUME_STAGE" in
            build|commit|tag|push-branch|push-tag|girar) ;;
            *) die "Cannot publish at stage '$RESUME_STAGE'; finish preparation first or check the previous Girar submission" ;;
        esac
    else
        package="$(basename "$root")"
        [[ -f .gear/rules ]] || die ".gear/rules not found"
        spec="$(find_spec .gear/rules "$package")"
        name="$(trim "$(read_spec_field "$spec" Name || true)")"
        [[ -z "$name" || "$name" == *'%'* ]] || package="$name"
        [[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9+_.-]*$ ]] || die "Cannot determine the package name"
        version="$(trim "$(read_spec_field "$spec" Version || true)")"
        release="$(trim "$(read_spec_field "$spec" Release || true)")"
        rpm_version_is_valid "$version" || die "Invalid package Version"
        [[ "$release" =~ ^[A-Za-z0-9][A-Za-z0-9._+~]*$ ]] || die "Invalid package Release"
        validate_altlinux_layout .gear/rules "$spec" || return 1
        [[ "$(git branch --show-current)" == "$TARGET_BRANCH" ]] \
            || die "Publish requires branch '$TARGET_BRANCH'"

        "$GEARFLOW_PYTHON" -m gearflow.services stage
        git diff --cached --quiet -- && die "No packaging changes to publish"
        head="$(git rev-parse --verify HEAD)" || die "An initial Git commit is required before publication"
        # Initial builds have no selected upstream tag. Use the same checkpoint
        # schema, with Gitery-only intent saved separately before any commit.
        RESUME_STAGE=commit
        RESUME_PACKAGE="$package"
        RESUME_VERSION="$version"
        RESUME_RELEASE="$release"
        RESUME_UPSTREAM_TAG=""
        RESUME_UPSTREAM_COMMIT="$head"
        RESUME_BRANCH="$TARGET_BRANCH"
        RESUME_HEAD="$head"
        RESUME_GEAR_TAG=""
        TAG_SCHEME_CHANGE_MODE=none
        TAG_SCHEME_OLD_TEMPLATE=""
        TAG_SCHEME_NEW_TEMPLATE=""
        LAYOUT_MIGRATION_SKIPPED=0
        git config --local --replace-all gearflow.gitery-only true
        save_resume_state
    fi

    [[ "$(git branch --show-current)" == "$RESUME_BRANCH" ]] || die "Publish requires branch '$RESUME_BRANCH'"
    case "$RESUME_STAGE" in
        build|commit)
            check_resume_metadata
            "$GEARFLOW_PYTHON" -m gearflow.services stage
            if [[ "$RESUME_STAGE" == build ]]; then
                [[ "$(git rev-parse HEAD)" == "$RESUME_HEAD" ]] || die "HEAD changed since preparation"
                git diff --cached --quiet -- && die "No packaging changes to publish"
            fi
            ;;
        *) working_tree_clean_except_backups || die "Uncommitted changes appeared after gear-commit" ;;
    esac
    # This survives failed tag creation/push and is honored by ordinary resume.
    git config --local --replace-all gearflow.gitery-only true
    [[ "$RESUME_STAGE" != build ]] || advance_resume_stage commit
    run_saved_update
}
