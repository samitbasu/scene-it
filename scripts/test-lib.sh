#!/usr/bin/env bash
# Tests for the gate's helpers in lib.sh: clear_stale_build and kill_doomed. Silent and exit 0
# when they pass; otherwise lists failures.
set -euo pipefail

source "$(dirname "$0")/lib.sh"
readonly lib=$PWD/scripts/lib.sh

fixtures=$(mktemp -d "${TMPDIR:-/tmp}/scene-it-lib-tests.XXXXXX")
readonly sleeper="sleep 30.$$"
trap 'pkill -fx "$sleeper" || true; rm -rf "$fixtures"' EXIT
failures=0

fail() {
    echo "✘ $*"
    failures=$((failures + 1))
}

cd "$fixtures"
mkdir -p project/Package project/App.xcodeproj/xcuserdata
echo 'let package = 1' >project/Package/Package.swift
echo 'objects = {}' >project/App.xcodeproj/project.pbxproj

# expect_build <kept|cleared> <what changed> <toolchain>
expect_build() {
    local verdict=$1 change=$2
    clear_stale_build out "$3" project
    [[ -f out/scene-it-build-inputs ]] || fail "clear_stale_build left no record of its inputs"
    case $verdict in
        kept) [[ -f out/product ]] || fail "the build folder was cleared after $change" ;;
        cleared) [[ ! -e out/product ]] || fail "the build folder was kept after $change" ;;
    esac
    touch out/product
}

expect_build cleared 'nothing was built yet' 'Xcode 1'
expect_build kept 'nothing changed' 'Xcode 1'
echo 'let package = 2' >project/Package/Package.swift
expect_build cleared 'an input file changed' 'Xcode 1'
echo 'scheme' >project/App.xcodeproj/Scheme.xcscheme
expect_build cleared 'a file was added to an input directory' 'Xcode 1'
mv project/App.xcodeproj/Scheme.xcscheme project/App.xcodeproj/Renamed.xcscheme
expect_build cleared 'a file was renamed' 'Xcode 1'
expect_build cleared 'the toolchain changed' 'Xcode 2'
echo 'state' >project/App.xcodeproj/xcuserdata/state
expect_build kept 'only xcuserdata changed' 'Xcode 2'
rm out/scene-it-build-inputs
expect_build cleared 'its record was lost' 'Xcode 2'

# survivors: waits up to 2 s for the sleepers to go, then prints any left.
survivors() {
    local tries
    for tries in {1..20}; do
        pgrep -fx "$sleeper" >/dev/null || return 0
        sleep 0.1
    done
    pgrep -fx "$sleeper"
}

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
' _ "$lib" "$fixtures" "$sleeper" >"$fixtures/output" 2>/dev/null
[[ $(<"$fixtures/output") == survived ]] || fail "kill_doomed killed the shell that called it"
leftovers=$(survivors) || true
[[ -z $leftovers ]] || fail "kill_doomed left processes running: $leftovers"
pkill -fx "$sleeper" || true

# The same tree killed from outside, as a timed-out step is.
( for _ in {1..300}; do $sleeper & sleep 0.01; done ) &
spawner=$!
sleep 0.5
{
    kill_doomed "$spawner" build " "
    wait "$spawner" || true
} 2>/dev/null
leftovers=$(survivors) || true
[[ -z $leftovers ]] || fail "kill_doomed left a timed-out step's processes running: $leftovers"

((failures == 0))
