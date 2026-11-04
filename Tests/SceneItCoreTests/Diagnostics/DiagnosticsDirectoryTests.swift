import Foundation
import Testing

@testable import SceneItCore

private func makeFolder(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("in use".utf8).write(to: url.appending(path: "file"))
    return url
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

@Test func aTemporaryDirectoryNeverEmptiesARunningProcesssFolder() throws {
    let parent = try TemporaryDirectory()
    let running = try makeFolder(parent.url.appending(path: "200"))
    let exited = try makeFolder(parent.url.appending(path: "300"))
    let ours = try makeFolder(parent.url.appending(path: "100"))
    let notAProcess = try makeFolder(parent.url.appending(path: "Reports"))
    try #require([running, exited, ours, notAProcess].allSatisfy(exists))

    let directory = DiagnosticsDirectory.temporary(under: parent.url, processID: 100) {
        $0 == 100 || $0 == 200
    }

    #expect(exists(running))
    #expect(!exists(exited))
    #expect(!exists(ours))
    #expect(exists(notAProcess))
    #expect(directory.root.path(percentEncoded: false).hasPrefix(ours.path(percentEncoded: false)))
    #expect(directory.reports.path(percentEncoded: false).hasPrefix(ours.path(percentEncoded: false)))
    #expect(directory.crashReports.path(percentEncoded: false).hasPrefix(ours.path(percentEncoded: false)))
}

@Test func processIsRunningKnowsThisProcessAndAnExitedOne() throws {
    #expect(DiagnosticsDirectory.processIsRunning(ProcessInfo.processInfo.processIdentifier))
    let finished = Process()
    finished.executableURL = URL(filePath: "/usr/bin/true")
    try finished.run()
    finished.waitUntilExit()
    #expect(!DiagnosticsDirectory.processIsRunning(finished.processIdentifier))
}
