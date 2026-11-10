#!/usr/bin/env bash
# site-screenshots.sh [<render folder>]: renders the website's screenshots with the `site` test
# (SceneItTests/SiteRenders.swift) and writes each as a 256-color PNG into site/images/. The
# renders and the test's log go in <render folder>, build/site-renders by default.
# .github/workflows/site-screenshots.yml runs this too, so a developer and CI take the same steps.
set -euo pipefail

usage() {
    echo "usage: scripts/site-screenshots.sh [<render folder>]" >&2
    exit 2
}

(($# <= 1)) || usage
[[ ${1:-} != -* ]] || usage
if (($# == 1)); then
    mkdir -p "$1"
    render_folder=$(cd "$1" && pwd)
fi

source "$(dirname "$0")/lib.sh"

render_folder=${render_folder:-$PWD/build/site-renders}
readonly renders=$render_folder/site
readonly log=$render_folder/xcodebuild.log

command -v magick >/dev/null || {
    echo "site-screenshots.sh: ImageMagick's magick isn't installed (brew install imagemagick)" >&2
    exit 1
}

rm -rf "$renders"
mkdir -p "$render_folder"

if ! TEST_RUNNER_SCENEIT_RENDER_DIR=$render_folder scripts/fresh-build.sh build/DerivedData \
    xcodebuild -project SceneIt.xcodeproj -scheme SceneIt -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData test -only-testing:SceneItTests/WindowRenders/site\(\) \
    >"$log" 2>&1; then
    echo "site-screenshots.sh: the site render failed (full log: $log)" >&2
    print_log_diagnostics "$log"
    exit 1
fi

shopt -s nullglob
rendered=("$renders"/*@2x.png)
((${#rendered[@]} > 0)) || {
    echo "site-screenshots.sh: the site test rendered nothing into $renders (full log: $log)" >&2
    exit 1
}

for render in "${rendered[@]}"; do
    name=$(basename "$render" @2x.png)
    magick "$render" -strip -dither None -colors 256 "PNG8:site/images/$name.png"
    echo "site/images/$name.png"
done
