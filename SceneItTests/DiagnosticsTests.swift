import AppKit
import Foundation
import SceneItCore
import Testing

@testable import SceneIt

private func menuItem(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
    for item in menu?.items ?? [] {
        if item.title == title { return item }
        if let found = menuItem(titled: title, in: item.submenu) { return found }
    }
    return nil
}

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

@Test func testHostKeepsDiagnosticsOutOfTheUsersFiles() throws {
    let directory = DiagnosticsController.shared.directory
    let real = try DiagnosticsDirectory.applicationSupport()
    #expect(isInsideTemporaryDirectory(directory.root))
    #expect(isInsideTemporaryDirectory(directory.crashReports))
    #expect(isInsideTemporaryDirectory(directory.reports))
    #expect(directory.root != real.root)
    #expect(directory.crashReports != real.crashReports)
    #expect(directory.reports != real.reports)
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
    let marker = UUID()
    Log.app.info("Hosted report test", ["marker": .id(marker)])
    let model = ReportModel(inputs: diagnostics.reportInputs(), reports: diagnostics.directory.reports)
    await model.prepare()
    guard case .ready(let report) = model.state else {
        Issue.record("report was not built: \(model.state)")
        return
    }
    guard case .zip(let zip) = report.archive else {
        Issue.record("report was not zipped: \(report.archive)")
        return
    }
    #expect(isInsideTemporaryDirectory(zip))
    let names = report.manifest.included.map(\.name)
    #expect(names.contains("logs/recent-sessions.log"))
    #expect(names.contains("logs/this-session.log"))
    #expect(try unzippedFile(endingWith: "logs/recent-sessions.log", in: zip).contains(marker.uuidString))
    #expect(try unzippedFile(endingWith: "logs/this-session.log", in: zip).contains(marker.uuidString))
}

@Test func helpMenuReportAProblemOpensTheReportWindow() async throws {
    let item = try #require(menuItem(titled: ReportWording.reportMenuItem, in: NSApp.mainMenu))
    let menu = try #require(item.menu)
    menu.performActionForItem(at: menu.index(of: item))
    let window = try #require(NSApp.windows.first { $0.title == ReportWording.windowTitle && $0.isVisible })
    await DiagnosticsController.shared.reportPreparation?.value
    window.close()
}

#if DEBUG
    @Test func debugBuildsHaveACrashNowMenuItem() {
        #expect(menuItem(titled: ReportWording.crashNowMenuItem, in: NSApp.mainMenu) != nil)
    }
#endif
