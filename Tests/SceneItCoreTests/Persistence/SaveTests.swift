import Foundation
import Testing

@testable import SceneItCore

/// Each step of a save that can fail, in pipeline order.
enum SaveFault: CaseIterable, CustomTestStringConvertible {
    case encode, verify
    case inspectBook, readBook, inspectBak1, readBak1, inspectBak2, shiftBak2, shiftBak1, backUpCurrent,
        writeBook

    /// The file-system call this step makes; `nil` for the in-memory steps.
    var call: FaultInjectingFileSystem.Call? {
        switch self {
        case .encode, .verify: nil
        case .inspectBook: .inspect("book.json")
        case .readBook: .read("book.json")
        case .inspectBak1: .inspect("book.json.bak1")
        case .readBak1: .read("book.json.bak1")
        case .inspectBak2: .inspect("book.json.bak2")
        case .shiftBak2: .move("book.json.bak2", over: "book.json.bak3")
        case .shiftBak1: .move("book.json.bak1", over: "book.json.bak2")
        case .backUpCurrent: .write("book.json.bak1")
        case .writeBook: .write("book.json")
        }
    }

    /// Whether every backup is still in its slot if the save stops at this step.
    var backupsUntouched: Bool {
        switch self {
        case .encode, .verify, .inspectBook, .readBook, .inspectBak1, .readBak1, .inspectBak2, .shiftBak2:
            true
        case .shiftBak1, .backUpCurrent, .writeBook: false
        }
    }

    var testDescription: String { "\(self)" }

    static let fileSystemSteps = allCases.filter { $0.call != nil }
}

/// A package at `url` whose `book.json` is draft 0 and whose `bak1`…`bak3` are drafts 1…3.
func makeFullPackage(at url: URL, fileSystem: any FileSystem) throws -> BookPackage {
    var package = try BookPackage.create(at: url, title: "Untitled", fileSystem: fileSystem).package
    for number in [3, 2, 1, 0] {
        #expect(try package.save(draft(number)) == .saved)
    }
    try expectStandardLayout(package.layout, book: draft(0), backups: [draft(1), draft(2), draft(3)])
    return package
}

func expectStandardLayout(
    _ layout: PackageLayout, book: Book, backups: [Book], sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let (current, saved) = layout.contents()
    #expect(current == (try encoded(book)), "book.json", sourceLocation: sourceLocation)
    for slot in BackupSlot.allCases {
        let expected =
            try backups.indices.contains(slot.rawValue - 1) ? encoded(backups[slot.rawValue - 1]) : nil
        #expect(saved[slot] == expected, "\(slot)", sourceLocation: sourceLocation)
    }
}

/// Bytes that decode to a valid book but aren't what the encoder writes.
func unstableEncoding(of book: Book) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: encoded(book))
    return try JSONSerialization.data(withJSONObject: object)
}

@Suite struct SaveTests {
    @Test func fiveSavesKeepThePreviousThreeVersionsAsBackups() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            var package = try BookPackage.create(at: url, title: "Novel").package
            var versions = [try #require(package.layout.contents().book)]
            for number in 1...5 {
                #expect(try package.save(draft(number)) == .saved)
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
        }
    }

