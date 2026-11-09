# Sourced by the scripts in this directory; moves to the repository root.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

readonly swift_paths=(Package.swift Sources Tests SceneIt SceneItTests)

lint_swift() {
    swift format lint --strict --recursive --parallel "${swift_paths[@]}"
}

strip_ansi() {
    sed -E $'s/\x1b\\[[0-9;]*m//g; s/\x1b\\]8;;[^\x1b]*\x1b\\\\//g'
}

# Every process that `pid` started, and theirs, children before parents.
descendants() {
    local child
    for child in $(pgrep -P "$1"); do
        descendants "$child"
        echo "$child"
    done
}

# SwiftPM's .build and xcodebuild's build, as a `built_here` pattern.
readonly every_build_folder='\.?build'

# built_here <folders>: processes running this checkout's build products from the build folders
# whose names match <folders>. <folders> is an extended regular expression, used unescaped, so
# a literal dot is written `\.`, as in `every_build_folder`. A test helper or test host can
# outlive the `swift test` or `xcodebuild` that started it, so it isn't always a descendant.
built_here() {
    local folders=$1 root
    root=$(sed 's/[][\.*^$+?(){}|]/\\&/g' <<<"$PWD")
    pgrep -f "$root/$folders/" || true
}

# Whether `pid`'s command line matches the extended regular expression `pattern`.
runs() {
    local pid=$1 pattern=$2
    ps -o command= -p "$pid" 2>/dev/null | grep -qE "$pattern"
}

readonly app_pattern='/Scene It\.app/'
readonly test_runner_pattern="swiftpm-testing-helper|\.xctest/|$app_pattern"

# The processes a timed-out step is killed with: its own process tree, and the build products
# from its build folders that started while it ran, other than the app. An app that isn't in
# the tree might be the writer's own Debug run, so it's left alone.
doomed() {
    local pid=$1 folders=$2 before=$3 process
    descendants "$pid"
    for process in $(built_here "$folders"); do
        [[ $before == *" $process "* ]] && continue
        runs "$process" "$app_pattern" && continue
        echo "$process"
    done
    echo "$pid"
}

# kill_doomed <pid> <folders> <before>: kills what `doomed` lists, other than this shell. It
# stops each process first and lists again until nothing new turns up, so a child started
# between the listing and the kill can't outlive it.
kill_doomed() {
    local pid=$1 folders=$2 before=$3 stopped=' ' process found
    while :; do
        found=0
        for process in $(doomed "$pid" "$folders" "$before"); do
            [[ $process == "$$" || $stopped == *" $process "* ]] && continue
            kill -STOP "$process" 2>/dev/null || continue
            stopped+="$process "
            found=1
        done
        ((found)) || break
    done
    kill -9 $stopped 2>/dev/null || true
}

# sample_test_runners <prefix> <pid>...: samples up to four of the test runners among the
# processes, at once, for 3 seconds, to <prefix>-<pid>.txt. Prints how many it sampled.
sample_test_runners() {
    local prefix=$1 process samplers=() count=0
    shift
    for process in "$@"; do
        ((count < 4)) || break
        runs "$process" "$test_runner_pattern" || continue
        sample "$process" 3 -file "$prefix-$process.txt" >/dev/null 2>&1 &
        samplers+=($!)
        count=$((count + 1))
    done
    ((count == 0)) || wait "${samplers[@]}" 2>/dev/null || true
    echo "$count"
}

# with_time_limit <seconds> <sample-prefix> <folders> <command>...: runs the command, and if
# it's still running after <seconds>, samples its stuck test runners to
# <sample-prefix>-<pid>.txt, kills what `doomed` lists (kill_doomed), and returns 124. Swift
# Testing's time limits can't end a test that's blocked, so this is what stops a hung test run
# (#77).
# <folders> is the `built_here` pattern for the command's own build folders, so a timeout
# spares a command running alongside it from another folder.
with_time_limit() {
    local limit=$1 prefix=$2 folders=$3 pid deadline before sampled duration
    shift 3
    before=" $(built_here "$folders" | tr '\n' ' ') "
    "$@" &
    pid=$!
    deadline=$((SECONDS + limit))
    while kill -0 "$pid" 2>/dev/null; do
        if ((SECONDS >= deadline)); then
            sampled=$(sample_test_runners "$prefix" $(doomed "$pid" "$folders" "$before" | sort -u))
            kill_doomed "$pid" "$folders" "$before"
            wait "$pid" 2>/dev/null || true
            if ((limit < 60)); then duration="$limit s"; else duration="$((limit / 60)) min"; fi
            echo "error: still running after $duration, so it was killed: $*" >&2
            ((sampled == 0)) || echo "error: samples of its stuck test runners: $prefix-*.txt" >&2
            return 124
        fi
        sleep 0.2
    done
    wait "$pid"
}


# The toolchain a build folder is built with: Xcode, the macOS SDK and Swift.
describe_toolchain() {
    xcodebuild -version
    xcrun --sdk macosx --show-sdk-build-version
    swift --version 2>&1
}

# clear_stale_build <folder> <toolchain> <input>...: deletes the build folder unless it was
# built with this toolchain (from describe_toolchain) and these inputs (files or directories),
# then records them in the folder. An incremental build can't be trusted across either: a new
# SDK doesn't recompile what it breaks, and a package-graph change can leave a stale module
# that shadows the new one (#151).
clear_stale_build() {
    local folder=$1 toolchain=$2 stamp=$1/scene-it-build-inputs fingerprint
    shift 2
    fingerprint=$({
        echo "$toolchain"
        find "$@" -type f -not -path '*/xcuserdata/*' -exec shasum -a 256 {} + | sort
    } | shasum -a 256)
    [[ -f $stamp && $(<"$stamp") == "$fingerprint" ]] && return 0
    rm -rf "$folder"
    mkdir -p "$folder"
    echo "$fingerprint" >"$stamp"
}

# Prints a failed step's error and warning lines from its log, or the log's tail if none match.
print_log_diagnostics() {
    local log=$1 diagnostics
    diagnostics=$(grep -E 'error:|warning:|✘|\*\* [A-Z ]+ FAILED' "$log" | grep -v appintentsmetadataprocessor | strip_ansi || true)
    if [[ -n $diagnostics ]]; then
        echo "$diagnostics" >&2
    else
        tail -n 50 "$log" | strip_ansi >&2
    fi
}
