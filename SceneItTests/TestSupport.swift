import Foundation
import SceneItCore
import Testing

/// Gives `condition` a number of polls, not a wall-clock deadline: polls are at least 5 ms apart,
/// so it waits at least 30 s, but while a loaded machine or another test holds the main actor,
/// the work the condition waits for is held too, and that costs one poll instead of the budget.
/// A suite's time limit still ends a real hang.
func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<6000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if condition() { return }
    Issue.record("the condition never held", sourceLocation: sourceLocation)
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
