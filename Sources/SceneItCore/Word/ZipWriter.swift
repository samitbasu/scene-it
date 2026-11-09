import Foundation
import zlib

/// Writes a zip archive of named files, enough for a .docx, which is a zip of XML parts (Office
/// Open XML). Entries are stored, not compressed: a scene's document is a few kilobytes, the
/// format allows it, and stored entries leave no compressor to fail or to differ between macOS
/// versions. The checksum is the system zlib's. Every entry is dated 1 January 1980, so the same
/// files always make the same bytes.
enum ZipWriter {
    struct Entry: Equatable {
        let name: String
        let bytes: Data
    }

    static func archive(_ entries: [Entry]) throws(ZipFailure) -> Data {
        var archive = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            guard let size = UInt32(exactly: entry.bytes.count), let nameLength = UInt16(exactly: name.count),
                let offset = UInt32(exactly: archive.count)
            else { throw .tooLarge }
            var shared = ByteWriter()
            shared.uint16(version)  // needed to extract
            shared.uint16(utf8Names)
            shared.uint16(0)  // method: stored
            shared.uint16(0)  // time: midnight
            shared.uint16(firstDOSDate)
            shared.uint32(checksum(entry.bytes))
            shared.uint32(size)  // compressed
            shared.uint32(size)
            shared.uint16(nameLength)
            shared.uint16(0)  // extra field length

            var local = ByteWriter()
            local.uint32(Signature.localHeader)
            archive += local.bytes + shared.bytes + name + entry.bytes

            var central = ByteWriter()
            central.uint32(Signature.centralHeader)
            central.uint16(version)  // made by
            central.append(shared.bytes)
            central.uint16(0)  // comment length
            central.uint16(0)  // disk
            central.uint16(0)  // internal attributes
            central.uint32(0)  // external attributes
            central.uint32(offset)
            directory += central.bytes + name
        }
        guard let count = UInt16(exactly: entries.count),
            let directorySize = UInt32(exactly: directory.count),
            let directoryOffset = UInt32(exactly: archive.count)
        else { throw .tooLarge }
        var end = ByteWriter()
        end.uint32(Signature.endOfCentralDirectory)
        end.uint16(0)  // this disk
        end.uint16(0)  // the directory's disk
        end.uint16(count)  // on this disk
        end.uint16(count)
        end.uint32(directorySize)
        end.uint32(directoryOffset)
        end.uint16(0)  // comment length
        return archive + directory + end.bytes
    }

    private enum Signature {
        static let localHeader: UInt32 = 0x0403_4B50
        static let centralHeader: UInt32 = 0x0201_4B50
        static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    }

    /// 2.0, what a reader needs for these entries.
    private static let version: UInt16 = 20
    private static let utf8Names: UInt16 = 1 << 11
    /// 1980-01-01 in MS-DOS's format: (year − 1980) << 9 | month << 5 | day.
    private static let firstDOSDate: UInt16 = 1 << 5 | 1

    static func checksum(_ bytes: Data) -> UInt32 {
        bytes.withUnsafeBytes { buffer in
            UInt32(crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
    }
}

/// Why an archive couldn't be written.
enum ZipFailure: Error, Hashable, Sendable {
    /// More than a zip without zip64 can hold: 65,535 entries, or 4 GiB.
    case tooLarge
}

/// Little-endian integers, as zip writes them.
private struct ByteWriter {
    private(set) var bytes = Data()

    mutating func uint16(_ value: UInt16) {
        bytes += [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    mutating func uint32(_ value: UInt32) {
        uint16(UInt16(value & 0xFFFF))
        uint16(UInt16(value >> 16))
    }

    mutating func append(_ data: Data) {
        bytes += data
    }
}
