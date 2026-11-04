# shellcheck shell=bash
# SPDX-License-Identifier: MIT

ensure_gitery_repo() {
    local package="$1"
    local remote="gitery:packages/$package"

    log "Checking Gitery repository"
    if git ls-remote "$remote" >/dev/null 2>&1; then
        info "Repository exists: $remote"
        return 0
    fi

    info "Repository is not available yet; creating packages/$package"
    ssh "$GITERY_HOST" init-db "$package" </dev/null

    # Verify after creation so a network/auth error is not silently ignored.
    git ls-remote "$remote" >/dev/null 2>&1 \
        || die "Gitery repository is still unavailable after init-db: $remote"
}

# girar-sh is a restricted command dispatcher, not a POSIX shell: it splits
# on blanks and does not remove quotes or backslash escapes. Pass bare tokens.
# Messages containing spaces must go through stdin (task run -m -).
validate_girar_arguments() {
    local argument quoted
    for argument in "$@"; do
        if [[ -z "$argument" || "$argument" == *[[:space:][:cntrl:]]* ]]; then
            printf -v quoted '%q' "$argument"
            warn "Girar arguments must be nonempty tokens without whitespace/control characters: $quoted"
            return 2
        fi
    done
}

girar_ssh() {
    validate_girar_arguments "$@" || return
    ssh "$GYLE_HOST" "$@"
}

show_girar_run_command() {
    printf "  printf '%%s\\\\n' 'New version' | ssh %q task run -m - %q\n" \
        "$GYLE_HOST" "$1"
}

run_girar_task() {
    log "Running Girar task #$1 (reason: New version)"
    # -m - is supported by Girar and avoids SSH word-splitting of the reason.
    printf '%s\n' 'New version' | girar_ssh task run -m - "$1"
}

# Read the live text output: --json serves asynchronously generated info.json.
# Never eval task show output (tag authors and messages are arbitrary text).
parse_girar_task() {
    "$GEARFLOW_PYTHON" -m gearflow.services parse-task "$1"
}

read_girar_task() {
    local output
    output="$(girar_ssh task show "$1" </dev/null)" || return 1
    printf '%s\n' "$output" | parse_girar_task "$1"
}

# The package endpoint also works before the first build of a task. The task
# dependency endpoint may reject NEW tasks or use their previous iteration.
# Query every root together so RDB can return the combined build order.
query_rebuild_candidates() {
    "$GEARFLOW_PYTHON" -m gearflow.services rebuilds \
        "$RDB_API_URL" "$REBUILD_DEPTH" "$REBUILD_DPTYPE" "$@"
}

