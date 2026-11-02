/// The alert shown when quitting would lose edits. The owner approved the `.saveFailed` and
/// `.changedOnDisk` wording; `.stillSaving` is a draft awaiting approval.
public struct QuitAlert: Hashable, Sendable {
    public let title: String
    public let message: String
    /// In button order: the first is the default (Return), and `.cancel`, if present, answers Escape.
    public let choices: [QuitAlertChoice]
}

/// Every string in the quit alert, in one place so the owner can review it as a whole.
public enum QuitWording {
    public static func alert(for problem: QuitProblem) -> QuitAlert {
        switch problem {
        case .saveFailed(let error):
            QuitAlert(
                title: "Scene It couldn't save your latest changes.",
                message: reason(error)
                    + " If you quit now, the changes you made since the last save will be lost.",
                choices: [.retry, .cancel, .quitAnyway])
        case .changedOnDisk:
            QuitAlert(
                title: "This book was changed by another program.",
                message: "Scene It stopped saving so it wouldn't overwrite the other version. "
                    + "If you quit now, the changes you made since the last save will be lost. "
                    + "Choose Cancel to go back and decide which version to keep.",
                choices: [.cancel, .quitAnyway])
        case .stillSaving:
            QuitAlert(
                title: "Scene It is still saving your book.",
                message: "Saving is taking longer than usual. "
                    + "If you quit now, the changes you made since the last save may be lost.",
                choices: [.wait, .quitAnyway])
        }
    }

    public static func label(_ choice: QuitAlertChoice) -> String {
        switch choice {
        case .retry: "Retry"
        case .wait: "Wait"
        case .quitAnyway: "Quit Anyway"
        case .cancel: "Cancel"
        }
    }

    private static func reason(_ error: SaveError) -> String {
        switch error {
        case .fileSystem(let error):
            switch error.cause {
            case .noSpace: "The disk is full."
            case .readOnlyVolume: "The disk is read-only."
            case .permissionDenied: "Scene It doesn't have permission to write to the book."
            case .notFound, .alreadyExists, .unsupported, .io, .other: "The disk reported an error."
            }
        case .writeProtected(.locked):
            "The book is locked in Finder."
        case .writeProtected(.readOnly):
            "The book is read-only."
        case .encoding:
            "Scene It found a problem in the book while preparing to save it."
        case .externallyModified, .couldNotBackUpTheirVersion:
            "Another program changed the book."
        }
    }
}
