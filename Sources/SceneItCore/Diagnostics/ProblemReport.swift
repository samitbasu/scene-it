import Foundation

/// A zip of diagnostics for Help → Report a Problem (ADR 0006). Gathering is best-effort:
/// anything that can't be read is listed under "Not included" in the manifest and skipped.
public struct ProblemReport: Sendable {
    /// ADR 0009.
    public static let destination = "basu.samit@gmail.com"

    public let manifest: Manifest
    public let archive: Archive

    public enum Archive: Sendable, Equatable {
        case zip(URL)
        /// Zipping failed; the unzipped folder is the report.
        case folder(URL)

        public var url: URL {
            switch self {
            case .zip(let url), .folder(let url): url
            }
        }
    }

    public struct LogSource: Sendable {
        public let fileName: String
        public let title: String
        public let reason: String
        public let entries: @Sendable () throws -> [LogEntry]

        public init(
            fileName: String, title: String, reason: String,
            entries: @escaping @Sendable () throws -> [LogEntry]
        ) {
            self.fileName = fileName
            self.title = title
            self.reason = reason
            self.entries = entries
        }

        public static func previousSessions(_ ring: LogRing) -> LogSource {
            LogSource(
                fileName: "recent-sessions.log", title: ReportWording.previousSessionsLog,
                reason: ReportWording.previousSessionsLogReason, entries: ring.entries)
        }
    }

    public struct Inputs: Sendable {
        public var logSources: [LogSource]
        public var metricKitDirectory: URL
        /// Searched along with its `Retired` subfolder, where macOS moves reports it has sent to Apple.
        public var crashReportsDirectory: URL
        public var system: SystemSummary
        public var status: StatusSummary
        public var now: Date
        public var timeZone: TimeZone

        public init(
            logSources: [LogSource], metricKitDirectory: URL,
            crashReportsDirectory: URL,
            system: SystemSummary, status: StatusSummary, now: Date = .now, timeZone: TimeZone = .current
        ) {
            self.logSources = logSources
            self.metricKitDirectory = metricKitDirectory
            self.crashReportsDirectory = crashReportsDirectory
            self.system = system
            self.status = status
            self.now = now
            self.timeZone = timeZone
        }
    }

    public struct Manifest: Sendable, Equatable {
        public struct Item: Sendable, Equatable {
            public let name: String
            public let reason: String
        }

        public let header: String
        public internal(set) var included: [Item] = []
        public internal(set) var notIncluded: [String] = []

