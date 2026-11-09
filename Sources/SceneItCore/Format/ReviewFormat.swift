import Foundation

/// A review file's id (review format §3.2): made when the review is, it names the review's
/// folder of backups (§9 Q9) and keys the standalone page's ticks (§7.3).
public typealias ReviewID = Identifier<Review>

/// What a reviewer reads (review format §2.4): a review copy's story scenes, each with its
/// title, id, `modified` and body text in bold, italic and strikethrough, as the copy parsed.
/// Everything else the copy might hold (notes, comments, marks, tags, a Boneyard) is ignored.
/// It's never written.
public struct ReceivedCopy: Hashable, Sendable {
    public let export: ExportID
    /// Informational; `nil` when the copy's was missing or unreadable.
    public let exported: Timestamp?
    /// The story scenes only.
    public let book: Book

    /// `nil` for a file that isn't a review copy (review format §2.3).
    public init?(_ parsed: ParsedReviewCopy) {
        guard case .reviewCopy(let export, let exported) = parsed.recognition else { return nil }
        self.export = export
        self.exported = exported
        book = Book(
            title: parsed.parsed.book.title, scenes: parsed.parsed.book.scenes.map(ReviewCopy.projected))
    }

    /// Whether the copy is in a format newer than this version reads (review format §9 Q4).
    public static func isNewerThanSupported(_ parsed: ParsedReviewCopy) -> Bool {
        parsed.parsed.isNewerThanSupported
    }
}

/// A reviewer's comments and notes on a review copy (ADR 0029, review format §3).
///
/// In memory a review is a book (ADR 0042): the copy's story scenes, in story order, each
/// carrying the reviewer's comments on its text, the reviewer's notes on it and the error
/// entries the review file holds for it; the review's own entries are the book's. So the
/// page, the comments panel, the Notes and Errors tabs, undo and autosave are the book's own.
public struct Review: Hashable, Sendable {
    public var book: Book
    /// On the review as a whole (review format §3.3). Never carries a comment id: every
    /// assignment takes any off.
    public var notes: [Paragraph] {
        didSet {
            if !Paragraph.commentIDs(in: notes).isEmpty { notes = notes.map(\.uncommented) }
        }
    }
    /// The export id of the copy this reviews.
    public let copy: ExportID
    public let id: ReviewID

    init(book: Book, notes: [Paragraph], copy: ExportID, id: ReviewID) {
        self.book = book
        self.notes = notes.map(\.uncommented)
        self.copy = copy
        self.id = id
    }

    /// A review of `copy` with nothing in it yet: its file isn't written until there is.
    public init(of copy: ReceivedCopy, id: ReviewID) {
        self.init(book: copy.book, notes: [], copy: copy.export, id: id)
    }

    var withMaximalRuns: Review {
        Review(book: book.withMaximalRuns, notes: notes.map(\.withMaximalRuns), copy: copy, id: id)
    }

    /// Whether the review holds anything its file would: notes, comments or error entries.
    public var isEmpty: Bool {
        notes.isEmpty && book.errors.isEmpty
            && book.scenes.allSatisfy { $0.notes.isEmpty && $0.comments.isEmpty && $0.errors.isEmpty }
    }
}

/// The review file, `<name>.review.md` (review format §3): tolerant Markdown in the book
/// format's dialect, read against the copy it reviews. `parse` never fails.
public enum ReviewFormat {
    public static let current = FormatVersion(1)

    /// Reads any bytes as a review of `copy`. A review with no id gets `freshID()`, with a notice.
    public static func parse(
        _ bytes: Data, against copy: ReceivedCopy, freshID: () -> ReviewID
    ) -> ParsedReview {
        ReviewParser.parse(bytes, against: copy, freshID: freshID)
    }

    /// The export id a review file's front matter binds it to (review format §2.3, §4.1): its
    /// first `copy` line, if that's a valid id. `nil` for any other file.
    public static func boundCopy(in bytes: Data) -> ExportID? {
        let text = CharacterPolicy.fileText(BookTextDecoder.decode(bytes).text)
        let lines = BookParser.lines(text.bytes)
        for number in Lexical.frontMatter(lines).lines {
            guard let (key, value) = Lexical.keyValue(lines[number]), key == "copy" else { continue }
            let id = Lexical.string(value)
            return Lexical.isValidID(id.utf8) ? ExportID(rawValue: id) : nil
        }
        return nil
    }

