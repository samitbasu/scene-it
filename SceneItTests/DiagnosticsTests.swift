import AppKit
import Foundation
import SceneItCore
import Testing

@testable import SceneIt

private func isInsideTemporaryDirectory(_ url: URL) -> Bool {
    url.path(percentEncoded: false).hasPrefix(
        FileManager.default.temporaryDirectory.path(percentEncoded: false))
}

/// Unzips `zip` into a fresh folder and returns the contents of the file whose path ends in `suffix`.
private func unzippedFile(endingWith suffix: String, in zip: URL) throws -> String {
    let destination = zip.deletingLastPathComponent().appending(path: "Unzipped-\(UUID().uuidString)")
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ditto")
    process.arguments = [
        "-x", "-k", zip.path(percentEncoded: false), destination.path(percentEncoded: false),
    ]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    let enumerator = try #require(
        FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil))
    for case let url as URL in enumerator where url.path(percentEncoded: false).hasSuffix(suffix) {
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
    Issue.record("no \(suffix) in \(zip.lastPathComponent)")
    return ""
}

/// The report's zip; otherwise records an issue quoting the diagnostics errors logged since `start`.
private func zip(
    of report: ProblemReport, since start: Date, sourceLocation: SourceLocation = #_sourceLocation
) -> URL? {
    if case .zip(let zip) = report.archive { return zip }
    let logged = ((try? CurrentProcessLog.entries(since: start)) ?? [])
        .filter { $0.category == .diagnostics && $0.level == .error }.map(\.message)
    Issue.record(
        "report was not zipped: \(report.archive); diagnostics errors: \(logged)",
        sourceLocation: sourceLocation)
    return nil
}

@Test func testHostKeepsDiagnosticsOutOfTheUsersFiles() throws {
    let directory = DiagnosticsController.shared.directory
    let real = try DiagnosticsDirectory.applicationSupport()
    #expect(isInsideTemporaryDirectory(directory.root))
    #expect(isInsideTemporaryDirectory(directory.crashReports))
    #expect(isInsideTemporaryDirectory(directory.reports))
    #expect(directory.root != real.root)
    #expect(directory.crashReports != real.crashReports)
    #expect(directory.reports != real.reports)
    let owner = directory.root.deletingLastPathComponent().lastPathComponent
    #expect(owner == String(ProcessInfo.processInfo.processIdentifier), "another test host would empty it")
}

@Test func thisLaunchWroteASessionMarker() throws {
    let marker = DiagnosticsController.shared.directory.sessionMarker.file
    #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
}

@Test func theAppDoesNotOptIntoSuddenOrAutomaticTermination() {
    for key in ["NSSupportsSuddenTermination", "NSSupportsAutomaticTermination"] {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? Bool
        #expect(value != true, "\(key) would let macOS skip applicationWillTerminate")
    }
}

@Test func liveInstanceCheckRecognisesOnlyRunningSceneIt() throws {
    #expect(DiagnosticsController.isRunningSceneIt(ProcessInfo.processInfo.processIdentifier))
    #expect(!DiagnosticsController.isRunningSceneIt(1))
    let finished = Process()
    finished.executableURL = URL(filePath: "/usr/bin/true")
    try finished.run()
    finished.waitUntilExit()
    #expect(!DiagnosticsController.isRunningSceneIt(finished.processIdentifier))
}

@Test func currentProcessLogReadsOurOwnEntriesFromTheUnifiedLog() throws {
    let marker = UUID()
    Log.diagnostics.error("Unified log test", ["marker": .id(marker)])
    let entries = try CurrentProcessLog.entries(since: .now - .minutes(1))
    let match = try #require(entries.first { $0.message.contains(marker.uuidString) })
    #expect(match.category == .diagnostics)
    #expect(match.level == .error)
}

@Test func reportFromTheAppsRealInputsHasInfoEntriesInBothLogs() async throws {
    let diagnostics = DiagnosticsController.shared
    let start = Date.now
    let marker = UUID()
    Log.app.info("Hosted report test", ["marker": .id(marker)])
    let model = ReportModel(inputs: diagnostics.reportInputs(), reports: diagnostics.directory.reports)
    await model.prepare()
    guard case .ready(let report) = model.state else {
        Issue.record("report was not built: \(model.state)")
        return
    }
    guard let zip = zip(of: report, since: start) else { return }
    #expect(isInsideTemporaryDirectory(zip))
    let names = report.manifest.included.map(\.name)
    #expect(names.contains("logs/recent-sessions.log"))
    #expect(names.contains("logs/this-session.log"))
    #expect(try unzippedFile(endingWith: "logs/recent-sessions.log", in: zip).contains(marker.uuidString))
    #expect(try unzippedFile(endingWith: "logs/this-session.log", in: zip).contains(marker.uuidString))
}

@Test func twoReportsPreparedAtOnceAreBothZipped() async throws {
    try await withTemporaryFolder { reports in
        let start = Date.now
        let inputs = DiagnosticsController.shared.reportInputs()
        let first = ReportModel(inputs: inputs, reports: reports)
        let second = ReportModel(inputs: inputs, reports: reports)
        async let preparingFirst: Void = first.prepare()
        async let preparingSecond: Void = second.prepare()
        _ = await (preparingFirst, preparingSecond)
        var zips: [URL] = []
        for model in [first, second] {
            guard case .ready(let report) = model.state else {
                Issue.record("report was not built: \(model.state)")
                return
            }
            guard let zip = zip(of: report, since: start) else { return }
            zips.append(zip)
        }
        try #require(Set(zips.map(\.lastPathComponent)).count == 1, "the two reports must share a name")
        #expect(Set(zips).count == 2)
        for zip in zips {
            #expect(try unzippedFile(endingWith: "manifest.txt", in: zip).contains("logs/this-session.log"))
        }
    }
}

@Test func helpMenuReportAProblemOpensTheReportWindow() async throws {
    let item = try #require(menuItem(titled: ReportWording.reportMenuItem, in: NSApp.mainMenu))
    try perform(item)
    let window = try #require(NSApp.windows.first { $0.title == ReportWording.windowTitle && $0.isVisible })
    await DiagnosticsController.shared.reportPreparation?.value
    window.close()
}

#if DEBUG
    @Test func debugBuildsHaveACrashNowMenuItem() {
        #expect(menuItem(titled: ReportWording.crashNowMenuItem, in: NSApp.mainMenu) != nil)
    }
#endif
