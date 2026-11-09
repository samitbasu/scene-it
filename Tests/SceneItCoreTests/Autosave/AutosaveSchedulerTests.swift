import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

typealias Scheduler = AutosaveScheduler<ManualClock.Instant>

func at(_ offset: Duration) -> ManualClock.Instant {
    ManualClock.Instant(offset: offset)
}

let diskFull = SaveError.fileSystem(
    FileSystemError(.write, URL(filePath: "/Books/Novel.sceneit/book.md"), .noSpace))
let theirVersion = ContentDigest(Data("their version".utf8))
let changedOnDisk = SaveError.externallyModified(.changed(theirs: theirVersion))

extension Scheduler {
    /// A scheduler that has just started a save of edits made at `start`.
    static func saving(at start: Duration = .seconds(2)) -> Scheduler {
        var scheduler = Scheduler()
        _ = scheduler.handle(.edited, at: at(.zero))
        let decision = scheduler.handle(.tick, at: at(start))
        precondition(decision == .saveNow(.typingPaused), "the helper's save must start")
        return scheduler
    }

    var isPaused: Bool {
        if case .paused = state { true } else { false }
    }

    var isSaving: Bool {
        if case .saving = state { true } else { false }
    }
}

extension Scheduler.Decision {
    /// A save that refuses to replace another program's version, as every save does except
    /// those after "Keep My Version".
    static func saveNow(_ trigger: SaveTrigger) -> Self {
        .saveNow(SaveRequest(trigger))
    }

    static func overwriting(_ trigger: SaveTrigger, theirs: ContentDigest = theirVersion) -> Self {
        .saveNow(SaveRequest(trigger, onExternalChange: .overwriteKeepingTheirsAsBackup(theirs: theirs)))
    }
}

// MARK: Timed saves

@Test func savesTwoSecondsAfterTheLastEdit() {
    var scheduler = Scheduler()
    #expect(scheduler.handle(.edited, at: at(.zero)) == .waitUntil(at(.seconds(2))))
    #expect(scheduler.handle(.tick, at: at(.milliseconds(1999))) == .waitUntil(at(.seconds(2))))
    #expect(scheduler.handle(.tick, at: at(.seconds(2))) == .saveNow(.typingPaused))
    #expect(scheduler.isSaving)
}

@Test func eachEditPushesTheIdleSaveBack() {
    var scheduler = Scheduler()
    _ = scheduler.handle(.edited, at: at(.zero))
    #expect(scheduler.handle(.edited, at: at(.milliseconds(1500))) == .waitUntil(at(.milliseconds(3500))))
    #expect(scheduler.handle(.tick, at: at(.seconds(2))) == .waitUntil(at(.milliseconds(3500))))
    #expect(scheduler.handle(.tick, at: at(.milliseconds(3500))) == .saveNow(.typingPaused))
}

@Test func continuousEditingSavesEveryThirtySecondsFromTheFirstUnsavedEdit() {
    var scheduler = Scheduler()
    var saves: [(Duration, SaveTrigger)] = []
    for second in 0..<100 {
        let now = at(.seconds(second))
        if case .saveNow(let request) = scheduler.handle(.edited, at: now) {
            saves.append((.seconds(second), request.trigger))
            #expect(scheduler.handle(.saveSucceeded, at: now) == .idle)
        }
    }
    #expect(saves.map(\.0) == [.seconds(30), .seconds(61), .seconds(92)])
    #expect(saves.allSatisfy { $0.1 == .continuousEditing })
}

@Test func theThirtySecondDeadlineWinsOverTheIdleDeadline() {
    var scheduler = Scheduler()
    _ = scheduler.handle(.edited, at: at(.zero))
    #expect(scheduler.handle(.edited, at: at(.seconds(29))) == .waitUntil(at(.seconds(30))))
    #expect(scheduler.handle(.tick, at: at(.seconds(30))) == .saveNow(.continuousEditing))
}

// MARK: Immediate saves

