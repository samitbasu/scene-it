# Sourced by the scripts in this directory; moves to the repository root.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

readonly swift_paths=(Package.swift Sources Tests SceneIt SceneItTests)

strip_ansi() {
    sed -E $'s/\x1b\\[[0-9;]*m//g; s/\x1b\\]8;;[^\x1b]*\x1b\\\\//g'
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
