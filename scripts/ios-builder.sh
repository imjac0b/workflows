#!/usr/bin/env bash

set -euo pipefail

readonly WORKER_ROOT="${GITHUB_WORKSPACE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly TEMP_ROOT="${RUNNER_TEMP:?RUNNER_TEMP is required}"
readonly CONTROL_DIR="$TEMP_ROOT/control"
readonly SOURCE_DIR="$TEMP_ROOT/src"
readonly CONFIG_PATH="$TEMP_ROOT/config.json"
readonly OUTPUT_DIR="$TEMP_ROOT/output"
readonly DERIVED_DATA_DIR="$TEMP_ROOT/derived-data"
readonly GIT_CONFIG_PATH="$TEMP_ROOT/gitconfig"
readonly BUNDLE_ROOT="$TEMP_ROOT/bundle"

# The worker is thrown away with the job, so nothing survives on disk: what carries a build's
# products to the next build is the workflow, which restores this directory before the build
# and saves it after. Everything cacheable lives under one root so the workflow needs one path
# and one key, and finalize leaves it alone -- it is saved before finalize runs.
readonly CACHE_ROOT="${IOS_CI_CACHE_ROOT:-$TEMP_ROOT/cache}"

fail() {
    printf '%s\n' "${1:-Build failed.}" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Prepare failed."
}

require_runtime_paths() {
    [[ -n "${IOS_CI_CONFIG:-}" ]] || fail "Build failed."
    [[ -n "${IOS_CI_SOURCE:-}" ]] || fail "Build failed."
    [[ -n "${IOS_CI_OUTPUT:-}" ]] || fail "Build failed."
    [[ -f "$IOS_CI_CONFIG" ]] || fail "Build failed."
    [[ -d "$IOS_CI_SOURCE" ]] || fail "Build failed."
}

configure_private_git() {
    local token="$1"

    export GIT_TERMINAL_PROMPT=0
    export GIT_CONFIG_NOSYSTEM=1
    rm -f "$GIT_CONFIG_PATH"
    git config --file "$GIT_CONFIG_PATH" --add credential.helper ""
    git config --file "$GIT_CONFIG_PATH" --add \
        "url.https://x-access-token:${token}@github.com/.insteadOf" \
        "https://github.com/"
    git config --file "$GIT_CONFIG_PATH" --add \
        "url.https://x-access-token:${token}@github.com/.insteadOf" \
        "git@github.com:"
    export GIT_CONFIG_GLOBAL="$GIT_CONFIG_PATH"
}

mask_config_values() {
    jq -r '
        del(.ci)
        | ..
        | strings
        | select(length >= 3)
        | select(contains("\n") | not)
        | select(contains("\r") | not)
    ' "$CONFIG_PATH" 2>/dev/null | while IFS= read -r value; do
        printf '::add-mask::%s\n' "$value"
    done
}

