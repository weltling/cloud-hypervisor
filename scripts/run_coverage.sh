#!/usr/bin/env bash

set -x

# shellcheck source=/dev/null
source "$HOME"/.cargo/env
source "$(dirname "$0")/test-util.sh"

process_common_args "$@"

PROJECT_DIR="/cloud-hypervisor"
TARGET_DIR="$PROJECT_DIR/target"

pushd $PROJECT_DIR || exit

export BUILD_TARGET=${BUILD_TARGET-$(uname -m)-unknown-linux-gnu}

if ! command -v grcov >/dev/null; then
    mkdir -p "$TARGET_DIR" || exit 1
    grcov_dir=$(mktemp -d "$TARGET_DIR/grcov.XXXXXXXXXX") || exit 1
    trap 'rm -rf -- "$grcov_dir"' EXIT
    bash "$PROJECT_DIR/scripts/install_grcov.sh" "$grcov_dir" || exit 1
    export PATH="$grcov_dir:$PATH"
fi

export_lcov() {
    rm -f "coverage.info" || return 1

    mapfile -t profraw_files < <(find . -name 'ch-*.profraw' -print)
    if [[ ${#profraw_files[@]} -eq 0 ]]; then
        echo "No coverage profiles found. Run unit tests with --unit --coverage or set RUSTFLAGS and LLVM_PROFILE_FILE before running the tests." >&2
        return 1
    fi
    grcov "${profraw_files[@]}" -s . \
        --ignore "tests/*" \
        --ignore "test_infra/*" \
        --ignore "performance-metrics/*" \
        --binary-path "$TARGET_DIR/$BUILD_TARGET/release/" \
        --branch --ignore-not-existing -t lcov \
        -o "coverage.info" || return 1

    find . -type f -name 'ch-*.profraw' -exec rm {} \;
}

# Generate HTML report
export_html() {
    OUTPUT_DIR="$TARGET_DIR/coverage"
    rm -rf $OUTPUT_DIR
    mapfile -t profraw_files < <(find . -name 'ch-*.profraw' -print)
    grcov "${profraw_files[@]}" -s . \
        --ignore "tests/*" \
        --ignore "test_infra/*" \
        --ignore "performance-metrics/*" \
        --binary-path "$TARGET_DIR/$BUILD_TARGET/release/" \
        --branch --ignore-not-existing -t html \
        -o $OUTPUT_DIR
    find . -type f -name 'ch-*.profraw' -exec rm {} \;
}

# test_binary_args is now a command name. Check if it is a valid command and, if so,
# run it.
#
# shellcheck disable=SC2154
type=${test_binary_args[*]}
declare -f "export_$type" >/dev/null
code=$?
if [[ $code != 0 ]]; then
    echo "Unknown command: $type. Only support \"lcov\" and \"html\". Change to default command: html"
    type="html"
fi

func=export_$type
$func || exit 1

popd || exit 1
