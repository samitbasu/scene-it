import Foundation

/// Which export a review copy came from (review format §2.1): fresh for every export, so two
/// copies of the same scenes are still told apart.
public typealias ExportID = Identifier<ReviewCopy>

/// What Export as SceneIt… writes (ADR 0029, review format §2.2): the book's title and the
/// chosen story scenes, in story order, each with its title, id, `modified` and body text in
/// bold, italic and strikethrough. The only way to make one is to project a book, so a copy
/// can't hold tags, notes, comments, colors, highlights, error entries or a Boneyard.
public struct ReviewCopy: Hashable, Sendable {
    /// The projected book: `scenes` only, every run plain but for its styles.
    public let book: Book
    public let export: ExportID
    public let exported: Timestamp

    /// The story scenes of `book` whose ids are in `chosen`; any other id is ignored.
    public init(projecting book: Book, chosen: Set<SceneID>, export: ExportID, exported: Timestamp) {
        self.init(book: Self.projected(book, chosen: chosen), export: export, exported: exported)
    }

    static func projected(_ book: Book, chosen: Set<SceneID>) -> Book {
        Book(title: book.title, scenes: book.scenes.filter { chosen.contains($0.id) }.map(Self.projected))
    }

    private init(book: Book, export: ExportID, exported: Timestamp) {
        self.book = book
        self.export = export
        self.exported = exported
    }

    static func projected(_ scene: BookScene) -> BookScene {
        BookScene(
            id: scene.id, modified: scene.modified, title: scene.title,
            body: scene.body.map { paragraph in
                Paragraph(paragraph.runs.map { Run($0.text, styles: $0.styles) }).withMaximalRuns
            })
    }

    /// Exporting `scene` leaves out text Scene It couldn't read: an entry of its `### Unparsed`
    /// section, as the Errors tab lists it, that isn't a repair notice.
    public static func leavesOutUnreadableText(of scene: BookScene) -> Bool {
        dropsUnreadableText(scene.errors, keeping: projected(scene).errors)
    }

    /// Exporting any scenes of `book` leaves out text Scene It couldn't read that belongs to the
    /// book rather than to a scene: its front matter's and its own `### Unparsed` section's.
    public static func leavesOutUnreadableText(ofBookItself book: Book) -> Bool {
        dropsUnreadableText(book.errors, keeping: projected(book, chosen: []).errors)
    }

    private static func dropsUnreadableText(_ entries: [ErrorEntry], keeping kept: [ErrorEntry]) -> Bool {
        entries.contains { $0.tag.holdsUnreadableText && !kept.contains($0) }
    }

    /// The copy a verified parse describes, for checking that it serializes to the same bytes.
    fileprivate init(rereading parsed: ParsedReviewCopy, as copy: ReviewCopy) {
        self.init(book: parsed.parsed.book, export: copy.export, exported: copy.exported)
    }
}

/// The review copy's file: the book format (ADR 0022) with two more front-matter keys, read in
/// review-copy mode (review format §2.4). `parse` never fails, like the book format's.
public enum ReviewCopyFormat {
    public static func serialize(_ copy: ReviewCopy) -> Data {
        let marker = ["export: \(copy.export)", "exported: \(copy.exported)"]
        return Data(BookSerializer.text(of: copy.book, extraFrontMatter: marker).utf8)
    }

    /// Reads any bytes as a review copy, or as something that isn't one (review format §2.3).
    /// A scene missing its `modified` gets `opened`, with a notice.
    public static func parse(_ bytes: Data, opened: Timestamp) -> ParsedReviewCopy {
        let (parsed, frontMatter) = BookParser.parseReviewCopy(bytes, opened: opened)
        let recognition: ReviewCopyRecognition =
            frontMatter.export.map { .reviewCopy($0, exported: frontMatter.exported) } ?? .notAReviewCopy
        return ParsedReviewCopy(parsed: parsed, recognition: recognition)
    }

    /// The bytes to write for `copy`, once they read back exactly as it (book format §7.2, as
    /// review format §2.2 applies it): no error entries, the same marker and scenes, and the
    /// same bytes again when serialized.
    public static func verifiedSerialization(of copy: ReviewCopy) throws(VerificationFailure) -> Data {
        let bytes = serialize(copy)
        let reread = parse(bytes, opened: BookFormat.rereadTime)
        guard reread.parsed.newEntries.isEmpty else { throw .newEntries(reread.parsed.newEntries) }
        guard reread.recognition == .reviewCopy(copy.export, exported: copy.exported),
            reread.parsed.book == copy.book
        else { throw .changed }
        guard serialize(ReviewCopy(rereading: reread, as: copy)) == bytes else { throw .unstable }
        return bytes
    }
}

/// What `ReviewCopyFormat.parse` read.
public struct ParsedReviewCopy: Hashable, Sendable {
    /// The file as a book: what the reviewer sees and comments on is its story scenes.
    public let parsed: ParsedBook
    public let recognition: ReviewCopyRecognition
}

/// Whether a file is a review copy (review format §2.3), by its front matter's `export`.
public enum ReviewCopyRecognition: Hashable, Sendable {
    /// `exported` is informational, and `nil` when it was missing or unreadable.
    case reviewCopy(ExportID, exported: Timestamp?)
    case notAReviewCopy
}
