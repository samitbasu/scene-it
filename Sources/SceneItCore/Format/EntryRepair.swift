import Foundation

/// Why an error entry is one, as the Errors tab explains it (book format §5.4). Derived from
/// the entry in its context, never stored.
public enum ErrorReason: Error, Hashable, Sendable {
    case comment(EntryProblem)
    case mark(EntryProblem)
    case metadata(FieldProblem)
    case frontMatter(FieldProblem)
    /// A `[line]` entry, or an entry with no place it could go back to.
    case line
    case notice
    /// The payload reads correctly where it is now (the text it points at changed back, say),
    /// so repairing it as it stands applies it.
    case readsNow
}

/// Why a `key: value` line of the front matter or a scene's metadata is an error (§1.5, §2.2).
public enum FieldProblem: Hashable, Sendable {
    case notAField
    case unknownKey
    case repeatedKey
    case badID
    /// Another scene has this id.
    case idInUse
    case badDate
    case badFormat
    /// A format number this version doesn't read as its own.
    case otherFormat
}

extension ErrorTag {
    /// Whether the writer can edit an entry with this tag and have it take effect (§5.4).
    public var isRepairable: Bool {
        switch self {
        case .frontMatter, .metadata, .comments, .marks: true
        case .line, .notice: false
        }
    }
}

extension RepairNotice {
    var reason: ErrorReason {
        switch self {
        case .duplicateSceneID: .metadata(.idInUse)
        case .otherFormat: .frontMatter(.otherFormat)
        default: .notice
        }
    }
}

extension BookFormat {
    /// Why `ref`'s entry is an error where it is now: the first rule its payload breaks when
    /// it's read back in its place, with the code that loads books.
    public static func reason(for ref: ErrorRef, in book: Book) -> ErrorReason {
        switch ref.entry.tag {
        case .line: return .line
        case .notice: return .notice
        case .frontMatter, .metadata, .comments, .marks:
            switch EntryRepairTrial.attempt(ref, payload: ref.entry.payload, in: book) {
            case .success: return .readsNow
            case .failure(let reason): return reason
            }
        }
    }

    /// `ref`'s owner after the writer edited its entry's payload to `payload` (§5.4 Repair):
    /// read back in its place, with the code that loads books. If it now reads correctly it
    /// takes effect, and the entry is gone; otherwise the entry stays, with the edited
    /// payload, and the reason says why. `nil` if `ref` isn't in `book`, or its entry can't
    /// be repaired.
    public static func repair(_ ref: ErrorRef, as payload: String, in book: Book) -> EntryRepair? {
        guard book.holds(ref), ref.entry.tag.isRepairable, let part = book.part(ref.owner) else { return nil }
        switch EntryRepairTrial.attempt(ref, payload: payload, in: book) {
        case .success(let repaired):
            return .repaired(repaired)
        case .failure(let reason):
            var errors = part.errors
            errors[ref.index] = ErrorEntry(ref.entry.tag, payload)
            return .kept(part.with(errors: errors), reason)
        }
    }
}

public enum EntryRepair: Hashable, Sendable {
    /// The edited entry took effect; this is its owner without it.
    case repaired(BookPart)
    /// The edited entry still doesn't read; this is its owner holding it.
    case kept(BookPart, ErrorReason)
}

/// Puts an entry's payload back where its tag says it came from, in a file made from its
/// owner's current state, and parses that file. Only the owner is written in full; other
/// scenes are reduced to their ids, which is all a scene's lines are checked against.
private enum EntryRepairTrial {
    static func attempt(_ ref: ErrorRef, payload: String, in book: Book) -> Result<BookPart, ErrorReason> {
        guard let entries = book.errors(of: ref.owner), entries.indices.contains(ref.index) else {
            return .failure(.line)
        }
        var remaining = entries
        remaining.remove(at: ref.index)
        let line = ErrorEntry(ref.entry.tag, payload).payload
        switch (ref.owner, ref.entry.tag) {
        case (.book, .frontMatter):
            return frontMatter(line, title: book.title, remaining: remaining)
        case (.scene(let id), .metadata), (.scene(let id), .comments), (.scene(let id), .marks):
            guard var scene = book.scene(id) else { return .failure(.line) }
            scene.errors = remaining
            return self.scene(scene, line: line, tag: ref.entry.tag, in: book)
        default:
            return .failure(.line)
        }
    }

    private static func frontMatter(_ line: String, title: String, remaining: [ErrorEntry])
        -> Result<BookPart, ErrorReason>
    {
        guard let fields = replacingField(BookSerializer.frontMatterFields(title), with: line) else {
            return .failure(.frontMatter(.notAField))
        }
        let parsed = parse(BookSerializer.frontMatter(fields: fields) + "\n")
        guard parsed.newEntries.isEmpty else { return .failure(parsed.firstNewReason ?? .line) }
        return .success(.header(title: parsed.book.title, errors: remaining))
    }

    private static func scene(_ scene: BookScene, line: String, tag: ErrorTag, in book: Book)
        -> Result<BookPart, ErrorReason>
    {
        var blocks = BookSerializer.blocks(scene)
        switch tag {
        case .metadata:
            let header = blocks[0].components(separatedBy: "\n")
            guard let fields = replacingField(Array(header.dropFirst()), with: line) else {
                return .failure(.metadata(.notAField))
            }
            blocks[0] = ([header[0]] + fields).joined(separator: "\n")
        case .comments:
            guard Lexical.isEntryStart(bytes(line)) else { return .failure(.comment(.strayLine)) }
            blocks.append("### Comments\n" + line)
        case .marks:
            guard Lexical.isEntryStart(bytes(line)) else { return .failure(.mark(.strayLine)) }
            blocks.append("### Marks\n" + line)
        case .frontMatter, .line, .notice:
            return .failure(.line)
        }
        let others = (book.scenes + book.boneyard).filter { $0.id != scene.id }.map {
            BookScene(id: $0.id, modified: $0.modified, title: "")
        }
        let parsed = parse(
            BookSerializer.text(of: Book(title: "", scenes: others)) + "\n" + blocks.joined(separator: "\n\n")
                + "\n")
        guard parsed.newEntries.isEmpty, parsed.book.scenes.count == others.count + 1,
            let read = parsed.book.scenes.last, read.errors == scene.errors
        else {
            return .failure(parsed.firstNewReason ?? .line)
        }
        return .success(.scene(read))
    }

    /// `fields` with the one whose key `line` has replaced by `line`, or `line` added after
    /// them; `nil` if `line` isn't a `key: value` line.
    private static func replacingField(_ fields: [String], with line: String) -> [String]? {
        guard let key = Lexical.keyValue(bytes(line))?.key else { return nil }
        var fields = fields
        if let index = fields.firstIndex(where: { Lexical.keyValue(bytes($0))?.key == key }) {
            fields[index] = line
        } else {
            fields.append(line)
        }
        return fields
    }

    /// An admitted line's Latin-1 code units.
    private static func bytes(_ line: String) -> [UInt8] {
        line.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }

    private static func parse(_ text: String) -> ParsedBook {
        var ids = UnusedSceneIDs()
        return BookFormat.parse(Data(text.utf8), opened: BookFormat.rereadTime, ids: &ids)
    }
}
