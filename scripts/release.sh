#!/usr/bin/env bash
# Builds a distributable Scene It (docs/decisions/0001-distribution-developer-id.md).
# Prints only the output paths on success; otherwise the failing step's diagnostics.
set -euo pipefail

source "$(dirname "$0")/lib.sh"

usage() {
    echo "usage: scripts/release.sh [--unnotarized]" >&2
    exit 2
}

readonly team=8H6754RJ2W
readonly identity="Developer ID Application: Samit BASU ($team)"
readonly notary_profile=scene-it-notary
readonly app_name="Scene It"

notarize=yes
case $# in
    0) ;;
    1) [[ $1 == --unnotarized ]] || usage; notarize=no ;;
    *) usage ;;
esac

die() {
    echo "release.sh: $*" >&2
    exit 1
}

# A step that takes longer than an hour fails.
run() {
    local step=$1
    shift
    local log="$log_dir/$step.log"
    with_time_limit 3600 "$log_dir/$step-hang" "$every_build_folder" "$@" >>"$log" 2>&1 || {
        echo "release.sh: $step failed (full log: $log)" >&2
        print_log_diagnostics "$log"
        exit 1
    }
}

require_clean_tree() {
    local changes
    changes=$(git status --porcelain --untracked-files=normal)
    [[ -z $changes ]] || die "the working tree has uncommitted changes; commit or remove them first:
$changes"
}

require_merged_commit() {
    [[ $(git rev-parse --is-shallow-repository) == false ]] \
        || die "this is a shallow clone, so the commit count (the build number) is wrong; run git fetch --unshallow"
    git fetch -q origin || die "can't fetch origin"
    git merge-base --is-ancestor HEAD "$main_branch" \
        || die "HEAD is not on origin/main. Release only merged commits, so each build number names one commit and later releases get higher numbers."
}

require_identity() {
    local identities
    identities=$(security find-identity -v -p codesigning)
    [[ $identities == *"\"$identity\""* ]] \
        || die "no valid \"$identity\" signing identity in the keychain (see issue #3)"
}

require_notary_profile() {
    local output
    output=$(xcrun notarytool history --keychain-profile "$notary_profile" 2>&1) || die "notarytool can't use the keychain profile \"$notary_profile\":
$output
Create the profile once (it prompts for an app-specific password from account.apple.com), then re-run:
    xcrun notarytool store-credentials $notary_profile --apple-id <your Apple ID email> --team-id $team
Or build a tester copy without notarization: scripts/release.sh --unnotarized"
}

release_setting() {
    local settings
    settings=$(xcodebuild -project SceneIt.xcodeproj -target SceneIt -configuration Release \
        -showBuildSettings -json) || die "xcodebuild -showBuildSettings failed"
    jq -er ".[0].buildSettings.$1" <<<"$settings" || die "no $1 in the Release build settings"
}

# Checks the things notarization rejects: a broken seal, another team, no hardened runtime,
# no secure timestamp.
verify_signature() {
    local path=$1 step=$2 details
    run "$step" codesign --verify --deep --strict --verbose=2 "$path"
    run "$step-details" codesign -dvv "$path"
    details=$(<"$log_dir/$step-details.log")
    grep -qx "TeamIdentifier=$team" <<<"$details" || die "$path is not signed by team $team"
    grep -q '^Timestamp=' <<<"$details" || die "$path has no secure timestamp"
    if [[ $path == *.app ]]; then
        grep -qE '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details" \
            || die "$path is not signed with the hardened runtime"
    fi
}

submit_for_notarization() {
    local file=$1 step=$2 result status id
    result=$(xcrun notarytool submit "$file" --keychain-profile "$notary_profile" --wait \
        --output-format json 2>>"$log_dir/$step.log") || true
    echo "$result" >>"$log_dir/$step.log"
    status=$(jq -r '.status // empty' <<<"$result" 2>/dev/null || true)
    id=$(jq -r '.id // empty' <<<"$result" 2>/dev/null || true)
    [[ $status == Accepted ]] && return 0
    echo "release.sh: notarization of $file ended with status '${status:-unknown}' (full log: $log_dir/$step.log)" >&2
    if [[ -z $id ]]; then
        print_log_diagnostics "$log_dir/$step.log"
    elif xcrun notarytool log "$id" --keychain-profile "$notary_profile" "$log_dir/$step-notary.json" \
        >/dev/null 2>&1; then
        cat "$log_dir/$step-notary.json" >&2
    else
        echo "Fetch Apple's log with: xcrun notarytool log $id --keychain-profile $notary_profile" >&2
    fi
    exit 1
}

# The ticket can take a little while to become fetchable after notarytool reports Accepted.
staple() {
    local path=$1 step=$2 attempt
    for attempt in 1 2 3; do
        xcrun stapler staple "$path" >>"$log_dir/$step.log" 2>&1 && return 0
        ((attempt == 3)) || sleep $((attempt * 15))
    done
    echo "release.sh: $step failed 3 times (full log: $log_dir/$step.log)" >&2
    print_log_diagnostics "$log_dir/$step.log"
    exit 1
}