let immediateEvents: [(AutosaveEvent, ImmediateTrigger)] = [
    (.sceneSwitched, .sceneSwitched),
    (.appDeactivated, .appDeactivated),
    (.quitRequested, .quit),
    (.saveCommand, .saveCommand),
]

@Test(arguments: immediateEvents)
func immediateTriggersSaveMidWait(event: AutosaveEvent, trigger: ImmediateTrigger) {
    var scheduler = Scheduler()
    #expect(scheduler.handle(.edited, at: at(.zero)) == .waitUntil(at(.seconds(2))))
    #expect(scheduler.handle(event, at: at(.seconds(1))) == .saveNow(.immediate(trigger)))
    #expect(scheduler.isSaving)
}

@Test(arguments: immediateEvents.map(\.0) + [.externalChangeResolved, .saveSucceeded, .tick])
func nothingSavesWhenTheBookIsClean(event: AutosaveEvent) {
    var scheduler = Scheduler()
    #expect(scheduler.handle(event, at: at(.zero)) == .idle)
    #expect(scheduler.state == .clean)
}

// MARK: A save in flight

@Test func editsDuringASaveScheduleTheNextOne() {
    var scheduler = Scheduler.saving(at: .seconds(2))
    #expect(scheduler.handle(.edited, at: at(.milliseconds(2500))) == .idle)
    #expect(scheduler.handle(.edited, at: at(.seconds(3))) == .idle)
    #expect(scheduler.handle(.tick, at: at(.seconds(10))) == .idle)
    #expect(scheduler.handle(.saveSucceeded, at: at(.seconds(10))) == .saveNow(.typingPaused))

    var later = Scheduler.saving(at: .seconds(2))
    _ = later.handle(.edited, at: at(.milliseconds(2500)))
    #expect(later.handle(.saveSucceeded, at: at(.seconds(3))) == .waitUntil(at(.milliseconds(4500))))
    guard case .unsaved(let unsaved) = later.state else {
        Issue.record("edits made during the save must stay unsaved")
        return
    }
    #expect(unsaved.edits.first == at(.milliseconds(2500)))
}

@Test(arguments: immediateEvents.map(\.0))
func anImmediateRequestDuringASaveWaitsForIt(event: AutosaveEvent) {
    var covered = Scheduler.saving()
    #expect(covered.handle(event, at: at(.seconds(3))) == .idle)
    #expect(covered.handle(.saveSucceeded, at: at(.seconds(4))) == .idle)
    #expect(covered.state == .clean)

    var withEdits = Scheduler.saving()
    _ = withEdits.handle(.edited, at: at(.seconds(3)))
    #expect(withEdits.handle(event, at: at(.seconds(3))) == .idle)
    guard case .saveNow(let request) = withEdits.handle(.saveSucceeded, at: at(.seconds(4))),
        case .immediate = request.trigger
    else {
        Issue.record("the request must start a save as soon as the running one ends")
        return
    }
}

@Test func strayCompletionsAreIgnored() {
    var scheduler = Scheduler()
    _ = scheduler.handle(.edited, at: at(.zero))
    #expect(scheduler.handle(.saveSucceeded, at: at(.seconds(1))) == .waitUntil(at(.seconds(2))))
    #expect(scheduler.handle(.saveFailed(diskFull), at: at(.seconds(1))) == .waitUntil(at(.seconds(2))))
}

// MARK: Failures

@Test func failedSavesRetryWithBackoffAndNeverGiveUp() {
    var scheduler = Scheduler.saving(at: .seconds(2))
    var now = Duration.seconds(2)
    for (attempt, delay) in [2, 5, 15, 30, 30, 30].enumerated() {
        let retryAt = now + .seconds(delay)
        #expect(scheduler.handle(.saveFailed(diskFull), at: at(now)) == .waitUntil(at(retryAt)))
        #expect(scheduler.failure?.consecutive == attempt + 1)
        #expect(scheduler.failure?.error == diskFull)
        #expect(scheduler.handle(.tick, at: at(retryAt - .milliseconds(1))) == .waitUntil(at(retryAt)))
        #expect(scheduler.handle(.tick, at: at(retryAt)) == .saveNow(.retry))
        #expect(scheduler.failure?.consecutive == attempt + 1, "a retry in flight still shows the failure")
        now = retryAt
    }
    #expect(scheduler.handle(.saveSucceeded, at: at(now)) == .idle)
    #expect(scheduler.state == .clean)
    #expect(scheduler.failure == nil)
}

