import Foundation
import Testing

@testable import SceneItCore

/// The adversarial review of #85, kept as regression tests: a fault at every step of a filing,
/// what the writer types surviving the index, a damaged index, decoy numbering and the seam's
/// guard on a re-cased path.
@Suite struct ArchiveReviewTests {
    typealias Call = FaultInjectingFileSystem.Call

    static func names(_ archive: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: archive.path(percentEncoded: false))) ?? [])
            .sorted()
    }

    /// The calls a clean filing of `draft(1)` makes, each with how many times it came before.
    static func filingSteps() throws -> [(call: Call, skip: Int)] {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            fixture.fileSystem.clearCalls()
            #expect(try fixture.file(try draft(1)).isComplete, "precondition: a clean filing")
            var seen: [Call: Int] = [:]
            return fixture.fileSystem.calls.map { call in
                defer { seen[call, default: 0] += 1 }
                return (call, seen[call, default: 0])
            }
        }
    }

    enum Injection: CaseIterable { case crash, fail }

    /// Whatever fails or crashes, every `saveNNNN.md` holds exactly the book, a copy reported
    /// locked is locked, one reported indexed has its tags and note, a failure leaves no copy,
    /// and reopening lists every copy and locks it.
    @Test func everyFaultLeavesExactCopiesOrNoneAndReopeningLocksThem() throws {
        let steps = try Self.filingSteps()
        #expect(steps.count > 10, "precondition: the filing's steps were recorded")
        let filed = try encoded(draft(1))
        for (call, skip) in steps {
            for injection in Injection.allCases where injection == .fail || skip == 0 {
                try withTemporaryDirectory { directory in
                    let context = "\(injection) at \(call)#\(skip)"
                    let url = directory.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
                    do {
                        let fixture = try FilingFixture(directory)
                        fixture.fileSystem.inject(
                            injection == .crash ? .crash(call) : .fail(call, skipping: skip))
                        do {
                            let outcome = try fixture.file(try draft(1))
                            let copy = fixture.copy(outcome.number.value)
                            #expect(try Data(contentsOf: copy) == filed, "\(context)")
                            switch outcome.lock {
                            case .locked: #expect(try isImmutable(copy), "reported locked: \(context)")
                            case .notLocked: #expect(try !isImmutable(copy), "reported unlocked: \(context)")
                            case .unverified: break
                            }
                            if case .updated = outcome.index {
                                let entry = try fixture.index().copies.first { $0.number == outcome.number }
                                #expect(entry?.tags == FilingFixture.record.tags, "\(context)")
                                #expect(entry?.note == FilingFixture.record.note, "\(context)")
                            }
                        } catch {
                            if injection == .fail {
                                #expect(
                                    Self.names(fixture.layout.archive).allSatisfy {
                                        FiledCopyNumber(fileName: $0) == nil
                                    },
                                    "a failure left a copy: \(context)")
                            }
                        }
                    }
                    let archive = url.appending(path: "Archive")
                    let onDisk = Self.names(archive).compactMap { FiledCopyNumber(fileName: $0) }
                    for number in onDisk {
                        #expect(
                            try Data(contentsOf: archive.appending(path: number.fileName)) == filed,
                            "\(context)")
                    }
                    guard
                        case .editing(let editable) = try BookPackage.open(
                            at: url, fileSystem: LocalFileSystem())
                    else { return }
                    let reconciled = editable.package.reconcileArchive()
                    #expect(reconciled.index.copies.map(\.number) == onDisk, "\(context)")
                    for number in onDisk {
                        #expect(
                            try isImmutable(archive.appending(path: number.fileName)), "unlocked: \(context)")
                    }
                }
            }
        }
    }

    /// What's typed in the dialog is what the index keeps.
    @Test(arguments: [
        ("a, b", " leading space note"), ("back\\slash", "trailing space "), ("#hash", "ends with newline\n"),
        ("tab\there", "line1\r\nline2"), ("x", "\n\nleading newlines"), ("ünïcödé 🎬", "note: inner"),
        ("## save0002.md", "## save0002.md\nfiled: 2020-01-01"), ("---", "---\nformat: 9\n---"),
        ("dup", "### Unparsed\n[line] x"), ("\u{00A0}nbsp\u{00A0}", "\u{2028}sep"),
    ])
    func typedTagsAndNotesRoundTrip(_ tag: String, _ note: String) throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            var draft = FilingDraft(today: FilingFixture.day)
            draft.pendingTag = tag
            draft.note = note
            let record = draft.record
            #expect(record.note == draft.note, "the dialog shows what's kept")
            let outcome = try fixture.file(nil, record)
            let stored = try fixture.index().copies.first { $0.number == outcome.number }
            #expect(stored?.tags == record.tags)
            #expect(stored?.note == record.note)
        }
    }

    /// A damaged index rewritten on open keeps every phrase the writer wrote, and the original.
    @Test func aDamagedIndexRewrittenOnOpenLosesNothing() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            let damaged = """
                ---
                format: 2
                ---

                ## Save0001.md
                filed: 2026-09-14
                tags: typo heading tag
                note: typo heading note

                ## save0002.md
                filed: 2026-13-45
                tags: kept tag
                note: bad date note \u{01}control

                ## save0003.md
                filed: 2026-09-16
                tags: recased file tag
                note: recased file note

                """
            do {
                let fixture = try FilingFixture(directory)
                for _ in 0..<3 { try fixture.file() }
                try FileManager.default.setAttributes(
                    [.immutable: false], ofItemAtPath: fixture.copy(3).path(percentEncoded: false))
                try FileManager.default.moveItem(
                    at: fixture.copy(3), to: fixture.layout.archive.appending(path: "Save0003-moved.md"))
                try Data(damaged.utf8).write(to: fixture.layout.archiveIndex)
            }
            guard case .editing(let editable) = try BookPackage.open(at: url, fileSystem: LocalFileSystem())
            else {
                Issue.record("not editable")
                return
            }
            let reconciled = editable.package.reconcileArchive()
            #expect(reconciled.notices.contains(.keptEntryWithoutFile(FiledCopyNumber(3)!)))
            let layout = editable.package.layout
            let after = String(decoding: try Data(contentsOf: layout.archiveIndex), as: UTF8.self)
            for phrase in [
                "typo heading tag", "typo heading note", "kept tag", "recased file tag", "recased file note",
            ] {
                #expect(after.contains(phrase), "\(phrase)")
            }
            let originals = Self.names(layout.archive).filter { $0.hasPrefix("index.md.original-") }
            #expect(originals.count == 1)
            #expect(
                try originals.first.map { try Data(contentsOf: layout.archive.appending(path: $0)) }
                    == Data(damaged.utf8))
            #expect(editable.package.reconcileArchive().rewrite == .unneeded, "the original is kept once")
        }
    }

    @Test func decoysNeitherCountNorBlockTheNumbering() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let archive = fixture.layout.archive
            for name in [
                "save٠٠٠٧.md", "save０００８.md", "SAVE0009.MD", "save00010.md", "save0011.MD",
                "save99999999999999999999999.md", " save0012.md", "save0013.md ",
            ] {
                try Data("decoy".utf8).write(to: archive.appending(path: name))
            }
            try FileManager.default.createDirectory(
                at: archive.appending(path: "save0005.md"), withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: archive.appending(path: "save0006.md"), withDestinationURL: fixture.layout.book)
            #expect(try fixture.file().number == FiledCopyNumber.first)
            #expect(
                try Data(contentsOf: fixture.layout.book) == (try encoded(draft(0))),
                "the link's target is intact")

            try Data("x".utf8).write(to: archive.appending(path: "save9999.md"))
            #expect(try fixture.file().number == FiledCopyNumber(10_000))
            try Data("x".utf8).write(to: archive.appending(path: "save\(Int.max).md"))
            #expect(try fixture.file().number == FiledCopyNumber(10_001), "a huge stray doesn't block filing")
            try Data("x".utf8).write(to: archive.appending(path: FiledCopyNumber.highest.fileName))
            #expect(throws: FilingFailure.noFreeNumber) { try fixture.file() }
            let message = try #require(
                ArchiveWording.notice(for: .failed(.noFreeNumber), record: FilingFixture.record)?.message)
            #expect(message.contains(FiledCopyNumber.highest.fileName), "the alert says why")
        }
    }

    @Test func theSeamRefusesARecasedPathToAFiledCopy() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let copy = fixture.copy(3)
            try Data("unlocked, as on a share that can't lock".utf8).write(to: copy)
            for variant in ["archive/save0003.md", "ARCHIVE/SAVE0003.MD", "Archive/Save0003.md"] {
                let url = fixture.layout.root.appending(path: variant)
                #expect(PackageLayout.isFiledCopy(url), "\(variant)")
                #expect(throws: FileSystemError(.remove, url, .filedCopy)) {
                    try LocalFileSystem().remove(url)
                }
            }
            #expect(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        }
    }

    /// A check of the lock that fails after the flag was set is never reported as unlocked.
    @Test func aLockThatCantBeCheckedIsReportedUnverified() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            let fileSystem = fixture.fileSystem
            fileSystem.before(.makeImmutable("Archive/save0001.md")) {
                fileSystem.inject(.fail(.inspect("Archive/save0001.md")))
            }
            let outcome = try fixture.file()
            fixture.fileSystem.clearFault()
            guard case .unverified = outcome.lock else {
                Issue.record("expected an unverified lock, got \(outcome.lock)")
                return
            }
            #expect(try isImmutable(fixture.copy(1)), "precondition: the flag is set")
        }
    }

    /// Point `REVIEW85_VOLUME` at a mounted scratch volume (FAT, exFAT, SMB) to try it there.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REVIEW85_VOLUME"] != nil))
    func onAnotherVolume() throws {
        let volume = try #require(ProcessInfo.processInfo.environment["REVIEW85_VOLUME"])
        let directory = URL(filePath: volume).appending(
            path: "r85-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { removeUnlocking(directory) }
        let fixture = try FilingFixture(directory)
        _ = try fixture.file()
        #expect(try Data(contentsOf: fixture.copy(1)) == (try encoded(draft(0))))
        #expect(throws: FileSystemError.self) { try LocalFileSystem().remove(fixture.copy(1)) }
    }
}
