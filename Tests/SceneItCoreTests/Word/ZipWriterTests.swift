import Foundation
import Testing

@testable import SceneItCore

/// The zip the .docx is written as, read back by macOS's own `unzip` and `zipinfo`, never by code
/// of ours.
struct ZipWriterTests {
    static let entries: [ZipWriter.Entry] = [
        .init(name: "[Content_Types].xml", bytes: Data("<Types/>".utf8)),
        .init(name: "word/document.xml", bytes: Data(String(repeating: "<w:p>text</w:p>", count: 200).utf8)),
        .init(name: "docProps/app.xml", bytes: Data([0, 1, 2, 255])),
        .init(name: "empty.xml", bytes: Data()),
    ]

    @Test func macOSUnzipFindsEveryEntryIntactInOrder() throws {
        let zip = try ZipWriter.archive(Self.entries)
        #expect(try Unzip.test(zip), "every entry's checksum matches")
        #expect(try Unzip.names(zip) == Self.entries.map(\.name))
        for entry in Self.entries {
            #expect(try Unzip.part(entry.name, of: zip) == entry.bytes)
        }
    }

    @Test func theSameFilesMakeTheSameBytes() throws {
        #expect(try ZipWriter.archive(Self.entries) == ZipWriter.archive(Self.entries))
    }

    @Test func moreEntriesThanAZipHoldsAreRefused() {
        let entries = Array(repeating: ZipWriter.Entry(name: "a", bytes: Data()), count: Int(UInt16.max) + 1)
        #expect(throws: ZipFailure.tooLarge) { try ZipWriter.archive(entries) }
    }

    @Test func theChecksumIsCRC32() {
        #expect(ZipWriter.checksum(Data("123456789".utf8)) == 0xCBF4_3926, "the standard check value")
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

    /// `zip` in a file of its own, removed when `body` returns; `body` gets its path.
    private static func withFile<T>(_ zip: Data, _ body: (String) throws -> T) throws -> T {
        let file = FileManager.default.temporaryDirectory.appending(
            path: "SceneItZip-\(UUID().uuidString).zip")
        try zip.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try body(file.path(percentEncoded: false))
    }
}
