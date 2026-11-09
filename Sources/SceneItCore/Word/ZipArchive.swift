import Foundation
import zlib

/// A zip archive's files, read and written whole: enough for a .docx, which is a zip of XML parts
/// (Office Open XML). Entries are stored or deflated; zip64, encryption and archives split across
/// files are refused. Deflate is Foundation's (`NSData`'s `.zlib`, raw DEFLATE) and the checksum
/// zlib's, both part of macOS.
struct ZipArchive: Equatable {
    struct Entry: Equatable {
        var name: String
        var bytes: Data
    }

    /// In the archive's order.
    private(set) var entries: [Entry]

    init(_ entries: [Entry]) {
        self.entries = entries
    }

    /// The file named `name`. Setting a name the archive doesn't have adds it at the end.
    subscript(name: String) -> Data? {
        get { entries.first { $0.name == name }?.bytes }
        set {
            let index = entries.firstIndex { $0.name == name }
            switch (index, newValue) {
            case (let index?, let bytes?): entries[index].bytes = bytes
            case (let index?, nil): entries.remove(at: index)
            case (nil, let bytes?): entries.append(Entry(name: name, bytes: bytes))
            case (nil, nil): break
            }
        }
    }

    /// Reads every entry through the central directory, checking each one's size and checksum.
    init(reading data: Data) throws(ZipFailure) {
        let bytes = ByteReader(data)
        let end = try Self.endOfCentralDirectory(in: bytes)
        let count = Int(try bytes.uint16(at: end + 10))
        var cursor = Int(try bytes.uint32(at: end + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard try bytes.uint32(at: cursor) == Signature.centralHeader else { throw .malformed }
            let flags = try bytes.uint16(at: cursor + 8)
            let method = try bytes.uint16(at: cursor + 10)
            let checksum = try bytes.uint32(at: cursor + 16)
            let compressedSize = try bytes.uint32(at: cursor + 20)
            let size = try bytes.uint32(at: cursor + 24)
            let nameLength = Int(try bytes.uint16(at: cursor + 28))
            let extraLength = Int(try bytes.uint16(at: cursor + 30))
            let commentLength = Int(try bytes.uint16(at: cursor + 32))
            let local = Int(try bytes.uint32(at: cursor + 42))
            let name = String(decoding: try bytes.slice(cursor + 46, nameLength), as: UTF8.self)
            guard flags & Flag.encrypted == 0, compressedSize != UInt32.max, size != UInt32.max else {
                throw .unsupported
            }
            guard try bytes.uint32(at: local) == Signature.localHeader else { throw .malformed }
            let start =
                local + 30 + Int(try bytes.uint16(at: local + 26)) + Int(try bytes.uint16(at: local + 28))
            let stored = try bytes.slice(start, Int(compressedSize))
            let contents = try Self.expand(stored, method: method)
            guard contents.count == Int(size), Self.checksum(contents) == checksum else { throw .malformed }
            entries.append(Entry(name: name, bytes: contents))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// The archive, every entry deflated, dated 1 January 1980 so the same files always make the
    /// same bytes.
    func data() throws(ZipFailure) -> Data {
        var archive = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let packed = try Self.deflate(entry.bytes)
            let offset = archive.count
            guard
                let size = UInt32(exactly: entry.bytes.count), let packedSize = UInt32(exactly: packed.count),
                let nameLength = UInt16(exactly: name.count), let localOffset = UInt32(exactly: offset)
            else { throw .tooLarge }
            var shared = ByteWriter()
            shared.uint16(Flag.utf8Name)
            shared.uint16(Method.deflated)
            shared.uint16(0)  // time: midnight
            shared.uint16(Self.firstDOSDate)
            shared.uint32(Self.checksum(entry.bytes))
            shared.uint32(packedSize)
            shared.uint32(size)
            shared.uint16(nameLength)
            shared.uint16(0)  // extra field length

            var local = ByteWriter()
            local.uint32(Signature.localHeader)
            local.uint16(Self.version)
            archive += local.bytes + shared.bytes + name + packed

            var central = ByteWriter()
            central.uint32(Signature.centralHeader)
            central.uint16(Self.version)  // made by
            central.uint16(Self.version)  // needed
            central.append(shared.bytes)
            central.uint16(0)  // comment length
            central.uint16(0)  // disk
            central.uint16(0)  // internal attributes
            central.uint32(0)  // external attributes
            central.uint32(localOffset)
            directory += central.bytes + name
        }
        guard
            let count = UInt16(exactly: entries.count), let directorySize = UInt32(exactly: directory.count),
            let directoryOffset = UInt32(exactly: archive.count)
        else { throw .tooLarge }
        var end = ByteWriter()
        end.uint32(Signature.endOfCentralDirectory)
        end.uint16(0)  // this disk
        end.uint16(0)  // the directory's disk
        end.uint16(count)
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

    private enum Flag {
        static let encrypted: UInt16 = 1
        static let utf8Name: UInt16 = 1 << 11
    }

    private enum Method {
        static let stored: UInt16 = 0
        static let deflated: UInt16 = 8
    }

    /// 2.0, the version that introduced deflate.
    private static let version: UInt16 = 20
    /// 1980-01-01 in MS-DOS's format: (year − 1980) << 9 | month << 5 | day.
    private static let firstDOSDate: UInt16 = 1 << 5 | 1

    /// Where the end-of-central-directory record starts: it's last, after at most a 64 KiB comment.
    private static func endOfCentralDirectory(in bytes: ByteReader) throws(ZipFailure) -> Int {
        let fixedLength = 22
        let lowest = max(0, bytes.count - fixedLength - Int(UInt16.max))
        var start = bytes.count - fixedLength
        while start >= lowest {
            if try bytes.uint32(at: start) == Signature.endOfCentralDirectory {
                guard try bytes.uint16(at: start + 4) == 0, try bytes.uint16(at: start + 6) == 0 else {
                    throw .unsupported
                }
                return start
            }
            start -= 1
        }
        throw .malformed
    }

    private static func expand(_ stored: Data, method: UInt16) throws(ZipFailure) -> Data {
        switch method {
        case Method.stored: return stored
        case Method.deflated:
            guard !stored.isEmpty else { return Data() }
            guard let expanded = try? (stored as NSData).decompressed(using: .zlib) else { throw .malformed }
            return expanded as Data
        default: throw .unsupported
        }
    }

    private static func deflate(_ bytes: Data) throws(ZipFailure) -> Data {
        guard let packed = try? (bytes as NSData).compressed(using: .zlib) else { throw .tooLarge }
        return packed as Data
    }

    static func checksum(_ bytes: Data) -> UInt32 {
        bytes.withUnsafeBytes { buffer in
            UInt32(crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
    }
}

/// Why an archive couldn't be read or written.
enum ZipFailure: Error, Hashable, Sendable {
    /// Not a zip, or a damaged one.
    case malformed
    /// A zip using something a .docx doesn't need: zip64, encryption, several disks, another method.
    case unsupported
    /// Too big for a zip without zip64.
    case tooLarge
}

/// Little-endian reads that refuse to run off the end.
private struct ByteReader {
    private let bytes: [UInt8]

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var count: Int { bytes.count }

    func slice(_ start: Int, _ length: Int) throws(ZipFailure) -> Data {
        guard start >= 0, length >= 0, start <= bytes.count - length else { throw .malformed }
        return Data(bytes[start..<start + length])
    }

    func uint16(at offset: Int) throws(ZipFailure) -> UInt16 {
        UInt16(try integer(at: offset, length: 2))
    }

    func uint32(at offset: Int) throws(ZipFailure) -> UInt32 {
        try integer(at: offset, length: 4)
    }

    private func integer(at offset: Int, length: Int) throws(ZipFailure) -> UInt32 {
        guard offset >= 0, offset <= bytes.count - length else { throw .malformed }
        return (0..<length).reduce(0) { value, index in value | UInt32(bytes[offset + index]) << (8 * index) }
    }
}

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
