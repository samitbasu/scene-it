import Foundation
import Testing

@testable import SceneItCore

/// Distinctive sentences from a fixture book. None may appear anywhere in a report.
private let bookSentences = [
    "Marguerite folded the map into a paper crane and set it adrift on the canal.",
    "The lighthouse keeper burned every letter except the one addressed to the sea.",
    "Nobody in Halvorsen Street had ever heard the piano play itself before midnight.",
]

private struct BookError: LocalizedError {
    var errorDescription: String? { "Couldn't save: \(bookSentences[1])" }
}

private struct Unreadable: Error {}

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
private let utc = TimeZone(identifier: "UTC") ?? .gmt

private let system = SystemSummary(
    appVersion: "0.1.0", appBuild: "7", osVersion: "Version 26.1 (Build 25B78)", hardwareModel: "Mac16,1",
    architecture: "arm64", physicalMemoryBytes: 17_179_869_184)

private struct Fixture {
    let directory: TemporaryDirectory
    let inputs: ProblemReport.Inputs

    init(logSources: [ProblemReport.LogSource]? = nil) throws {
        directory = try TemporaryDirectory()
        let root = directory.url
        let metricKit = root.appending(path: "MetricKit")
        let crashReports = root.appending(path: "DiagnosticReports")
        try FileManager.default.createDirectory(at: metricKit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashReports, withIntermediateDirectories: true)
        try Data(#"{"crashDiagnostics":[]}"#.utf8).write(to: metricKit.appending(path: "diagnostic-1.json"))
        try Data(#"{"app_name":"Scene It"}"#.utf8).write(
            to: crashReports.appending(path: "Scene It-2026-10-31-120000.ips"))
        let retired = crashReports.appending(path: "Retired")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try Data(#"{"app_name":"Scene It"}"#.utf8).write(
            to: retired.appending(path: "Scene It-2026-10-20-090000.ips"))
        try Data("Other app crash quoting \(bookSentences[0])".utf8)
            .write(to: crashReports.appending(path: "Other App-2026-10-31-120000.ips"))
        try Data("Scene It sysdiagnose quoting \(bookSentences[2])".utf8)
            .write(to: crashReports.appending(path: "Scene It-unrelated.txt"))

        let ring = LogRing(directory: root.appending(path: "Log"))
        ring.append(
            LogEntry(
                date: now - .hours(30), level: .error, category: "store",
                message: Log.compose(
                    "Save failed", ["scenes": .count(42), "error": .error(LoggedError(BookError()))])))
        ring.append(
            LogEntry(
                date: now - .hours(29), level: .info, category: "editor",
                message: Log.compose("Opened scene", ["scene": .id(UUID()), "words": .count(1834)])))

        inputs = ProblemReport.Inputs(
            logSources: logSources ?? [
                .previousSessions(ring),
                ProblemReport.LogSource(
                    fileName: "this-session.log", title: ReportWording.thisSessionLog,
                    reason: ReportWording.thisSessionLogReason
                ) { [LogEntry(date: now, level: .info, category: "app", message: "Launched")] },
            ],
            metricKitDirectory: metricKit, crashReportsDirectory: crashReports, system: system,
            status: StatusSummary(["backups": .symbol("not set up"), "autosave": .interval(.seconds(2))]),
            now: now, timeZone: utc)
    }

    func build() throws -> ProblemReport {
        try ProblemReport.build(inputs, in: directory.url.appending(path: "Output"))
    }
}

/// Unzips `zip` and returns each file's path inside the report folder and its contents.
private func unzip(_ zip: URL, into directory: URL) throws -> [String: Data] {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", zip.path(percentEncoded: false), directory.path(percentEncoded: false)]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    let enumerator = try #require(
        FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
    var files: [String: Data] = [:]
    let prefix = directory.resolvingSymlinksInPath().path(percentEncoded: false)
    for case let url as URL in enumerator where !url.hasDirectoryPath {
        let path = String(url.resolvingSymlinksInPath().path(percentEncoded: false).dropFirst(prefix.count))
        files[path] = try Data(contentsOf: url)
    }
    return files
}

@Test func destinationIsTheOwnersAddress() {
    #expect(ProblemReport.destination == "basu.samit@gmail.com")
}

@Test func reportIsNamedWithItsCreationMinute() {
    #expect(ProblemReport.name(at: now, in: utc) == "Scene It Report 2026-10-29 2053")
}

@Test func reportZipContainsEveryGatheredPieceAndOnlyThose() throws {
    let fixture = try Fixture()
    let report = try fixture.build()
    guard case .zip(let zip) = report.archive else {
        Issue.record("expected a zip, got \(report.archive)")
        return
    }
    #expect(zip.lastPathComponent == "Scene It Report 2026-10-29 2053.zip")
    let files = try unzip(zip, into: fixture.directory.url.appending(path: "Unzipped"))
    let folder = "Scene It Report 2026-10-29 2053/"
    #expect(
        Set(files.keys) == [
            folder + "manifest.txt",
            folder + "system.txt",
            folder + "logs/recent-sessions.log",
            folder + "logs/this-session.log",
            folder + "metrickit/diagnostic-1.json",
            folder + "crash-reports/Scene It-2026-10-31-120000.ips",
            folder + "crash-reports/Scene It-2026-10-20-090000.ips",
        ])
    #expect(Set(report.manifest.included.map { folder + $0.name }) == Set(files.keys))

