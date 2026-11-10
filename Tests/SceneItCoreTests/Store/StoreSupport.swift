import Dispatch
import Foundation
import Observation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// Answers the store's questions from a script and records every question. An alert whose
/// scripted answer is missing (or of another kind) gets its first button, as Return would;
/// with `holding`, questions wait until `releaseHeld()`.
@MainActor
@Observable
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
        reviews: ReviewsFolder(root: folder.appending(path: "Reviews")),
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

/// Holds a file-system call (on the thread making it) until the test opens the gate, so the
/// test can act on the main actor while the store waits for the disk. Made by `withGate`.
///
/// The store makes its file-system calls synchronously on a thread of Swift's shared pool, so
/// a held call keeps that thread, and the fake can't suspend instead. `withGate` takes one of
/// `GatePermits` first, which keeps the held calls from taking every thread of the pool: the
/// work that opens the gates needs one.
final class Gate: Sendable {
    private let arrivals = AsyncStream<Void>.makeStream()
    private let proceed = DispatchSemaphore(value: 0)

    fileprivate init() {}

    /// Called by the blocked call.
    func pass() {
        arrivals.continuation.yield()
        proceed.wait()
    }

    /// Returns at the next arrival, however long the disk call takes to get here. Cancelling the
    /// task (as a suite's time limit does) ends the wait with an issue.
    @MainActor
    func waitForArrival(sourceLocation: SourceLocation = #_sourceLocation) async {
        var next = arrivals.stream.makeAsyncIterator()
        if await next.next() == nil {
            Issue.record("cancelled before the call arrived", sourceLocation: sourceLocation)
        }
    }

    func open() {
        proceed.signal()
    }
}

/// Runs `body` with a gate, once a permit is free. However `body` ends, the gate opens, so a
/// held call goes on, and the permit is returned.
@MainActor
func withGate<T>(
    sourceLocation: SourceLocation = #_sourceLocation, _ body: (Gate) async throws -> T
) async throws -> T {
    guard await GatePermits.shared.acquire() == .resumed else {
        Issue.record("cancelled before a gate was free", sourceLocation: sourceLocation)
        throw CancellationError()
    }
    let gate = Gate()
    let result: Result<T, any Error>
    do {
        result = .success(try await body(gate))
    } catch {
        result = .failure(error)
    }
    gate.open()
    await GatePermits.shared.release()
    return try result.get()
}

/// How many gates may be held at once: half the pool's threads, so the other half always runs.
/// On a one-core host the pool has one thread, which any held call takes, so the gated tests
/// need two cores or more.
actor GatePermits {
    static let shared = GatePermits(ProcessInfo.processInfo.activeProcessorCount / 2)

    private var free: Int
    private var waiting: [Wake] = []

    init(_ count: Int) {
        free = max(1, count)
    }

    /// `.cancelled` if the task was cancelled first, holding no permit.
    func acquire() async -> WakeOutcome {
        if free > 0 {
            free -= 1
            return .resumed
        }
        return await suspend { waiting.append($0) }
    }

    /// Hands the permit to the first waiter still waiting, or frees it.
    func release() {
        while !waiting.isEmpty {
            if waiting.removeFirst().resume() { return }
        }
        free += 1
    }
}
