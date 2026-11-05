# shellcheck shell=bash
# SPDX-License-Identifier: MIT

git_http() {
    GIT_HTTP_LOW_SPEED_LIMIT="$LOW_SPEED_LIMIT" \
    GIT_HTTP_LOW_SPEED_TIME="$LOW_SPEED_TIME" \
        git "$@"
}

clone_gear_repo() {
    local url="$1"
    local dir="$2"

    while true; do
        info "Slow-transfer guard: abort below $((LOW_SPEED_LIMIT / 1024)) KiB/s for ${LOW_SPEED_TIME}s"

        # We only work with sisyphus, so do not fetch unrelated remote
        # branches during the initial clone.
        if git_http clone --single-branch --branch "$TARGET_BRANCH" "$url" "$dir"; then
            return 0
        fi

        warn "Clone failed or the HTTP transfer stayed below the configured speed limit."

        # The directory did not exist before clone_gear_repo() was called, so a
        # partial clone created by the failed attempt is safe to remove.
        rm -rf -- "$dir"

        if ! ask_yes_no "Retry cloning $url"; then
            die "Clone cancelled"
        fi
    done
}

load_upstream_tags() {
    local output

    while true; do
        # ls-remote downloads refs only; it does not download repository
        # history/objects.
        if output="$(git_http ls-remote --tags --refs upstream)"; then
            mapfile -t UPSTREAM_TAGS < <(
                printf '%s\n' "$output" |
                    awk '{sub(/^refs\/tags\//, "", $2); print $2}' |
                    sort -Vu
            )

            (( ${#UPSTREAM_TAGS[@]} > 0 )) || die "No tags found in upstream repository"
            return 0
        fi

        warn "Could not read upstream tags, or the HTTP connection was too slow."
        if ! ask_yes_no "Retry checking upstream tags"; then
            die "Upstream tag check cancelled"
        fi
    done
}

fetch_upstream_tag() {
    local tag="$1"

    log "Fetching selected upstream tag: $tag"
    info "Only this release tag and the objects required for it will be fetched."
    info "Slow-transfer guard: abort below $((LOW_SPEED_LIMIT / 1024)) KiB/s for ${LOW_SPEED_TIME}s"

    while true; do
        if git_http fetch --no-tags upstream \
            "+refs/tags/$tag:refs/tags/$tag"; then
            return 0
        fi

        warn "Fetching tag '$tag' failed or the HTTP transfer was too slow."
        if ! ask_yes_no "Retry fetching $tag"; then
            die "Upstream fetch cancelled"
        fi
    done
}

working_tree_clean_except_backups() {
    local record status path old_path
    local -a build_logs=()
    mapfile -d '' -t build_logs < <(git config --null --get-all gearflow.build-log || true)

    while IFS= read -r -d '' record; do
        status="${record:0:2}"
        path="${record:3}"
        old_path=""

        # Porcelain -z writes the second path of a rename/copy as the next NUL
        # record.  Consume it so it is not mistaken for a status record.
        if [[ "$status" == *R* || "$status" == *C* ]]; then
            IFS= read -r -d '' old_path || true
        fi

        if [[ "$path" == *~ && ( -z "$old_path" || "$old_path" == *~ ) ]]; then
            continue
        fi
        if [[ "$status" == '??' ]]; then
            if array_contains "$path" "${build_logs[@]}" || array_contains "$(pwd -P)/$path" "${build_logs[@]}"; then
                continue
            fi
        fi
        return 1
    done < <(git status --porcelain=v1 -z --untracked-files=all)

    return 0
}

save_upstream_remote() {
    local url="$1"
    local remotes_file=".gear/upstream/remotes"

    if [[ ! -e "$remotes_file" ]]; then
        info "$remotes_file is absent; leaving it absent."
        return 0
    fi

    [[ -f "$remotes_file" ]] || die "$remotes_file is not a regular file"
    git config -f "$remotes_file" --replace-all remote.upstream.url "$url"
    git config -f "$remotes_file" --replace-all remote.upstream.fetch \
        '+refs/heads/*:refs/remotes/upstream/*'
    info "Saved upstream remote: $remotes_file"
}
