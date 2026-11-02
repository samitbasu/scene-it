import Foundation
import Testing

@testable import SceneItCore

/// Each step of a save that can fail, in pipeline order.
enum SaveFault: CaseIterable, CustomTestStringConvertible {
    case encode, verify
    case inspectBook, readBook, inspectBak1, readBak1
    case writeBackupTemporary, writeBookTemporary
    case shiftBak2, shiftBak1, publishBak1
    case exchangeBook, readDisplaced

    /// The file-system call this step makes; `nil` for the in-memory steps.
    var call: FaultInjectingFileSystem.Call? {
        switch self {
        case .encode, .verify: nil
        case .inspectBook: .inspect("book.json")
        case .readBook: .read("book.json")
        case .inspectBak1: .inspect("book.json.bak1")
        case .readBak1: .read("book.json.bak1")
        case .writeBackupTemporary: .writeTemporary("book.json.bak1")
        case .writeBookTemporary: .writeTemporary("book.json")
        case .shiftBak2: .move("book.json.bak2", over: "book.json.bak3")
        case .shiftBak1: .move("book.json.bak1", over: "book.json.bak2")
        case .publishBak1: .publish("book.json.bak1")
        case .exchangeBook: .exchange("book.json")
        case .readDisplaced: .read("temporary book.json")
        }
    }

    enum Result {
        case saved(BackupState)
        case refused
    }

    enum BackupState {
        case intact
        case previousVersionNotBackedUp(OlderBackups)
    }

    /// ADR 0019, as a table. Starting from `book.json` = draft 0 (our own last save) and
    /// `bak1`…`bak3` = drafts 1…3, what a save of draft 9 that fails at this step does, and
    /// which drafts are left in `book.json` and each slot.
    var expected: (result: Result, book: Int, backups: [Int?]) {
        switch self {
        case .encode, .verify, .inspectBook, .readBook, .writeBackupTemporary, .writeBookTemporary:
            (.refused, 0, [1, 2, 3])
        // A failure to look at bak1 counts as "bak1 differs", so the save goes ahead normally.
        case .inspectBak1, .readBak1: (.saved(.intact), 9, [0, 1, 2])
        // The rotation stops at its first failure; draft 0 was ours, so the save goes ahead.
        case .shiftBak2: (.saved(.previousVersionNotBackedUp(.untouched)), 9, [1, 2, 3])
        case .shiftBak1: (.saved(.previousVersionNotBackedUp(.oldestRetired)), 9, [1, nil, 2])
        case .publishBak1: (.saved(.previousVersionNotBackedUp(.oldestRetired)), 9, [nil, 1, 2])
        // bak1 already holds book.json, so retries don't rotate again.
        case .exchangeBook: (.refused, 0, [0, 1, 2])
        // The displaced file can't be confirmed as ours, so it's swapped back.
        case .readDisplaced: (.refused, 0, [0, 1, 2])
        }
    }

    var testDescription: String { "\(self)" }

    static let fileSystemSteps = allCases.filter { $0.call != nil }
    static let rotationSteps: [SaveFault] = [.shiftBak2, .shiftBak1, .publishBak1]
}

/// A package at `url` whose `book.json` is draft 0 and whose `bak1`…`bak3` are drafts 1…3.
func makeFullPackage(at url: URL, fileSystem: any FileSystem) throws -> BookPackage {
    let package = try BookPackage.create(at: url, title: "Untitled", fileSystem: fileSystem).package
    for number in [3, 2, 1, 0] {
        #expect(try package.save(draft(number)).backupStatus == .intact)
    }
    try expectLayout(package.layout, book: 0, backups: [1, 2, 3])
    return package
}

/// Expects `book.json` and `bak1`…`bak3` to hold these drafts (`nil`: the slot is empty).
func expectLayout(
    _ layout: PackageLayout, book: Int, backups: [Int?], sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let (current, saved) = layout.contents()
    #expect(current == (try encoded(draft(book))), "book.json", sourceLocation: sourceLocation)
    for slot in BackupSlot.allCases {
        let expected = try backups[slot.rawValue - 1].map { try encoded(draft($0)) }
        #expect(saved[slot] == expected, "\(slot)", sourceLocation: sourceLocation)
    }
}