    @Test func anUnchangedSaveWritesNothing() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            var package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            let before = try DirectorySnapshot(url)
            #expect(try package.save(draft(0)) == .unchanged)
            var reopened = try BookPackage.open(at: url).package
            #expect(try reopened.save(draft(0)) == .unchanged)
            #expect(try DirectorySnapshot(url) == before)
        }
    }

    @Test func aSaveMakesExactlyThePipelineCallsInOrder() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            var package = try makeFullPackage(at: url, fileSystem: fileSystem)
            fileSystem.clearCalls()
            #expect(try package.save(draft(9)) == .saved)
            #expect(fileSystem.calls == SaveFault.fileSystemSteps.compactMap(\.call))
        }
    }

    @Test(arguments: SaveFault.allCases)
    func aFailedSaveLeavesTheBookAndBackupsIntact(_ fault: SaveFault) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            var package = try makeFullPackage(at: url, fileSystem: fileSystem)
            let original = package.layout.contents()
            let survivors = try Set([0, 1, 2].map { try encoded(draft($0)) })

            // Twice: a retry that fails the same way must not lose anything more.
            for _ in 1...2 {
                let error = try #require(throws: SaveError.self) {
                    try attemptSave(&package, failing: fault, fileSystem)
                }
                switch (fault, error) {
                case (.encode, .encoding(.rejected)), (.verify, .encoding(.unstable)): break
                case (_, .fileSystem) where fault.call != nil: break
                default: Issue.record("unexpected error \(error)")
                }
                let (book, backups) = package.layout.contents()
                #expect(book == original.book)
                #expect(survivors.isSubset(of: Set(backups.values).union([book].compactMap { $0 })))
                if fault.backupsUntouched {
                    #expect(backups == original.backups)
                }
            }

            fileSystem.clearFault()
            #expect(try package.save(draft(9)) == .saved)
            try expectStandardLayout(package.layout, book: draft(9), backups: [draft(0), draft(1), draft(2)])
        }
    }

    @Test(arguments: SaveFault.fileSystemSteps)
    func aCrashAtAnyStepLeavesABookThatLoads(_ crash: SaveFault) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            let fileSystem = FaultInjectingFileSystem(root: url)
            var package = try makeFullPackage(at: url, fileSystem: fileSystem)
            fileSystem.inject(try #require(crash.call), leaving: .partialTemporaryFile)
            #expect(throws: SaveError.self) { try package.save(draft(9)) }
            if case .write(let name)? = crash.call {
                #expect(
                    FileManager.default.fileExists(
                        atPath: url.appending(path: ".\(name).crashed.tmp").path()),
                    "precondition: the crash left a half-written temporary file")
            }

            var restarted = try BookPackage.open(at: url)
            #expect(restarted.book == (try draft(0)))
            #expect(try restarted.package.save(draft(9)) == .saved)
            try expectStandardLayout(url.layout, book: draft(9), backups: [draft(0), draft(1), draft(2)])
            #expect(try BookPackage.open(at: url).book == (try draft(9)))
        }
    }

    @Test func aCrashAfterTheLastStepLoadsTheNewBook() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            var package = try makeFullPackage(at: url, fileSystem: LocalFileSystem())
            #expect(try package.save(draft(9)) == .saved)
            #expect(try BookPackage.open(at: url).book == (try draft(9)))
        }
    }

    @Test func theFirstSaveOfANewBookBacksUpOnlyTheEmptyBook() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            var package = try BookPackage.create(at: url, title: "Novel").package
            #expect(try package.save(draft(1)) == .saved)
            try expectStandardLayout(package.layout, book: draft(1), backups: [Book(title: "Novel")])
        }
    }

    @Test func verificationRejectsBytesThatAreNotAFixedPoint() throws {
        let unstable = try unstableEncoding(of: draft(1))
        #expect(throws: EncodingFailure.unstable) { try BookPackage.verify(unstable) }
        #expect(throws: EncodingFailure.self) { try BookPackage.verify(Data("{".utf8)) }
        try BookPackage.verify(encoded(draft(1)))
    }
}

/// Runs a save that fails at `fault`.
private func attemptSave(
    _ package: inout BookPackage, failing fault: SaveFault, _ fileSystem: FaultInjectingFileSystem
) throws {
    switch fault {
    case .encode:
        var book = try draft(9)
        book.scenes.append(book.scenes[0])
        _ = try package.save(book)
    case .verify:
        _ = try package.save(encoded: unstableEncoding(of: draft(9)))
    default:
        fileSystem.inject(try #require(fault.call))
        _ = try package.save(draft(9))
    }
}

extension URL {
    var layout: PackageLayout { PackageLayout(root: self) }
}
