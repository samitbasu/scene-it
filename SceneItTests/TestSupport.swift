import Foundation
import SceneItCore
import Testing

func eventually(
    within limit: Duration = .seconds(10), _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("the condition never held", sourceLocation: sourceLocation)
}

func withTemporaryFolder(_ body: (URL) async throws -> Void) async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "SceneItAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    try await body(url)
}

func bookOnDisk(_ package: URL) throws -> Book {
    var ids = IDGenerator.system
    return BookFormat.parse(
        try Data(contentsOf: package.appending(path: "book.json")), opened: Timestamp(.now, in: .current),
        ids: &ids
    ).book
}
