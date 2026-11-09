import Foundation
import Testing

@testable import SceneItCore

/// ADR 0024 under attack: faults at every step, occupied names, the lock held, mismatched
/// packages, odd `format:` spellings and damaged files of every kind. From the review of #66.
@Suite struct MakeEditableAdversarialTests {
    private static let keptAt = Date(timeIntervalSince1970: 1_793_620_800)

    private static func originals(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
            .filter { $0.hasPrefix("book.md.original-") }.sorted().map { url.appending(path: $0) }
    }

    /// The invariant: whenever `book.md` doesn't hold the damaged original, a regular file
    /// `book.md.original-*.md` in the package does.
    private static func originalIsSafe(_ url: URL, _ bytes: Data) throws -> Bool {
        if (try? Data(contentsOf: url.layout.book)) == bytes { return true }
        return try originals(url).contains { candidate in
            let path = candidate.path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil
            else { return false }
            return (try? Data(contentsOf: candidate)) == bytes
        }
    }

    private func repaired(_ url: URL, _ fileSystem: any FileSystem = LocalFileSystem()) throws -> Repair {
        let opened = try BookPackage.open(at: url, defaults: fixedDefaults, fileSystem: fileSystem)
        guard case .readOnly(_, .repairedOnOpen(let repair)) = opened else {
            Issue.record("expected repairedOnOpen, got \(String(describing: opened.readOnlyReason))")
            throw CancellationError()
        }
        return repair
    }

    /// keepOriginal → edit → save, driven to completion while ignoring every error.
    private func makeEditableAndSave(_ url: URL, _ fileSystem: any FileSystem) {
        guard
            case .readOnly(_, .repairedOnOpen(let repair))? = try? BookPackage.open(
                at: url, defaults: fixedDefaults, fileSystem: fileSystem),
            let kept = try? BookPackage.keepOriginal(of: repair, now: Self.keptAt, fileSystem: fileSystem),
            let editable = BookPackage.edit(kept, fileSystem: fileSystem).editable()
        else { return }
        _ = try? editable.package.save(editable.book)
    }

