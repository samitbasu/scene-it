#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

swift format format --in-place --recursive --parallel "${swift_paths[@]}"
