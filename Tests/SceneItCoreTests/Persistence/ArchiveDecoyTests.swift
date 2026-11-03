import Foundation
import Testing

@testable import SceneItCore

/// Nothing that deletes or renames ever reaches `Archive/` (PLAN §5.5): not snapshot pruning,
/// not the stray-temporary-file sweeps, not removing an unfinished copy of a book. Each test
/// plants files there that look like what those clean up, makes the cleanup run for real, and
/// checks that `Archive/` is exactly as it was. `Archive/`'s own sweep touches only its own
/// temporary files.
@Suite struct ArchiveDecoyTests {
    static let longAgo = Date.now - .days(30)

    /// Names that the sweeps or pruning act on elsewhere, each in `Archive/`.
    static func decoyNames() throws -> [String] {
        [
            TemporaryFile.name(for: "save0002.MD", id: UUID()),
            TemporaryFile.name(for: "save2.md", id: UUID()),
            TemporaryFile.name(for: "index.md.original-20261101T143005Z.md", id: UUID()),
            "save0002.md.\(UUID().uuidString).tmp",
            TemporaryFile.name(for: "book.md", id: UUID()),
            TemporaryFile.name(for: "book.md.bak1", id: UUID()),
            TemporaryFile.name(for: try #require(SnapshotName(date: longAgo)).fileName, id: UUID()),
            try #require(SnapshotName(date: longAgo)).fileName,
            try #require(SnapshotName(date: longAgo - .days(3))).fileName,
            "book.md.bak1", "book-id",
        ]
    }

    private func plant(_ names: [String], in folder: URL, holding data: Data) throws {
        for name in names {
            let url = folder.appending(path: name)
            try data.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Self.longAgo], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    @Test func savesSnapshotsPruningAndSweepsLeaveTheArchiveAlone() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try fixture.file()
            let bait = try encoded(draft(0))
            let decoys = try Self.decoyNames()
            try plant(decoys, in: fixture.layout.archive, holding: bait)
            let control = TemporaryFile.name(for: "book.md", id: UUID())
            try plant([control], in: fixture.layout.root, holding: bait)
            let before = try DirectorySnapshot(fixture.layout.archive)
            #expect(before.entries.count == decoys.count + 2, "precondition: every decoy is planted")

            let keeper = BackupKeeper(
                package: fixture.package, mirror: BackupMirror(root: directory.appending(path: "Mirror")))
            let start = Date.now - .days(20)
            var written = 0
            for step in 1...40 {
                guard let published = try fixture.package.save(draft(step % 3 + 1)).published else {
                    continue
                }
                if keeper.keep(published, now: start + .hours(step * 12)).package == .written { written += 1 }
            }
            StrayTemporaryFiles(packageRoot: fixture.layout, fileSystem: LocalFileSystem()).sweep(now: .now)

            let root = try FileManager.default.contentsOfDirectory(
                atPath: fixture.layout.root.path(percentEncoded: false))
            #expect(!root.contains(control), "precondition: the sweep ran and cleared a real stray")
            let snapshots = try FileManager.default.contentsOfDirectory(
                atPath: fixture.layout.snapshots.path(percentEncoded: false)
            ).filter { SnapshotName(fileName: $0) != nil }
            #expect(snapshots.count < written, "precondition: pruning removed snapshots")
            #expect(try DirectorySnapshot(fixture.layout.archive) == before)
        }
    }

    @Test func theArchivesOwnStrayTemporaryFilesAreClearedAndFiledCopiesNeverTouched() throws {
        try withTemporaryDirectory { directory in
            let fixture = try FilingFixture(directory)
            try fixture.file()
            let filed = try FileFingerprint(fixture.copy(1))
            let archive = fixture.layout.archive
            let kept = TemporaryFile.name(for: "save0002.md", id: UUID())
            let unique = TemporaryFile.name(for: "save0003.md", id: UUID())
            let index = TemporaryFile.name(for: "index.md", id: UUID())
            try plant([kept], in: archive, holding: filed.contents)
            try plant([unique], in: archive, holding: Data("found nowhere else".utf8))
            try plant([index], in: archive, holding: Data("---\nformat: 2\n---\n".utf8))
            let young = TemporaryFile.name(for: "save0004.md", id: UUID())
            try Data("too young".utf8).write(to: archive.appending(path: young))

            #expect(try fixture.package.save(draft(3)).published != nil)

            let names = try fixture.archiveNames()
            #expect(!names.contains(kept), "a copy of a filed copy is removed")
            #expect(!names.contains(index), "an index write's leftover goes once index.md is valid")
            #expect(!names.contains(unique))
            let recovered = names.filter { $0.hasPrefix("book.md.recovered-") }
            #expect(recovered.count == 1, "a version kept nowhere else is renamed, never removed")
            #expect(
                try recovered.first.map { try Data(contentsOf: archive.appending(path: $0)) }
                    == Data("found nowhere else".utf8))
            #expect(names.contains(young), "a write that may be in progress is left alone")
            #expect(try FileFingerprint(fixture.copy(1)) == filed)
        }
    }

    @Test func removingAnUnfinishedCopyOfABookNeverRemovesAFiledCopy() async throws {
        try await withTemporaryFolder { folder in
            let original = folder.appending(path: "Novel.sceneit", directoryHint: .isDirectory)
            let copy = try await BookWriter.createCopy(
                titled: "Novel", nextTo: original, named: { "Novel (my edits \($0)).sceneit" },
                fileSystem: LocalFileSystem(), mirror: BackupMirror(root: folder.appending(path: "Mirror")))
            let filed = copy.layout.filedCopy(FiledCopyNumber.first)
            _ = try await copy.fileCopy(
                of: draft(0), as: FilingRecord(filed: FilingFixture.day), pending: [:])
            #expect(try isImmutable(filed), "precondition: a filed copy is in the package")
            let before = try DirectorySnapshot(copy.layout.archive)

            await copy.discardCopy()

            #expect(try DirectorySnapshot(copy.layout.archive) == before)
            #expect(try Data(contentsOf: filed) == (try encoded(draft(0))))
        }
    }
}
