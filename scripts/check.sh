#!/usr/bin/env bash
# The commit gate (docs/decisions/0008-local-ci.md). Silent and exit 0 when green;
# otherwise prints the failing step's diagnostics and exits non-zero.
set -euo pipefail

source "$(dirname "$0")/lib.sh"

# The gate checks the corpus; it never rewrites it (Tests/Corpus/README.md).
unset CORPUS_REGENERATE
source scripts/guards.sh

readonly log_dir=build/check
readonly result_bundle="$log_dir/SceneIt.xcresult"
rm -rf "$result_bundle"
mkdir -p "$log_dir"

print_test_failures() {
    [[ -d $result_bundle ]] || return 0
    xcrun xcresulttool get test-results summary --path "$result_bundle" 2>/dev/null \
        | jq -r '.testFailures[]? | "✘ \(.targetName)/\(.testName): \(.failureText)"' >&2 || true
}

fail() {
    local step=$1 log=$2
    echo "check.sh: $step failed (full log: $log)" >&2
    print_log_diagnostics "$log"
    if [[ $step == xcodebuild ]]; then
        print_test_failures
    fi
    exit 1
}

# run <step> <minutes> <command>...: a step that takes longer than <minutes> fails.
run() {
    local step=$1 minutes=$2
    shift 2
    local log="$log_dir/$step.log"
    rm -f "$log_dir/$step"-hang-*.txt
    with_time_limit $((minutes * 60)) "$log_dir/$step-hang" "$@" >"$log" 2>&1 || fail "$step" "$log"
}

run guard-tests 5 scripts/test-guards.sh
for guard in "${source_guards[@]}"; do
    run "${guard%%:*}" 5 "${guard#*:}" "${swift_paths[@]}"
done
run lint 5 lint_swift
run swift-test 15 swift test
run xcodebuild 45 xcodebuild \
    -project SceneIt.xcodeproj \
    -scheme SceneIt \
    -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData \
    -resultBundlePath "$result_bundle" \
    test
