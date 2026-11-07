import Foundation
import SceneItCore
import Testing

@testable import SceneIt

extension BookController {
    /// Quits this session through the store's quit path and, once it has ended, starts the next,
    /// as relaunching would: a session never opens a second book (ADR 0038).
    @discardableResult
    func quitAndRelaunch() async -> AppBookStore.LeaveOutcome {
        let outcome = await store.prepareToQuit()
        if outcome == .left { startOver() }
        return outcome
    }

    /// The requests carried out since the last call (the test host's `RecordedRequests`).
    func takeRequests() -> [RecordedRequests.Carried] {
        recorded?.take() ?? []
    }
}

func withTemporaryFolder(_ body: (URL) async throws -> Void) async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "SceneItAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { removeUnlocking(url) }
    try await body(url)
}

/// Removes `directory`, first clearing the immutable flag that filing sets on a filed copy
/// (as `chflags -R nouchg` does), which would otherwise stop the removal.
func removeUnlocking(_ directory: URL) {
    let manager = FileManager.default
    if let paths = manager.enumerator(atPath: directory.path(percentEncoded: false)) {
        for case let path as String in paths {
            let file = directory.appending(path: path).path(percentEncoded: false)
            try? manager.setAttributes([.immutable: false], ofItemAtPath: file)
        }
    }
    try? manager.removeItem(at: directory)
}

func bookOnDisk(_ package: URL) throws -> Book {
    var ids = IDGenerator.system
    return BookFormat.parse(
        try Data(contentsOf: package.appending(path: "book.md")), opened: Timestamp(.now, in: .current),
        ids: &ids
    ).book
}
