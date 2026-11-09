#!/usr/bin/env bash
# Line coverage of SceneItCore (swift test) and the app (xcodebuild test). Not part of the gate.
# Prints a per-area table, the totals and the least-covered files; exits non-zero if a test fails.
set -euo pipefail

source "$(dirname "$0")/lib.sh"

usage() {
    echo "usage: scripts/coverage.sh [--core-only] [--open]" >&2
    exit 2
}

app=yes
open_html=no
for arg in "$@"; do
    case $arg in
        --core-only) app=no ;;
        --open) open_html=yes ;;
        *) usage ;;
    esac
done

# Instrumentation slows code unevenly, so the suites that compare timings would fail spuriously.
readonly timing_suites=(ScalingTests PerformanceTests SearchPerformanceTests)
readonly out=build/coverage
readonly core_html="$out/core-html"
readonly app_bundle="$out/app.xcresult"
readonly records="$out/files.tsv"
rm -rf "$core_html" "$app_bundle"
mkdir -p "$out"

fail() {
    local step=$1 log=$2
    echo "coverage.sh: $step failed (full log: $log)" >&2
    print_log_diagnostics "$log"
    exit 1
}

run() {
    local step=$1
    shift
    local log="$out/$step.log"
    "$@" >"$log" 2>&1 || fail "$step" "$log"
}

skips=()
for suite in "${timing_suites[@]}"; do
    skips+=(--skip "$suite")
done
run swift-test scripts/fresh-build.sh .build swift test --enable-code-coverage "${skips[@]}"

codecov_dir=$(dirname "$(swift test --show-codecov-path)")
# The bundle is SceneItCorePackageTests.xctest with the native build system, SceneItCoreTests.xctest with swiftbuild.
core_binaries=("$(swift build --show-bin-path)"/SceneItCore*Tests.xctest/Contents/MacOS/*)
[[ ${#core_binaries[@]} == 1 && -x ${core_binaries[0]} ]] \
    || { echo "coverage.sh: expected one SceneItCore test binary, found: ${core_binaries[*]}" >&2; exit 1; }
core_binary=${core_binaries[0]}
llvm_cov_args=(
    "$core_binary"
    -instr-profile "$codecov_dir/default.profdata"
    -ignore-filename-regex '(/Tests/|/\.build/)'
)
run llvm-cov-html xcrun llvm-cov show -format=html -output-dir "$core_html" "${llvm_cov_args[@]}"
xcrun llvm-cov export -summary-only "${llvm_cov_args[@]}" 2>"$out/llvm-cov-export.log" \
    | jq -r --arg root "$PWD/" '.data[0].files[]
        | [(.filename | ltrimstr($root)), .summary.lines.covered, .summary.lines.count] | @tsv' \
    >"$records"

if [[ $app == yes ]]; then
    run xcodebuild xcodebuild \
        -project SceneIt.xcodeproj \
        -scheme SceneIt \
        -destination 'platform=macOS' \
        -derivedDataPath "$out/DerivedData" \
        -resultBundlePath "$app_bundle" \
        -enableCodeCoverage YES \
        test
    xcrun xccov view --report --json "$app_bundle" 2>"$out/xccov.log" \
        | jq -r --arg root "$PWD/" '.targets[] | select(.name == "Scene It.app") | .files[]
            | [(.path | ltrimstr($root)), .coveredLines, .executableLines] | @tsv' \
        >>"$records"
fi

# Area: the directory under Sources/SceneItCore or SceneIt, or the root itself for files directly in it.
awk -F'\t' '
    function percent(covered, count) { return count ? sprintf("%5.1f%%", 100 * covered / count) : "    -" }
    $3 > 0 {
        n = split($1, part, "/")
        root = ($1 ~ /^Sources\/SceneItCore\//) ? "Sources/SceneItCore" : part[1]
        depth = (root == "Sources/SceneItCore") ? 3 : 2
        area = (n > depth) ? root "/" part[depth] : root
        covered[area] += $2; count[area] += $3
        total_covered[root] += $2; total_count[root] += $3
    }
    END {
        printf "%-36s %8s %8s %7s\n", "Area", "Covered", "Lines", "Cover"
        for (area in count) printf "%-36s %8d %8d %7s\n", area, covered[area], count[area], percent(covered[area], count[area]) | "sort"
        close("sort")
        print ""
        for (root in total_count) printf "%-36s %8d %8d %7s\n", "Total " root, total_covered[root], total_count[root], percent(total_covered[root], total_count[root]) | "sort"
    }' "$records"

echo
echo "Least covered files:"
awk -F'\t' '$3 > 0 { printf "%8.4f\t%5.1f%%  %5d/%-5d  %s\n", $2 / $3, 100 * $2 / $3, $2, $3, $1 }' "$records" \
    | sort -n | head -n 5 | cut -f2-

echo
echo "Skipped under coverage (timing-sensitive): ${timing_suites[*]}"
echo "Core HTML: $PWD/$core_html/index.html"
if [[ $app == yes ]]; then
    echo "App result bundle: $PWD/$app_bundle"
fi

if [[ $open_html == yes ]]; then
    open "$core_html/index.html"
fi