@Test func editsDuringAFailureWaitForTheRetry() {
    var scheduler = Scheduler.saving(at: .seconds(2))
    _ = scheduler.handle(.saveFailed(diskFull), at: at(.seconds(2)))
    #expect(scheduler.handle(.edited, at: at(.seconds(3))) == .waitUntil(at(.seconds(4))))
    #expect(scheduler.handle(.saveCommand, at: at(.seconds(3))) == .saveNow(.immediate(.saveCommand)))
}

@Test func aSuccessAfterFailuresResetsTheBackoff() {
    var scheduler = Scheduler.saving(at: .seconds(2))
    _ = scheduler.handle(.saveFailed(diskFull), at: at(.seconds(2)))
    _ = scheduler.handle(.tick, at: at(.seconds(4)))
    _ = scheduler.handle(.saveFailed(diskFull), at: at(.seconds(4)))
    #expect(scheduler.failure?.consecutive == 2)
    _ = scheduler.handle(.tick, at: at(.seconds(9)))
    _ = scheduler.handle(.edited, at: at(.seconds(10)))
    #expect(scheduler.handle(.saveSucceeded, at: at(.seconds(11))) == .waitUntil(at(.seconds(12))))
    #expect(scheduler.failure == nil)
    #expect(scheduler.handle(.tick, at: at(.seconds(12))) == .saveNow(.typingPaused))
    #expect(scheduler.handle(.saveFailed(diskFull), at: at(.seconds(12))) == .waitUntil(at(.seconds(14))))
    #expect(scheduler.failure?.consecutive == 1)
}

// MARK: Pause on an external change (ADR 0018)

@Test(arguments: [
    (changedOnDisk, ExternalChangePolicy.overwriteKeepingTheirsAsBackup(theirs: theirVersion)),
    (.externallyModified(.removed), .recreate),
    (.externallyModified(.notAFile), .refuse),
    (
        .couldNotBackUpTheirVersion(
            FileSystemError(.move, URL(filePath: "/Books/Novel.sceneit/book.md"), .noSpace)),
        .refuse
    ),
])
func anExternalChangePausesAutosaveUntilResolved(error: SaveError, keepingMine: ExternalChangePolicy) {
    var scheduler = Scheduler.saving(at: .seconds(2))
    #expect(scheduler.handle(.saveFailed(error), at: at(.seconds(2))) == .idle)
    guard case .paused(let paused) = scheduler.state else {
        Issue.record("an external change must pause autosave")
        return
    }
    #expect(paused.error == error)
    #expect(paused.keepingMine == keepingMine)
    for event in immediateEvents.map(\.0) + [.edited, .tick, .saveSucceeded] {
        #expect(scheduler.handle(event, at: at(.seconds(300))) == .idle)
    }
    guard case .paused(let stillPaused) = scheduler.state else {
        Issue.record("only externalChangeResolved ends a pause")
        return
    }
    #expect(stillPaused.edits.first == at(.zero))
    #expect(stillPaused.edits.last == at(.seconds(300)))

    #expect(
        scheduler.handle(.externalChangeResolved, at: at(.seconds(360)))
            == .saveNow(SaveRequest(.immediate(.externalChangeResolved), onExternalChange: keepingMine)))
    #expect(scheduler.handle(.saveSucceeded, at: at(.seconds(360))) == .idle)
    #expect(scheduler.state == .clean)
}

// MARK: Quitting