    private func recordedCalls(_ bytes: Data) throws -> [FaultInjectingFileSystem.Call] {
        try withTemporaryDirectory { directory in
            let url = try package(holding: bytes, in: directory)
            let fileSystem = FaultInjectingFileSystem(root: url)
            makeEditableAndSave(url, fileSystem)
            try #require(
                try Data(contentsOf: url.layout.book) != bytes, "precondition: the save replaced book.md")
            return fileSystem.calls
        }
    }

    /// A crash, and separately a failure, at every call of Make Editable and the first save;
    /// then a "restart" that tries again. The original is never lost.
    @Test func aCrashOrFailureAtAnyStepNeverLosesTheOriginal() throws {
        let bytes = damaged(try draft(1))
        let calls = try recordedCalls(bytes)
        try #require(calls.count > 10)
        var faults: [FaultInjectingFileSystem.Fault] = []
        var seen: [FaultInjectingFileSystem.Call: Int] = [:]
        for call in calls {
            let n = seen[call, default: 0]
            seen[call] = n + 1
            faults.append(.fail(call, cause: .io, skipping: n))
            if n == 0 { faults.append(.crash(call)) }
        }
        for cause in [FileSystemError.Cause.io, .alreadyExists, .notFound] {
            for call in Set(calls) { faults.append(.fail(call, cause: cause)) }
        }
        #expect(faults.count > 50, "precondition: many faults")
        for fault in faults {
            try withTemporaryDirectory { directory in
                let url = try package(holding: bytes, in: directory)
                let fileSystem = FaultInjectingFileSystem(root: url)
                fileSystem.inject(fault)
                makeEditableAndSave(url, fileSystem)
                #expect(try Self.originalIsSafe(url, bytes), "\(fault)")
                makeEditableAndSave(url, LocalFileSystem())
                #expect(try Self.originalIsSafe(url, bytes), "after restart: \(fault)")
            }
        }
    }

    @Test func occupiedOriginalNamesAreSkippedAndLeftAlone() throws {
        try withTemporaryDirectory { directory in
            let bytes = damaged(try draft(1))
            let url = try package(holding: bytes, in: directory)
            let manager = FileManager.default
            let first = url.layout.original(at: Self.keptAt, attempt: 1)
            let second = url.layout.original(at: Self.keptAt, attempt: 2)
            let third = url.layout.original(at: Self.keptAt, attempt: 3)
            try manager.createDirectory(at: first, withIntermediateDirectories: false)
            try manager.createSymbolicLink(at: second, withDestinationURL: url.layout.book)
            try manager.createSymbolicLink(
                at: third, withDestinationURL: directory.appending(path: "nowhere"))
            let kept = try BookPackage.keepOriginal(of: try repaired(url), now: Self.keptAt)
            #expect(kept.url == url.layout.original(at: Self.keptAt, attempt: 4))
            #expect(try Data(contentsOf: kept.url) == bytes)
            #expect(
                try manager.destinationOfSymbolicLink(atPath: second.path(percentEncoded: false)).hasSuffix(
                    "book.md"))
            #expect(
                try Data(contentsOf: url.layout.book) == bytes, "the link's target wasn't written through")
            #expect(
                !manager.fileExists(atPath: directory.appending(path: "nowhere").path(percentEncoded: false)))
        }
    }

    /// `KeptOriginal` can't be copied, so it can't make two packages: `edit` consumes it (a
    /// second `edit(kept)` doesn't compile). While the lock is held elsewhere it comes back,
    /// and the retry makes the one package.
    @Test func aKeptOriginalComesBackWhileTheLockIsHeldAndThenMakesOnePackage() throws {
        try withTemporaryDirectory { directory in
            let bytes = damaged(try draft(1))
            let url = try package(holding: bytes, in: directory)
            let kept = try BookPackage.keepOriginal(of: try repaired(url), now: Self.keptAt)
            let held = open(url.layout.lock.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            try #require(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0, "precondition: the lock was free")
            let refused = BookPackage.edit(kept)
            #expect(refused.readOnlyReason == .openElsewhere)
            close(held)
            guard let returned = refused.keptOriginal() else {
                Issue.record("the kept original comes back with the refusal")
                return
            }
            let made = BookPackage.edit(returned).editable()
            let editable = try #require(made)
            #expect(try editable.package.save(editable.book).backupStatus == .intact)
            #expect(try Self.originals(url).count == 1)
            #expect(try Data(contentsOf: Self.originals(url)[0]) == bytes)
        }
    }

    /// `Repair` carries its package, so a book's original can only be kept in its own package.
    @Test func theOriginalGoesIntoThePackageItWasReadFrom() throws {
        try withTemporaryDirectory { directory in
            let folders = ["A", "B"].map { directory.appending(path: $0) }
            for folder in folders {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            let bytes = [damaged(try draft(1)), damaged(try draft(2))]
            let urls = try zip(bytes, folders).map { try package(holding: $0, in: $1) }
            let repairA = try repaired(urls[0])
            #expect(repairA.file == .book(urls[0].layout))
            let kept = try BookPackage.keepOriginal(of: repairA, now: Self.keptAt)
            #expect(kept.url.deletingLastPathComponent().standardizedFileURL == urls[0].standardizedFileURL)
            #expect(try Data(contentsOf: kept.url) == bytes[0])
            #expect(try Self.originals(urls[1]).isEmpty)
            #expect(try Data(contentsOf: urls[1].layout.book) == bytes[1])
        }
    }

    /// Book format §1.5: anything spelled as a number larger than 2 is newer, never damaged.
    @Test(arguments: [
        ("format: 3", "newer"), ("format: 03", "newer"), ("FORMAT: 3", "newer"), ("format: 99999", "newer"),
        ("format: 99999999999999999999999", "newer"), ("format: +3", "newer"), ("format: 3.0", "repaired"),
        ("format: 1", "repaired"), ("format: 0", "repaired"), ("format: -3", "repaired"),
        ("format: +", "repaired"),
    ])
    func formatSpellings(line: String, expected: String) throws {
        try withTemporaryDirectory { directory in
            let url = try package(holding: Data("---\ntitle: T\n\(line)\n---\n".utf8), in: directory)
            let reason = try BookPackage.open(at: url, defaults: fixedDefaults).readOnlyReason
            let got: String =
                switch reason {
                case .newerFormat?: "newer"
                case .repairedOnOpen?: "repaired"
                default: "\(String(describing: reason))"
                }
            #expect(got == expected, "\(line)")
            #expect(lockIsFree(url))
        }
    }

    @Test func plusTwoIsFormatTwoAndIsWrittenWithoutThePlus() {
        let parsed = parse("---\ntitle: T\nformat: +2\n---\n")
        #expect(parsed.newEntries.isEmpty)
        #expect(serialized(parsed.book) == "---\ntitle: T\nformat: 2\n---\n")
    }

    @Test func legacyOnlyPackageWritesNothing() throws {
        try withTemporaryDirectory { directory in
            let url = try package(holding: Data(), in: directory)
            try FileManager.default.removeItem(at: url.layout.book)
            try? FileManager.default.removeItem(at: url.layout.lock)
            try Data("{}".utf8).write(to: url.layout.legacyBook)
            let before = try FileManager.default.subpathsOfDirectory(atPath: url.path(percentEncoded: false))
                .sorted()
            let fileSystem = FaultInjectingFileSystem(root: url)
            do throws(LoadError) {
                _ = try BookPackage.open(at: url, fileSystem: fileSystem)
                Issue.record("a book.json alone doesn't open")
            } catch {
                #expect(error.problem == .legacyJSONBook)
            }
            #expect(fileSystem.calls.filter(\.isMutation).isEmpty)
            #expect(
                try FileManager.default.subpathsOfDirectory(atPath: url.path(percentEncoded: false)).sorted()
                    == before)
        }
    }

    /// An emptied `book.md` beside a legacy `book.json` is a damaged book.md: read-only, so
    /// nothing is saved before the writer has seen it.
    @Test func anEmptiedBookMdBesideABookJsonOpensRepaired() throws {
        try withTemporaryDirectory { directory in
            let url = try package(holding: Data(), in: directory)
            try Data(#"{"title":"Real","scenes":[]}"#.utf8).write(to: url.layout.legacyBook)
            guard
                case .repairedOnOpen? = try BookPackage.open(at: url, defaults: fixedDefaults).readOnlyReason
            else {
                Issue.record("expected repairedOnOpen")
                return
            }
        }
    }

    /// Any damaged file that opens repaired, once made editable and saved, reopens editable
    /// with the same book: no perpetual read-only, and one original.
    @Test func makeEditableThenSaveConverges() throws {
        var random = SplitMix64(seed: fuzzSalt ^ 0x66_66)
        var exercised = 0
        for round in 0..<60 {
            var generator = BookGenerator(seed: fuzzSalt ^ UInt64(round))
            var bytes = Array(BookFormat.serialize(generator.book()))
            for _ in 0..<Int.random(in: 1...6, using: &random) {
                switch Int.random(in: 0..<4, using: &random) {
                case 0 where !bytes.isEmpty:
                    bytes.insert(
                        UInt8.random(in: 0...255, using: &random),
                        at: Int.random(in: 0..<bytes.count, using: &random))
                case 1 where !bytes.isEmpty:
                    bytes.remove(at: Int.random(in: 0..<bytes.count, using: &random))
                case 2:
                    bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &random)))
                default:
                    bytes += Array("\n## \u{1F30A}\nstray: x\n- [bogus\n".utf8)
                }
            }
            let data = Data(bytes)
            try withTemporaryDirectory { directory in
                let url = try package(holding: data, in: directory)
                let opened = try BookPackage.open(at: url, defaults: fixedDefaults)
                guard case .readOnly(_, .repairedOnOpen(let repair)) = opened else { return }
                exercised += 1
                do {
                    let editable = try #require(
                        BookPackage.edit(try BookPackage.keepOriginal(of: repair)).editable())
                    _ = try editable.package.save(editable.book)
                }
                let reopened = try BookPackage.open(at: url, defaults: fixedDefaults)
                #expect(
                    reopened.editable != nil, "round \(round): \(String(describing: reopened.readOnlyReason))"
                )
                #expect(reopened.book == repair.book, "round \(round)")
                #expect(try Self.originals(url).count == 1)
                #expect(try Data(contentsOf: Self.originals(url)[0]) == data)
            }
        }
        #expect(exercised > 30)
    }

    // MARK: Archive index

    private static let day = CalendarDay(year: 2026, month: 3, day: 6)!

    @Test(arguments: [
        ["a, b"], ["a,b", "c"], ["\\"], ["a\\,b"], [" lead", "trail "], ["#hash"], ["x | y"], ["new\nline"],
        ["\\n"], ["-"], ["- [line] x"], ["## save0001.md"], ["tags: x"], [","], [" "], ["\u{1F30A}"],
    ])
    func tagsRoundTrip(tags: [String]) throws {
        let index = ArchiveIndex(copies: [FiledCopy(number: FiledCopyNumber(1)!, filed: Self.day, tags: tags)]
        )
        let bytes = try ArchiveIndexFormat.verifiedSerialization(of: index)
        let back = ArchiveIndexFormat.parse(bytes, filed: { _ in Self.day })
        #expect(back.index == index, "\(tags)")
        #expect(back.newEntries.isEmpty)
    }

    @Test(arguments: [
        "a | b", "line1\nline2", "\\n literal", " lead", "trail ", "\r\n", "\r", "- item", "## save0002.md",
        "### Unparsed", "---", "\\", "\n", "\n\n", "x\n## Heading\ny", "\t", "a\u{2028}b", "\u{FEFF}",
        "\u{0}",
    ])
    func notesRoundTrip(note: String) throws {
        let index = ArchiveIndex(copies: [FiledCopy(number: FiledCopyNumber(1)!, filed: Self.day, note: note)]
        )
        let bytes = try ArchiveIndexFormat.verifiedSerialization(of: index)
        let back = ArchiveIndexFormat.parse(bytes, filed: { _ in Self.day })
        #expect(back.index == index, "\(note.debugDescription)")
        #expect(back.newEntries.isEmpty)
    }

    @Test(arguments: [
        "---\nformat: 2\n---\n\n## save0001.md\nscenes: 99999999999999999999999\nwords: 1\ncomments: 1\n",
        "---\nformat: 2\n---\n\n## save0001.md\nfiled: 2026-02-30\n",
        "---\nformat: 3\n---\n\n## save0001.md\nfiled: 2026-02-03\n",
        "## save0001.md\nfiled: 2026-02-03\n",
        "---\nformat: 2\n---\n\n## save99999999999999999999999.md\nfiled: 2026-02-03\n",
        "---\nformat: 2\n---\n\n## SAVE0001.MD\nfiled: 2026-02-03\n",
        "---\nformat: 2\n---\n\n## save0001.md\nnote: a\nnote continues?\n",
    ])
    func indexEdgeCasesCanAlwaysBeSaved(_ text: String) {
        let parsed = ArchiveIndexFormat.parse(Data(text.utf8), filed: { _ in Self.day })
        #expect(throws: Never.self) { try ArchiveIndexFormat.verifiedSerialization(of: parsed.index) }
    }

    @Test(arguments: [
        ("---\nformat: 2\n---\n", false), ("---\nformat: 3\n---\n", true), ("---\nformat: +3\n---\n", true),
        ("---\nformat: 99999999999999999999999\n---\n", true), ("", false), ("---\nformat: x\n---\n", false),
    ])
    func aNewerIndexSaysSo(text: String, newer: Bool) {
        let parsed = ArchiveIndexFormat.parse(Data(text.utf8), filed: { _ in Self.day })
        #expect(parsed.isNewerThanSupported == newer, "\(text.debugDescription)")
    }
}