/// A book whose serialization reads back as a different book, with no new error entries:
/// a run carries a comment id the scene doesn't list (book format §7.5), so the save
/// would lose it.
func lossyBook(_ number: Int) throws -> Book {
    var book = try draft(number)
    book.scenes[0].body.append([Run("ghost", comments: [CommentID(rawValue: "ghost")])])
    return book
}

/// A book whose re-read gains error entries: two scenes with the same id.
func bookWithNewEntries(_ number: Int) throws -> Book {
    var book = try draft(number)
    book.scenes.append(book.scenes[0])
    return book
}

@Suite struct SaveTests {
    @Test func fiveSavesKeepThePreviousThreeVersionsAsBackups() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try BookPackage.create(at: url, title: "Novel").package
            var versions = [try #require(package.layout.contents().book)]
            for number in 1...5 {
                #expect(try package.save(draft(number)).backupStatus == .intact)
                versions.append(try encoded(draft(number)))
                let (book, backups) = package.layout.contents()
                #expect(book == versions.last)
                for slot in BackupSlot.allCases {
                    let index = versions.count - 1 - slot.rawValue
                    #expect(
                        backups[slot] == (index >= 0 ? versions[index] : nil), "after save \(number), \(slot)"
                    )
                }
            }
            #expect(Set(versions).count == versions.count, "precondition: every version is distinct")
            #expect(try temporaryFiles(in: url).isEmpty)
        }
    }

    @Test func anUnchangedSaveWritesNothing() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let before = try DirectorySnapshot(url)
            #expect(try package.save(draft(0)) == .unchanged)
            _ = consume package
            #expect(try #require(BookPackage.open(at: url).editable).package.save(draft(0)) == .unchanged)
            #expect(try DirectorySnapshot(url) == before)
        }
    }

    @Test func aSaveMakesExactlyThePipelineCallsInOrder() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            fileSystem.clearCalls()
            #expect(try package.save(draft(9)).backupStatus == .intact)
            let steps = SaveFault.fileSystemSteps.compactMap(\.call)
            #expect(fileSystem.calls == steps + [.discard("temporary book.json"), .list("")])
        }
    }

    @Test(arguments: SaveFault.allCases)
    func aFailedStepDoesWhatThePolicyTableSays(_ fault: SaveFault) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            let expected = fault.expected

            switch expected.result {
            case .saved(let state):
                let outcome = try attemptSave(package, failing: fault, fileSystem)
                switch (state, outcome) {
                case (.intact, .saved(.intact, _)): break
                case (
                    .previousVersionNotBackedUp(let expected),
                    .saved(.previousVersionNotBackedUp(_, let actual), _)
                ):
                    #expect(actual == expected)
                default: Issue.record("unexpected outcome \(outcome)")
                }
                try expectLayout(package.layout, book: expected.book, backups: expected.backups)
            case .refused:
                // Twice: a retry that fails the same way must not lose anything more.
                for _ in 1...2 {
                    let error = try #require(throws: SaveError.self) {
                        try attemptSave(package, failing: fault, fileSystem)
                    }
                    switch (fault, error) {
                    case (.encode, .encoding(.newEntries)), (.verify, .encoding(.changed)),
                        (.readDisplaced, .externallyModified(.changed)):
                        break
                    case (_, .fileSystem) where fault.call != nil: break
                    default: Issue.record("unexpected error \(error)")
                    }
                    try expectLayout(package.layout, book: expected.book, backups: expected.backups)
                }
                fileSystem.clearFault()
                #expect(try package.save(draft(9)).backupStatus == .intact)
                try expectLayout(package.layout, book: 9, backups: [0, 1, 2])
            }
            #expect(try temporaryFiles(in: url).isEmpty, "every unpublished temporary file was discarded")
        }
    }

    /// Their version is never replaced unless it's safely in bak1 (ADR 0019).
    @Test(arguments: SaveFault.rotationSteps)
    func aFailedRotationNeverReplacesTheirVersion(_ fault: SaveFault) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            try encoded(draft(7)).write(to: url.layout.book)
            fileSystem.inject(.fail(try #require(fault.call)))
            let error = try #require(throws: SaveError.self) {
                try package.save(draft(9), onExternalChange: overwriting(7))
            }
            guard case .couldNotBackUpTheirVersion = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(url.layout.contents().book == (try encoded(draft(7))))
            #expect(try temporaryFiles(in: url).isEmpty)
        }
    }

    @Test func repeatedFailuresWhileKeepingTheirsNeverPushHistoryOut() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            try encoded(draft(7)).write(to: url.layout.book)
            fileSystem.inject(.fail(.exchange("book.json")))
            for _ in 1...3 {
                #expect(throws: SaveError.self) {
                    try package.save(draft(9), onExternalChange: overwriting(7))
                }
            }
            try expectLayout(url.layout, book: 7, backups: [7, 1, 2])
            fileSystem.clearFault()
            #expect(throws: try changed(to: 7)) { try package.save(draft(9)) }
            #expect(
                try package.save(draft(9), onExternalChange: overwriting(7))
                    .backupStatus == .intact)
            try expectLayout(url.layout, book: 9, backups: [7, 1, 2])
        }
    }

    @Test(arguments: SaveFault.fileSystemSteps)
    func aCrashAtAnyStepLeavesABookThatLoads(_ crash: SaveFault) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            let package = try makeFullPackage(at: url, fileSystem: fileSystem)
            fileSystem.inject(.crash(try #require(crash.call)))
            _ = try? package.save(draft(9))
            if case .writeTemporary? = crash.call {
                #expect(
                    try temporaryFiles(in: url).contains { $0.hasSuffix(".crashed.tmp") },
                    "precondition: the crash left a half-written temporary file")
            }
            let expected = crash.crashRow
            try expectLayout(url.layout, book: expected.book, backups: expected.backups)

            _ = consume package
            let restarted = try #require(
                BookPackage.open(at: url).editable, "the crashed process's lock is gone")
            #expect(restarted.book == (try draft(expected.book)))
            _ = try restarted.package.save(draft(9))
            try expectLayout(url.layout, book: 9, backups: [0, 1, 2])
            #expect(try BookPackage.open(at: url).book == (try draft(9)))
        }
    }

    @Test func theFirstSaveOfANewBookBacksUpOnlyTheEmptyBook() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let package = try BookPackage.create(at: url, title: "Novel").package
            #expect(try package.save(draft(1)).backupStatus == .intact)
            let (book, backups) = package.layout.contents()
            #expect(book == (try encoded(draft(1))))
            #expect(backups == [.bak1: try encoded(Book(title: "Novel"))])
        }
    }

    @Test func verificationRejectsBooksThatDontReadBack() throws {
        #expect(throws: VerificationFailure.changed) {
            try BookFormat.verifiedSerialization(of: lossyBook(1))
        }
        #expect(throws: VerificationFailure.self) {
            try BookFormat.verifiedSerialization(of: bookWithNewEntries(1))
        }
        #expect(try BookFormat.verifiedSerialization(of: draft(1)) == encoded(draft(1)))
    }
}

