import Foundation

/// Every string a writer sees about a book opening read-only (ADR 0020), in one place so the
/// owner can review the wording as a whole. Drafts awaiting the owner's approval.
public enum LockWording {
    public static let readOnlyTitle = "Opened Read-Only"

    public static func readOnlyMessage(_ reason: ReadOnlyReason) -> String {
        switch reason {
        case .openElsewhere:
            "This book is already open in Scene It, in another user account or another copy of "
                + "the app. To make changes, close it there, then open it again here."
        case .openOnAnotherMac(let record):
            "This book is open on “\(record.host)” (since "
                + "\(record.since.formatted(date: .abbreviated, time: .shortened))). To make changes, "
                + "close it on that Mac, then open it again here. If that Mac isn't using it any more, "
                + "choose \(openAnyway)."
        case .lockUnavailable(let error):
            "Scene It can't make changes to this book: it couldn't mark the book as in use "
                + "(\(error.cause))."
        }
    }

    /// Offered only for `.openOnAnotherMac`.
    public static let openAnyway = "Open Anyway"
    public static let openAnywayWarning =
        "If the book is still open on that Mac, each Mac will stop and ask before saving over "
        + "the other's changes."
    public static let keepReadOnly = "Keep Read-Only"
}
