import Foundation
import SystemConfiguration

/// Which Mac and process hold a book on a network volume, written into its `.lock` while
/// they have it open (ADR 0020). A `flock` there only keeps out processes on the same Mac,
/// so this record is how another Mac finds out. It's advisory: nothing enforces it, and it
/// can be overridden with `OtherMacPolicy.openAnyway`.
public struct LockRecord: Hashable, Sendable, Codable {
    /// The Mac's name from Sharing settings, for messages.
    public let host: String
    /// Tells apart two Macs with the same name.
    public let hostID: String
    public let processID: Int32
    /// Whole seconds, as the record stores it, so a record equals itself read back.
    public let since: Date

    public init(host: String, hostID: String, processID: Int32, since: Date) {
        self.host = host
        self.hostID = hostID
        self.processID = processID
        self.since = Date(timeIntervalSince1970: since.timeIntervalSince1970.rounded(.down))
    }

    init(_ mac: ThisMac, processID: Int32, since: Date) {
        self.init(host: mac.name, hostID: mac.id, processID: processID, since: since)
    }

    /// A Mac that crashed, slept or lost the network with the book open leaves its record
    /// behind. After this long it's assumed gone; before then, "Open Anyway" is the way past it.
    public static let staleAfter = Interval.hours(12)

    /// The record that keeps this Mac from editing, if any.
    ///
    /// A record from this Mac never does: whoever wrote it no longer holds the `flock`, or
    /// this Mac's kernel wouldn't have granted it to us. So that's a leftover from a crash,
    /// and needs no process-liveness check.
    public static func blocking(
        _ record: LockRecord?, thisMac: ThisMac, now: Date, policy: OtherMacPolicy
    ) -> LockRecord? {
        guard let record, record.hostID != thisMac.id, record.since > now - staleAfter,
            policy != .openAnyway(record)
        else { return nil }
        return record
    }

    /// `nil` for an empty `.lock` or anything that isn't a record: it's never treated as book data.
    static func decode(_ data: Data) -> LockRecord? {
        try? decoder.decode(LockRecord.self, from: data)
    }

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
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

/// What to do about another Mac's `LockRecord`.
public enum OtherMacPolicy: Hashable, Sendable {
    /// Open read-only.
    case respect
    /// "Open Anyway": edit despite exactly this record. A different record, such as one
    /// written after the writer saw this one, is respected again.
    case openAnyway(LockRecord)
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
