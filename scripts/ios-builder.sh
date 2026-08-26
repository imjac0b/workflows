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
        ..
        | strings
        | select(length >= 3)
        | select(contains("\n") | not)
        | select(contains("\r") | not)
    ' "$CONFIG_PATH" 2>/dev/null | while IFS= read -r value; do
        printf '::add-mask::%s\n' "$value"
    done
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
    control_url="https://github.com/${control_repo}.git"

    prepare_stage="control workspace"
    rm -rf "$CONTROL_DIR" "$SOURCE_DIR" "$OUTPUT_DIR" "$DERIVED_DATA_DIR"
    mkdir -p "$CONTROL_DIR" "$SOURCE_DIR" "$OUTPUT_DIR" "$DERIVED_DATA_DIR" || fail "Prepare failed at ${prepare_stage}."

    prepare_stage="control repository fetch"
    git init -q "$CONTROL_DIR" || fail "Prepare failed at ${prepare_stage}."
    git -C "$CONTROL_DIR" remote add origin "$control_url" >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."
    if ! git -C "$CONTROL_DIR" fetch --quiet --no-tags --depth=1 origin "$control_branch" >"$TEMP_ROOT/control-fetch.log" 2>&1; then
        sed -E 's#(https://x-access-token:)[^@]+@#\1***@g' "$TEMP_ROOT/control-fetch.log" | tail -n 20 >&2 || true
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
        "https://github.com/${source_repo}.git" \
        >/dev/null 2>&1 || fail "Prepare failed at ${prepare_stage}."
    if ! git -C "$SOURCE_DIR" fetch --quiet --no-tags --depth=1 origin "$source_sha" >"$TEMP_ROOT/source-fetch.log" 2>&1; then
        sed -E 's#(https://x-access-token:)[^@]+@#\1***@g' "$TEMP_ROOT/source-fetch.log" | tail -n 20 >&2 || true
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

    chmod 700 "$CONTROL_DIR" "$SOURCE_DIR" "$OUTPUT_DIR" "$DERIVED_DATA_DIR"
    write_runtime_environment
    printf '%s\n' 'Prepare completed.'
}

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

    if ! (cd "$WORKER_ROOT" && \
        BUNDLE_GEMFILE="$WORKER_ROOT/Gemfile" \
        BUNDLE_PATH="$BUNDLE_ROOT" \
        bundle exec fastlane ios "$lane" "config:$IOS_CI_CONFIG") >"$log_path" 2>&1; then
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
    run_prebuild
    install_dependencies
    run_lane ci_build Build "$TEMP_ROOT/build.log"
}

publish() {
    require_command jq
    require_runtime_paths
    install_dependencies
    run_lane ci_publish Publish "$TEMP_ROOT/publish.log"
}

finalize() {
    rm -rf "$SOURCE_DIR" "$CONTROL_DIR" "$CONFIG_PATH" "$OUTPUT_DIR" \
        "$DERIVED_DATA_DIR" "$GIT_CONFIG_PATH" "$BUNDLE_ROOT" \
        "$TEMP_ROOT/dependencies.log" "$TEMP_ROOT/prebuild.log" \
        "$TEMP_ROOT/build.log" "$TEMP_ROOT/publish.log" \
        "$TEMP_ROOT/control-fetch.log" "$TEMP_ROOT/source-fetch.log"
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
    finalize)
        finalize
        ;;
    *)
        printf '%s\n' 'Build failed.' >&2
        exit 2
        ;;
esac
