# shellcheck shell=bash
# SPDX-License-Identifier: MIT

show_help() {
    local program="${GEARFLOW_PROGRAM:-gearflow}"

    cat <<EOF
Usage:
  $program [ALT-gear-repository-URL]
  $program --prepare-package [DIR|URL]
  $program --check-layout [DIR]
  $program --migrate-layout [DIR]
  $program --resume [DIR]
  $program --resume-after-merge [DIR]
  $program --resume-status [DIR]
  $program --progress [DIR]
  $program --clear-resume [DIR]
  $program --continue [DIR]
  $program --continue-update [DIR]
  $program --continue-fix [DIR]
  $program --scan-task [TASK] [--dry-run]
  $program --version
  $program -h|--help

Update an ALT Linux gear package from an upstream Git tag.
With no arguments, offer to update a clean released package in the current
repository; otherwise prompt for an ALT gear repository URL.

Options:
  --prepare-package [DIR|URL]
      Prepare the current/local repository or clone a URL: remove import.info,
      move packaging files to altlinux/, and optionally delete old source
      directories. Preparation changes are committed separately.
  --check-layout [DIR]
      Check the packaging layout without changing files.
  --migrate-layout [DIR]
      Interactively move packaging files to altlinux/ and commit the migration.
  --resume [DIR]
      Continue a saved upstream update from its next unfinished stage. Preserve
      the selected version/tag, planned rules changes, Release and branch.
  --resume-after-merge [DIR]
      Adopt a completed manual merge or an update started with an older script.
      Prompt for the merged local upstream tag, package Version and next step:
      rules, spec/changelog, stored tags, or build. Later use --resume.
  --resume-status [DIR]
      Show saved package, version, upstream tag and next stage without changes.
  --progress [DIR]
      Show all ten update stages with done/current/pending status.
      Read-only; no build tools needed. Without an active update, show
      the most recent saved result, if available.
  --clear-resume [DIR]
      Ask to forget saved progress; keep commits and all working-tree changes.
  --continue [DIR]
      If saved progress exists, behave like --resume. Otherwise resume the
      build and finalization stages using the spec's current Version
      and Release. Detect update mode when Version differs from HEAD;
      otherwise use package-fix mode.
  --continue-update [DIR]
      With saved progress, behave like --resume. Otherwise force update mode
      and refresh stored gear tags before building.
  --continue-fix [DIR]
      With saved progress, behave like --resume. Otherwise force package-fix
      mode and leave stored gear tags unchanged.
  --scan-task [TASK] [--dry-run]
      Read the task directly from Girar and query RDB reverse dependencies for
      all its source builds (gear and SRPM). Prompt for TASK when omitted.
      Add each missing source package once, keeping RDB build order. Exclude
      existing builds/rebuilds/copies/removals; existing rebuilds are not roots.
      Submit the whole rebuild list with one task add / SSH command.
      Show the plan and ask before adding, then offer to run with the fixed
      reason "New version". --dry-run only displays the plan.
      Requires only Bash, ssh and Python; works outside a package repository.
      For unbuilt gear subtasks, use the repository basename until Girar knows
      the SRPM name. If they differ, build the task once and scan again.
  --version
      Show the installed version without checking build tools.
  -h, --help
      Show this help and exit without checking build tools or changing files.

DIR defaults to the current repository. New updates save progress in the local
Git configuration (gear-update-upstream.resume) after fetching the selected tag
and before merging it. No separate progress or text-buffer files are created.
With no arguments in a repository that has saved progress, resume that update.
Active saved progress is removed after successful completion. The final
snapshot is retained in Git config (gear-update-upstream.last-update) so
--progress can show the result. Normal execution prints action names without
additional stage counters or percentages.

After merge conflicts: resolve conflicts, stage the resolutions, finish
"git commit --no-edit", then run --resume. It updates rules/spec/changelog
before building. No upstream tag listing or fetch is repeated.

Completed stages are skipped. An interrupted build is rerun, and failed pushes
can be retried. Spec/rules transformations are held in memory, and the automatic
changelog entry is not duplicated. Existing packaging commits and signed gear
tags are reused. On add_changelog failure, original spec contents are restored.
If Girar submission was interrupted, check Girar and choose whether it already
succeeded or needs to be retried; submission is never silently repeated.

Resume requires the saved branch and unchanged history, except for finishing
the expected upstream merge or packaging commit. Keep packaging fixes
uncommitted before the final gear-commit. Without saved progress, the legacy
--continue modes only build/finalize; edit metadata yourself first.

Update workflow:
  Check/migrate layout -> select upstream version/tag -> fetch and merge tag
  -> update rules/spec/changelog -> gear-store-tags -> stage changes and build
  -> user confirmation -> gear-commit -> signed gear tag -> push to Gitery
  -> standalone Girar build or add to an existing task.

Standalone submission offers to add dependent rebuilds before starting the
task. It always uses task new -> task add (source and optional rebuilds)
-> task run; ssh build is never used. RDB is queried against its target branch,
with build and runtime reverse dependencies at depth 1 by default.
This is a repository-based rebuild plan,
not an ABI comparison against newly built task binaries. New source packages
absent from RDB cause an explicit error, not an empty "successful" scan.
If interrupted while adding rebuilds, rerun --scan-task TASK: packages already
present are skipped and existing rebuilds do not expand the scan recursively.
Girar requires the reason when running the task, not when adding a rebuild.
All task run commands here pass "New version" through stdin with -m -.
If starting later manually, use the printed command with that same reason.

Environment variables (defaults):
  TARGET_BRANCH           sisyphus
  GITERY_HOST             gitery (SSH host used by init-db)
  GYLE_HOST               gyle
  RDB_API_URL             https://rdb.altlinux.org/api
  REBUILD_DEPTH           1 (positive integer; RDB enforces its depth limit)
  REBUILD_DPTYPE          both (source, binary or both)
  RELEASE                 alt1 (new upstream updates only)
  RECENT_TAGS             15
  LOW_SPEED_LIMIT         65536 bytes/second (HTTP Git transfers)
  LOW_SPEED_TIME          60 seconds
  LAYOUT_COMMIT_MESSAGE   Moved packaging files to altlinux directory

Gitery repository URLs use gitery:packages/<package>.
The HTTP slow-transfer guard aborts transfers below LOW_SPEED_LIMIT for
LOW_SPEED_TIME seconds; the script then offers a retry.

Examples:
  $program
  $program https://git.altlinux.org/gears/m/maven.git
  $program --prepare-package ./maven
  $program --check-layout ./maven
  $program --migrate-layout ./maven
  $program --resume ./maven
  $program --resume-after-merge ./maven
  $program --resume-status ./maven
  $program --progress ./maven
  $program --continue ./maven
  $program --continue-update ./maven
  $program --continue-fix ./maven
  $program --scan-task 123456 --dry-run
  $program --scan-task 123456
  RELEASE=alt2 $program
EOF
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        show_help
        return 0
    fi

    case "${1:-}" in
        --prepare-package|--check-layout|--migrate-layout|--resume|--resume-after-merge|--resume-status|--progress|--clear-resume|--continue|--continue-update|--continue-fix|--scan-task) ;;
        -*) printf 'ERROR: Unknown option: %s. See %s --help.\n' "$1" "${GEARFLOW_PROGRAM:-gearflow}" >&2; return 2 ;;
    esac

    printf "%s: started\n" "${GEARFLOW_PROGRAM:-gearflow}"

    SCRIPT_INVOKED_AS="${GEARFLOW_COMMAND:-gearflow}"
    export SCRIPT_INVOKED_AS

    if [[ "${1:-}" == "--scan-task" ]]; then
        shift
        local scan_task="" scan_dry_run=0
        while (( $# )); do
            case "$1" in
                --dry-run) scan_dry_run=1 ;;
                [1-9]*)
                    [[ -z "$scan_task" && "$1" =~ ^[1-9][0-9]*$ ]] \
                        || die "Usage: ${GEARFLOW_PROGRAM:-gearflow} --scan-task [TASK] [--dry-run]"
                    scan_task="$1"
                    ;;
                *) die "Usage: ${GEARFLOW_PROGRAM:-gearflow} --scan-task [TASK] [--dry-run]" ;;
            esac
            shift
        done
        scan_task_mode "$scan_task" "$scan_dry_run"
        return
    fi

    case "${1:-}" in
        --resume|--resume-after-merge|--resume-status|--progress|--clear-resume)
            (( $# <= 2 )) || die "Usage: ${GEARFLOW_PROGRAM:-gearflow} $1 [repository-directory]"
            case "$1" in
                --resume) resume_update "${2:-.}" ;;
                --resume-after-merge) resume_after_merge "${2:-.}" ;;
                --resume-status) show_resume_status "${2:-.}" ;;
                --progress) show_update_progress "${2:-.}" ;;
                --clear-resume) clear_resume_state "${2:-.}" ;;
            esac
            return
            ;;
    esac

    if [[ "${1:-}" == "--prepare-package" ]]; then
        (( $# <= 2 )) || die "Usage: ${GEARFLOW_PROGRAM:-gearflow} --prepare-package [repository-directory|gear-repository-URL]"
        need_cmd git
        need_cmd sed
        need_cmd awk
        need_cmd find
        need_cmd sort
        prepare_package "${2:-}"
        return
    fi

    if [[ "${1:-}" == "--continue" || "${1:-}" == "--continue-update" || "${1:-}" == "--continue-fix" ]]; then
        (( $# <= 2 )) || die "Usage: ${GEARFLOW_PROGRAM:-gearflow} --continue [repository-directory]"
        case "$1" in
            --continue) continue_update "${2:-.}" auto ;;
            --continue-update) continue_update "${2:-.}" update ;;
            --continue-fix) continue_update "${2:-.}" fix ;;
        esac
        return
    fi

    if [[ "${1:-}" == "--check-layout" ]]; then
        (( $# <= 2 )) || die "Usage: ${GEARFLOW_PROGRAM:-gearflow} --check-layout [repository-directory]"
        need_cmd git
        check_altlinux_layout "${2:-.}"
        return
    fi

    if [[ "${1:-}" == "--migrate-layout" ]]; then
        (( $# <= 2 )) || die "Usage: ${GEARFLOW_PROGRAM:-gearflow} --migrate-layout [repository-directory]"
        need_cmd git
        migrate_altlinux_layout "${2:-.}"
        return
    fi

    local gear_url="${1:-}"
    local package workdir rules spec vcs_url spec_name current_version
    local upstream_tag version candidate gear_source_tag
    local use_current_repo=0 detected="" detected_spec="" detected_version="" detected_release="" detected_tag=""
    LAYOUT_MIGRATION_SKIPPED=0
    local -a templates=()
    local -a upstream_tags=()

    if (( $# > 1 )); then
        die "Usage: ${GEARFLOW_PROGRAM:-gearflow} [ALT gear repository URL]"
    fi

    check_common_commands

    # With no URL, prefer the current directory when it is a clean released
    # gear package.  This makes `gear-update-upstream` useful directly from a
    # package checkout while keeping the old URL/clone workflow as fallback.
    if [[ -z "$gear_url" ]]; then
        if git rev-parse --show-toplevel >/dev/null 2>&1; then
            if resume_state_exists; then
                info "Saved upstream-update progress found in the current repository."
                resume_update .
                return
            fi
        fi
        detected="$(detect_current_release_repo || true)"
        if [[ -n "$detected" ]]; then
            IFS=$'\t' read -r workdir package detected_spec detected_version detected_release detected_tag <<< "$detected"

            printf '\nDetected released gear package in the current repository:\n'
            info "Package: $package"
            info "Version: $detected_version"
            info "Release tag: $detected_tag"

            if ask_yes_no "Update package $package"; then
                use_current_repo=1
            else
                printf 'Cancelled.\n'
                return 0
            fi
        else
            read -r -p "ALT gear repository URL: " gear_url
        fi
    fi

    if (( use_current_repo )); then
        cd "$workdir"
        info "Using current repository: $workdir"
    else
        gear_url="$(trim "$gear_url")"
        [[ -n "$gear_url" ]] || die "Repository URL is empty"

        package="$(basename "${gear_url%/}")"
        package="${package%.git}"
        [[ -n "$package" ]] || die "Cannot determine package name from: $gear_url"
        workdir="$package"

        if [[ -e "$workdir" ]]; then
            [[ -d "$workdir/.git" ]] || die "$workdir already exists and is not a Git repository"
            log "Using existing clone: $workdir"
        else
            log "Cloning ALT gear repository"
            clone_gear_repo "$gear_url" "$workdir"
        fi

        cd "$workdir"

        if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
            git switch "$TARGET_BRANCH" >/dev/null
        elif git show-ref --verify --quiet "refs/remotes/origin/$TARGET_BRANCH"; then
            git switch -c "$TARGET_BRANCH" --track "origin/$TARGET_BRANCH" >/dev/null
        else
            die "Branch '$TARGET_BRANCH' not found"
        fi
    fi

    ! resume_state_exists \
        || die "Saved update exists here. Use --resume, or --clear-resume to forget its progress."

    working_tree_clean_except_backups || die "Working tree is not clean: $(pwd)"

    rules=".gear/rules"
    [[ -f "$rules" ]] || die "$rules not found"

    log "Checking ALT Linux packaging layout"
    if ! ensure_altlinux_layout_interactive "$rules" "$package" 1; then
        exit 1
    fi
    spec="$RESOLVED_SPEC"

    # The optional edit shell may have left unrelated changes behind.  Do not
    # let them leak into the upstream update commit.
    working_tree_clean_except_backups \
        || die "Working tree is not clean after layout migration: $(pwd)"

    vcs_url="$(read_vcs_url "$spec")"
    spec_name="$(read_spec_field "$spec" 'Name' || true)"
    spec_name="$(trim "$spec_name")"
    [[ -n "$spec_name" && "$spec_name" != *'%'* ]] || spec_name="$package"
    current_version="$(read_spec_field "$spec" 'Version' || true)"
    current_version="$(trim "$current_version")"

    log "Package data"
    info "Package:         $package"
    info "Spec:            $spec"
    info "Current version: ${current_version:-unknown}"
    info "Vcs:             $vcs_url"

    log "Configuring upstream remote"
    if git remote get-url upstream >/dev/null 2>&1; then
        git remote set-url upstream "$vcs_url"
    else
        git remote add upstream "$vcs_url"
    fi
    info "upstream -> $vcs_url"
    save_upstream_remote "$vcs_url"

    log "Checking upstream tags"
    declare -a UPSTREAM_TAGS=()
    load_upstream_tags
    upstream_tags=("${UPSTREAM_TAGS[@]}")
    inferred_upstream_template=""
    if inferred_upstream_template="$(
        infer_upstream_version_template "$current_version" "${upstream_tags[@]}"
    )"; then
        :
    else
        inferred_upstream_template=""
    fi

    show_recent_tags "$rules" "$spec_name" "$inferred_upstream_template" "${upstream_tags[@]}"

    read_version_or_tag
    version="$SELECTED_PACKAGE_VERSION"

    # .gear/rules describes the exact source tag gear expects.  This script no
    # longer creates local tag aliases, so a renamed upstream tag requires the
    # rules template to be updated as part of the package update.
    resolve_gear_source_tag "$rules" "$spec_name" "$version"
    gear_source_tag="$RESOLVED_GEAR_SOURCE_TAG"

    upstream_tag="$ENTERED_UPSTREAM_TAG"

    # Best case: upstream uses exactly the same tag name as gear rules.
    if [[ -z "$upstream_tag" ]] && \
        tag_exists_upstream "$gear_source_tag" "${upstream_tags[@]}"; then
        upstream_tag="$gear_source_tag"
    fi

    # Otherwise use the upstream naming scheme inferred from the current
    # package version (for example docx4j-parent-@version@).
    if [[ -z "$upstream_tag" && -n "$inferred_upstream_template" ]]; then
        candidate="$(expand_version_template "$inferred_upstream_template" "$version")"
        if tag_exists_upstream "$candidate" "${upstream_tags[@]}"; then
            upstream_tag="$candidate"
        fi
    fi

    # Last safe fallback: if exactly one upstream tag ends in the exact version,
    # use it.  Never silently pick between several candidates.
    if [[ -z "$upstream_tag" ]]; then
        mapfile -t version_candidates < <(
            printf '%s\n' "${upstream_tags[@]}" |
            awk -v v="$version" '
                $0 == v { print; next }
                length($0) > length(v) &&
                substr($0, length($0)-length(v)+1) == v {
                    p = substr($0, 1, length($0)-length(v))
                    if (p !~ /[0-9]$/) print
                }
            ' |
            sort -Vu
        )

        if (( ${#version_candidates[@]} == 1 )); then
            upstream_tag="${version_candidates[0]}"
        elif (( ${#version_candidates[@]} > 1 )); then
            choose_upstream_tag_interactively "$version" "${version_candidates[@]}"
            upstream_tag="$SELECTED_UPSTREAM_TAG"
        fi
    fi

    if [[ -z "$upstream_tag" ]]; then
        choose_upstream_tag_interactively "$version"
        upstream_tag="$SELECTED_UPSTREAM_TAG"
    fi

    # If upstream renamed its release tags, choose how .gear/rules will be
    # updated after the merge.  The rules change stays uncommitted so it is
    # included in the normal final gear-commit with the spec update.
    plan_tag_scheme_change "$rules" "$spec_name" "$version" "$upstream_tag"

    info "Selected version:    $version"
    info "Upstream tag:        $upstream_tag"
    if [[ "$TAG_SCHEME_CHANGE_MODE" == none ]]; then
        info "Gear source tag:     $gear_source_tag"
    else
        info "Gear rules update:   planned after merge"
    fi

    fetch_upstream_tag "$upstream_tag"

    initialize_resume_state merge "$package" "$version" "$RELEASE" "$upstream_tag"
    run_saved_update

}
