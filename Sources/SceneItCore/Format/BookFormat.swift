import Foundation

/// The book file format, version 2: tolerant Markdown (ADR 0022). The grammar is
/// docs/format/book-format.md; this is its executable form.
///
/// `parse` never fails: anything it can't understand becomes an error entry in the book.
/// `serialize` is canonical: equal books give equal bytes.
public enum BookFormat {
    /// The title of a book whose file has none.
    public static let untitled = "Untitled"

    /// Reads any bytes as a book. Defaults the file leaves out come from `opened` (a missing
    /// `modified`) and `ids` (a missing or duplicate scene id); each default is recorded
    /// as a notice.
    public static func parse(
        _ bytes: Data, opened: Timestamp, ids: inout some SceneIDSource
    ) -> ParsedBook {
        BookParser.parse(bytes, opened: opened, ids: &ids)
    }

    public static func serialize(_ book: Book) -> Data {
        Data(BookSerializer.text(of: book).utf8)
    }

    /// The bytes to save for `book`, after checking that they read back as the same book
    /// (book format §7.2): serializing what they parse to gives the same bytes, and the
    /// parse found exactly the error entries `book` already had.
    public static func verifiedSerialization(of book: Book) throws(VerificationFailure) -> Data {
        let bytes = serialize(book)
        var ids = UnusedSceneIDs()
        let reread = parse(bytes, opened: verificationTime, ids: &ids).book
        guard reread.errorEntries == book.errorEntries else {
            throw .newEntries(newEntries(in: reread, comparedWith: book))
        }
        guard serialize(reread) == bytes else { throw .unstable }
        return bytes
    }

    private static let verificationTime = Timestamp(secondsSince1970: 0, offset: .zero)

    private static func newEntries(in reread: Book, comparedWith book: Book) -> [ErrorEntry] {
        let had = Set(book.errorEntries.joined())
        let found = reread.errorEntries.joined().filter { !had.contains($0) }
        return found.isEmpty ? Array(reread.errorEntries.joined()) : found
    }
}

/// What `BookFormat.parse` read.
public struct ParsedBook: Hashable, Sendable {
    public var book: Book
    /// The file's `format:` value; `nil` if it had none (or not a number). The book was read
    /// as the current format either way, with a notice if this isn't it.
    public var declaredFormat: FormatVersion?

    /// Whether the file says it's a format newer than this version reads. Such a book
    /// should open read-only, so a downgraded copy can't be saved over it (book format §10 Q7).
    public var isNewerThanSupported: Bool {
        declaredFormat.map { $0 > .current } ?? false
    }
}

/// A `book.md` format number.
public struct FormatVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let current = FormatVersion(2)

    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.number < rhs.number
    }

    public var description: String { String(number) }
}

/// Why `BookFormat.verifiedSerialization` refused a book. Either means the serializer wrote
/// something the parser reads differently, typically because the book breaks one of the
/// model's invariants (book format §7.5).
public enum VerificationFailure: Error, Hashable, Sendable, CustomStringConvertible {
    /// Reading the bytes back produced error entries the book didn't have.
    case newEntries([ErrorEntry])
    /// Reading the bytes back and serializing again gave different bytes.
    case unstable

    public var description: String {
        switch self {
        case .newEntries(let entries):
            "the serialized book reads back with new error entries:\n"
                + entries.map { "- \($0.tag.rawValue)" }.joined(separator: "\n")
        case .unstable: "the serialized book changes when it's read and serialized again"
        }
    }
}

/// Where the parser gets a fresh id for a scene whose own is missing or a duplicate.
public protocol SceneIDSource {
    mutating func sceneID() -> SceneID
}

extension IDGenerator: SceneIDSource {}

/// For re-reading a book's own serialization, which needs no fresh ids: if it did, the
/// accompanying notice fails verification anyway.
private struct UnusedSceneIDs: SceneIDSource {
    private var count = 0

    mutating func sceneID() -> SceneID {
        count += 1
        return SceneID(rawValue: "verification-\(count)")
    }
}
