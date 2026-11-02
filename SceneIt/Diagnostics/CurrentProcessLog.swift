import OSLog
import SceneItCore

/// This process's entries from the unified log. On macOS, `OSLogStore` can only read the
/// current process, so earlier sessions come from the `LogRing` instead. Only our own
/// subsystem is read: other frameworks' messages follow privacy annotations we don't control.
nonisolated enum CurrentProcessLog {
    static func source(since launch: Date) -> ProblemReport.LogSource {
        ProblemReport.LogSource(
            fileName: "this-session.log", title: ReportWording.thisSessionLog,
            reason: ReportWording.thisSessionLogReason
        ) { try entries(since: launch) }
    }

    /// Starting at `launch` rather than the store's beginning cuts the read from several
    /// seconds to about one.
    static func entries(since launch: Date) throws -> [LogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let ours = NSPredicate(format: "subsystem == %@", Log.subsystem)
        let start = store.position(date: launch)
        return try store.getEntries(at: start, matching: ours).compactMap { $0 as? OSLogEntryLog }.map {
            LogEntry(
                date: $0.date, level: LogLevel($0.level), category: $0.category, message: $0.composedMessage)
        }
    }
}

extension LogLevel {
    nonisolated fileprivate init(_ level: OSLogEntryLog.Level) {
        switch level {
        case .debug: self = .debug
        case .error: self = .error
        case .fault: self = .fault
        case .undefined, .info, .notice: self = .info
        @unknown default: self = .info
        }
    }
}