scan_task_rebuilds() {
    local task="$1" dry_run="${2:-0}"
    local snapshot refreshed branch="" kind value output package
    local -a roots=() candidates=()
    local -A present=()

    need_cmd ssh
    need_cmd "$GEARFLOW_PYTHON"
    [[ "$task" =~ ^[1-9][0-9]*$ ]] || die "Task number must be a positive integer"
    log "Scanning source builds in Girar task #$task"
    snapshot="$(read_girar_task "$task")" || die "Could not read task #$task"
    while IFS=$'\t' read -r kind value; do
        case "$kind" in
            branch) branch="$value" ;;
            root) roots+=("$value") ;;
            present) present["$value"]=1 ;;
        esac
    done <<< "$snapshot"
    info "Repository: $branch; dependency type: $REBUILD_DPTYPE; depth: $REBUILD_DEPTH"
    if (( ${#roots[@]} == 0 )); then
        info "No source builds to scan (existing rebuilds/copies/removals are excluded)."
        return 0
    fi
    printf 'Source builds: %s\n' "${roots[*]}"
    info "Looking up reverse dependencies in RDB..."
    output="$(query_rebuild_candidates "$branch" "${roots[@]}")" \
        || die "No rebuilds were added. Fix the lookup error and rerun --scan-task $task."
    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        if [[ -z "${present[$package]+exists}" ]]; then
            candidates+=("$package")
            present["$package"]=1
        fi
    done <<< "$output"
    if (( ${#candidates[@]} == 0 )); then
        info "No missing dependent packages; nothing to add."
        return 0
    fi
    printf '\nUnique rebuilds to add (%d), in RDB build order:\n' "${#candidates[@]}"
    printf '  %s\n' "${candidates[@]}"
    if (( dry_run )); then
        info "Dry run: task was not changed or started."
        return 0
    fi
    if ! ask_yes_no "Add these ${#candidates[@]} rebuilds to task #$task"; then
        info "Rebuilds were not added."
        return 0
    fi
    refreshed="$(read_girar_task "$task")" || die "Could not recheck task #$task"
    [[ "$snapshot" == "$refreshed" ]] \
        || die "Task #$task changed during the scan. Rerun --scan-task $task."
    info "Adding ${#candidates[@]} rebuilds in one SSH command."
    if ! girar_ssh task add "$task" rebuild "${candidates[@]}" </dev/null; then
        # Girar processes a rebuild list in order; a failure or lost SSH reply
        # may leave part of it queued. Do not retry the original list blindly.
        warn "Adding rebuilds failed or its result is unknown; some packages may already be queued."
        die "Rerun --scan-task $task; packages already in the task will be skipped."
    fi
    info "Added ${#candidates[@]} unique rebuilds to task #$task."
}

scan_task_mode() {
    local task="${1:-}" dry_run="${2:-0}"
    if [[ -z "$task" ]]; then
        read -r -p "Task number to scan: " task
    fi
    scan_task_rebuilds "$task" "$dry_run"
    if (( ! dry_run )); then
        if ask_yes_no "Run task #$task with reason 'New version'"; then
            run_girar_task "$task"
        else
            info "When ready, run the task with the required reason:"
            show_girar_run_command "$task"
        fi
    fi
}

handle_girar() {
    local package="$1"
    local gear_tag="$2"
    local task subtask
    local add_rebuilds=0

    # Reject unsupported tokens before creating a task on the server.
    validate_girar_arguments "$package" "$gear_tag" "$TARGET_BRANCH" || return

    printf '\n'
    if ask_yes_no "Is this package standalone"; then
        if ask_yes_no "Look up dependent packages for rebuild in the same task"; then
            need_cmd "$GEARFLOW_PYTHON"
            add_rebuilds=1
        fi
        log "Creating standalone task in $TARGET_BRANCH"
        task="$(girar_ssh task new "$TARGET_BRANCH" </dev/null)" \
            || die "Task creation failed; check Girar before retrying submission."
        task="$(trim "$task")"
        [[ "$task" =~ ^[1-9][0-9]*$ ]] \
            || die "Unexpected task creation response; check Girar before retrying."
        info "Created task #$task."
        girar_ssh task add "$task" repo "packages/$package" "$gear_tag" </dev/null \
            || die "Could not add source build to task #$task; check Girar before retrying."
        info "Source build added. Recovery: $SCRIPT_INVOKED_AS --scan-task $task"
        if (( add_rebuilds )); then
            scan_task_rebuilds "$task"
        fi
        run_girar_task "$task"
        return 0
    fi

    while true; do
        read -r -p "Existing task number: " task
        [[ "$task" =~ ^[0-9]+$ ]] && break
        printf 'Task number must be numeric.\n'
    done

    while true; do
        read -r -p "Subtask number (leave empty if not needed): " subtask
        [[ -z "$subtask" || "$subtask" =~ ^[0-9]+$ ]] && break
        printf 'Subtask number must be numeric or empty.\n'
    done

    log "Adding package to Girar task"
    if [[ -n "$subtask" ]]; then
        info "ssh $GYLE_HOST task add $task $subtask repo $package $gear_tag"
        girar_ssh task add "$task" "$subtask" repo "$package" "$gear_tag" </dev/null
    else
        info "ssh $GYLE_HOST task add $task repo $package $gear_tag"
        girar_ssh task add "$task" repo "$package" "$gear_tag" </dev/null
    fi
    info "When ready, run the task with reason 'New version':"
    show_girar_run_command "$task"
}
