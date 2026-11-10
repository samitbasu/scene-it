# Source guards run by check.sh and tested by test-guards.sh. Each guard takes the paths to
# scan as arguments, prints `file:line: error: …` for every hit and returns 1 if there is one.
# Lines that are only a `//` comment are ignored; the patterns match one line at a time.

# Every source guard, as <check.sh step name>:<function>.
readonly source_guards=(
    textkit1-guard:forbid_textkit1
    logging-guard:forbid_unchecked_logging
    trap-message-guard:forbid_interpolated_traps
    exit-test-guard:forbid_exit_tests
    no-ai-guard:forbid_ai_and_networking
)

# forbid_all <path>…: runs every source guard, reporting all their hits.
forbid_all() {
    local entry status=0
    for entry in "${source_guards[@]}"; do
        "${entry#*:}" "$@" || status=1
    done
    return "$status"
}

# forbid_pattern <message> <extended regex> [<exempt file>…] -- <path>…
forbid_pattern() {
    local message=$1 pattern=$2
    shift 2
    local exempt=()
    while [[ $1 != -- ]]; do
        exempt+=("$1")
        shift
    done
    shift
    local path hits status=0
    # BSD grep applies --include to its operands too, so it skips a missing directory silently.
    for path in "$@"; do
        [[ -e $path ]] || { echo "$path: error: no such file or directory"; return 2; }
    done
    hits=$(grep -rnE --include='*.swift' "$pattern" "$@") || status=$?
    case $status in
        0) ;;
        1) return 0 ;;
        *) return "$status" ;;
    esac
    hits=$(grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' <<<"$hits" || true)
    local file
    for file in ${exempt[@]+"${exempt[@]}"}; do
        hits=$(awk -v prefix="$file:" 'index($0, prefix) != 1' <<<"$hits")
    done
    [[ -n $hits ]] || return 0
    sed -E "s#^([^:]+:[0-9]+):[[:space:]]*#\1: error: $message: #" <<<"$hits"
    return 1
}

forbid_textkit1() {
    # TextKit 2 only (PLAN §2): any of these silently puts a text view on TextKit 1.
    # `willSwitchToNSLayoutManagerNotification`, which the tests' alarm listens for, isn't one.
    forbid_pattern 'TextKit 1 is forbidden (PLAN §2)' \
        '\blayoutManager\b|\bNSLayoutManager|usingTextLayoutManager: *false' -- "$@"
}

forbid_unchecked_logging() {
    # Only the Log facade may log, so the type system can keep manuscript text out (ADR 0006).
    forbid_pattern 'log through Log, not os.Logger/os_log/NSLog (ADR 0006)' \
        '\bLogger\(|\bos_log\b|\bOSLog|\bNSLog\(' \
        Sources/SceneItCore/Diagnostics/Log.swift Sources/SceneItCore/Diagnostics/CurrentProcessLog.swift -- "$@"
}

forbid_interpolated_traps() {
    # A trap's message is copied verbatim into crash reports, which are sent to us.
    forbid_pattern 'trap messages must be static: crash reports include them verbatim' \
        '\b(fatalError|precondition|preconditionFailure|assert|assertionFailure)\(.*\\\(' -- "$@"
}

forbid_exit_tests() {
    # An exit test's child process launches as the real app against the owner's data (#120).
    forbid_pattern 'exit tests are forbidden: the child runs the real app against real data (issue 120)' \
        'processExitsWith|exitsWith:|ExitTest\b' -- "$@"
}

forbid_ai_and_networking() {
    # Scene It's text never reaches a language model or the network (ADR 0049): no machine
    # learning, language or AI framework, no Siri or Shortcuts surface, and no networking API.
    # HTMLPasteTests records requests through URLProtocol (URLRequest) to prove there are none.
    # Like every guard, only whole-line comments are skipped: a trailing comment naming one of
    # these is a hit, and is reworded.
    local status=0 path app_paths=()
    forbid_pattern 'no AI, machine learning or networking (ADR 0049)' \
        '(^|[^[:alnum:]_])import[[:space:]]+([a-z]+[[:space:]]+)?(CoreML|CreateML|NaturalLanguage|FoundationModels|Speech|Translation|Vision|VisionKit|ImagePlayground|SoundAnalysis|AppIntents|Intents|Network|CFNetwork|CloudKit)([.[:space:]]|$)|\b(URLSession|URLRequest|NWConnection|NWListener|NWBrowser|NSURLConnection|CKContainer|CFStream[[:alnum:]]*|CFSocket[[:alnum:]]*|NSLinguisticTagger)\b|\b(Data|String)\(contentsOf: *URL\(string: *"[a-z]+://' \
        SceneItTests/HTMLPasteTests.swift -- "$@" || status=$?
    # WebKit fetches what a page names; the tests may use it to render previews, the app may not.
    for path in "$@"; do
        [[ $path == SceneIt || $path == SceneIt/* || $path == Sources || $path == Sources/* ]] && app_paths+=("$path")
    done
    if ((${#app_paths[@]} > 0)); then
        forbid_pattern 'no WebKit in the app (ADR 0049)' \
            '(^|[^[:alnum:]_])import[[:space:]]+([a-z]+[[:space:]]+)?WebKit([.[:space:]]|$)' -- "${app_paths[@]}" \
            || status=$?
    fi
    return "$status"
}
