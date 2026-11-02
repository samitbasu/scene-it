#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift format format --in-place --recursive --parallel Package.swift Sources Tests SceneIt SceneItTests
