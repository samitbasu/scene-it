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
        case .openInAnotherProcess(let record):
            "This book is already open in Scene It on this Mac, \(holder(record)) (since "
                + "\(record.since.formatted(date: .abbreviated, time: .shortened))). To make changes, "
                + "close it there, then open it again here. If it isn't open there any more, "
                + "choose \(openAnyway)."
        case .lockUnavailable(let error):
            "Scene It can't make changes to this book: it couldn't mark the book as in use "
                + "(\(error.cause))."
        }
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
        "If the book is still open on that Mac, each Mac will stop and ask before saving over "
        + "the other's changes."
    public static let keepReadOnly = "Keep Read-Only"
}
