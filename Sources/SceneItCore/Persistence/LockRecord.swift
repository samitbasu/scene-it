import Foundation
import SystemConfiguration

/// Which Mac, user and process hold a book whose `flock` can't be trusted, written into its
/// `.lock` while they have it open (ADR 0020). On a network volume a `flock` only keeps out
/// processes on the same Mac; on a volume without `flock` it keeps out nobody. This record
/// is how others find out. It's advisory: nothing enforces it, and
/// `LockRecordPolicy.openAnyway` overrides it.
public struct LockRecord: Hashable, Sendable, Codable {
    /// The Mac's name from Sharing settings, for messages.
    public let host: String
    /// Tells apart two Macs with the same name.
    public let hostID: String
    public let userID: UInt32
    public let processID: Int32
    /// Whole seconds, as the record stores it, so a record equals itself read back.
    public let since: Date

    public init(host: String, hostID: String, userID: UInt32, processID: Int32, since: Date) {
        self.host = host
        self.hostID = hostID
        self.userID = userID
        self.processID = processID
        self.since = Date(timeIntervalSince1970: since.timeIntervalSince1970.rounded(.down))
    }

    init(_ opener: Opener, since: Date) {
        self.init(
            host: opener.mac.name, hostID: opener.mac.id, userID: opener.userID, processID: opener.processID,
            since: since)
    }

    /// The record that keeps `opener` from editing, if any.
    ///
    /// A record never expires on its own: a writer can leave a book open for days, and a
    /// crashed Mac's leftover costs one "Open Anyway". On this Mac, where the process can be
    /// checked, a record whose process has died is a leftover and is ignored, and so is one
    /// naming the opener's own process.
    static func blocking(_ record: LockRecord?, opener: Opener, policy: LockRecordPolicy) -> LockRecord? {
        guard let record, policy != .openAnyway(record) else { return nil }
        if record.hostID == opener.mac.id
            && (record.processID == opener.processID || !opener.isAlive(record.processID))
        {
            return nil
        }
        return record
    }

    /// `nil` for an empty `.lock` or anything that isn't a record: it's never treated as book data.
    static func decode(_ data: Data) -> LockRecord? {
        try? decoder.decode(LockRecord.self, from: data)
    }

    func encoded() throws(EncodingError) -> Data {
        do {
            return try Self.encoder.encode(self)
        } catch let error as EncodingError {
            throw error
        } catch {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "\(error)"))
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// What to do about another holder's `LockRecord`.
public enum LockRecordPolicy: Hashable, Sendable {
    /// Open read-only.
    case respect
    /// "Open Anyway": edit despite exactly this record. A different record, such as one
    /// written after the writer saw this one, is respected again.
    case openAnyway(LockRecord)
}

/// The process opening a book, as `LockRecord`s describe it.
struct Opener: Sendable {
    let mac: ThisMac
    let userID: UInt32
    let processID: Int32
    let isAlive: @Sendable (Int32) -> Bool

    static let current = Opener(
        mac: .current, userID: getuid(), processID: getpid(), isAlive: Opener.processIsAlive)

    /// `EPERM` means the process exists but belongs to another user.
    static func processIsAlive(_ processID: Int32) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }
}

/// This Mac, as a `LockRecord` names it.
public struct ThisMac: Hashable, Sendable {
    public let name: String
    public let id: String

    public init(name: String, id: String) {
        self.name = name
        self.id = id
    }

    /// The computer name from Sharing settings (not the network host name, which changes with
    /// the network), and the hardware UUID. If the UUID can't be read, the name stands in.
    public static let current: ThisMac = {
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        let status = withUnsafeMutableBytes(of: &uuid) { bytes in
            gethostuuid(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), &wait)
        }
        return ThisMac(name: name, id: status == 0 ? UUID(uuid: uuid).uuidString : name)
    }()
}
