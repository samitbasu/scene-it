import Foundation
import Testing

@testable import SceneItCore

private let rotationFailure = FileSystemError(
    .publish, URL(filePath: "/Books/Novel.sceneit/book.json.bak1"), .io)
private let snapshotFailure = SnapshotFailure.fileSystem(
    .write, FileSystemError(.write, URL(filePath: "/Mirror/book.json"), .noSpace))

private func backups(_ rotation: BackupStatus, _ package: SnapshotOutcome, _ mirror: SnapshotOutcome)
    -> SavedBackups
{
    SavedBackups(rotation: rotation, snapshots: SnapshotReport(package: package, mirror: mirror))
}

private func state(after events: [AutosaveEvent]) -> Scheduler.State {
    var scheduler = Scheduler()
    for (index, event) in events.enumerated() {
        _ = scheduler.handle(event, at: at(.seconds(Int64(index))))
    }
    return scheduler.state
}

@Test func backupsWorkOnlyWhenTheRotationIsIntactAndNoSnapshotFailed() {
    let working: [SavedBackups] = [
        backups(.intact, .written, .written), backups(.intact, .notDue, .notDue),
        backups(.intact, .written, .notDue),
    ]
    let notWorking: [SavedBackups] = [
        backups(.previousVersionNotBackedUp(rotationFailure, olderBackups: .untouched), .written, .written),
        backups(.previousVersionNotBackedUp(rotationFailure, olderBackups: .oldestRetired), .notDue, .notDue),
        backups(.intact, .failed(snapshotFailure), .written),
        backups(.intact, .written, .failed(.notARealFolder)),
        backups(.intact, .failed(.clockOutOfRange), .failed(snapshotFailure)),
    ]
    #expect(working.allSatisfy { $0.areWorking })
    #expect(!notWorking.contains { $0.areWorking })
}

@Test func theStatusFollowsAutosaveAndTheLastSavesBackups() {
    let degraded = backups(.intact, .written, .failed(snapshotFailure))
    let healthy = backups(.intact, .written, .written)
    let clean = state(after: [])
    #expect(BookStatus(autosave: clean, lastBackups: nil) == .saved)
    #expect(BookStatus(autosave: clean, lastBackups: healthy) == .saved)
    #expect(BookStatus(autosave: clean, lastBackups: degraded) == .backupsNotWorking(degraded))

    let unsaved = state(after: [.edited])
    #expect(BookStatus(autosave: unsaved, lastBackups: degraded) == .unsaved)
    let saving = state(after: [.edited, .saveCommand])
    #expect(BookStatus(autosave: saving, lastBackups: degraded) == .saving)
    let failed = state(after: [.edited, .saveCommand, .saveFailed(diskFull)])
    #expect(BookStatus(autosave: failed, lastBackups: nil) == .failed(diskFull))
    let retrying = state(after: [.edited, .saveCommand, .saveFailed(diskFull), .saveCommand])
    #expect(BookStatus(autosave: retrying, lastBackups: nil) == .saving)
    for error in [
        changedOnDisk, .externallyModified(.removed), .externallyModified(.notAFile),
        .externallyModified(.keptAsConflict(fileName: "book.json.conflict-20261102T120000Z")),
        .couldNotBackUpTheirVersion(rotationFailure),
    ] {
        let paused = state(after: [.edited, .saveCommand, .saveFailed(error)])
        #expect(BookStatus(autosave: paused, lastBackups: healthy) == .changedOnDisk(error))
    }
}

@Test func everyStatusHasItsOwnWords() {
    let statuses: [BookStatus] = [
        .saved, .unsaved, .saving, .failed(diskFull), .changedOnDisk(changedOnDisk),
        .backupsNotWorking(backups(.intact, .failed(.clockOutOfRange), .written)), .readOnly(.openElsewhere),
        .closed,
    ]
    let words = statuses.map(StoreWording.status)
    #expect(Set(words).count == statuses.count)
    #expect(words[0] == "Saved")
    #expect(words[1] == "Unsaved changes")
    #expect(words[3] == "Not saved: The disk is full.")
    #expect(words[5] == "Backups aren't working")
}

@Test func externalChangeAlertsOfferOnlyChoicesThatCanWork() {
    let name = "Novel (my edits).sceneit"
    let both: [ExternalChangeChoice] = [.keepMyVersion, .openOtherVersion]
    #expect(StoreWording.externalChangeAlert(changedOnDisk, myEditsName: name).choices == both)
    #expect(
        StoreWording.externalChangeAlert(.externallyModified(.removed), myEditsName: name).choices == both)
    #expect(
        StoreWording.externalChangeAlert(.couldNotBackUpTheirVersion(rotationFailure), myEditsName: name)
            .choices
            == both)
    #expect(
        StoreWording.externalChangeAlert(.externallyModified(.notAFile), myEditsName: name).choices
            == [.openOtherVersion])
    let conflict = StoreWording.externalChangeAlert(
        .externallyModified(.keptAsConflict(fileName: "book.json.conflict-X")), myEditsName: name)
    #expect(conflict.choices == [.keepMyVersion])
    #expect(conflict.message.contains("book.json.conflict-X"))
}

@Test func theReadOnlyAlertOffersOpenAnywayOnlyForARecord() {
    let record = LockRecord(host: "Studio", hostID: "X", userID: 501, processID: 9, since: .now)
    let onAnotherMac = LockWording.alert(for: .openOnAnotherMac(record))
    #expect(onAnotherMac.choices == [.keepReadOnly, .openAnyway(record)])
    #expect(onAnotherMac.message.hasSuffix(LockWording.openAnywayWarning))
    #expect(LockWording.alert(for: .openElsewhere).choices == [.keepReadOnly])
    #expect(LockWording.alert(for: .lockUnavailable(rotationFailure)).choices == [.keepReadOnly])
}

@Test func closingABookWordsTheQuitAlertForClosing() {
    let quit = QuitWording.alert(for: .saveFailed(diskFull), leaving: .quit)
    let close = QuitWording.alert(for: .saveFailed(diskFull), leaving: .closeBook)
    #expect(quit.choices == close.choices)
    #expect(quit.buttons.map(\.label) == ["Retry", "Cancel", "Quit Anyway"])
    #expect(close.buttons.map(\.label) == ["Retry", "Cancel", "Close Anyway"])
    #expect(
        quit.message
            == "The disk is full. If you quit now, the changes you made since the last save will be lost.")
    #expect(
        close.message
            == "The disk is full. If you close this book now, the changes you made since the last save will be lost."
    )
}

@Test func theCrashAlertMentionsASaveOnlyFromTheCrashedSession() {
    let launch = Date(timeIntervalSince1970: 1_800_000_000)
    let during = launch.addingTimeInterval(600)
    let before = launch.addingTimeInterval(-600)
    let savedSentence = "Your book was last saved \(during.formatted(date: .abbreviated, time: .shortened))."
    #expect(ReportWording.crashAlertMessage(lastLaunch: launch, lastSaved: during).contains(savedSentence))
    #expect(!ReportWording.crashAlertMessage(lastLaunch: launch, lastSaved: before).contains("last saved"))
    #expect(!ReportWording.crashAlertMessage(lastLaunch: launch, lastSaved: nil).contains("last saved"))
    #expect(ReportWording.crashAlertMessage(lastLaunch: nil, lastSaved: during).hasPrefix(savedSentence))
}