@Test func quittingACleanBookTerminatesAtOnce() {
    var scheduler = Scheduler()
    _ = scheduler.handle(.quitRequested, at: at(.zero))
    #expect(scheduler.state.quitDecision == .settled(.terminate))
}

@Test func quittingWithUnsavedEditsSavesFirst() {
    var scheduler = Scheduler()
    _ = scheduler.handle(.edited, at: at(.zero))
    #expect(scheduler.handle(.quitRequested, at: at(.seconds(1))) == .saveNow(.immediate(.quit)))
    #expect(scheduler.state.quitDecision == .waitForSave)
    _ = scheduler.handle(.saveSucceeded, at: at(.seconds(1)))
    #expect(scheduler.state.quitDecision == .settled(.terminate))
}

@Test func quittingDuringASaveWaitsForItAndSavesLaterEdits() {
    var scheduler = Scheduler.saving()
    _ = scheduler.handle(.edited, at: at(.seconds(3)))
    #expect(scheduler.handle(.quitRequested, at: at(.seconds(3))) == .idle)
    #expect(scheduler.state.quitDecision == .waitForSave)
    #expect(scheduler.handle(.saveSucceeded, at: at(.seconds(4))) == .saveNow(.immediate(.quit)))
    #expect(scheduler.state.quitDecision == .waitForSave)
    _ = scheduler.handle(.saveSucceeded, at: at(.seconds(4)))
    #expect(scheduler.state.quitDecision == .settled(.terminate))
}

@Test func aFailingSaveAtQuitAsksTheWriterAndRetryTriesAgain() {
    var scheduler = Scheduler()
    _ = scheduler.handle(.edited, at: at(.zero))
    _ = scheduler.handle(.quitRequested, at: at(.zero))
    _ = scheduler.handle(.saveFailed(diskFull), at: at(.zero))
    #expect(scheduler.state.quitDecision == .settled(.askWriter(.saveFailed(diskFull))))

    #expect(scheduler.handle(.quitRequested, at: at(.seconds(1))) == .saveNow(.immediate(.quit)))
    #expect(scheduler.state.quitDecision == .waitForSave)
    _ = scheduler.handle(.saveSucceeded, at: at(.seconds(1)))
    #expect(scheduler.state.quitDecision == .settled(.terminate))
}

@Test func quittingAfterAnEarlierFailureTriesOnceMoreBeforeAsking() {
    var scheduler = Scheduler.saving()
    _ = scheduler.handle(.saveFailed(diskFull), at: at(.seconds(2)))
    #expect(scheduler.handle(.quitRequested, at: at(.seconds(3))) == .saveNow(.immediate(.quit)))
    #expect(scheduler.state.quitDecision == .waitForSave)
    _ = scheduler.handle(.saveFailed(diskFull), at: at(.seconds(3)))
    #expect(scheduler.state.quitDecision == .settled(.askWriter(.saveFailed(diskFull))))
}

@Test func quittingWhilePausedAsksTheWriter() {
    var scheduler = Scheduler.saving()
    _ = scheduler.handle(.saveFailed(changedOnDisk), at: at(.seconds(2)))
    #expect(scheduler.handle(.quitRequested, at: at(.seconds(3))) == .idle)
    #expect(scheduler.state.quitDecision == .settled(.askWriter(.changedOnDisk(changedOnDisk))))
}

@Test func quitWordingOffersNoRetryWhilePausedAndNeverDefaultsToQuitting() {
    let failed = QuitWording.alert(for: .saveFailed(diskFull), leaving: .quit)
    #expect(failed.choices == [.retry, .cancel, .quitAnyway])
    #expect(failed.message.hasPrefix("The disk is full."))
    let paused = QuitWording.alert(for: .changedOnDisk(changedOnDisk), leaving: .quit)
    #expect(paused.choices == [.cancel, .quitAnyway])
    for alert in [failed, paused] {
        #expect(alert.choices.first != .quitAnyway)
        #expect(alert.choices.contains(.cancel))
    }
}
