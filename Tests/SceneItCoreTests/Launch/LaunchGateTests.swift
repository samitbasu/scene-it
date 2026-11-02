import Foundation
import Testing

@testable import SceneItCore

/// What a launch did, in order, and how it ended.
private struct Trace {
    var steps: [String] = []
    var outcome: Outcome?

    enum Outcome: Equatable {
        case proceed(InstanceLockSummary)
        case handOff
    }
}

private func launch(_ role: ProcessRole, lock attempt: @escaping () -> LockAttempt) -> Trace {
    var trace = Trace()
    let launch = LaunchGate.open(
        role: role,
        acquire: {
            trace.steps.append("lock")
            return attempt()
        },
        startSession: { trace.steps.append("marker") })
    switch consume launch {
    case .proceed(let lock, session: _): trace.outcome = .proceed(lock.summary)
    case .handOff: trace.outcome = .handOff
    }
    return trace
}

@Test func theRoleComesFromTheEnvironment() {
    #expect(ProcessRole(environment: [:]) == .app)
    #expect(ProcessRole(environment: ["XCTestConfigurationFilePath": "/x"]) == .testHost)
    #expect(ProcessRole(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]) == .preview)
    #expect(ProcessRole(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "0"]) == .app)
}

@Test(arguments: [ProcessRole.testHost, .preview])
func theTestHostAndPreviewsNeverAskForTheLock(_ role: ProcessRole) {
    let trace = launch(role) {
        Issue.record("asked for the lock")
        return .heldElsewhere
    }
    #expect(trace.steps == ["marker"])
    #expect(trace.outcome == .proceed(.exempt(role)))
}

@Test func theAppLocksBeforeWritingTheMarker() throws {
    let directory = try TemporaryDirectory()
    let file = directory.url.appending(path: "instance.lock")
    let trace = launch(.app) { ExclusiveFileLock.acquire(file) }
    #expect(trace.steps == ["lock", "marker"])
    #expect(trace.outcome == .proceed(.held))
}

@Test func aSecondInstanceHandsOffWithoutTouchingTheMarker() {
    let trace = launch(.app) { .heldElsewhere }
    #expect(trace.steps == ["lock"])
    #expect(trace.outcome == .handOff)
}

@Test func anUnusableLockFileDoesntStopTheLaunch() {
    let error = FileSystemError(.lock, URL(filePath: "/instance.lock"), .permissionDenied)
    let trace = launch(.app) { .failed(error) }
    #expect(trace.steps == ["lock", "marker"])
    #expect(trace.outcome == .proceed(.unavailable))
}

@Test func whileOneInstanceRunsTheNextHandsOff() throws {
    let directory = try TemporaryDirectory()
    let file = directory.url.appending(path: "Scene It/instance.lock")
    switch LaunchGate.open(role: .app, acquire: { LaunchGate.acquire(file) }, startSession: {}) {
    case .proceed(let lock, session: _):
        #expect(lock.summary == .held, "acquire created the missing folder")
        #expect(launch(.app) { LaunchGate.acquire(file) }.outcome == .handOff)
        _ = consume lock
        #expect(launch(.app) { LaunchGate.acquire(file) }.outcome == .proceed(.held))
    case .handOff:
        Issue.record("the first instance should run")
    }
}

@Test func theHolderRecordsItsProcessIDForTheNextLaunch() throws {
    let directory = try TemporaryDirectory()
    let file = directory.url.appending(path: "instance.lock")
    let lock = try LaunchGate.acquire(file, processID: 4321).lock()
    #expect(LaunchGate.recordedHolder(in: try Data(contentsOf: file)) == 4321)
    lock.release()
    #expect(LaunchGate.recordedHolder(in: Data()) == nil)
    #expect(LaunchGate.recordedHolder(in: Data("garbage".utf8)) == nil)
}

@Test func theHandOffPrefersTheRecordedHolder() {
    func target(_ recorded: Int32?, running: Set<Int32>, sameBundle: [Int32]) -> Int32? {
        LaunchGate.handOffTarget(
            recorded: recorded, ours: 10, isRunningSceneIt: running.contains, sameBundle: sameBundle)
    }
    #expect(target(20, running: [20, 30], sameBundle: [10, 30, 20]) == 20)
    #expect(target(20, running: [30], sameBundle: [10, 30]) == 30, "the recorded holder is gone")
    #expect(target(10, running: [10, 30], sameBundle: [10, 30]) == 30, "never ourselves")
    #expect(target(nil, running: [], sameBundle: [10, 30]) == 30)
    #expect(target(nil, running: [], sameBundle: [10]) == nil)
}
