import Foundation
import Testing

@testable import SceneItCore

/// The zip the .docx is read from and written back to: what it writes, macOS's own `unzip` reads
/// and finds intact, and what's damaged is refused.
struct ZipArchiveTests {
    static let archive = ZipArchive([
        .init(name: "[Content_Types].xml", bytes: Data("<Types/>".utf8)),
        .init(name: "word/document.xml", bytes: Data(String(repeating: "<w:p>text</w:p>", count: 200).utf8)),
        .init(name: "docProps/app.xml", bytes: Data([0, 1, 2, 255])),
    ])

    @Test func whatIsWrittenReadsBackTheSame() throws {
        let data = try Self.archive.data()
        #expect(try ZipArchive(reading: data) == Self.archive)
        #expect(try Self.archive.data() == data, "the same files always make the same bytes")
    }

    @Test func macOSUnzipFindsEveryEntryIntact() throws {
        let zip = try Self.archive.data()
        #expect(try Unzip.test(zip), "every entry's checksum matches")
        #expect(try Unzip.names(zip) == Self.archive.entries.map(\.name))
        for entry in Self.archive.entries {
            #expect(try Unzip.part(entry.name, of: zip) == entry.bytes)
        }
    }

    @Test func settingAPartReplacesItInPlaceOrAddsItAtTheEnd() {
        var archive = Self.archive
        archive["word/document.xml"] = Data("new".utf8)
        archive["word/styles.xml"] = Data("styles".utf8)
        #expect(
            archive.entries.map(\.name) == [
                "[Content_Types].xml", "word/document.xml", "docProps/app.xml", "word/styles.xml",
            ])
        #expect(archive["word/document.xml"] == Data("new".utf8))
        archive["docProps/app.xml"] = nil
        #expect(archive["docProps/app.xml"] == nil && archive.entries.count == 3)
    }

    @Test func aTruncatedArchiveIsRefused() throws {
        let data = try Self.archive.data()
        #expect(throws: ZipFailure.malformed) { try ZipArchive(reading: data.prefix(data.count - 30)) }
        #expect(throws: ZipFailure.malformed) { try ZipArchive(reading: Data("not a zip".utf8)) }
    }

    @Test func aDamagedEntryIsRefused() throws {
        var data = try Self.archive.data()
        let text = Data("<Types/>".utf8)
        let deflated = try (text as NSData).compressed(using: .zlib) as Data
        let start = try #require(data.firstRange(of: deflated), "precondition: the first entry's bytes")
        data[start.lowerBound] ^= 0xFF
        #expect(throws: ZipFailure.malformed) { try ZipArchive(reading: data) }
    }

    @Test func aStoredEntryIsRead() throws {
        try withTemporaryDirectory { folder in
            let file = folder.appending(path: "plain.xml")
            try Data("<stored/>".utf8).write(to: file)
            let zip = folder.appending(path: "stored.zip")
            try Unzip.run(
                "/usr/bin/zip",
                ["-0", "-j", "-q", zip.path(percentEncoded: false), file.path(percentEncoded: false)])
            let archive = try ZipArchive(reading: Data(contentsOf: zip))
            #expect(archive.entries == [.init(name: "plain.xml", bytes: Data("<stored/>".utf8))])
        }
    }
}

/// macOS's own `unzip`, to check our archives with a reader that isn't ours.
enum Unzip {
    static func part(_ name: String, of zip: Data) throws -> Data {
        // unzip reads a name as a pattern, where `[` opens a set of characters.
        let pattern = name.replacingOccurrences(of: "[", with: "[[]")
        return try withFile(zip) { try run("/usr/bin/unzip", ["-p", $0, pattern]) }
    }

    /// `unzip -t`: whether every entry decompresses and matches its checksum.
    static func test(_ zip: Data) throws -> Bool {
        try withFile(zip) { (try? run("/usr/bin/unzip", ["-tq", $0])) != nil }
    }

    /// The entries' names, in the archive's order.
    static func names(_ zip: Data) throws -> [String] {
        let listing = try withFile(zip) { try run("/usr/bin/zipinfo", ["-1", $0]) }
        return String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// `zip` in a file of its own, removed when `body` returns; `body` gets its path.
    private static func withFile<T>(_ zip: Data, _ body: (String) throws -> T) throws -> T {
        let file = FileManager.default.temporaryDirectory.appending(
            path: "SceneItZip-\(UUID().uuidString).zip")
        try zip.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try body(file.path(percentEncoded: false))
    }

    /// The tool's output; throws if it fails.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failed(status: process.terminationStatus) }
        return data
    }

    struct Failed: Error {
        let status: Int32
    }
}
