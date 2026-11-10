import Foundation
import SceneItCore
import Testing

@testable import SceneIt

extension BookController {
    /// The requests carried out since the last call (the test host's `RecordedRequests`).
    func takeRequests() -> [RecordedRequests.Carried] {
        recorded?.take() ?? []
    }
}

/// Suites whose tests share something in the process that no test can keep to itself, so their
/// tests run one at a time, while the other suites' run beside them:
///
/// - the app's own store, `BookController.shared` (`BookStoreIntegrationTests`);
/// - the keyboard. No window in the test host is key, and then SwiftUI can hand a key equivalent
///   pressed in one window to a keyboard shortcut in another window's sheet or palette: one
///   test's Esc cancels another test's File a Copy dialog, and its own Esc is lost (#165). So a
///   suite that presses keys (`press`), or that shows a sheet window (a dialog, the Export
///   chooser) or a palette, goes here.
@Suite(.serialized)
enum OneAtATime {}

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

extension OpenedBook {
    /// `nil` when the book opened read-only.
    var editable: EditableBook? {
        if case .editing(let editable) = self { editable } else { nil }
    }
}

func bookOnDisk(_ package: URL) throws -> Book {
    var ids = IDGenerator.system
    return BookFormat.parse(
        try Data(contentsOf: package.appending(path: "book.md")), opened: Timestamp(.now, in: .current),
        ids: &ids
    ).book
}

/// Runs `body` from the run loop, as an event's handling runs, so an Objective-C exception in
/// AppKit doesn't unwind a Swift task. HIToolbox still swallows it, `done.resume()` never runs,
/// and the test hangs on the continuation until its time limit, but Swift concurrency is left
/// intact (ADR 0026). A block given to the run loop doesn't wake it: asleep, it would wait for
/// whatever wakes it next, which on an idle machine (GitHub's runners) can be a fraction of a
/// second.
@MainActor
func onTheRunLoop(_ body: @escaping @MainActor () -> Void) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        RunLoop.main.perform {
            MainActor.assumeIsolated(body)
            done.resume()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// Returns once the main queue has run the blocks queued on it before this call.
@MainActor
func afterTheMainQueue() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { done.resume() }
    }
}
