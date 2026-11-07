import Foundation
import Testing

@testable import SceneItCore

/// Answers the store's questions from a script and records every question. An alert whose
/// scripted answer is missing (or of another kind) gets its first button, as Return would;
/// with `holding`, questions wait until `releaseHeld()`.
@MainActor
final class ScriptedPrompts: StorePrompts {
    private var answers: [any Hashable & Sendable]
    private(set) var titles: [String] = []
    private(set) var labels: [[String]] = []
    private(set) var notices: [Notice] = []
    var holding = false
    /// Runs as each question arrives, with its title, before it's answered.
    var beforeAnswering: ((String) -> Void)?
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ answers: [any Hashable & Sendable] = []) {
        self.answers = answers
    }

    func answer(_ more: [any Hashable & Sendable]) {
        answers += more
    }

    func ask<Choice>(_ alert: WriterAlert<Choice>) async -> Choice {
        titles.append(alert.title)
        labels.append(alert.buttons.map(\.label))
        beforeAnswering?(alert.title)
        if holding { await withCheckedContinuation { held.append($0) } }
        if let next = answers.first as? Choice {
            answers.removeFirst()
            return next
        }
        return alert.choices[0]
    }

    func tell(_ notice: Notice) async {
        notices.append(notice)
    }

    func releaseHeld() {
        holding = false
        for continuation in held { continuation.resume() }
        held = []
    }
}

typealias TestStore = BookStore<ManualClock>

@MainActor
func makeStore(
    in folder: URL, prompts: ScriptedPrompts = ScriptedPrompts(),
    memory: TransientBookMemory = TransientBookMemory(),
    fileSystem: any FileSystem = LocalFileSystem(), clock: ManualClock = ManualClock(),
    parseDefaults: ParseDefaults = .system
) -> TestStore {
    BookStore(
        clock: clock, fileSystem: fileSystem, mirror: BackupMirror(root: folder.appending(path: "Mirror")),
        memory: memory, prompts: prompts, parseDefaults: parseDefaults)
}

/// A fresh directory under the system temporary directory, removed when `body` returns.
@MainActor
func withTemporaryFolder<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "SceneItStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { removeUnlocking(url) }
    return try await body(url)
}

/// The book in `package`'s `book.md`, parsed.
func bookOnDisk(_ package: URL, file: String = "book.md") throws -> Book {
    var ids = IDGenerator.system
    return BookFormat.parse(
        try Data(contentsOf: package.appending(path: file)), opened: Timestamp(.now, in: .current), ids: &ids
    ).book
}

/// What another program (a sync service, say) does: replaces `book.md` with `book`.
func writeExternally(_ book: Book, to package: URL) throws {
    try BookFormat.serialize(book).write(to: package.appending(path: "book.md"), options: .atomic)
}

extension OpenBook {
    var hasUnsavedEdits: Bool { status != .saved }

    /// Adds a scene and types `text` into it as one paragraph.
    @discardableResult
    func write(_ text: String) -> SceneID? {
        guard let scene = addScene(after: nil) else { return nil }
        replaceBody(of: scene, with: [[Run(text)]])
        return scene
    }
}

/// Creates `name.sceneit` in `folder` through the store and checks that it opened.
@MainActor
@discardableResult
func createBook(_ name: String, in folder: URL, store: TestStore) async throws -> URL {
    let url = folder.appending(path: "\(name).sceneit", directoryHint: .isDirectory)
    try #require(await store.create(at: url) == .created)
    return url
}
