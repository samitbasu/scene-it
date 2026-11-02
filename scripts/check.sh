#!/usr/bin/env bash
# The commit gate (docs/decisions/0008-local-ci.md). Silent and exit 0 when green;
# otherwise prints the failing step's diagnostics and exits non-zero.
set -euo pipefail

source "$(dirname "$0")/lib.sh"

readonly log_dir=build/check
readonly result_bundle="$log_dir/SceneIt.xcresult"
rm -rf "$result_bundle"
mkdir -p "$log_dir"

strip_ansi() {
    sed -E $'s/\x1b\\[[0-9;]*m//g; s/\x1b\\]8;;[^\x1b]*\x1b\\\\//g'
}

print_test_failures() {
    [[ -d $result_bundle ]] || return 0
    xcrun xcresulttool get test-results summary --path "$result_bundle" 2>/dev/null \
        | jq -r '.testFailures[]? | "✘ \(.targetName)/\(.testName): \(.failureText)"' >&2 || true
}

fail() {
    local step=$1 log=$2
    echo "check.sh: $step failed (full log: $log)" >&2
    local diagnostics
    diagnostics=$(grep -E 'error:|warning:|✘|\*\* (BUILD|TEST) FAILED' "$log" | grep -v appintentsmetadataprocessor | strip_ansi || true)
    if [[ -n $diagnostics ]]; then
        echo "$diagnostics" >&2
    else
        tail -n 50 "$log" | strip_ansi >&2
    fi
    if [[ $step == xcodebuild ]]; then
        print_test_failures
    fi
    exit 1
}

run() {
    local step=$1
    shift
    local log="$log_dir/$step.log"
    "$@" >"$log" 2>&1 || fail "$step" "$log"
}

forbid_textkit1() {
    # TextKit 2 only (PLAN §2): any of these silently puts a text view on TextKit 1.
    local path hits status=0
    # BSD grep applies --include to its operands too, so it skips a missing directory silently.
    for path in "${swift_paths[@]}"; do
        [[ -e $path ]] || { echo "$path: error: no such file or directory"; return 2; }
    done
    hits=$(grep -rnE --include='*.swift' \
        '\blayoutManager\b|NSLayoutManager|usingTextLayoutManager: *false' "${swift_paths[@]}") \
        || status=$?
    case $status in
        0)
            sed -E 's/^([^:]+:[0-9]+):[[:space:]]*/\1: error: TextKit 1 is forbidden (PLAN §2): /' <<<"$hits"
            return 1
            ;;
        1) return 0 ;;
        *) return "$status" ;;
    esac
}

run textkit1-guard forbid_textkit1
run lint swift format lint --strict --recursive --parallel "${swift_paths[@]}"
run swift-test swift test
run xcodebuild xcodebuild \
    -project SceneIt.xcodeproj \
    -scheme SceneIt \
    -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData \
    -resultBundlePath "$result_bundle" \
    test
