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
    pgrep -f "$(escape_regex "$PWD")/$1/" || true
}

# The extended regular expression that matches exactly <text>.
escape_regex() {
    sed 's/[][\.*^$+?(){}|]/\\&/g' <<<"$1"
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
# stops each process first, parents before children, and lists again until nothing new turns
# up (20 times at most), so a child started between the listing and the kill can't outlive it.
kill_doomed() {
    local pid=$1 folders=$2 before=$3 stopped=' ' process found pass
    for pass in {1..20}; do
        found=0
        for process in $(doomed "$pid" "$folders" "$before" | tail -r); do
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

# with_time_limit's status when the command ran out of time.
readonly timed_out=124

# with_time_limit <seconds> <sample-prefix> <folders> <command>...: runs the command, and if
# it's still running after <seconds>, samples its stuck test runners to
# <sample-prefix>-<pid>.txt, kills what `doomed` lists (kill_doomed), and returns $timed_out.
# Swift Testing's time limits can't end a test that's blocked, so this is what stops a hung
# test run (#77).
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
            return "$timed_out"
        fi
        sleep 0.2
    done
    wait "$pid"
}


# build_folder <folder>: the build database of a build folder the gate uses, then the inputs its
# builds depend on besides the toolchain.
build_folder() {
    case $1 in
        build/DerivedData) echo Build/Intermediates.noindex/XCBuildData/build.db Package.swift SceneIt.xcodeproj Config ;;
        .build) echo out/Intermediates.noindex/XCBuildData/build.db Package.swift ;;
        *) return 1 ;;
    esac
}

# The toolchain a build folder is built with: Xcode, the macOS SDK and Swift.
describe_toolchain() {
    xcodebuild -version && xcrun --sdk macosx --show-sdk-build-version && swift --version 2>&1
}

# fingerprint <toolchain> <input>...: a hash of the toolchain and of the names and contents of
# the inputs' files that git tracks or doesn't ignore, other than xcuserdata.
fingerprint() {
    local toolchain=$1
    shift
    {
        echo "$toolchain"
        git ls-files -z --cached --others --exclude-standard -- "$@" ':(exclude,glob)**/xcuserdata/**' \
            | while IFS= read -r -d '' path; do
                if [[ -e $path ]]; then shasum -a 256 "$path"; else echo "deleted $path"; fi
            done \
            | LC_ALL=C sort
    } | shasum -a 256
}

stale_build_check_failed() {
    echo "$(basename "$0"): stale-build check failed: $*" >&2
    return 1
}

# Whether a Scene It.app from <folder> is running.
app_running_from() {
    local process
    for process in $(built_here "$(escape_regex "$1")"); do
        runs "$process" "$app_pattern" && return 0
    done
    return 1
}

# Whether everything built into <folder> went through a recorded build: the folder holds no
# build database newer than its record, and no build output at all without a database (a
# build system that keeps its database elsewhere can't be checked).
recorded() {
    local folder=$1 database=$2 stamp=$1/scene-it-build-inputs
    [[ -f $stamp ]] || return 1
    if [[ -e $database ]]; then
        [[ ! $database -nt $stamp ]]
    else
        [[ -z $(ls -A "$folder" | grep -vx scene-it-build-inputs) ]]
    fi
}

# prepare_build <folder> <toolchain> <refuse|warn>: deletes the build folder unless every build
# into it since the last deletion was made with this toolchain and these inputs, and ended in
# record_build. Then it records the inputs in the folder. An incremental build can't be trusted
# across either: a new SDK doesn't recompile what it breaks, and a package-graph change can
# leave a stale module that shadows the new one (ADR 0008). If a Scene It.app from a stale
# folder is running, the folder is kept and left unrecorded, and the check fails (`refuse`) or
# passes with a warning (`warn`).
prepare_build() {
    local folder=$1 toolchain=$2 on_running_app=$3 spec stamp=$1/scene-it-build-inputs fingerprint
    spec=($(build_folder "$folder")) || stale_build_check_failed "$folder isn't a build folder" || return
    fingerprint=$(fingerprint "$toolchain" "${spec[@]:1}") \
        || stale_build_check_failed "couldn't hash the inputs of $folder" || return
    if [[ -f $stamp && $(<"$stamp") == "$fingerprint" ]] && recorded "$folder" "$folder/${spec[0]}"; then
        return 0
    fi
    if app_running_from "$folder"; then
        rm -f "$stamp"
        case $on_running_app in
            refuse)
                stale_build_check_failed "$folder is stale, but Scene It.app is running from it." \
                    "Quit the app, then run the gate again."
                return
                ;;
            warn)
                echo "$(basename "$0"): $folder is stale but wasn't cleared, because Scene It.app is" \
                    "running from it. Quit the app, then run this again to build from clean." >&2
                return 0
                ;;
        esac
    fi
    rm -rf "$folder"
    mkdir -p "$folder"
    echo "$fingerprint" >"$stamp"
}

readonly build_locks=build/locks

# lock_build <folder>: claims the folder for this shell until it exits, so another build can't
# clear it during this one's prepare, build and record. The lock is a symbolic link to the
# holder's process ID, created atomically; a lock whose holder has exited is taken over.
lock_build() {
    local lock=$build_locks/lock-${1//\//-} holder attempt
    mkdir -p "$build_locks"
    for attempt in 1 2; do
        ln -s "$$" "$lock" 2>/dev/null && return 0
        holder=$(readlink "$lock") || continue
        [[ $holder != "$$" ]] || return 0
        if kill -0 "$holder" 2>/dev/null; then
            stale_build_check_failed "$1 is in use by process $holder:" \
                "$(ps -o command= -p "$holder" | cut -c1-120)"
            return
        fi
        rm -f "$lock"
    done
    stale_build_check_failed "couldn't lock $1"
}

# Releases the build locks this shell holds.
unlock_builds() {
    local lock
    for lock in "$build_locks"/lock-*; do
        [[ -L $lock && $(readlink "$lock") == "$$" ]] && rm -f "$lock"
    done
    return 0
}

# prepare_builds <refuse|warn> <folder>...: locks each folder, then runs prepare_build on it with
# the current toolchain. The caller releases the locks with unlock_builds.
prepare_builds() {
    local on_running_app=$1 toolchain folder
    shift
    toolchain=$(describe_toolchain) || stale_build_check_failed "couldn't describe the toolchain" || return
    for folder in "$@"; do
        lock_build "$folder" || return
        prepare_build "$folder" "$toolchain" "$on_running_app" || return
    done
}

# record_build <folder>: marks the build that prepare_build prepared as finished, so the build
# database is no newer than the record. A folder prepare_build left unrecorded stays so. Builds
# that were interrupted or ran out of time aren't recorded.
record_build() {
    local stamp=$1/scene-it-build-inputs
    [[ ! -f $stamp ]] || touch "$stamp"
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
