# Shortcuts for the scripts in scripts/ (README.md, "Scripts"). Every recipe has a plain-shell equivalent.

set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

# Builds go through fresh-build.sh, so the gate can trust the build folders they leave (README, "fresh-build.sh").
swift_test := "scripts/fresh-build.sh .build swift test"
xcodebuild := "scripts/fresh-build.sh build/DerivedData xcodebuild -project SceneIt.xcodeproj -scheme SceneIt -destination 'platform=macOS' -derivedDataPath build/DerivedData"

# List the recipes
default:
    @just --list

# Run the commit gate (scripts/check.sh)
check:
    scripts/check.sh

# Format the Swift sources in place (scripts/format.sh)
fmt:
    scripts/format.sh

# Lint the Swift sources as the gate does, without the rest of the gate
lint:
    source scripts/lib.sh && lint_swift

# Run the guard tests, then the source guards over the Swift sources
guards:
    scripts/test-guards.sh
    source scripts/lib.sh && source scripts/guards.sh && forbid_all "${swift_paths[@]}"

# Run the SceneItCore tests (swift test)
test *ARGS:
    {{swift_test}} "$@"

# Run the app-hosted tests (xcodebuild test)
test-app *ARGS:
    {{xcodebuild}} test "$@"

# Run the SceneItCore tests matching PATTERN (swift test --filter)
test-filter PATTERN *ARGS:
    {{swift_test}} --filter "$@"

# Measure line coverage (scripts/coverage.sh [--core-only] [--open])
coverage *ARGS:
    scripts/coverage.sh "$@"

# Run the page fuzz longer than the gate does
fuzz-page SEEDS="8" STEPS="1500":
    TEST_RUNNER_PAGE_FUZZ_SEEDS={{SEEDS}} TEST_RUNNER_PAGE_FUZZ_STEPS={{STEPS}} {{xcodebuild}} test -only-testing:SceneItTests/PageFuzzTests

# Rewrite the corpus results from the Swift implementation (Tests/Corpus/README.md); fails on purpose
corpus-regenerate:
    CORPUS_REGENERATE=1 {{swift_test}} --filter CorpusConformance || echo "The run fails on purpose, one issue per case. Review the diff (git diff Tests/Corpus), then run: just test-filter CorpusConformance"

# Build the Debug app into build/DerivedData
build *ARGS:
    {{xcodebuild}} build "$@"

# Build the Debug app and launch it
run: build
    open "build/DerivedData/Build/Products/Debug/Scene It.app"

# Open the project in Xcode
open:
    open SceneIt.xcodeproj

# Build a signed, notarized DMG (scripts/release.sh)
release:
    scripts/release.sh

# Build a signed zip that isn't notarized, for testers (scripts/release.sh --unnotarized)
release-unnotarized:
    scripts/release.sh --unnotarized

# Delete build output, keeping build/release/ (the dSYMs of shipped builds)
clean:
    if [[ -d build ]]; then find build -mindepth 1 -maxdepth 1 ! -name release -exec rm -rf {} +; fi
    rm -rf .build
