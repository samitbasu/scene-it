#!/usr/bin/env bash
# The commit gate (docs/decisions/0008-local-ci.md). Silent and exit 0 when green;
# otherwise prints the failing step's diagnostics and exits non-zero.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly swift_paths=(Package.swift Sources Tests SceneIt SceneItTests)
readonly log_dir=build/check
readonly result_bundle="$log_dir/SceneIt.xcresult"
mkdir -p "$log_dir"

strip_ansi() {
    sed -E $'s/\x1b\\[[0-9;]*m//g; s/\x1b\\]8;;[^\x1b]*\x1b\\\\//g'
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
    if [[ -d $result_bundle ]]; then
        xcrun xcresulttool get test-results summary --path "$result_bundle" 2>/dev/null \
            | jq -r '.testFailures[]? | "✘ \(.targetName)/\(.testName): \(.failureText)"' >&2 || true
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
    # TextKit 2 only (PLAN §2): touching `layoutManager` silently reverts a text view to TextKit 1.
    local hits
    hits=$(grep -rnw --include='*.swift' 'layoutManager' SceneIt Sources || true)
    [[ -z $hits ]] && return 0
    sed -E 's/^([^:]+:[0-9]+):/\1: error: layoutManager is forbidden, use textLayoutManager:/' <<<"$hits"
    return 1
}

run textkit1-guard forbid_textkit1
run lint swift format lint --strict --recursive --parallel "${swift_paths[@]}"
run swift-test swift test
rm -rf "$result_bundle"
run xcodebuild xcodebuild \
    -project SceneIt.xcodeproj \
    -scheme SceneIt \
    -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData \
    -resultBundlePath "$result_bundle" \
    build test
