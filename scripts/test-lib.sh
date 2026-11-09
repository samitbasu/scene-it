#!/usr/bin/env bash
# Tests for the gate's helpers in lib.sh: the stale-build check (prepare_build, record_build)
# and kill_doomed. Silent and exit 0 when they pass; otherwise lists failures.
set -euo pipefail

source "$(dirname "$0")/lib.sh"
readonly lib=$PWD/scripts/lib.sh
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

fixtures=$(mktemp -d "${TMPDIR:-/tmp}/scene-it-lib-tests.XXXXXX")
readonly sleeper="sleep 30.$$"
started=()
trap 'exec 2>/dev/null; kill -9 ${started[@]+"${started[@]}"} 2>/dev/null || true; pkill -fx "$sleeper" || true; rm -rf "$fixtures"' EXIT
failures=0

fail() {
    echo "✘ $*"
    failures=$((failures + 1))
}

# start <command>...: starts the command in the background, outside any tree under test.
start() {
    "$@" &
    started+=($!)
}

# A link to sleep at <path>, so its command line names that path.
sleep_at() {
    mkdir -p "$(dirname "$1")"
    ln -s /bin/sleep "$1"
}

# --- The stale-build check -------------------------------------------------------------------

mkdir -p "$fixtures/repo" "$fixtures/not-a-repo"
cd "$fixtures/repo"
git init -q
mkdir -p SceneIt.xcodeproj/xcuserdata Config Sources
printf '%s\n' 'xcuserdata/' '.DS_Store' >.gitignore
echo 'let package = 1' >Package.swift
echo 'objects = {}' >SceneIt.xcodeproj/project.pbxproj
echo '<plist/>' >Config/Info.plist
git add Package.swift SceneIt.xcodeproj Config
readonly app_db=build/DerivedData/Build/Intermediates.noindex/XCBuildData/build.db
readonly core_db=.build/out/Intermediates.noindex/XCBuildData/build.db

# expect_build <kept|cleared> <folder> <toolchain> <what happened>: runs prepare_build, then
# builds into the folder the way the gate does (a product, the build database, record_build).
expect_build() {
    local verdict=$1 folder=$2 toolchain=$3 happened=$4 database
    database=$folder/$(build_folder "$folder" | cut -d' ' -f1)
    prepare_build "$folder" "$toolchain" 2>"$fixtures/stderr" || fail "prepare_build failed after $happened"
    [[ ! -s $fixtures/stderr ]] || fail "prepare_build printed after $happened: $(<"$fixtures/stderr")"
    [[ -f $folder/scene-it-build-inputs ]] || fail "prepare_build left no record in $folder after $happened"
    case $verdict in
        kept) [[ -f $folder/product ]] || fail "$folder was cleared after $happened" ;;
        cleared) [[ ! -e $folder/product ]] || fail "$folder was kept after $happened" ;;
    esac
    touch "$folder/product"
    mkdir -p "$(dirname "$database")"
    touch "$database"
    record_build "$folder"
}

expect_build cleared build/DerivedData 'Xcode 1' 'nothing was built yet'
expect_build kept build/DerivedData 'Xcode 1' 'nothing changed'
echo 'let package = 2' >Package.swift
expect_build cleared build/DerivedData 'Xcode 1' 'a tracked input changed'
echo 'scheme' >SceneIt.xcodeproj/Scheme.xcscheme
expect_build cleared build/DerivedData 'Xcode 1' 'an untracked file was added to an input directory'
mv SceneIt.xcodeproj/Scheme.xcscheme SceneIt.xcodeproj/Renamed.xcscheme
expect_build cleared build/DerivedData 'Xcode 1' 'a file was renamed'
expect_build cleared build/DerivedData 'Xcode 2' 'the toolchain changed'
echo 'state' >SceneIt.xcodeproj/xcuserdata/state
expect_build kept build/DerivedData 'Xcode 2' 'only xcuserdata changed'
echo 'finder' >Config/.DS_Store
expect_build kept build/DerivedData 'Xcode 2' 'only an ignored file changed'
echo 'struct S {}' >Sources/S.swift
expect_build kept build/DerivedData 'Xcode 2' 'a file outside the inputs changed'
rm build/DerivedData/scene-it-build-inputs
expect_build cleared build/DerivedData 'Xcode 2' 'its record was lost'
touch -t 202001010000 build/DerivedData/scene-it-build-inputs
touch "$app_db"
expect_build cleared build/DerivedData 'Xcode 2' 'a build that skipped record_build'

expect_build cleared .build 'Xcode 2' 'nothing was built yet'
expect_build kept .build 'Xcode 2' 'nothing changed'
touch -t 202001010000 .build/scene-it-build-inputs
touch "$core_db"
expect_build cleared .build 'Xcode 2' 'a swift build that skipped record_build'
echo 'let package = 3' >Package.swift
expect_build cleared .build 'Xcode 2' 'Package.swift changed'
expect_build cleared build/DerivedData 'Xcode 2' 'Package.swift changed'