        public var text: String {
            var lines = [header, "", ReportWording.manifestIncludedHeading]
            lines += included.map { "  \($0.name): \($0.reason)" }
            if !notIncluded.isEmpty {
                lines += ["", ReportWording.manifestNotIncludedHeading]
                lines += notIncluded.map { "  \($0)" }
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    public static let crashReportPrefix = "Scene It"
    static let outputRetention = RetentionPolicy(maxCount: 4, maxAge: .days(1))

    /// A new, empty folder under `reports` to build one report in. Older report folders are
    /// deleted first: any older than a day, and all but the newest few.
    public static func makeOutputFolder(in reports: URL, now: Date = .now) throws -> URL {
        outputRetention.prune(reports, now: now) { $0.hasDirectoryPath }
        let folder = reports.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static let maxCrashReports = 10

    /// The base name of the report: `Scene It Report yyyy-MM-dd HHmm`.
    public static func name(at date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Scene It Report \(formatter.string(from: date))"
    }

    /// Writes the report into `parent`. Throws only if `parent` itself can't be written.
    public static func build(_ inputs: Inputs, in parent: URL) throws -> ProblemReport {
        let name = name(at: inputs.now, in: inputs.timeZone)
        let folder = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let created = inputs.now.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: inputs.timeZone))
        var gatherer = Gatherer(
            folder: folder, manifest: Manifest(header: ReportWording.manifestHeader(created: created)))
        gatherer.manifest.included.append(.init(name: "manifest.txt", reason: ReportWording.manifestReason))
        gatherer.include("system.txt", reason: ReportWording.systemReason, title: ReportWording.systemSummary)
        {
            try systemText(inputs.system, inputs.status).write(to: $0, atomically: true, encoding: .utf8)
        }
        for source in inputs.logSources {
            gatherer.include("logs/\(source.fileName)", reason: source.reason, title: source.title) {
                let text = try source.entries().map { $0.rendered + "\n" }.joined()
                try text.write(to: $0, atomically: true, encoding: .utf8)
            }
        }
        gatherer.copyFiles(
            from: [inputs.metricKitDirectory], into: "metrickit", reason: ReportWording.metricKitReason,
            title: ReportWording.metricKitFolder, none: ReportWording.noMetricKitPayloads
        ) { $0.pathExtension == "json" }
        gatherer.copyFiles(
            from: [inputs.crashReportsDirectory, inputs.crashReportsDirectory.appending(path: "Retired")],
            into: "crash-reports",
            reason: ReportWording.crashReportReason,
            title: ReportWording.crashReportsFolder, none: ReportWording.noCrashReports,
            limit: maxCrashReports
        ) { $0.lastPathComponent.hasPrefix(crashReportPrefix) && $0.pathExtension == "ips" }

        let manifest = gatherer.manifest
        do {
            try manifest.text.write(
                to: folder.appending(path: "manifest.txt"), atomically: true, encoding: .utf8)
        } catch {
            Log.diagnostics.error("Report manifest not written", ["error": .error(LoggedError(error))])
        }

        let zip = parent.appending(path: "\(name).zip")
        do {
            try Zip.archive(folder, to: zip)
            try? FileManager.default.removeItem(at: folder)
            return ProblemReport(manifest: manifest, archive: .zip(zip))
        } catch {
            Log.diagnostics.error("Report not zipped", ["error": .error(LoggedError(error))])
            return ProblemReport(manifest: manifest, archive: .folder(folder))
        }
    }

    static func systemText(_ system: SystemSummary, _ status: StatusSummary) -> String {
        let systemLines = system.lines.map { "\($0.label): \($0.value)" }
        let statusLines = status.items.map { "\($0.label): \($0.value.rendered)" }
        return (systemLines + [""] + statusLines).joined(separator: "\n") + "\n"
    }
}

private struct Gatherer {
    let folder: URL
    var manifest: ProblemReport.Manifest

    mutating func include(
        _ path: String, reason: String, title: String? = nil, write: (URL) throws -> Void
    ) {
        let destination = folder.appending(path: path)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(destination)
            manifest.included.append(.init(name: path, reason: reason))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            manifest.notIncluded.append(ReportWording.couldNotRead(title ?? path))
            Log.diagnostics.error("Report item skipped", ["error": .error(LoggedError(error))])
        }
    }

    mutating func copyFiles(
        from sources: [URL], into subfolder: String, reason: String, title: String, none: String,
        limit: Int = .max, where isWanted: (URL) -> Bool
    ) {
        var candidates: [URL] = []
        for source in sources {
            do {
                candidates += try FileManager.default.contentsOfDirectory(
                    at: source, includingPropertiesForKeys: [.contentModificationDateKey])
            } catch CocoaError.fileReadNoSuchFile {
                continue
            } catch {
                manifest.notIncluded.append(ReportWording.couldNotRead(title))
                Log.diagnostics.error("Report folder unreadable", ["error": .error(LoggedError(error))])
                return
            }
        }
        var seen = Set<String>()
        let wanted = candidates.filter(isWanted)
            .sorted { modificationDate($0) > modificationDate($1) }
            .filter { seen.insert($0.lastPathComponent).inserted }
            .prefix(limit)
        if wanted.isEmpty {
            manifest.notIncluded.append(none)
        }
        for file in wanted.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            include("\(subfolder)/\(file.lastPathComponent)", reason: reason) {
                try FileManager.default.copyItem(at: file, to: $0)
            }
        }
    }
}

enum Zip {
    /// Zips `folder` with `NSFileCoordinator`'s `.forUploading` read, which produces a zip of
    /// a directory in-process with no third-party code or subprocess.
    static func archive(_ folder: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(
            readingItemAt: folder, options: .forUploading, error: &coordinationError
        ) {
            zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            throw error
        }
    }
}
