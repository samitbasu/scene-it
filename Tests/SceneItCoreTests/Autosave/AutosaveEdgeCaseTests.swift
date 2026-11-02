import Foundation
import Testing

@testable import SceneItCore

// MARK: "Keep My Version" lives in the state

extension Scheduler {
    /// Paused on an external change to edits made at zero, then resolved with "Keep My Version".
    static func resolvingExternalChange() -> Scheduler {
        var scheduler = Scheduler.saving()
        _ = scheduler.handle(.saveFailed(changedOnDisk), at: at(.seconds(2)))
        let decision = scheduler.handle(.externalChangeResolved, at: at(.seconds(3)))
        precondition(decision == .overwriting(.immediate(.externalChangeResolved)), "must resume")
        return scheduler
    }
}

@Test func keepMyVersionSurvivesOrdinaryFailuresUntilASaveSucceeds() {
    var scheduler = Scheduler.resolvingExternalChange()
    #expect(scheduler.handle(.saveFailed(diskFull), at: at(.seconds(3))) == .waitUntil(at(.seconds(5))))
    #expect(scheduler.handle(.tick, at: at(.seconds(5))) == .overwriting(.retry))
    #expect(scheduler.handle(.saveFailed(diskFull), at: at(.seconds(5))) == .waitUntil(at(.seconds(10))))
    #expect(scheduler.handle(.saveCommand, at: at(.seconds(6))) == .overwriting(.immediate(.saveCommand)))
    #expect(scheduler.handle(.saveSucceeded, at: at(.seconds(6))) == .idle)
    #expect(scheduler.state == .clean)

    _ = scheduler.handle(.edited, at: at(.seconds(7)))
    #expect(scheduler.handle(.saveCommand, at: at(.seconds(7))) == .saveNow(.immediate(.saveCommand)))
}

@Test func keepMyVersionNeverCoversASecondExternalVersion() {
    var scheduler = Scheduler.resolvingExternalChange()
    #expect(scheduler.handle(.saveFailed(diskFull), at: at(.seconds(3))) == .waitUntil(at(.seconds(5))))
    #expect(scheduler.handle(.tick, at: at(.seconds(5))) == .overwriting(.retry))

    let secondVersion = ContentDigest(Data("a sync wrote this later".utf8))
    let secondChange = SaveError.externallyModified(.changed(theirs: secondVersion))
    #expect(scheduler.handle(.saveFailed(secondChange), at: at(.seconds(5))) == .idle)
    guard case .paused(let paused) = scheduler.state else {
        Issue.record("a second version must pause again, not be overwritten")
        return
    }
    #expect(paused.keepingMine == .overwriteKeepingTheirsAsBackup(theirs: secondVersion))
    #expect(scheduler.handle(.tick, at: at(.seconds(60))) == .idle)
    #expect(
        scheduler.handle(.externalChangeResolved, at: at(.seconds(61)))
            == .overwriting(.immediate(.externalChangeResolved), theirs: secondVersion))
}

@Test func editsDuringTheOverwritingSaveAreSavedWithoutOverwriting() {
    var scheduler = Scheduler.resolvingExternalChange()
    _ = scheduler.handle(.edited, at: at(.seconds(4)))
    #expect(scheduler.handle(.saveSucceeded, at: at(.seconds(4))) == .waitUntil(at(.seconds(6))))
    #expect(scheduler.handle(.tick, at: at(.seconds(6))) == .saveNow(.typingPaused))
}

@Test func aNewPauseNeedsANewChoice() {
    var scheduler = Scheduler.resolvingExternalChange()
    let theirsNotBackedUp = SaveError.couldNotBackUpTheirVersion(
        FileSystemError(.move, URL(filePath: "/Books/Novel.sceneit/book.json"), .noSpace))
    #expect(scheduler.handle(.saveFailed(theirsNotBackedUp), at: at(.seconds(3))) == .idle)
    #expect(scheduler.isPaused)
    for event in [AutosaveEvent.saveCommand, .tick, .sceneSwitched] {
        #expect(scheduler.handle(event, at: at(.seconds(60))) == .idle)
    }
    #expect(
        scheduler.handle(.externalChangeResolved, at: at(.seconds(61)))
            == .overwriting(.immediate(.externalChangeResolved)))
}

@Test func externalChangeResolvedOutsideAPauseDoesNothing() {
    var unsaved = Scheduler()
    _ = unsaved.handle(.edited, at: at(.zero))
    #expect(unsaved.handle(.externalChangeResolved, at: at(.seconds(1))) == .waitUntil(at(.seconds(2))))
    #expect(unsaved.handle(.tick, at: at(.seconds(2))) == .saveNow(.typingPaused))

    var saving = Scheduler.saving()
    #expect(saving.handle(.externalChangeResolved, at: at(.seconds(3))) == .idle)
    _ = saving.handle(.edited, at: at(.seconds(3)))
    #expect(saving.handle(.saveSucceeded, at: at(.seconds(3))) == .waitUntil(at(.seconds(5))))
}

// MARK: Edge cases

@Test func aSceneSwitchDuringAFailingSaveIsDroppedButTheEditStaysPending() {
    var scheduler = Scheduler.saving()
    _ = scheduler.handle(.edited, at: at(.seconds(3)))
    #expect(scheduler.handle(.sceneSwitched, at: at(.seconds(3))) == .idle)
    #expect(scheduler.handle(.saveFailed(diskFull), at: at(.seconds(4))) == .waitUntil(at(.seconds(6))))
    guard case .unsaved(let unsaved) = scheduler.state else {
        Issue.record("edits must stay unsaved")
        return
    }
    #expect(unsaved.requested == nil)
    #expect(unsaved.edits.first == at(.zero))
    #expect(unsaved.edits.last == at(.seconds(3)))
}

@Test func repeatedFailuresWithCmdSKeepCountingAndNeverSpin() {
    var scheduler = Scheduler.saving()
    let now = at(.seconds(2))
    for attempt in 1...10 {
        guard case .waitUntil(let due) = scheduler.handle(.saveFailed(diskFull), at: now) else {
            Issue.record("a failure must wait")
            return
        }
        #expect(due > now)
        #expect(scheduler.failure?.consecutive == attempt)
        #expect(scheduler.handle(.saveCommand, at: now) == .saveNow(.immediate(.saveCommand)))
    }
    #expect(AutosavePolicy.retryDelay(afterFailures: 0) == .seconds(2))
    #expect(AutosavePolicy.retryDelay(afterFailures: -5) == .seconds(2))
    #expect(AutosavePolicy.retryDelay(afterFailures: .max) == .seconds(30))
}

@Test func outOfOrderAndEqualInstantsNeverYieldAPastDeadline() {
    var scheduler = Scheduler()
    _ = scheduler.handle(.edited, at: at(.seconds(10)))
    #expect(scheduler.handle(.edited, at: at(.seconds(5))) == .waitUntil(at(.seconds(12))))
    #expect(scheduler.handle(.tick, at: at(.seconds(12))) == .saveNow(.typingPaused))
    #expect(scheduler.handle(.edited, at: at(.seconds(12))) == .idle)
    #expect(scheduler.handle(.saveSucceeded, at: at(.seconds(12))) == .waitUntil(at(.seconds(14))))
}

@Test func stillSavingOffersWaitAsTheDefault() {
    let alert = QuitWording.alert(for: .stillSaving)
    #expect(alert.choices == [.wait, .quitAnyway])
    #expect(alert.title == "Scene It is still saving your book.")
}
