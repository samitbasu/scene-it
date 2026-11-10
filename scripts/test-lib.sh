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
    prepare_build "$folder" "$toolchain" refuse 2>"$fixtures/stderr" || fail "prepare_build failed after $happened"
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
rm "$app_db"
expect_build cleared build/DerivedData 'Xcode 2' 'its build database went missing'
rm Config/Info.plist
expect_build cleared build/DerivedData 'Xcode 2' 'a tracked file was deleted without staging'
expect_build kept build/DerivedData 'Xcode 2' 'nothing changed since the deletion'

expect_build cleared .build 'Xcode 2' 'nothing was built yet'
expect_build kept .build 'Xcode 2' 'nothing changed'
touch -t 202001010000 .build/scene-it-build-inputs
touch "$core_db"
expect_build cleared .build 'Xcode 2' 'a swift build that skipped record_build'
echo 'let package = 3' >Package.swift
expect_build cleared .build 'Xcode 2' 'Package.swift changed'
expect_build cleared build/DerivedData 'Xcode 2' 'Package.swift changed'

# A stale folder an app is running from is kept, unrecorded, until the app quits. The gate
# (`refuse`) fails on it; fresh-build.sh (`warn`) goes on.
readonly app="$PWD/build/DerivedData/Build/Products/Debug/Scene It.app/Contents/MacOS/Scene It"
sleep_at "$app"
start "$app" 30
sleep 0.2
echo 'objects = { a }' >SceneIt.xcodeproj/project.pbxproj
status=0
prepare_build build/DerivedData 'Xcode 2' refuse 2>"$fixtures/stderr" || status=$?
[[ $status != 0 ]] || fail "the gate's prepare_build passed a stale folder an app was running from"
[[ $(<"$fixtures/stderr") == *"stale-build check failed: "*"Quit the app, then run the gate again."* ]] \
    || fail "the gate's prepare_build didn't say why it failed: $(<"$fixtures/stderr")"
[[ -f build/DerivedData/product ]] || fail "prepare_build cleared a folder an app was running from"
[[ ! -e build/DerivedData/scene-it-build-inputs ]] || fail "prepare_build recorded a stale folder it kept"
prepare_build build/DerivedData 'Xcode 2' warn 2>"$fixtures/stderr" || fail "prepare_build warn failed with the app running"
[[ $(<"$fixtures/stderr") == *"wasn't cleared, because Scene It.app is running from it"* ]] \
    || fail "prepare_build warn didn't say why it kept a stale folder: $(<"$fixtures/stderr")"
[[ -f build/DerivedData/product ]] || fail "prepare_build warn cleared a folder an app was running from"
[[ ! -e build/DerivedData/scene-it-build-inputs ]] || fail "prepare_build warn recorded a stale folder it kept"
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
    prepare_builds refuse build/DerivedData
)
expect_failure 'with no toolchain' failing_toolchain

