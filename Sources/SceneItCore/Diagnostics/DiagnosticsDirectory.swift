import Foundation

/// Where diagnostics live: `~/Library/Application Support/Scene It/Diagnostics` in the app,
/// a temporary directory in tests.
public struct DiagnosticsDirectory: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func applicationSupport() throws -> DiagnosticsDirectory {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return DiagnosticsDirectory(root: support.appending(path: "Scene It/Diagnostics"))
    }

    public var sessionMarker: SessionMarker { SessionMarker(directory: root) }
    public var logRingDirectory: URL { root.appending(path: "Log") }
    public var metricKit: PayloadArchive { PayloadArchive(directory: root.appending(path: "MetricKit")) }

    /// Apple's crash reports (`.ips`) for this user.
    public static var systemCrashReports: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
    }
}
