import Foundation

/// Where diagnostics are kept and read from. The app uses `applicationSupport()`; tests and
/// previews use `temporary(at:)` so they never touch the user's real files.
public struct DiagnosticsDirectory: Sendable {
    /// Holds the session marker, the log ring and MetricKit payloads.
    public let root: URL
    /// Apple's crash reports (`.ips`) to search.
    public let crashReports: URL
    /// Where problem reports are built.
    public let reports: URL

    public init(root: URL, crashReports: URL, reports: URL) {
        self.root = root
        self.crashReports = crashReports
        self.reports = reports
    }

    public static func applicationSupport() throws -> DiagnosticsDirectory {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return DiagnosticsDirectory(
            root: support.appending(path: "Scene It/Diagnostics"),
            crashReports: fileManager.homeDirectoryForCurrentUser.appending(
                path: "Library/Logs/DiagnosticReports"),
            reports: fileManager.temporaryDirectory.appending(path: "Scene It Reports"))
    }

    /// Everything under `folder`, which is emptied first.
    public static func temporary(at folder: URL) -> DiagnosticsDirectory {
        try? FileManager.default.removeItem(at: folder)
        return DiagnosticsDirectory(
            root: folder.appending(path: "Diagnostics"),
            crashReports: folder.appending(path: "DiagnosticReports"),
            reports: folder.appending(path: "Reports"))
    }

    public var sessionMarker: SessionMarker { SessionMarker(directory: root) }
    public var logRingDirectory: URL { root.appending(path: "Log") }
    public var metricKit: PayloadArchive { PayloadArchive(directory: root.appending(path: "MetricKit")) }
}
