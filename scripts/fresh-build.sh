#!/usr/bin/env bash
# fresh-build.sh <folder> <command>...: runs a command that builds into build/DerivedData or
# .build, after the gate's stale-build check on that folder, and records the build afterwards
# so the gate can keep building on it. Exits with the command's status.
set -euo pipefail

source "$(dirname "$0")/lib.sh"

folder=$1
shift
prepare_builds "$folder"
status=0
"$@" || status=$?
record_build "$folder"
exit "$status"
