#!/usr/bin/env bash
# Negative and positive tests for the source guards in guards.sh. Silent and exit 0 when
# every guard rejects what it should and accepts what it should; otherwise lists failures.
set -euo pipefail

source "$(dirname "$0")/guards.sh"

fixtures=$(mktemp -d "${TMPDIR:-/tmp}/scene-it-guard-tests.XXXXXX")
trap 'rm -rf "$fixtures"' EXIT
failures=0

# expect <rejects|accepts> <guard> <file path> <swift source>
expect() {
    local verdict=$1 guard=$2 file=$3 source=$4 output status=0
    local case_dir
    case_dir=$(mktemp -d "$fixtures/case.XXXXXX")
    mkdir -p "$case_dir/$(dirname "$file")"
    printf '%s\n' "$source" >"$case_dir/$file"
    output=$(cd "$case_dir" && "$guard" "${file%%/*}") || status=$?
    case $verdict/$status in
        rejects/1)
            [[ $output == "$file:1: error: "* ]] && return 0
            echo "✘ $guard rejected $file but printed: $output"
            ;;
        accepts/0) return 0 ;;
        *) echo "✘ $guard should have ${verdict%s}ed $file: $source (status $status) $output" ;;
    esac
    failures=$((failures + 1))
}

expect rejects forbid_textkit1 SceneIt/View.swift 'let manager = view.layoutManager'
expect rejects forbid_textkit1 SceneIt/View.swift 'NSTextView(usingTextLayoutManager: false)'
expect accepts forbid_textkit1 SceneIt/View.swift 'let manager = view.textLayoutManager'

expect rejects forbid_unchecked_logging SceneIt/Store.swift 'let logger = Logger(subsystem: "x", category: "y")'
expect rejects forbid_unchecked_logging SceneIt/Store.swift 'let logger = os.Logger(subsystem: "x", category: "y")'
expect rejects forbid_unchecked_logging SceneIt/Store.swift 'os_log("%@", scene.text)'
expect rejects forbid_unchecked_logging SceneIt/Store.swift 'import OSLog'
expect rejects forbid_unchecked_logging Sources/Core/Store.swift 'let store = try OSLogStore(scope: .system)'
expect rejects forbid_unchecked_logging Tests/CoreTests/StoreTests.swift 'NSLog("%@", scene.text)'
expect accepts forbid_unchecked_logging SceneIt/Store.swift 'Log.store.info("Saved", ["scenes": .count(3)])'
expect accepts forbid_unchecked_logging SceneIt/Store.swift '    /// `OSLogStore` only reads this process.'
expect accepts forbid_unchecked_logging Sources/SceneItCore/Diagnostics/Log.swift 'private let logger: Logger = Logger(subsystem: s, category: c)'
expect accepts forbid_unchecked_logging Sources/SceneItCore/Diagnostics/CurrentProcessLog.swift 'let store = try OSLogStore(scope: .currentProcessIdentifier)'

expect rejects forbid_interpolated_traps SceneIt/Store.swift 'fatalError("bad scene \(scene.text)")'
expect rejects forbid_interpolated_traps SceneIt/Store.swift 'precondition(ok, "unexpected \(title)")'
expect rejects forbid_interpolated_traps SceneIt/Store.swift 'preconditionFailure("\(text)")'
expect rejects forbid_interpolated_traps Sources/Core/Store.swift 'assert(x, "x was \(x)")'
expect rejects forbid_interpolated_traps Sources/Core/Store.swift 'assertionFailure("lost \(paragraph)")'
expect accepts forbid_interpolated_traps SceneIt/Store.swift 'fatalError("Crash Now chosen from the Debug menu")'
expect accepts forbid_interpolated_traps SceneIt/Store.swift 'precondition(index >= 0, "index must not be negative")'
expect accepts forbid_interpolated_traps Tests/CoreTests/T.swift 'Issue.record("not built: \(state)")'

expect rejects forbid_exit_tests SceneItTests/T.swift 'await #expect(processExitsWith: .failure) { crash() }'
expect rejects forbid_exit_tests Tests/CoreTests/T.swift '#require(processExitsWith: .success) {}'
expect rejects forbid_exit_tests SceneItTests/T.swift 'let result: ExitTest.Result = r'
expect accepts forbid_exit_tests SceneItTests/T.swift 'app.terminate(nil)'

expect_missing_path_fails() {
    local status=0
    (cd "$fixtures" && forbid_textkit1 does-not-exist >/dev/null) || status=$?
    [[ $status == 2 ]] && return 0
    echo "✘ a missing path should fail with status 2, got $status"
    failures=$((failures + 1))
}
expect_missing_path_fails

((failures == 0))
