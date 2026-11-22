#!/usr/bin/env bash

set -euo pipefail

readonly WORKER_ROOT="${GITHUB_WORKSPACE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly TEMP_ROOT="${RUNNER_TEMP:?RUNNER_TEMP is required}"
readonly SOURCE_DIR="$TEMP_ROOT/src"
readonly CONFIG_PATH="$TEMP_ROOT/config.json"
readonly OUTPUT_DIR="$TEMP_ROOT/output"
readonly DERIVED_DATA_DIR="$TEMP_ROOT/derived-data"
readonly GIT_CONFIG_PATH="$TEMP_ROOT/gitconfig"
readonly BUNDLE_ROOT="$TEMP_ROOT/bundle"
readonly CLONE_TOKEN_PATH="$TEMP_ROOT/clone-token"
readonly LOGS_FLAG_PATH="$TEMP_ROOT/logs-enabled"
readonly CLAIMED_BUILD_PATH="$TEMP_ROOT/claimed-build"
readonly FAILURE_DIR="$TEMP_ROOT/failure-logs"

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

# The queue service that hands out jobs and records their results lives behind an address
# kept in secrets, and nothing here names it. A request carries the OIDC token the workflow can
# ask Actions for, so no credential for the service is stored on the worker either. Errors are
# reported without the address, which Actions would otherwise print as part of a curl failure.
backend_ready() {
    [[ -n "${CI_BACKEND_URL:-}" && -n "${CI_BACKEND_AUDIENCE:-}" ]] || return 1
    [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] || return 1
    [[ "${IOS_CI_JOB_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]]
}

# Actions masks a secret only as a whole, so the host and the audience on their own would still
# print. Run once per step, never inside a command whose output is captured.
backend_mask() {
    local host="${CI_BACKEND_URL#*://}"
    printf '::add-mask::%s\n' "${host%%/*}" "$CI_BACKEND_AUDIENCE"
}

backend_token() {
    local audience
    audience="$(jq -rn --arg value "$CI_BACKEND_AUDIENCE" '$value | @uri')" || return 1
    curl -fsS --retry 3 --retry-delay 2 \
        -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
        "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}" 2>/dev/null | jq -er '.value'
}

# backend METHOD PATH [FILE [CONTENT_TYPE]]: sends FILE as the body and prints the response.
# Fails on anything but a 2xx answer, saying only the status.
backend() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    local content_type="${4:-application/json}"
    local token
    local headers="$TEMP_ROOT/backend-headers"
    local response="$TEMP_ROOT/backend-response"
    local status
    local -a args=(-sS --retry 3 --retry-delay 2 -o "$response" -w '%{http_code}' -X "$method" -H "@$headers")

    token="$(backend_token)" || { printf '%s\n' 'Queue service: could not get a token.' >&2; return 1; }
    printf '::add-mask::%s\n' "$token" >&2
    (umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$headers")
    if [[ -n "$data" ]]; then
        args+=(-H "Content-Type: ${content_type}" --data-binary "@${data}")
    fi

    status="$(curl "${args[@]}" "${CI_BACKEND_URL%/}${path}" 2>/dev/null)" || status="000"
    rm -f "$headers"
    cat "$response" 2>/dev/null || true
    rm -f "$response"
    if [[ ! "$status" =~ ^2 ]]; then
        printf 'Queue service answered %s.\n' "$status" >&2
        return 1
    fi
}

# The clone token expires after an hour and a build can take three, so it is rewritten into the
# git configuration before each step that fetches repositories.
store_clone_token() {
    (umask 077; printf '%s' "$1" > "$CLONE_TOKEN_PATH")
}

refresh_clone_token() {
    local token
    token="$(backend POST "/runner/jobs/${IOS_CI_JOB_ID}/token" | jq -er '.token')" || return 1
    printf '::add-mask::%s\n' "$token"
    store_clone_token "$token"
    configure_private_git "$token"
}

scrub_tokens() {
    local token=""
    [[ -f "$CLONE_TOKEN_PATH" ]] && token="$(cat "$CLONE_TOKEN_PATH")"
    IOS_CI_SCRUB_TOKEN="$token" perl -pe '
        s#(https://x-access-token:)[^@\s]+@#$1***@#g;
        for my $name (qw(IOS_CI_SCRUB_TOKEN MATCH_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_BASE64)) {
            my $value = $ENV{$name};
            s/\Q$value\E/***/g if defined $value && length($value) >= 4;
        }
    '
}

# report_result RESULT DESCRIPTION [ERRORS_FILE]: the final word on this build. The service
# ignores a second report for a build it already closed.
report_result() {
    local result="$1"
    local description="${2:-}"
    local errors="${3:-}"
    local body="$TEMP_ROOT/report.json"
    local number=""
    local -a args=(--arg result "$result" --arg description "$description")

    if [[ -f "$CLAIMED_BUILD_PATH" ]]; then
        number="$(cat "$CLAIMED_BUILD_PATH")"
        [[ "$number" =~ ^[0-9]+$ ]] && args+=(--argjson build_number "$number")
    fi
    [[ -n "$errors" && -s "$errors" ]] && args+=(--rawfile errors "$errors")

    jq -n "${args[@]}" '
        {result: $result}
        + (if $description != "" then {description: $description} else {} end)
        + (if $ARGS.named | has("build_number") then {build_number: $ARGS.named.build_number} else {} end)
        + (if $ARGS.named | has("errors") then {errors: $ARGS.named.errors} else {} end)
    ' > "$body" || return 1
    backend POST "/runner/jobs/${IOS_CI_JOB_ID}/finish" "$body" >/dev/null || return 1
    rm -f "$body"
}

# Called by the build lane for each target: one above both TestFlight's newest build and every
# number the service already handed out, so builds that start together cannot collide. Prints
# only the number; the lane reads it from standard output.
claim_build_number() {
    local key="${1:-}"
    local latest="${2:-}"
    local body="$TEMP_ROOT/claim.json"
    local number

    [[ "$key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || fail "Build number could not be reserved."
    [[ "$latest" =~ ^[0-9]+$ ]] || fail "Build number could not be reserved."
    backend_ready || fail "Build number could not be reserved."

    jq -n --arg key "$key" --argjson latest "$latest" '{key: $key, latest: $latest}' > "$body" \
        || fail "Build number could not be reserved."
    number="$(backend POST "/runner/jobs/${IOS_CI_JOB_ID}/build-number" "$body" | jq -er '.build')" \
        || fail "Build number could not be reserved."
    rm -f "$body"
    [[ "$number" =~ ^[0-9]+$ ]] || fail "Build number could not be reserved."
    printf '%s' "$number" > "$CLAIMED_BUILD_PATH"
    printf '%s\n' "$number"
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
    require_command curl

    local job_id="${IOS_CI_JOB_ID:-}"
    local token
    local source_repo
    local source_sha
    local prepare_stage="input validation"

    [[ "$job_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]] || fail "Prepare failed at ${prepare_stage}."
    backend_ready || fail "Prepare failed at ${prepare_stage}."
    backend_mask

    prepare_stage="workspace"
    rm -rf "$SOURCE_DIR" "$OUTPUT_DIR" "$DERIVED_DATA_DIR" "$FAILURE_DIR" \
        "$CLONE_TOKEN_PATH" "$LOGS_FLAG_PATH" "$CLAIMED_BUILD_PATH"
    mkdir -p "$SOURCE_DIR" "$OUTPUT_DIR" "$DERIVED_DATA_DIR" || fail "Prepare failed at ${prepare_stage}."

    # The first request also tells the service this job has started. It answers with the job
    # file and a short-lived token that can read the source and signing repositories.
    prepare_stage="job lookup"
    backend GET "/runner/jobs/$job_id" > "$TEMP_ROOT/job.json" || fail "Prepare failed at ${prepare_stage}."
    jq -e '(.config | type == "object") and (.token | type == "string" and length > 0)' \
        "$TEMP_ROOT/job.json" >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."

    token="$(jq -r '.token' "$TEMP_ROOT/job.json")"
    printf '::add-mask::%s\n' "$token"
    store_clone_token "$token"
    if jq -e '.logs == true' "$TEMP_ROOT/job.json" >/dev/null 2>&1; then
        : > "$LOGS_FLAG_PATH"
    fi

    prepare_stage="queued job validation"
    jq '.config' "$TEMP_ROOT/job.json" > "$CONFIG_PATH" || fail "Prepare failed at ${prepare_stage}."
    chmod 600 "$CONFIG_PATH"
    rm -f "$TEMP_ROOT/job.json"
    jq -e '
        (.source.repository | type == "string" and length > 0)
        and (.source.sha | type == "string" and test("^[0-9A-Fa-f]{7,64}$"))
        and (.project.path | type == "string" and length > 0)
        and (.project.targets | type == "array" and length > 0)
        and (.signing.git_url | type == "string" and length > 0)
        and (.testflight | type == "object")
        and ((.ci // {}) | type == "object")
        and (((.ci // {}).kind // "push") | test("^(push|pull_request|refresh)$"))
        and (((.ci // {}).previous_sha // "0000000") | test("^[0-9A-Fa-f]{7,64}$"))
        and (((.ci // {}).state_key // "queue") | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
        and (((.ci // {}).state_key // "queue") | contains("..") | not)
        and (if ((.ci // {}).kind // "push") == "pull_request"
             then ((.ci // {}).pull_request | type == "number" and . > 0)
             else true end)
    ' "$CONFIG_PATH" >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."

    prepare_stage="runtime configuration"
    mask_config_values
    configure_private_git "$token"

    prepare_stage="source reference validation"
    source_repo="$(jq -er '.source.repository' "$CONFIG_PATH")" || fail "Prepare failed at ${prepare_stage}."
    source_sha="$(jq -er '.source.sha' "$CONFIG_PATH")" || fail "Prepare failed at ${prepare_stage}."
    [[ "$source_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Prepare failed at ${prepare_stage}."
    [[ "$source_sha" =~ ^[0-9A-Fa-f]{7,64}$ ]] || fail "Prepare failed at ${prepare_stage}."

    prepare_stage="source repository fetch"
    git init -q "$SOURCE_DIR" || fail "Prepare failed at ${prepare_stage}."
    git -C "$SOURCE_DIR" remote add origin "https://github.com/${source_repo}.git" >/dev/null 2>&1 \
        || fail "Prepare failed at ${prepare_stage}."
    if ! git -C "$SOURCE_DIR" fetch --quiet --no-tags --depth=1 origin "$source_sha" >"$TEMP_ROOT/source-fetch.log" 2>&1; then
        scrub_tokens < "$TEMP_ROOT/source-fetch.log" | tail -n 20 >&2 || true
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

    chmod 700 "$SOURCE_DIR" "$OUTPUT_DIR" "$DERIVED_DATA_DIR"
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

# The public run log only shows a masked tail, and fastlane keeps xcodebuild's own output --
# where compiler errors are -- in a separate log on the worker, which finalize deletes. A failed
# lane gathers both, with the error lines pulled into errors.txt, and reports the failure to the
# queue service, which shows the first error on the commit. The full logs are uploaded too when
# the service says it can keep them, so a failure can be read without exposing source in the
# public run. Credentials the step holds are scrubbed first. Recording is best effort and never
# changes the outcome of the build.
record_failure_logs() {
    local lane_log="$1"
    local log
    local name

    backend_ready || return 0
    rm -rf "$FAILURE_DIR"
    mkdir -p "$FAILURE_DIR" || return 0

    [[ -f "$lane_log" ]] && scrub_tokens < "$lane_log" > "$FAILURE_DIR/fastlane.log"
    for log in "$TEMP_ROOT/dependencies.log" "$TEMP_ROOT/prebuild.log"; do
        [[ -s "$log" ]] && scrub_tokens < "$log" > "$FAILURE_DIR/$(basename "$log")"
    done
    for log in "$HOME"/Library/Logs/gym/*.log; do
        [[ -f "$log" ]] || continue
        # The end of the log is where a failure is.
        tail -c 50000000 "$log" | scrub_tokens > "$FAILURE_DIR/xcodebuild.log"
    done
    if [[ -f "$FAILURE_DIR/xcodebuild.log" ]]; then
        grep -n -B 2 -A 6 -E '(^|[^A-Za-z])(error|fatal error): ' "$FAILURE_DIR/xcodebuild.log" \
            2>/dev/null | tail -c 60000 > "$FAILURE_DIR/errors.txt" || true
    fi
    # A lane that never got as far as xcodebuild (signing, upload) has its answer in its own log.
    if [[ ! -s "$FAILURE_DIR/errors.txt" && -f "$FAILURE_DIR/fastlane.log" ]]; then
        tail -n 60 "$FAILURE_DIR/fastlane.log" | tail -c 60000 > "$FAILURE_DIR/errors.txt"
    fi

    if [[ -f "$LOGS_FLAG_PATH" ]]; then
        for name in fastlane.log xcodebuild.log dependencies.log prebuild.log errors.txt; do
            [[ -s "$FAILURE_DIR/$name" ]] || continue
            backend PUT "/runner/jobs/${IOS_CI_JOB_ID}/logs/${name}" "$FAILURE_DIR/$name" text/plain >/dev/null || true
        done
    fi

    report_result failure "" "$FAILURE_DIR/errors.txt" || printf '%s\n' 'The failure could not be reported.' >&2
    return 0
}

run_lane() {
    local lane="$1"
    local label="$2"
    local log_path="$3"
    shift 3

    # fastlane prints its update notice, release notes included, after a lane fails, which
    # would fill the whole tail below and push the actual error out of it.
    if ! (cd "$WORKER_ROOT" && \
        FASTLANE_SKIP_UPDATE_CHECK=1 \
        BUNDLE_GEMFILE="$WORKER_ROOT/Gemfile" \
        BUNDLE_PATH="$BUNDLE_ROOT" \
        IOS_CI_HELPER="$WORKER_ROOT/scripts/ios-builder.sh" \
        bundle exec fastlane ios "$lane" "$@") >"$log_path" 2>&1; then
        printf '%s\n' "${label} log tail:"
        tail -n 160 "$log_path" || true
        record_failure_logs "$log_path"
        fail "$label failed."
    fi

    printf '%s\n' "$label completed."
}

build() {
    require_command xcodebuild
    require_command jq
    require_runtime_paths
    backend_ready && backend_mask
    refresh_clone_token || printf '%s\n' 'The repository token could not be renewed.' >&2
    assert_xcode_version
    setup_build_cache
    run_prebuild
    install_dependencies
    run_lane ci_build Build "$TEMP_ROOT/build.log" "config:$IOS_CI_CONFIG"
}

# A refresh rebuilds a commit that already reached TestFlight, and its build number still lands
# above everything uploaded so far. If a newer commit was published while it was queued or
# building, uploading the refresh would hand testers the older code as the latest build, so the
# upload is dropped. Anything that cannot be read leaves the refresh to publish as queued.
refresh_superseded() {
    local answer

    [[ "$(jq -r '.ci.kind // "push"' "$CONFIG_PATH" 2>/dev/null)" == "refresh" ]] || return 1
    answer="$(backend GET "/runner/jobs/${IOS_CI_JOB_ID}/superseded" | jq -r '.superseded // false')" || return 1
    [[ "$answer" == "true" ]]
}

# What testers see: pull request builds append the pull request number to the build.
published_build_label() {
    local number=""
    [[ -f "$CLAIMED_BUILD_PATH" ]] && number="$(cat "$CLAIMED_BUILD_PATH")"
    [[ "$number" =~ ^[0-9]+$ ]] || return 0
    if [[ "$(jq -r '.ci.kind // "push"' "$CONFIG_PATH" 2>/dev/null)" == "pull_request" ]]; then
        number="${number}.$(jq -r '.ci.pull_request' "$CONFIG_PATH")"
    fi
    printf '%s\n' "$number"
}

publish() {
    require_command jq
    require_runtime_paths
    backend_ready && backend_mask
    if refresh_superseded; then
        printf '%s\n' 'Publish skipped: a newer build reached TestFlight after this refresh was queued.'
        report_result skipped "a newer build reached TestFlight" || true
        return 0
    fi
    refresh_clone_token || printf '%s\n' 'The repository token could not be renewed.' >&2
    install_dependencies
    run_lane ci_publish Publish "$TEMP_ROOT/publish.log" "config:$IOS_CI_CONFIG"

    # Closing the job on the service records the commit as published, so the next changelog
    # starts there; a build that never reached TestFlight leaves its commits for the next one.
    local label
    label="$(published_build_label)"
    if ! report_result success "${label:+build ${label} is on TestFlight}"; then
        # The build is on TestFlight whatever the service heard, so this is never a failure.
        printf '%s\n' 'Publish completed without recording the result.' >&2
    fi
}

# Runs when a step failed or the job was cancelled. A failure the lane already reported is
# ignored by the service; this one covers the rest -- a step that died before any lane ran.
report_failure() {
    backend_ready || return 0
    backend_mask
    report_result failure "${IOS_CI_REPORT_DESCRIPTION:-build failed}" || true
    printf '%s\n' 'Report completed.'
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
    rm -rf "$SOURCE_DIR" "$CONFIG_PATH" "$CONFIG_PATH.next" "$OUTPUT_DIR" \
        "$DERIVED_DATA_DIR" "$GIT_CONFIG_PATH" "$BUNDLE_ROOT" "$FAILURE_DIR" \
        "$CLONE_TOKEN_PATH" "$LOGS_FLAG_PATH" "$CLAIMED_BUILD_PATH" \
        "$TEMP_ROOT/dependencies.log" "$TEMP_ROOT/prebuild.log" \
        "$TEMP_ROOT/build.log" "$TEMP_ROOT/publish.log" "$TEMP_ROOT/provision.log" \
        "$TEMP_ROOT/source-fetch.log" "$TEMP_ROOT/job.json" "$TEMP_ROOT/report.json" \
        "$TEMP_ROOT/claim.json" "$TEMP_ROOT/backend-headers" "$TEMP_ROOT/backend-response" \
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
    claim-build-number)
        claim_build_number "${2:-}" "${3:-}"
        ;;
    report-failure)
        report_failure
        ;;
    finalize)
        finalize
        ;;
    *)
        printf '%s\n' 'Build failed.' >&2
        exit 2
        ;;
esac
