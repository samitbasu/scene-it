import AppKit
import Testing

/// Records an issue if any text view falls back to TextKit 1 (asked for its `layoutManager`, say)
/// until the returned observer is removed. It hears every text view in the process, so another
/// test's fallback may be reported here too: either way, one has happened.
func failOnTextKit1(sourceLocation: SourceLocation = #_sourceLocation) -> any NSObjectProtocol {
    NotificationCenter.default.addObserver(
        forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: nil, queue: nil
    ) { notification in
        Issue.record(
            "a text view switched to TextKit 1: \(String(describing: notification.object))",
            sourceLocation: sourceLocation)
    }
}
