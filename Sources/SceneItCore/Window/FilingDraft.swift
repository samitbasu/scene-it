import Foundation

/// What the File a Copy dialog holds while the writer fills it in (PLAN §7.1): the tags as
/// chips, the text being typed as the next one, the date and the note.
public struct FilingDraft: Hashable, Sendable {
    /// Each one admitted, trimmed, non-empty and different from the others.
    public private(set) var tags: [String] = []
    /// What's typed in the tags field, not yet a tag: one line of text `CharacterPolicy`
    /// admits, as the editors keep it, so the field never shows what the index won't keep.
    public var pendingTag = "" {
        didSet { pendingTag = CharacterPolicy.admittedLine(pendingTag) }
    }
    public var filed: CalendarDay
    /// Text `CharacterPolicy` admits, as `pendingTag`.
    public var note = "" {
        didSet { note = CharacterPolicy.admittedInput(note) }
    }

    /// Dated `today`, as the dialog opens.
    public init(today: CalendarDay) {
        filed = today
    }

    /// Return in the tags field: the typed text becomes the last tag, unless it's empty or
    /// already a tag. The field empties either way.
    public mutating func commitPendingTag() {
        let tag = pendingTag.trimmingCharacters(in: .whitespaces)
        pendingTag = ""
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        tags.append(tag)
    }

    /// ⌫ in the tags field: removes the last tag, but only while nothing is typed (otherwise
    /// the key edits the text). Whether it removed one.
    @discardableResult
    public mutating func deleteBackward() -> Bool {
        guard pendingTag.isEmpty, !tags.isEmpty else { return false }
        tags.removeLast()
        return true
    }

    /// A chip's ×.
    public mutating func remove(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    /// Whether the writer typed anything that leaving would lose: a tag, one being typed, or a
    /// note. The date alone doesn't count.
    public var holdsTypedText: Bool {
        !record.tags.isEmpty || !note.isEmpty
    }

    /// File copy: what's filed, with a tag still being typed counted as one.
    public var record: FilingRecord {
        var draft = self
        draft.commitPendingTag()
        return FilingRecord(filed: draft.filed, tags: draft.tags, note: draft.note)
    }
}

/// Whether File a Copy's dialog is being edited, or its File copy is running: while it is, the
/// whole dialog waits, and nothing closes it.
public enum FilingStage: Hashable, Sendable {
    case editing
    case filing
}
