import Foundation

/// Where diagnostics are kept and read from. The app uses `applicationSupport()`; tests and
/// previews use `temporary(under:)` so they never touch the user's real files.
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

    /// A folder of this process's own under `parent`, named by its process ID, so test hosts
    /// running at the same time never empty each other's. It starts empty, and the folders of
    /// processes that have exited are removed.
    public static func temporary(
        under parent: URL, processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        isRunning: (Int32) -> Bool = processIsRunning
    ) -> DiagnosticsDirectory {
        let manager = FileManager.default
        let siblings = (try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        for sibling in siblings {
            guard let owner = Int32(sibling.lastPathComponent), owner == processID || !isRunning(owner)
            else { continue }
            try? manager.removeItem(at: sibling)
        }
        let folder = parent.appending(path: String(processID), directoryHint: .isDirectory)
        return DiagnosticsDirectory(
            root: folder.appending(path: "Diagnostics"),
            crashReports: folder.appending(path: "DiagnosticReports"),
            reports: folder.appending(path: "Reports"))
    }

    /// True if any process has this ID, ours or not.
    public static func processIsRunning(_ processID: Int32) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }

    public var sessionMarker: SessionMarker { SessionMarker(directory: root) }
    public var logRingDirectory: URL { root.appending(path: "Log") }
    public var metricKit: PayloadArchive { PayloadArchive(directory: root.appending(path: "MetricKit")) }
}