extension SaveFault {
    /// The files left by a crash *at* this step (that is, after the step before it).
    var crashRow: (book: Int, backups: [Int?]) {
        switch self {
        case .encode, .verify, .inspectBook, .readBook, .inspectBak1, .readBak1, .writeBackupTemporary,
            .writeBookTemporary, .shiftBak2:
            (0, [1, 2, 3])
        case .shiftBak1: (0, [1, nil, 2])
        case .publishBak1: (0, [nil, 1, 2])
        case .exchangeBook: (0, [0, 1, 2])
        case .readDisplaced: (9, [0, 1, 2])
        }
    }
}

/// Runs a save of draft 9 that fails at `fault`.
private func attemptSave(
    _ package: BookPackage, failing fault: SaveFault, _ fileSystem: FaultInjectingFileSystem
) throws -> SaveOutcome {
    switch fault {
    case .encode:
        return try package.save(bookWithNewEntries(9))
    case .verify:
        return try package.save(lossyBook(9))
    default:
        fileSystem.inject(.fail(try #require(fault.call)))
        return try package.save(draft(9))
    }
}

/// The hidden temporary files in a package's root.
func temporaryFiles(in url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
        .filter { $0.hasPrefix(".") && $0.hasSuffix(".tmp") }
}

/// Whether `book.json` or any backup slot holds `data`.
func packageKeeps(_ data: Data, _ layout: PackageLayout) -> Bool {
    let (book, backups) = layout.contents()
    return book == data || backups.values.contains(data)
}

extension URL {
    var layout: PackageLayout { PackageLayout(root: self) }
}
