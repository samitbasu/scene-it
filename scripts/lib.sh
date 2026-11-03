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

# Processes running this checkout's build products. A test helper or test host can outlive
# the `swift test` or `xcodebuild` that started it, so it isn't always a descendant.
built_here() {
    local root
    root=$(sed 's/[][\.*^$+?(){}|]/\\&/g' <<<"$PWD")
    pgrep -f "$root/\.?build/" || true
}

# with_time_limit <seconds> <sample-prefix> <command>...: runs the command, and if it's still
# running after <seconds>, samples the stuck build products to <sample-prefix>-<pid>.txt, kills
# them and the command's whole process tree, and returns 124. Swift Testing's time limits can't
# end a test that's blocked, so this is what stops a hung test run (#77).
with_time_limit() {
    local limit=$1 prefix=$2 pid deadline stuck process
    shift 2
    "$@" &
    pid=$!
    deadline=$((SECONDS + limit))
    while kill -0 "$pid" 2>/dev/null; do
        if ((SECONDS >= deadline)); then
            stuck=$(built_here)
            for process in $stuck; do
                sample "$process" 3 -file "$prefix-$process.txt" >/dev/null 2>&1 || true
            done
            kill -9 $(descendants "$pid") $stuck "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            echo "error: still running after $((limit / 60)) min, so it was killed: $*" >&2
            [[ -z $stuck ]] || echo "error: samples of the stuck processes: $prefix-*.txt" >&2
            return 124
        fi
        sleep 0.2
    done
    wait "$pid"
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
