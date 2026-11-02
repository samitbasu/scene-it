import Foundation
import Testing

@testable import SceneItCore

@Suite struct LoadTests {
    enum Damage: CaseIterable, CustomTestStringConvertible {
        case truncated, empty, garbage, invalidBook, unsupportedFormat
        case bookMissing, bookIsADirectory, packageIsAFile, packageMissing, missingExtension

        /// Damages a full package at `url`; returns the URL to open.
        func apply(to url: URL) throws -> URL {
            let book = url.layout.book
            let bytes = try Data(contentsOf: book)
            switch self {
            case .truncated:
                try bytes.prefix(bytes.count / 2).write(to: book)
            case .empty:
                try Data().write(to: book)
            case .garbage:
                try Data((0..<256).map { UInt8(truncatingIfNeeded: $0 &* 37) }).write(to: book)
            case .invalidBook:
                let text = String(decoding: bytes, as: UTF8.self)
                try Data(text.replacingFirst(#""text" : "letter""#, with: #""text" : """#).utf8).write(
                    to: book)
            case .unsupportedFormat:
                let text = String(decoding: bytes, as: UTF8.self)
                try Data(text.replacingFirst(#""format" : 1"#, with: #""format" : 2"#).utf8).write(to: book)
            case .bookMissing:
                try FileManager.default.removeItem(at: book)
            case .bookIsADirectory:
                try FileManager.default.removeItem(at: book)
                try FileManager.default.createDirectory(at: book, withIntermediateDirectories: false)
            case .packageIsAFile:
                try FileManager.default.removeItem(at: url)
                try bytes.write(to: url)
            case .packageMissing:
                try FileManager.default.removeItem(at: url)
            case .missingExtension:
                let renamed = url.deletingPathExtension()
                try FileManager.default.moveItem(at: url, to: renamed)
                return renamed
            }
            return url
        }

        func matches(_ problem: LoadProblem) -> Bool {
            switch (self, problem) {
            case (.truncated, .undecodable), (.empty, .undecodable), (.garbage, .undecodable),
                (.unsupportedFormat, .undecodable), (.invalidBook, .invalid), (.bookMissing, .bookMissing),
                (.bookIsADirectory, .bookNotAFile), (.packageIsAFile, .notADirectory),
                (.packageMissing, .notFound), (.missingExtension, .missingPackageExtension):
                true
            default: false
            }
        }

        /// Whether the package's backups are still where the loader looks for them.
        var backupsReachable: Bool {
            switch self {
            case .packageIsAFile, .packageMissing: false
            default: true
            }
        }

        var testDescription: String { "\(self)" }
    }

    @Test(arguments: Damage.allCases)
    func aDamagedPackageFailsWithATypedErrorAndNoWrites(_ damage: Damage) throws {
        try withTemporaryDirectory { directory in
            let url = try damage.apply(
                to: makeFullPackage(
                    at: directory.appending(path: "Novel.sceneit"), fileSystem: LocalFileSystem()
                )
                .layout.root)
            let before = try DirectorySnapshot(directory)
            let fileSystem = FaultInjectingFileSystem(root: url)

            let error = try #require(throws: LoadError.self) {
                try BookPackage.open(at: url, fileSystem: fileSystem)
            }
            #expect(damage.matches(error.problem), "\(error.problem)")
            #expect(error.backups.map(\.slot) == (damage.backupsReachable ? BackupSlot.allCases : []))
            #expect(fileSystem.calls.allSatisfy { !$0.isMutation })
            #expect(try DirectorySnapshot(directory) == before)
        }
    }

    @Test func theErrorNamesTheProblemAndListsTheBackups() throws {
        try withTemporaryDirectory { directory in
            let url = try LoadTests.Damage.invalidBook.apply(
                to: makeFullPackage(
                    at: directory.appending(path: "Novel.sceneit"), fileSystem: LocalFileSystem()
                )
                .layout.root)
            let error = try #require(throws: LoadError.self) { try BookPackage.open(at: url) }
            let description = error.description
            #expect(description.hasPrefix("Couldn't open Novel.sceneit: book.json isn't a valid book:"))
            #expect(description.contains("a run's text is empty"))
            for slot in BackupSlot.allCases {
                #expect(description.contains("- \(slot.fileName) (last modified "))
            }
        }
    }

    /// Random single-byte edits, deletions, insertions and truncations of a valid file:
    /// each either loads a valid book or fails with a `LoadError`, and nothing is written.
    @Test func mutatedFilesNeverHalfLoad() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "Novel.sceneit")
            _ = try BookPackage.create(at: url, title: "Novel")
            let original = try encoded(RichBook.make())
            var random = SplitMix64(seed: 0x5CE7E_17)
            var outcomes = (loaded: 0, refused: 0)
            for _ in 0..<400 {
                var bytes = [UInt8](original)
                for _ in 0..<Int.random(in: 1...3, using: &random) {
                    let index = Int.random(in: 0..<bytes.count, using: &random)
                    switch Int.random(in: 0..<4, using: &random) {
                    case 0: bytes[index] = UInt8.random(in: .min ... .max, using: &random)
                    case 1: bytes.remove(at: index)
                    case 2: bytes.insert(UInt8.random(in: .min ... .max, using: &random), at: index)
                    default: bytes.removeLast(Int.random(in: 1...(bytes.count - index), using: &random))
                    }
                    if bytes.isEmpty { bytes = [UInt8(ascii: "{")] }
                }
                try Data(bytes).write(to: url.layout.book)
                let fileSystem = FaultInjectingFileSystem(root: url)
                do {
                    let book = try BookPackage.open(at: url, fileSystem: fileSystem).book
                    #expect(BookValidator.problems(in: book).isEmpty)
                    outcomes.loaded += 1
                } catch {
                    outcomes.refused += 1
                }
                #expect(fileSystem.calls.allSatisfy { !$0.isMutation })
            }
            #expect(
                outcomes.refused > 0 && outcomes.loaded > 0, "precondition: the fuzz exercised both outcomes")
        }
    }
}