mask_provision_values() {
    local value
    local field
    local -a fields

    for value in "$@"; do
        IFS=',' read -r -a fields <<< "$value"
        for field in "${fields[@]}"; do
            if [[ ${#field} -ge 3 ]]; then
                printf '::add-mask::%s\n' "$field"
            fi
        done
    done
}

forget_changelog_reference() {
    local scratch="$CONFIG_PATH.next"

    jq 'del(.ci.previous_sha)' "$CONFIG_PATH" > "$scratch" || return 1
    chmod 600 "$scratch"
    mv "$scratch" "$CONFIG_PATH"
}

# The source is fetched at a single commit, so the commits a changelog should list are not
# in the clone yet. Deepen the history until it reaches the reference point recorded for this
# job -- the previously published commit for a branch build, the base branch head for a pull
# request -- and drop the reference when it is unreachable, which leaves the changelog to fall
# back to recent history instead of failing a build over it.
resolve_changelog_history() {
    local source_sha="$1"
    local previous
    local round

    previous="$(jq -r '.ci.previous_sha // empty' "$CONFIG_PATH")" || return 1
    [[ -n "$previous" ]] || return 0

    if git -C "$SOURCE_DIR" fetch --quiet --no-tags --depth=1 origin "$previous" >/dev/null 2>&1; then
        for round in 1 2 3 4; do
            git -C "$SOURCE_DIR" merge-base "$previous" HEAD >/dev/null 2>&1 && return 0
            [[ "$(git -C "$SOURCE_DIR" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]] || break
            git -C "$SOURCE_DIR" fetch --quiet --no-tags --deepen=250 origin "$source_sha" "$previous" \
                >/dev/null 2>&1 || break
        done
        git -C "$SOURCE_DIR" merge-base "$previous" HEAD >/dev/null 2>&1 && return 0
    fi

    forget_changelog_reference
}

write_runtime_environment() {
    {
        printf 'IOS_CI_CONFIG=%s\n' "$CONFIG_PATH"
        printf 'IOS_CI_SOURCE=%s\n' "$SOURCE_DIR"
        printf 'IOS_CI_OUTPUT=%s\n' "$OUTPUT_DIR"
        printf 'IOS_CI_DERIVED_DATA=%s\n' "$DERIVED_DATA_DIR"
        printf 'GIT_CONFIG_GLOBAL=%s\n' "$GIT_CONFIG_PATH"
        printf 'GIT_CONFIG_NOSYSTEM=1\n'
        printf 'GIT_TERMINAL_PROMPT=0\n'
    } >> "${GITHUB_ENV:?GITHUB_ENV is required}"
}

prepare() {
    require_command git
    require_command jq

    local job_id="${IOS_CI_JOB_ID:-}"
    local control_repo="${CI_CONTROL_REPO:-}"
    local control_branch="${CI_CONTROL_BRANCH:-main}"
    local jobs_path="${CI_CONTROL_JOBS_PATH:-jobs}"
    local control_url
    local job_file
    local source_repo
    local source_sha
    local prepare_stage="input validation"

    [[ "$job_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || fail "Prepare failed at ${prepare_stage}."
    [[ "$control_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Prepare failed at ${prepare_stage}."
    [[ "$control_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "Prepare failed at ${prepare_stage}."
    [[ "$jobs_path" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "Prepare failed at ${prepare_stage}."
    [[ "$jobs_path" != *..* ]] || fail "Prepare failed at ${prepare_stage}."
    [[ -n "${GITHUB_PAT:-}" ]] || fail "Prepare failed at ${prepare_stage}."

    configure_private_git "$GITHUB_PAT"
    control_url="https://x-access-token:${GITHUB_PAT}@github.com/${control_repo}.git"

    prepare_stage="control workspace"
    rm -rf "$CONTROL_DIR" "$SOURCE_DIR" "$OUTPUT_DIR" "$DERIVED_DATA_DIR"
    mkdir -p "$CONTROL_DIR" "$SOURCE_DIR" "$OUTPUT_DIR" "$DERIVED_DATA_DIR" || fail "Prepare failed at ${prepare_stage}."

    prepare_stage="control repository fetch"
    git init -q "$CONTROL_DIR" || fail "Prepare failed at ${prepare_stage}."
    git -C "$CONTROL_DIR" remote add origin "$control_url" >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."
    if ! git -C "$CONTROL_DIR" fetch --quiet --no-tags --depth=1 origin "$control_branch" >"$TEMP_ROOT/control-fetch.log" 2>&1; then
        sed -E 's#(https://x-access-token:)[^@]+@#\1***@#g' "$TEMP_ROOT/control-fetch.log" | tail -n 20 >&2 || true
        fail "Prepare failed at ${prepare_stage}."
    fi
    git -C "$CONTROL_DIR" checkout --quiet --detach FETCH_HEAD >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."

    prepare_stage="queued job lookup"
    job_file="$CONTROL_DIR/$jobs_path/$job_id.json"
    [[ -f "$job_file" ]] || fail "Prepare failed at ${prepare_stage}."

    prepare_stage="queued job validation"
    jq -e '
        (.source.repository | type == "string" and length > 0)
        and (.source.sha | type == "string" and test("^[0-9A-Fa-f]{7,64}$"))
        and (.project.path | type == "string" and length > 0)
        and (.project.targets | type == "array" and length > 0)
        and (.signing.git_url | type == "string" and length > 0)
        and (.testflight | type == "object")
        and ((.ci // {}) | type == "object")
        and (((.ci // {}).kind // "push") | test("^(push|pull_request)$"))
        and (((.ci // {}).previous_sha // "0000000") | test("^[0-9A-Fa-f]{7,64}$"))
        and (((.ci // {}).state_key // "queue") | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
        and (((.ci // {}).state_key // "queue") | contains("..") | not)
        and (if ((.ci // {}).kind // "push") == "pull_request"
             then ((.ci // {}).pull_request | type == "number" and . > 0)
             else true end)
    ' "$job_file" >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."

    prepare_stage="runtime configuration"
    cp "$job_file" "$CONFIG_PATH" || fail "Prepare failed at ${prepare_stage}."
    chmod 600 "$CONFIG_PATH"
    mask_config_values

    prepare_stage="source reference validation"
    source_repo="$(jq -er '.source.repository' "$CONFIG_PATH")" || fail "Prepare failed at ${prepare_stage}."
    source_sha="$(jq -er '.source.sha' "$CONFIG_PATH")" || fail "Prepare failed at ${prepare_stage}."
    [[ "$source_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Prepare failed at ${prepare_stage}."
    [[ "$source_sha" =~ ^[0-9A-Fa-f]{7,64}$ ]] || fail "Prepare failed at ${prepare_stage}."

    prepare_stage="source repository fetch"
    git init -q "$SOURCE_DIR" || fail "Prepare failed at ${prepare_stage}."
    git -C "$SOURCE_DIR" remote add origin \
        "https://x-access-token:${GITHUB_PAT}@github.com/${source_repo}.git" \
        >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."
    if ! git -C "$SOURCE_DIR" fetch --quiet --no-tags --depth=1 origin "$source_sha" >"$TEMP_ROOT/source-fetch.log" 2>&1; then
        sed -E 's#(https://x-access-token:)[^@]+@#\1***@#g' "$TEMP_ROOT/source-fetch.log" | tail -n 20 >&2 || true
        fail "Prepare failed at ${prepare_stage}."
    fi
    git -C "$SOURCE_DIR" checkout --quiet --detach FETCH_HEAD >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."

    prepare_stage="submodule initialization"
    if [[ -f "$SOURCE_DIR/.gitmodules" ]]; then
        git -C "$SOURCE_DIR" submodule sync --recursive >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."
        git -C "$SOURCE_DIR" submodule update --init --recursive --quiet >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."
    fi

    if jq -e '.source.lfs == true' "$CONFIG_PATH" >/dev/null 2>&1; then
        require_command git-lfs
        prepare_stage="Git LFS download"
        git -C "$SOURCE_DIR" lfs pull --quiet >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."
    fi

    prepare_stage="changelog history"
    resolve_changelog_history "$source_sha" || fail "Prepare failed at ${prepare_stage}."

    chmod 700 "$CONTROL_DIR" "$SOURCE_DIR" "$OUTPUT_DIR" "$DERIVED_DATA_DIR"
    write_runtime_environment
    publish_cache_key
    printf '%s\n' 'Prepare completed.'
}

# True when this build must not touch the cache: the operator switched it off, the job asked
# for a cold build, or the worker cannot hash a cache key -- which amounts to the same thing,
# since every directory here is named after one.
cache_disabled() {
    [[ "${IOS_CI_CACHE_DISABLED:-}" == "1" ]] && return 0
    command -v shasum >/dev/null 2>&1 || return 0
    # CONFIG_PATH rather than IOS_CI_CONFIG: the two name the same file, but prepare asks this
    # question before the runtime environment it writes has reached any process.
    [[ -f "$CONFIG_PATH" ]] || return 1
    jq -e '.build.cache == false' "$CONFIG_PATH" >/dev/null 2>&1
}

cache_digest() {
    local value
    value="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-32)" || return 1
    [[ "$value" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf '%s\n' "$value"
}

# The key is a digest of everything the cached products depend on -- which source repository,
# which project inside it, and the exact Xcode -- so an upgrade or a different app misses
# rather than restoring products that no longer apply. It is also the only form this key could
# take: cache keys are listed in this repository's Actions tab, which is public, and the name
# of a private repository does not belong there.
cache_key_prefix() {
    local repository
    local project_path
    local xcode_version
    local key

    repository="$(jq -r '.source.repository // empty' "$CONFIG_PATH")" || return 1
    project_path="$(jq -r '.project.path // empty' "$CONFIG_PATH")" || return 1
    [[ -n "$repository" && -n "$project_path" ]] || return 1
    xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
    [[ -n "$xcode_version" ]] || return 1
    key="$(cache_digest "$repository|$project_path|$xcode_version")" || return 1

    printf 'xcode-%s-\n' "$key"
}

# The workflow cannot name the cache it wants: which app a dispatch builds is only known once
# the queued job has been read. So prepare hands the key out here, and a build whose key could
# not be worked out simply runs uncached.
publish_cache_key() {
    local prefix
    local source_sha

    [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
    cache_disabled && return 0
    prefix="$(cache_key_prefix)" || return 0
    source_sha="$(jq -r '.source.sha // empty' "$CONFIG_PATH")" || return 0
    [[ "$source_sha" =~ ^[0-9A-Fa-f]{7,64}$ ]] || return 0

    # The workflow saves this path unconditionally once a key exists, and saving a path that
    # is not there is an error, so a build that dies before it ever reaches the cache still
    # leaves an empty directory behind for the save step to find.
    mkdir -p "$CACHE_ROOT" 2>/dev/null || return 0

    {
        printf 'cache_prefix=%s\n' "$prefix"
        printf 'cache_key=%s%s\n' "$prefix" "$source_sha"
    } >> "$GITHUB_OUTPUT"
}

# Reads NUL separated paths and prints "<epoch>\t<path>" for each. BSD and GNU stat disagree
# on how to ask for a modification time, and GNU answers the BSD spelling with an unrelated
# filesystem field rather than an error, so the probe looks at what comes back.
stat_mtimes() {
    if [[ "$(stat -f %m . 2>/dev/null || true)" =~ ^[0-9]+$ ]]; then
        xargs -0 stat -f '%m	%N' 2>/dev/null
    else
        xargs -0 stat -c '%Y	%n' 2>/dev/null
    fi
}

# touch wants YYYYMMDDhhmm.ss, and only BSD date turns an epoch into one with -r; GNU date
# reads -r as a reference file and needs -d @.
touch_stamp() {
    date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null
}

# Xcode decides what to recompile from each file's size and modification time, and a clone
# stamps every file with the moment it was written -- which on its own would leave restored
# derived data as dead weight, because every file looks new. git has already hashed the whole
# tree for the index, so a file whose blob is the one the last build compiled gets that build's
# timestamp back and its object is reused. Anything git hashes differently keeps the clone's
# time and is rebuilt: the content decides, never the clock.
#
# Every file is rewritten, not just the restored ones, because touch resolves to the second
# while the build system records nanoseconds. Stamping the whole tree to whole seconds makes
# the timestamps reproducible from one build to the next, which is what the comparison needs;
# leaving the untouched files alone would cost a rebuild to settle each one.
sync_source_mtimes() {
    local manifest="$1"
    local blobs="$TEMP_ROOT/mtime-blobs.tsv"
    local plan="$TEMP_ROOT/mtime-plan.tsv"
    local stamp
    local formatted

    command -v awk >/dev/null 2>&1 || return 0
    rm -f "$blobs" "$plan"

    # core.quotePath=false keeps non-ASCII names -- localized resources, mostly -- readable
    # instead of escaped into something that matches nothing on disk.
    git -C "$SOURCE_DIR" -c core.quotePath=false ls-files -s 2>/dev/null \
        | awk -F'\t' 'NF == 2 { split($1, meta, " "); if (meta[2] != "") print meta[2] "\t" $2 }' \
        > "$blobs" 2>/dev/null || true
    [[ -s "$blobs" ]] || { rm -f "$blobs"; return 0; }

    # Each file wants the timestamp the last build gave this exact content, or its own
    # timestamp truncated to the second when the manifest has nothing to say about it.
    cut -f2 "$blobs" | tr '\n' '\0' \
        | (cd "$SOURCE_DIR" && stat_mtimes) \
        | awk -F'\t' -v blobs="$blobs" -v manifest="$manifest" '
            BEGIN {
                while ((getline line < blobs) > 0) {
                    if (split(line, field, "\t") == 2) blob[field[2]] = field[1]
                }
                while ((getline line < manifest) > 0) {
                    if (split(line, field, "\t") == 3) recorded[field[1] "\t" field[3]] = field[2]
                }
            }
            NF == 2 && ($2 in blob) {
                key = blob[$2] "\t" $2
                print (key in recorded ? recorded[key] : $1) "\t" $2
            }
        ' > "$plan" 2>/dev/null || true

    if [[ -s "$plan" ]]; then
        # Most of a tree shares a handful of timestamps, so stamping by group keeps this to a
        # few touch calls rather than one per file.
        while IFS= read -r stamp; do
            formatted="$(touch_stamp "$stamp" || true)"
            [[ -n "$formatted" ]] || continue
            awk -F'\t' -v want="$stamp" '$1 == want { print $2 }' "$plan" \
                | tr '\n' '\0' \
                | (cd "$SOURCE_DIR" && xargs -0 touch -t "$formatted" 2>/dev/null) || true
        done < <(cut -f1 "$plan" | sort -u)

        # The manifest records what was just stamped, which is what the next build compares
        # against -- so it is written from the plan, never from a second look at the disk.
        awk -F'\t' -v blobs="$blobs" '
            BEGIN {
                while ((getline line < blobs) > 0) {
                    if (split(line, field, "\t") == 2) blob[field[2]] = field[1]
                }
            }
            NF == 2 && ($2 in blob) { print blob[$2] "\t" $1 "\t" $2 }
        ' "$plan" > "$manifest.next" 2>/dev/null || true

        if [[ -s "$manifest.next" ]]; then
            mv "$manifest.next" "$manifest" 2>/dev/null || rm -f "$manifest.next"
        else
            rm -f "$manifest.next"
        fi
    fi

    rm -f "$blobs" "$plan"
}

# Points the build at whatever the workflow restored. Every failure path leaves the RUNNER_TEMP
# directories prepare created, so the build still runs -- it just pays full price, exactly as
# it did before there was a cache.
setup_build_cache() {
    cache_disabled && return 0
    mkdir -p "$CACHE_ROOT/derived-data" "$CACHE_ROOT/spm" 2>/dev/null || return 0
    sync_source_mtimes "$CACHE_ROOT/mtime.tsv"

    export IOS_CI_DERIVED_DATA="$CACHE_ROOT/derived-data"
    export IOS_CI_CLONED_SOURCE_PACKAGES="$CACHE_ROOT/spm"
    export IOS_CI_INCREMENTAL=1
    printf '%s\n' 'Build cache ready.'
}

# BUNDLE_ROOT is restored by the workflow when a previous build's gems are still current, in
# which case bundle check passes and there is nothing to install.
install_dependencies() {
    require_command bundle
    [[ -f "$WORKER_ROOT/Gemfile" ]] || fail "Build failed."

    if (cd "$WORKER_ROOT" && \
        BUNDLE_GEMFILE="$WORKER_ROOT/Gemfile" \
        BUNDLE_PATH="$BUNDLE_ROOT" \
        bundle check >/dev/null 2>&1); then
        return
    fi

    if ! (cd "$WORKER_ROOT" && \
        BUNDLE_GEMFILE="$WORKER_ROOT/Gemfile" \
        BUNDLE_PATH="$BUNDLE_ROOT" \
        bundle install --jobs 4 --retry 3) >"$TEMP_ROOT/dependencies.log" 2>&1; then
        fail "Build failed."
    fi
}

assert_xcode_version() {
    local version_line
    local actual_major
    local expected_major

    version_line="$(xcodebuild -version 2>/dev/null | sed -n '1p' || true)"
    actual_major="${version_line#Xcode }"
    actual_major="${actual_major%%.*}"
    expected_major="${IOS_CI_EXPECTED_XCODE_MAJOR:-}"

    [[ "$actual_major" =~ ^[0-9]+$ ]] || fail "Build failed."
    [[ -z "$expected_major" || "$actual_major" == "$expected_major" ]] || fail "Build failed."
}

run_prebuild() {
    local command
    command="$(jq -r '.build.prebuild // empty' "$IOS_CI_CONFIG")" || fail "Build failed."
    [[ -z "$command" ]] && return

    if ! (cd "$IOS_CI_SOURCE" && bash -euo pipefail -c "$command") >"$TEMP_ROOT/prebuild.log" 2>&1; then
        fail "Build failed."
    fi
}

run_lane() {
    local lane="$1"
    local label="$2"
    local log_path="$3"
    shift 3

    if ! (cd "$WORKER_ROOT" && \
        BUNDLE_GEMFILE="$WORKER_ROOT/Gemfile" \
        BUNDLE_PATH="$BUNDLE_ROOT" \
        bundle exec fastlane ios "$lane" "$@") >"$log_path" 2>&1; then
        printf '%s\n' "${label} log tail:"
        tail -n 160 "$log_path" || true
        fail "$label failed."
    fi

    printf '%s\n' "$label completed."
}

build() {
    require_command xcodebuild
    require_command jq
    require_runtime_paths
    assert_xcode_version
    setup_build_cache
    run_prebuild
    install_dependencies
    run_lane ci_build Build "$TEMP_ROOT/build.log" "config:$IOS_CI_CONFIG"
}

# Branch builds carry a marker key; the commit they publish becomes the starting point of the
# next changelog. Writing it here rather than at queue time means a build that never reached
# TestFlight leaves its commits for the build that follows.
record_build_state() {
    local control_branch="${CI_CONTROL_BRANCH:-main}"
    local state_path="${CI_CONTROL_STATE_PATH:-state}"
    local state_key
    local source_sha
    local state_file
    local existing
    local existing_time
    local source_time
    local attempt

    state_key="$(jq -r '.ci.state_key // empty' "$CONFIG_PATH")" || return 0
    [[ -n "$state_key" ]] || return 0
    [[ "$state_key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 0
    [[ "$state_key" != *..* ]] || return 0
    [[ "$state_path" =~ ^[A-Za-z0-9._/-]+$ ]] || return 0
    [[ "$state_path" != *..* ]] || return 0
    [[ "$control_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || return 0
    [[ -d "$CONTROL_DIR/.git" ]] || return 0
    source_sha="$(jq -er '.source.sha' "$CONFIG_PATH")" || return 0
    state_file="$state_path/$state_key.json"

    for attempt in 1 2 3 4 5; do
        git -C "$CONTROL_DIR" fetch --quiet --no-tags --depth=1 origin "$control_branch" >/dev/null 2>&1 || break
        git -C "$CONTROL_DIR" checkout --quiet --force --detach FETCH_HEAD >/dev/null 2>&1 || break

        if [[ -f "$CONTROL_DIR/$state_file" ]]; then
            existing="$(jq -r '.sha // empty' "$CONTROL_DIR/$state_file" 2>/dev/null || true)"
            [[ "$existing" != "$source_sha" ]] || return 0
            # A slower build finishing after a newer one must not move the marker backwards.
            # The clone is shallow in the direction of history it was fetched for, so it cannot
            # answer whether the recorded commit descends from this one; the commit dates of the
            # two objects are enough to order them, and a tie or a missing object still writes.
            if [[ -n "$existing" ]]; then
                git -C "$SOURCE_DIR" fetch --quiet --no-tags --depth=1 origin "$existing" >/dev/null 2>&1 || true
                existing_time="$(git -C "$SOURCE_DIR" show -s --format=%ct "$existing" 2>/dev/null || true)"
                source_time="$(git -C "$SOURCE_DIR" show -s --format=%ct "$source_sha" 2>/dev/null || true)"
                if [[ "$existing_time" =~ ^[0-9]+$ && "$source_time" =~ ^[0-9]+$ ]] \
                    && (( source_time < existing_time )); then
                    return 0
                fi
            fi
        fi

        mkdir -p "$CONTROL_DIR/$state_path" || break
        jq -n --arg sha "$source_sha" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{sha: $sha, updated_at: $updated}' > "$CONTROL_DIR/$state_file" || break
        git -C "$CONTROL_DIR" add -- "$state_file" >/dev/null 2>&1 || break
        git -C "$CONTROL_DIR" diff --quiet --cached && return 0
        git -C "$CONTROL_DIR" \
            -c user.name="github-actions[bot]" \
            -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
            commit -qm "Record published build" >/dev/null 2>&1 || break
        git -C "$CONTROL_DIR" push -q origin "HEAD:$control_branch" >/dev/null 2>&1 && return 0
    done

    # The marker only shapes the next changelog; a build that already reached TestFlight
    # must not be reported as failed because the marker could not be written.
    printf '%s\n' 'Publish completed without recording the build marker.' >&2
    return 0
}

publish() {
    require_command jq
    require_runtime_paths
    install_dependencies
    run_lane ci_publish Publish "$TEMP_ROOT/publish.log" "config:$IOS_CI_CONFIG"
    record_build_state
}

provision() {
    require_command git

    local bundle_ids="${IOS_CI_PROVISION_BUNDLE_IDS:-}"
    local platform="${IOS_CI_PROVISION_PLATFORM:-ios}"
    local profile_type="${IOS_CI_PROVISION_TYPE:-appstore}"
    local git_url="${IOS_CI_PROVISION_GIT_URL:-}"
    local git_branch="${IOS_CI_PROVISION_GIT_BRANCH:-main}"
    local force="${IOS_CI_PROVISION_FORCE:-false}"

    [[ "$bundle_ids" =~ ^[A-Za-z0-9.-]+(,[A-Za-z0-9.-]+)*$ ]] || fail "Provision failed."
    [[ "$platform" =~ ^(ios|tvos)$ ]] || fail "Provision failed."
    [[ "$profile_type" =~ ^(appstore|adhoc|development)$ ]] || fail "Provision failed."
    [[ "$git_url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] || fail "Provision failed."
    [[ "$git_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "Provision failed."
    [[ "$force" =~ ^(true|false)$ ]] || fail "Provision failed."
    [[ -n "${GITHUB_PAT:-}" ]] || fail "Provision failed."
    [[ -n "${MATCH_PASSWORD:-}" ]] || fail "Provision failed."

    # Actions masks a secret only as a whole, so a comma-separated list leaves each
    # identifier unmasked where match echoes it back one at a time.
    mask_provision_values "$bundle_ids" "$git_url"

    # match writes the new certificate and profile back to the signing repository,
    # so this path needs push credentials and a commit identity the build path never uses.
    configure_private_git "$GITHUB_PAT"
    git config --file "$GIT_CONFIG_PATH" user.name "github-actions[bot]"
    git config --file "$GIT_CONFIG_PATH" user.email "41898282+github-actions[bot]@users.noreply.github.com"

    install_dependencies
    run_lane ci_provision Provision "$TEMP_ROOT/provision.log" \
        "bundle_ids:$bundle_ids" \
        "platform:$platform" \
        "type:$profile_type" \
        "git_url:$git_url" \
        "git_branch:$git_branch" \
        "force:$force"
}

# CACHE_ROOT is deliberately absent here: the workflow saves it in the step before this one,
# and everything else a job put in RUNNER_TEMP, source included, goes.
finalize() {
    rm -rf "$SOURCE_DIR" "$CONTROL_DIR" "$CONFIG_PATH" "$CONFIG_PATH.next" "$OUTPUT_DIR" \
        "$DERIVED_DATA_DIR" "$GIT_CONFIG_PATH" "$BUNDLE_ROOT" \
        "$TEMP_ROOT/dependencies.log" "$TEMP_ROOT/prebuild.log" \
        "$TEMP_ROOT/build.log" "$TEMP_ROOT/publish.log" "$TEMP_ROOT/provision.log" \
        "$TEMP_ROOT/control-fetch.log" "$TEMP_ROOT/source-fetch.log" \
        "$TEMP_ROOT/mtime-blobs.tsv" "$TEMP_ROOT/mtime-plan.tsv"
    printf '%s\n' 'Finalize completed.'
}

case "${1:-}" in
    prepare)
        prepare
        ;;
    build)
        build
        ;;
    publish)
        publish
        ;;
    provision)
        provision
        ;;
    finalize)
        finalize
        ;;
    *)
        printf '%s\n' 'Build failed.' >&2
        exit 2
        ;;
esac
