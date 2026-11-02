import AppKit
import SceneItCore

/// What a second launch does instead of running (ADR 0020): passes its books to the instance
/// that holds the app lock, brings that instance forward, and quits.
enum InstanceHandoff {
    /// `NSWorkspace.open(_:withApplicationAt:)` names the running instance's own bundle, so
    /// Launch Services sends the open request to that process rather than starting another,
    /// even when it's a different copy of the app (a Debug build beside the installed one).
    static func forward(_ books: [URL], then finish: @escaping @MainActor () -> Void) {
        guard let running = runningInstance() else {
            Log.app.error("the app lock is held, but no other Scene It is running")
            finish()
            return
        }
        guard !books.isEmpty, let bundle = running.bundleURL else {
            activate(running)
            finish()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(books, withApplicationAt: bundle, configuration: configuration) { _, error in
            if let error {
                Log.app.error(
                    "couldn't pass books to the running instance", ["error": .error(LoggedError(error))])
            }
            Task { @MainActor in
                activate(running)
                finish()
            }
        }
    }

    private static func runningInstance() -> NSRunningApplication? {
        let us = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: SceneItCore.bundleIdentifier)
            .first { $0.processIdentifier != us.processIdentifier && !$0.isTerminated }
    }

    private static func activate(_ running: NSRunningApplication) {
        NSApp.yieldActivation(to: running)
        running.activate()
    }
}
