import Foundation

/// Every string a writer sees about a book opening read-only (ADR 0020, 0024 and book format
/// §10 Q7), in one place so the owner can review the wording as a whole. The owner approved
/// the repaired-book, newer-format and Make Editable wording on 2026-11-02, and the title of
/// Make Editable…'s confirmation the same day.
public enum ReadOnlyWording {
    public static let readOnlyTitle = "Opened Read-Only"

    public static func readOnlyMessage(_ reason: ReadOnlyReason, of kind: DocumentKind = .book) -> String {
        let noun = kind.noun
        return switch reason {
        case .openElsewhere:
            "This \(noun) is already open in Scene It, in another user account or another copy of "
                + "the app. To make changes, close it there, then open it again here."
        case .openOnAnotherMac(let record):
            "This \(noun) is open on “\(record.host)” (since "
                + "\(record.since.formatted(date: .abbreviated, time: .shortened))). To make changes, "
                + "close it on that Mac, then open it again here. If that Mac isn't using it any more, "
                + "choose \(openAnyway)."
        case .openInAnotherProcess(let record):
            "This \(noun) is already open in Scene It on this Mac, \(holder(record)) (since "
                + "\(record.since.formatted(date: .abbreviated, time: .shortened))). To make changes, "
                + "close it there, then open it again here. If it isn't open there any more, "
                + "choose \(openAnyway)."
        case .lockUnavailable(let error):
            "Scene It can't make changes to this \(noun): it couldn't mark the \(noun) as in use "
                + "(\(error.cause))."
        case .repairedOnOpen(.review(let repair)):
            "Part of this review's file couldn't be read as it was written, so Scene It repaired it "
                + "while opening it (\(repairs(repair.newEntries.count))). Nothing on disk has changed. "
                + "Each repair is noted in the review, so you can check what changed before you edit."
                + "\n\n\(makeEditable) first keeps an exact copy of the file as it is now, in Scene It's own "
                + "folder for this review, then lets you edit. Your next save replaces the damaged file with "
                + "the repaired review. The review copy itself is never changed."
        case .repairedOnOpen(let repair):
            "Part of this book's file couldn't be read as it was written, so Scene It repaired it "
                + "while opening it (\(repairs(repair.newEntries.count))). Nothing on disk has changed. "
                + "Each repair is noted in the book, so you can check what changed before you edit."
                + "\n\n\(makeEditable) first keeps an exact copy of the file as it is now, inside the "
                + "book, then lets you edit. Your next save replaces the damaged file with the repaired book."
        case .newerFormat(let format):
            "This book was saved by a newer version of Scene It (book format \(format)). This version "
                + "can show it, but saving it here could lose what the newer version added. To make "
                + "changes, open it in the newer version."
        case .newerReviewFormat(let format):
            "This review was saved by a newer version of Scene It (review format \(format)). This version "
                + "can show it, but saving it here could lose what the newer version added. To make "
                + "changes, open it in the newer version."
        }
    }

    private static func repairs(_ count: Int) -> String {
        count == 1 ? "1 repair" : "\(count) repairs"
    }

    private static func holder(_ record: LockRecord) -> String {
        guard record.userID != getuid() else { return "in another copy of the app" }
        guard let entry = getpwuid(record.userID), let name = entry.pointee.pw_gecos ?? entry.pointee.pw_name
        else {
            return "in another user account"
        }
        return "in \(String(cString: name))’s user account"
    }

    /// Offered only for `.openOnAnotherMac` and `.openInAnotherProcess`.
    public static let openAnyway = "Open Anyway"
    public static let openAnywayWarning =
        "If the book is still open there, each copy of Scene It will stop and ask before saving over "
        + "the other's changes."
    public static let keepReadOnly = "Keep Read-Only"
    /// Offered only for `.repairedOnOpen` (ADR 0024).
    public static let makeEditable = "Make Editable"

    /// The alert after a book opened read-only. "Open Anyway" is offered only where a
    /// `LockRecord` names the holder, and its warning then follows the message; "Make Editable"
    /// only for a book repaired as it opened. "Keep Read-Only" is always first, so it's the
    /// default.
    public static func alert(for reason: ReadOnlyReason, of kind: DocumentKind = .book)
        -> WriterAlert<ReadOnlyChoice>
    {
        let keep = WriterAlert<ReadOnlyChoice>.Button(choice: .keepReadOnly, label: keepReadOnly)
        switch reason {
        case .openOnAnotherMac(let record), .openInAnotherProcess(let record):
            // A review's lock is in Application Support, on this Mac: nothing to open anyway.
            guard kind == .book else {
                return WriterAlert(
                    title: readOnlyTitle, message: readOnlyMessage(.openElsewhere, of: kind), buttons: [keep])
            }
            return WriterAlert(
                title: readOnlyTitle, message: readOnlyMessage(reason, of: kind) + "\n\n" + openAnywayWarning,
                buttons: [keep, .init(choice: .openAnyway(record), label: openAnyway)])
        case .repairedOnOpen:
            return WriterAlert(
                title: readOnlyTitle, message: readOnlyMessage(reason, of: kind),
                buttons: [keep, .init(choice: .makeEditable, label: makeEditable)])
        case .openElsewhere, .lockUnavailable, .newerFormat, .newerReviewFormat:
            return WriterAlert(
                title: readOnlyTitle, message: readOnlyMessage(reason, of: kind), buttons: [keep])
        }
    }

    public static let makeEditableTitle = "Make This Book Editable?"

    /// Make Editable… from the banner or the File menu: the open-time alert's message and
    /// buttons, under a title that asks rather than reports.
    public static func confirmMakeEditable(_ repair: Repair) -> WriterAlert<ReadOnlyChoice> {
        let opened = alert(for: .repairedOnOpen(repair))
        let title = if case .review = repair { "Make This Review Editable?" } else { makeEditableTitle }
        return WriterAlert(title: title, message: opened.message, buttons: opened.buttons)
    }

    /// When Make Editable couldn't keep the original, so the book stayed read-only.
    public static func makeEditableFailed(_ error: FileSystemError, of kind: DocumentKind = .book) -> Notice {
        Notice(
            title: "Scene It couldn't make the \(kind.noun) editable.",
            message:
                "It couldn't keep a copy of the \(kind.noun)'s file as it is now (\(error.cause)), so the "
                + "\(kind.noun) is still read-only. Nothing was changed.")
    }
}

public enum ReadOnlyChoice: Hashable, Sendable {
    case keepReadOnly
    /// Reopen for editing despite exactly this record (`LockRecordPolicy.openAnyway`).
    case openAnyway(LockRecord)
    /// Keep the repaired book's original, then edit it (ADR 0024).
    case makeEditable
}

/// What's open: a book, or a review of a review copy (ADR 0042).
public enum DocumentKind: Hashable, Sendable {
    case book, review

    /// What the wording calls it.
    public var noun: String {
        switch self {
        case .book: "book"
        case .review: "review"
        }
    }
}