assess() {
    local type=$1 path=$2 verdict
    verdict=$(spctl -a -vvv -t "$type" "$path" 2>&1) || die "Gatekeeper rejects $path:
$verdict"
    echo "$verdict" >>"$log_dir/gatekeeper.log"
    grep -q '^source=Notarized Developer ID$' <<<"$verdict" \
        || die "Gatekeeper doesn't see $path as notarized:
$verdict"
}

write_tester_readme() {
    cat >"$1" <<EOF
$app_name $version (build $build): test copy

This copy of $app_name is signed by its developer but has not been notarized by
Apple yet, so macOS blocks it the first time you open it. To allow it once:

1. Move "$app_name.app" to your Applications folder.
2. Double-click it. macOS says it can't verify that the app is free of malware.
   Click Done (not Move to Trash).
3. Open System Settings > Privacy & Security and scroll down to Security.
   Next to the message about "$app_name", click Open Anyway and confirm with
   your password or Touch ID.
4. Open $app_name again and click Open.

From then on it opens normally. (On macOS 15 and later, Control-clicking the
app and choosing Open no longer skips this check.)
EOF
}

require_clean_tree
require_merged_commit
require_identity
[[ $notarize == no ]] || require_notary_profile

version=$(release_setting MARKETING_VERSION)
build=$(git rev-list --count HEAD)
if [[ $notarize == yes ]]; then
    name="$version-$build"
    artifact_name="$app_name $version.dmg"
else
    name="$version-$build-unnotarized"
    artifact_name="$app_name $version-unnotarized.zip"
fi
final_dir="build/release/$name"
release_dir="$final_dir.partial"
artifact="dist/$artifact_name"
xcode_archive="$HOME/Library/Developer/Xcode/Archives/$(date +%F)/$app_name $name.xcarchive"
log_dir="$release_dir/logs"
archive="$release_dir/$app_name.xcarchive"
app="$release_dir/export/$app_name.app"

[[ ! -e $final_dir ]] || die "$final_dir already exists. It keeps the dSYM for any copy of build $build \
you shipped; delete it only if nothing from it was shipped."
[[ ! -e $xcode_archive ]] || die "$xcode_archive already exists."
[[ ! -e $artifact ]] || die "$artifact already exists; bump MARKETING_VERSION or delete it."

if ! scripts/check.sh; then
    die "scripts/check.sh failed; releases are built only from a green tree."
fi
require_clean_tree

rm -rf "$release_dir"
mkdir -p "$log_dir" dist

run archive xcodebuild -project SceneIt.xcodeproj -scheme SceneIt -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/release/DerivedData \
    -archivePath "$archive" CURRENT_PROJECT_VERSION="$build" clean archive
run export xcodebuild -exportArchive -archivePath "$archive" \
    -exportPath "$release_dir/export" -exportOptionsPlist Config/ExportOptions.plist
verify_signature "$app" verify-app

if [[ $notarize == yes ]]; then
    run zip-app ditto -c -k --keepParent "$app" "$release_dir/$app_name.zip"
    submit_for_notarization "$release_dir/$app_name.zip" notarize-app
    staple "$app" staple-app
    assess exec "$app"

    dmg_root="$release_dir/dmg"
    run dmg mkdir "$dmg_root"
    run dmg ditto "$app" "$dmg_root/$app_name.app"
    run dmg ln -s /Applications "$dmg_root/Applications"
    run dmg diskutil image create from --format UDZO --volumeName "$app_name $version" \
        "$dmg_root" "$release_dir/$artifact_name"
    run sign-dmg codesign --sign "$identity" --timestamp --identifier com.samitbasu.SceneIt.dmg \
        "$release_dir/$artifact_name"
    verify_signature "$release_dir/$artifact_name" verify-dmg
    submit_for_notarization "$release_dir/$artifact_name" notarize-dmg
    staple "$release_dir/$artifact_name" staple-dmg
    assess install "$release_dir/$artifact_name"
else
    zip_root="$release_dir/zip/$app_name $version"
    run zip mkdir -p "$zip_root"
    run zip ditto "$app" "$zip_root/$app_name.app"
    write_tester_readme "$zip_root/README.txt"
    run zip ditto -c -k --keepParent "$zip_root" "$release_dir/$artifact_name"
fi

[[ ! -e $xcode_archive ]] || die "$xcode_archive appeared during the build; not overwriting it."
run keep-archive mkdir -p "$(dirname "$xcode_archive")"
run keep-archive ditto "$archive" "$xcode_archive"
run publish mv "$release_dir/$artifact_name" "$artifact"
mv "$release_dir" "$final_dir"

echo "$PWD/$artifact"
echo "$PWD/$final_dir/$app_name.xcarchive/dSYMs/$app_name.app.dSYM"
echo "$xcode_archive"