    let manifest = String(decoding: try #require(files[folder + "manifest.txt"]), as: UTF8.self)
    #expect(manifest == report.manifest.text)
    #expect(manifest.contains(ProblemReport.destination))

    let recent = String(decoding: try #require(files[folder + "logs/recent-sessions.log"]), as: UTF8.self)
    #expect(recent.contains("Save failed scenes=42"))
    #expect(recent.contains("Opened scene"))
    let systemText = String(decoding: try #require(files[folder + "system.txt"]), as: UTF8.self)
    #expect(systemText.contains("Mac16,1"))
    #expect(systemText.contains("backups: not set up"))
}

@Test func reportContainsNoManuscriptText() throws {
    let fixture = try Fixture()
    let crashReports = fixture.inputs.crashReportsDirectory
    let fixtureText = try FileManager.default.contentsOfDirectory(
        at: crashReports, includingPropertiesForKeys: nil
    )
    .filter { !$0.hasDirectoryPath }
    .map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }.joined()
    #expect(
        bookSentences.allSatisfy { fixtureText.contains($0) || BookError().localizedDescription.contains($0) }
    )

    let report = try fixture.build()
    let files = try unzip(report.archive.url, into: fixture.directory.url.appending(path: "Unzipped"))
    try #require(files.count >= 7)
    for (path, data) in files {
        let text = String(decoding: data, as: UTF8.self)
        for sentence in bookSentences {
            #expect(!text.contains(sentence), "\(path) contains manuscript text")
        }
    }
    #expect(bookSentences.allSatisfy { !report.manifest.text.contains($0) })
}

@Test func anUnreadablePieceIsListedAndSkippedWithoutFailingTheReport() throws {
    let fixture = try Fixture(logSources: [
        ProblemReport.LogSource(fileName: "broken.log", title: "Broken log", reason: "Fixture") {
            throw Unreadable()
        }
    ])
    let report = try fixture.build()
    #expect(report.manifest.notIncluded == [ReportWording.couldNotRead("Broken log")])
    #expect(!report.manifest.included.contains { $0.name == "logs/broken.log" })
    let files = try unzip(report.archive.url, into: fixture.directory.url.appending(path: "Unzipped"))
    #expect(!files.keys.contains { $0.hasSuffix("broken.log") })
    #expect(files.keys.contains { $0.hasSuffix("system.txt") })
}

@Test func missingSourceFoldersAreNotedAsEmpty() throws {
    let directory = try TemporaryDirectory()
    let inputs = ProblemReport.Inputs(
        logSources: [], metricKitDirectory: directory.url.appending(path: "absent-metrickit"),
        crashReportsDirectory: directory.url.appending(path: "absent-reports"), system: system,
        status: StatusSummary([:]), now: now, timeZone: utc)
    let report = try ProblemReport.build(inputs, in: directory.url.appending(path: "Output"))
    #expect(report.manifest.notIncluded == [ReportWording.noMetricKitPayloads, ReportWording.noCrashReports])
    #expect(report.manifest.included.map(\.name) == ["manifest.txt", "system.txt"])
}