# The lock: a live holder keeps another build out, an exited one is taken over, and a shell
# releases only its own locks.
readonly app_lock=build/locks/lock-build-DerivedData
prepare_builds_with_toolchain() (
    describe_toolchain() { echo 'Xcode 2'; }
    prepare_builds "$@"
)
start sleep 35
readonly lock_holder=${started[${#started[@]} - 1]}
mkdir -p build/locks
ln -s "$lock_holder" "$app_lock"
touch build/DerivedData/product
echo 'objects = { b }' >SceneIt.xcodeproj/project.pbxproj
expect_failure 'while another build holds the folder' prepare_builds_with_toolchain refuse build/DerivedData
[[ $(<"$fixtures/stderr") == *"build/DerivedData is in use by process $lock_holder"* ]] \
    || fail "the lock didn't name its holder: $(<"$fixtures/stderr")"
[[ -f build/DerivedData/product ]] || fail "a build cleared a folder another build held"
{
    kill -9 "$lock_holder"
    wait "$lock_holder" || true
} 2>/dev/null
prepare_builds_with_toolchain refuse build/DerivedData 2>"$fixtures/stderr" \
    || fail "a lock whose holder exited wasn't taken over: $(<"$fixtures/stderr")"
[[ $(readlink "$app_lock") == "$$" ]] || fail "the lock wasn't taken over: $(readlink "$app_lock")"
[[ ! -e build/DerivedData/product ]] || fail "the build after a takeover didn't clear the stale folder"
lock_build .build
ln -s 1 build/locks/lock-elsewhere
unlock_builds
[[ ! -L $app_lock && ! -L build/locks/lock-.build ]] || fail "unlock_builds kept this shell's locks"
[[ -L build/locks/lock-elsewhere ]] || fail "unlock_builds removed another process's lock"
rm build/locks/lock-elsewhere

cd "$fixtures/not-a-repo"
expect_failure 'outside a git repository' prepare_build build/DerivedData 'Xcode 2' refuse
expect_failure 'with an unknown folder' prepare_build build/Elsewhere 'Xcode 2' refuse

# --- The docs-only gate ---------------------------------------------------------------------

for path in README.md CLAUDE.md LICENSE docs/decisions/0001-x.md docs/dev/WORKFLOW.md docs/user/guide.md \
    site/index.html site/images/a.png design/icon/notes.txt design/icon/art.png \
    novel-app-build-bundle/PLAN.md .github/workflows/check.yml .github/workflows/pages.yaml; do
    is_docs_path "$path" || fail "is_docs_path took $path for code"
done
for path in Package.swift Justfile .swift-format .gitignore Sources/SceneItCore/A.swift \
    Tests/Corpus/README.md Tests/Corpus/book/s1/book.md SceneIt/Notes.md SceneItTests/A.swift \
    scripts/check.sh scripts/README.md Config/Info.plist SceneIt.xcodeproj/project.pbxproj \
    docs/format/book-format.md docs/tutorial/01-anatomy.md design/icon/generate.swift \
    novel-app-build-bundle/mockups/screenshots/01-main-window.png .github/actions/x/action.yml \
    unknown/README.md LICENSE.txt '"docs/caf\303\251.md"'; do
    ! is_docs_path "$path" || fail "is_docs_path took $path for docs"
done

mkdir -p "$fixtures/docs-gate"
cd "$fixtures/docs-gate"
git init -q -b main
git config user.email gate@example.com
git config user.name Gate
git config commit.gpgsign false
mkdir -p docs Sources
echo 'readme' >README.md
echo 'decision' >docs/decision.md
echo 'let a = 1' >Sources/A.swift
git add -A
git commit -qm base
git branch base

# expect_scope <docs|full> <what> [<paths printed>]: what docs_only_change makes of the
# checked-out commit, compared with the `base` branch.
expect_scope() {
    local scope=$1 what=$2 printed status=0
    printed=$(docs_only_change base) || status=$?
    case $scope in
        docs)
            ((status == 0)) || fail "docs_only_change ran the full gate on $what"
            [[ $printed == "$3" ]] || fail "docs_only_change listed '$printed' for $what, not '$3'"
            ;;
        full) ((status != 0)) || fail "docs_only_change skipped the build for $what: $printed" ;;
    esac
}

# on_branch <name> <command>…: starts branch <name> from `base`, runs the command and commits.
on_branch() {
    local name=$1
    shift
    git switch -q -c "$name" base
    "$@"
    git add -A
    git commit -qm "$name"
}

expect_scope full 'the base itself, with nothing changed'
on_branch docs-only eval 'echo more >>README.md; echo more >>docs/decision.md'
expect_scope docs 'a docs-only change' $'README.md\ndocs/decision.md'
CHECK_FULL=1 expect_scope full 'a docs-only change with CHECK_FULL set'
echo 'let b = 2' >Sources/B.swift
expect_scope full 'a docs-only commit with an untracked file'
rm Sources/B.swift
echo 'more' >>README.md
expect_scope full 'a docs-only commit with a modified file'
git checkout -q README.md
on_branch mixed eval 'echo more >>README.md; echo "let a = 2" >Sources/A.swift'
expect_scope full 'a change to docs and code'
on_branch code-only eval 'echo "let a = 3" >Sources/A.swift'
expect_scope full 'a code-only change'
on_branch unknown eval 'echo "x" >Justfile'
expect_scope full 'a change to a path that is neither'
on_branch renamed-out git mv Sources/A.swift docs/A.swift
expect_scope full 'a rename from code into docs'
on_branch renamed-in-docs git mv docs/decision.md docs/renamed.md
expect_scope docs 'a rename within docs' $'docs/decision.md\ndocs/renamed.md'
git switch -q docs-only
git merge -q --no-edit code-only
expect_scope full 'a docs-only branch that merged in code'
! docs_only_change no-such-branch >/dev/null 2>&1 || fail "docs_only_change skipped the build with no merge-base"

# --- check_html ------------------------------------------------------------------------------

printf '%s\n' '<!DOCTYPE html>' '<html><head><meta charset="utf-8"><title>t</title></head>' \
    '<body><main><p>One<br>two</p><img src="a.png" alt=""/></main></body></html>' >"$fixtures/good.html"
check_html "$fixtures/good.html" >"$fixtures/output" || fail "check_html rejected well-formed HTML: $(<"$fixtures/output")"
printf '%s\n' '<html><body>' '<main><p>x</div>' '</body></html>' >"$fixtures/bad.html"
status=0
check_html "$fixtures/bad.html" >"$fixtures/output" || status=$?
((status != 0)) || fail "check_html accepted a mismatched end tag"
[[ $(<"$fixtures/output") == *"bad.html:2: error: </div> where </p> was expected"* ]] \
    || fail "check_html didn't name the mismatched tag's line: $(<"$fixtures/output")"
printf '%s\n' '<html><body>' '<section>' '</body></html>' >"$fixtures/open.html"
! check_html "$fixtures/open.html" >/dev/null || fail "check_html accepted an element left open"

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
