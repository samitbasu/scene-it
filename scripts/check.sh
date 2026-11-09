#!/usr/bin/env bash
# The commit gate (docs/decisions/0008-local-ci.md). Silent and exit 0 when green;
# otherwise prints every failing step's diagnostics and exits non-zero.
set -euo pipefail

source "$(dirname "$0")/lib.sh"

# The gate checks the corpus; it never rewrites it (Tests/Corpus/README.md).
unset CORPUS_REGENERATE
source scripts/guards.sh

readonly log_dir=build/check
readonly result_bundle="$log_dir/SceneIt.xcresult"
readonly products_before=" $(built_here "$every_build_folder" | tr '\n' ' ') "

# stop_everything <signal>: kills what the gate started, as a timeout does, then dies of the
# signal, so a calling loop sees the interrupt. It leaves both builds unrecorded, so the next
# gate builds from clean. The steps run in the background, where Ctrl-C doesn't reach them, so
# without this they would outlive the gate and keep writing to build/.
stop_everything() {
    trap '' INT TERM HUP
    kill_doomed $$ "$every_build_folder" "$products_before"
    trap - "$1"
    kill -"$1" $$
}
trap 'stop_everything INT' INT
trap 'stop_everything TERM' TERM
trap 'stop_everything HUP' HUP
trap unlock_builds EXIT

rm -rf "$result_bundle"
mkdir -p "$log_dir"

print_test_failures() {
    [[ -d $result_bundle ]] || return 0
    xcrun xcresulttool get test-results summary --path "$result_bundle" 2>/dev/null \
        | jq -r '.testFailures[]? | "✘ \(.targetName)/\(.testName): \(.failureText)"' >&2 || true
}

report_failure() {
    local step=$1 log="$log_dir/$1.log"
    echo "check.sh: $step failed (full log: $log)" >&2
    print_log_diagnostics "$log"
    if [[ $step == xcodebuild ]]; then
        print_test_failures
    fi
}

# time_limited <step> <minutes> <build folders> <command>...: runs the command into the step's
# log, failing if it takes longer than <minutes>. A timeout also kills what runs from <build
# folders> (with_time_limit in lib.sh).
time_limited() {
    local step=$1 minutes=$2 folders=$3
    shift 3
    rm -f "$log_dir/$step"-hang-*.txt
    with_time_limit $((minutes * 60)) "$log_dir/$step-hang" "$folders" "$@" >"$log_dir/$step.log" 2>&1
}

# run <step> <minutes> <command>...: a step that runs alone; the gate stops if it fails.
run() {
    time_limited "$1" "$2" "$every_build_folder" "${@:3}" || {
        report_failure "$1"
        exit 1
    }
}

run guard-tests 5 scripts/test-guards.sh
run lib-tests 5 scripts/test-lib.sh
for guard in "${source_guards[@]}"; do
    run "${guard%%:*}" 5 "${guard#*:}" "${swift_paths[@]}"
done
run lint 5 lint_swift

prepare_builds refuse build/DerivedData .build || exit 1

# SwiftPM builds into .build and xcodebuild into build/, so the two steps run at once.
time_limited swift-test 15 '\.build' swift test &
swift_test=$!
time_limited xcodebuild 45 build xcodebuild \
    -project SceneIt.xcodeproj \
    -scheme SceneIt \
    -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData \
    -resultBundlePath "$result_bundle" \
    test &
xcodebuild=$!

# finish <step> <pid> <folder>: waits for a build step, records its build unless it ran out of
# time, and reports it if it failed.
finish() {
    local step=$1 pid=$2 folder=$3 status=0
    wait "$pid" || status=$?
    ((status == timed_out)) || record_build "$folder"
    ((status == 0)) || { report_failure "$step"; return 1; }
}

status=0
finish swift-test "$swift_test" .build || status=1
finish xcodebuild "$xcodebuild" build/DerivedData || status=1
exit "$status"