    /// The canonical form (review format §3.9).
    public static func serialize(_ review: Review) -> Data {
        let frontMatter = BookSerializer.frontMatter(fields: [
            BookSerializer.keyValue("title", FieldEscaping.freeText.escape(review.book.title)),
            "format: \(current)", "copy: \(review.copy)", "id: \(review.id)",
        ])
        var blocks = [frontMatter]
        blocks += BookSerializer.notes(review.notes)
        blocks += BookSerializer.unparsed(review.book.errors)
        for scene in review.book.scenes
        where !scene.notes.isEmpty || !scene.comments.isEmpty || !scene.errors.isEmpty {
            let title = scene.title.text.isEmpty ? "##" : "## " + Inline.writeTitle(scene.title.text)
            blocks.append(title + "\nid: \(scene.id)")
            blocks += BookSerializer.notes(scene.notes)
            blocks += BookSerializer.comments(scene)
            blocks += BookSerializer.unparsed(scene.errors)
        }
        return Data((blocks.joined(separator: "\n\n") + "\n").utf8)
    }

    /// The bytes to save for `review`, once they read back against `copy` as exactly it
    /// (review format §3.9): the same error entries, the same review, and the same bytes again.
    /// A review whose text no longer matches the copy's reads back differently, so it's refused.
    public static func verifiedSerialization(of review: Review, against copy: ReceivedCopy)
        throws(VerificationFailure) -> Data
    {
        let bytes = serialize(review)
        let reread = parse(bytes, against: copy, freshID: { ReviewID(rawValue: "verification") }).review
        guard reread.book.errorEntries == review.book.errorEntries else {
            let had = Set(review.book.errorEntries.joined())
            let found = reread.book.errorEntries.joined().filter { !had.contains($0) }
            throw .newEntries(found.isEmpty ? Array(reread.book.errorEntries.joined()) : found)
        }
        guard reread == review.withMaximalRuns else { throw .changed }
        guard serialize(reread) == bytes else { throw .unstable }
        return bytes
    }
}

/// What `ReviewFormat.parse` read.
public struct ParsedReview: Hashable, Sendable {
    public var review: Review
    /// The file's `format:` value; `nil` if it had none (or not a number).
    public var declaredFormat: FormatVersion?
    /// The error entries this parse made, in the Errors tab's order. A review with any opens
    /// read-only until the reviewer confirms (review format §3.8, ADR 0024).
    public var newEntries: [ErrorEntry]

    public var wasRepaired: Bool {
        !newEntries.isEmpty
    }

    public var isNewerThanSupported: Bool {
        declaredFormat.map { $0 > ReviewFormat.current } ?? false
    }
}

/// The notices the review format adds (review format §3.7).
enum ReviewNotice: Hashable {
    case missingFormat
    case otherFormat(Int)
    case missingCopy(ExportID)
    case missingID(given: ReviewID)
    case sectionWithoutID
    case sectionForNoScene(SceneID)

    var entry: ErrorEntry {
        ErrorEntry(.notice, payload)
    }

    var payload: String {
        switch self {
        case .missingFormat: "The file had no format line; it was read as format \(ReviewFormat.current)."
        case .otherFormat(let number):
            "The file says format \(number); this version of Scene It reads review format \(ReviewFormat.current)."
        case .missingCopy(let export):
            "This review had no copy line, so it was taken to be the review of this copy, \(export)."
        case .missingID(let given): "This review had no id, so it was given \(given)."
        case .sectionWithoutID: "A scene section had no id, so its lines were kept as entries."
        case .sectionForNoScene(let id):
            "There's no scene with id \(id) in this review copy, so that section's lines were kept as entries."
        }
    }

    static func format(_ declared: Int?) -> [ReviewNotice] {
        guard let declared else { return [.missingFormat] }
        return declared == ReviewFormat.current.number ? [] : [.otherFormat(declared)]
    }
}
