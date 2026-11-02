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

@Test func testHostKeepsDiagnosticsOutOfTheUsersApplicationSupport() throws {
    let diagnostics = DiagnosticsController.shared
    let applicationSupport = try DiagnosticsDirectory.applicationSupport().root
    #expect(
        diagnostics.directory.root.path(percentEncoded: false).hasPrefix(
            FileManager.default.temporaryDirectory.path(percentEncoded: false)))
    #expect(diagnostics.directory.root != applicationSupport)
}

@Test func thisLaunchWroteASessionMarker() throws {
    let diagnostics = DiagnosticsController.shared
    #expect(
        FileManager.default.fileExists(
            atPath: diagnostics.directory.sessionMarker.file.path(percentEncoded: false)))
}

@Test func currentProcessLogReadsOurOwnEntriesFromTheUnifiedLog() throws {
    let marker = UUID()
    Log.diagnostics.error("Unified log test", ["marker": .id(marker)])
    let entries = try CurrentProcessLog.entries(since: .now - .minutes(1))
    let match = try #require(entries.first { $0.message.contains(marker.uuidString) })
    #expect(match.category == "diagnostics")
    #expect(match.level == .error)
}

@Test func reportBuiltFromTheAppsRealInputsIncludesBothLogs() async throws {
    let diagnostics = DiagnosticsController.shared
    let model = ReportModel(inputs: diagnostics.reportInputs())
    await model.prepare()
    guard case .ready(let report) = model.state else {
        Issue.record("report was not built: \(model.state)")
        return
    }
    defer { try? FileManager.default.removeItem(at: report.archive.url.deletingLastPathComponent()) }
    #expect(report.archive == .zip(report.archive.url))
    #expect(FileManager.default.fileExists(atPath: report.archive.url.path(percentEncoded: false)))
    let names = report.manifest.included.map(\.name)
    #expect(names.contains("logs/recent-sessions.log"))
    #expect(names.contains("logs/this-session.log"))
}

@Test func helpMenuReportAProblemOpensTheReportWindow() throws {
    let item = try #require(menuItem(titled: ReportWording.reportMenuItem, in: NSApp.mainMenu))
    let menu = try #require(item.menu)
    menu.performActionForItem(at: menu.index(of: item))
    let window = try #require(NSApp.windows.first { $0.title == ReportWording.windowTitle && $0.isVisible })
    window.close()
}

#if DEBUG
    @Test func debugBuildsHaveACrashNowMenuItem() {
        #expect(menuItem(titled: ReportWording.crashNowMenuItem, in: NSApp.mainMenu) != nil)
    }
#endif