# A stale folder an app is running from is kept, unrecorded, until the app quits.
readonly app="$PWD/build/DerivedData/Build/Products/Debug/Scene It.app/Contents/MacOS/Scene It"
sleep_at "$app"
start "$app" 30
sleep 0.2
echo 'objects = { a }' >SceneIt.xcodeproj/project.pbxproj
prepare_build build/DerivedData 'Xcode 2' 2>"$fixtures/stderr" || fail "prepare_build failed with the app running"
[[ $(<"$fixtures/stderr") == *"wasn't cleared, because Scene It.app is running from it"* ]] \
    || fail "prepare_build didn't say why it kept a stale folder: $(<"$fixtures/stderr")"
[[ -f build/DerivedData/product ]] || fail "prepare_build cleared a folder an app was running from"
[[ ! -e build/DerivedData/scene-it-build-inputs ]] || fail "prepare_build recorded a stale folder it kept"
{
    kill -9 "${started[@]}"
    wait "${started[@]}" || true
} 2>/dev/null
started=()
expect_build cleared build/DerivedData 'Xcode 2' 'the app it was running quit'

# expect_failure <what> <command>...: the command fails and says the stale-build check failed.
expect_failure() {
    local what=$1 status=0
    shift
    "$@" 2>"$fixtures/stderr" || status=$?
    [[ $status != 0 ]] || fail "the stale-build check passed $what"
    [[ $(<"$fixtures/stderr") == *": stale-build check failed: "* ]] \
        || fail "the stale-build check didn't report $what: $(<"$fixtures/stderr")"
}

failing_toolchain() (
    describe_toolchain() { return 1; }
    prepare_builds build/DerivedData
)
expect_failure 'with no toolchain' failing_toolchain
cd "$fixtures/not-a-repo"
expect_failure 'outside a git repository' prepare_build build/DerivedData 'Xcode 2'
expect_failure 'with an unknown folder' prepare_build build/Elsewhere 'Xcode 2'

# --- kill_doomed ----------------------------------------------------------------------------

# survivors: waits up to 2 s for the sleepers to go, then prints any left.
survivors() {
    local tries
    for tries in {1..20}; do
        pgrep -fx "$sleeper" >/dev/null || return 0
        sleep 0.1
    done
    pgrep -fx "$sleeper"
}

# expect_untouched <pid> <what>: the process is still running, and not stopped.
expect_untouched() {
    local state
    state=$(ps -o state= -p "$1") || { fail "kill_doomed killed $2"; return; }
    [[ $state != T* ]] || fail "kill_doomed left $2 stopped"
}

mkdir -p "$fixtures/procs"
cd "$fixtures/procs"
start sleep 31
readonly decoy=${started[${#started[@]} - 1]}

# A shell killing its own process tree while a child keeps starting new ones (for 3 s at most),
# as the gate does when it's interrupted. Nothing it started may survive, and it must outlive
# the call. Bash reports each killed job on stderr, so stderr is dropped. The output goes to a
# file because an orphan would hold a pipe open until it ended.
bash -c '
    source "$1"
    cd "$2"
    ( for _ in {1..300}; do $3 & sleep 0.01; done ) &
    sleep 0.5
    kill_doomed $$ build " "
    echo survived
' _ "$lib" "$fixtures/procs" "$sleeper" >"$fixtures/output" 2>/dev/null
[[ $(<"$fixtures/output") == survived ]] || fail "kill_doomed killed the shell that called it"
leftovers=$(survivors) || true
[[ -z $leftovers ]] || fail "kill_doomed left processes running: $leftovers"
pkill -fx "$sleeper" || true
expect_untouched "$decoy" 'a process outside the tree'

# The same tree killed from outside, as a timed-out step is, along with the build products
# that started while it ran, other than the app.
readonly helper=$PWD/build/Products/Debug/helper
readonly test_host="$PWD/build/Products/Debug/Scene It.app/Contents/MacOS/Scene It"
sleep_at "$helper"
sleep_at "$test_host"
start "$helper" 32
readonly earlier_helper=${started[${#started[@]} - 1]}
sleep 0.2
before=" $(built_here build | tr '\n' ' ') "
[[ $before == *" $earlier_helper "* ]] || fail "built_here didn't list a build product: $earlier_helper"
start "$helper" 33
readonly later_helper=${started[${#started[@]} - 1]}
start "$test_host" 34
readonly later_app=${started[${#started[@]} - 1]}
( for _ in {1..300}; do $sleeper & sleep 0.01; done ) &
spawner=$!
sleep 0.5
{
    kill_doomed "$spawner" build "$before"
    wait "$spawner" || true
    wait "$later_helper" || true
} 2>/dev/null
leftovers=$(survivors) || true
[[ -z $leftovers ]] || fail "kill_doomed left a timed-out step's processes running: $leftovers"
! kill -0 "$later_helper" 2>/dev/null || fail "kill_doomed spared a build product started while the step ran"
expect_untouched "$earlier_helper" 'a build product that was already running'
expect_untouched "$later_app" 'the app'
expect_untouched "$decoy" 'a process outside the tree'

((failures == 0))
