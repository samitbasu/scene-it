import Foundation
import OSLog

/// This process's entries from the unified log. On macOS, `OSLogStore` can only read the
/// current process, so earlier sessions come from the `LogRing` instead. Only our own
/// subsystem is read: other frameworks' messages follow privacy annotations we don't control.
public enum CurrentProcessLog {
    public static func source(since launch: Date) -> ProblemReport.LogSource {
        ProblemReport.LogSource(
            fileName: "this-session.log", title: ReportWording.thisSessionLog,
            reason: ReportWording.thisSessionLogReason
        ) { try entries(since: launch) }
    }

    /// Starting at `launch` rather than the store's beginning cuts the read from several
    /// seconds to about one.
    public static func entries(since launch: Date) throws -> [LogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let ours = NSPredicate(format: "subsystem == %@", Log.subsystem)
        let start = store.position(date: launch)
        return try store.getEntries(at: start, matching: ours).compactMap { entry in
            guard let entry = entry as? OSLogEntryLog, let category = LogCategory(rawValue: entry.category)
            else {
                return nil
            }
            return LogEntry(
                date: entry.date, level: LogLevel(entry.level), category: category,
                message: entry.composedMessage)
        }
    }
}

extension LogLevel {
    fileprivate init(_ level: OSLogEntryLog.Level) {
        switch level {
        case .debug: self = .debug
        case .error: self = .error
        case .fault: self = .fault
        case .undefined, .info, .notice: self = .info
        @unknown default: self = .info
        }
    }
}
