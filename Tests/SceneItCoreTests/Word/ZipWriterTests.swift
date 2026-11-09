import Foundation
import SceneItTestSupport
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
