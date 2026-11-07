/// An alert that asks the writer to choose. Every alert the store raises has this shape, so
/// the app presents all of them with one function.
public struct WriterAlert<Choice: Hashable & Sendable>: Hashable, Sendable {
    public struct Button: Hashable, Sendable {
        public let choice: Choice
        public let label: String
    }

    public let title: String
    public let message: String
    /// In order: the first is the default (Return), and a button labelled "Cancel" answers Escape.
    public let buttons: [Button]

    public init(title: String, message: String, buttons: [Button]) {
        self.title = title
        self.message = message
        self.buttons = buttons
    }

    public var choices: [Choice] { buttons.map(\.choice) }
}

public typealias QuitAlert = WriterAlert<QuitAlertChoice>

/// Every string in the alert shown when quitting would lose edits, in one place so the owner
/// can review it as a whole. Close Book and closing the window quit too (ADR 0038), so they
/// share it. The owner approved this wording.
public enum QuitWording {
    public static func alert(for problem: QuitProblem) -> QuitAlert {
        let ifYouLeave = "If you quit now"
        let (title, message, choices): (String, String, [QuitAlertChoice]) =
            switch problem {
            case .saveFailed(let error):
                (
                    "Scene It couldn't save your latest changes.",
                    reason(error) + " \(ifYouLeave), the changes you made since the last save will be lost.",
                    [.retry, .cancel, .quitAnyway]
                )
            case .changedOnDisk:
                (
                    changedOnDiskTitle,
                    "Scene It stopped saving so it wouldn't overwrite the other version. "
                        + "\(ifYouLeave), the changes you made since the last save will be lost. "
                        + "Choose Cancel to go back and decide which version to keep.",
                    [.cancel, .quitAnyway]
                )
            case .stillSaving:
                (
                    "Scene It is still saving your book.",
                    "Saving is taking longer than usual. "
                        + "\(ifYouLeave), the changes you made since the last save may be lost.",
                    [.wait, .quitAnyway]
                )
            }
        return QuitAlert(
            title: title, message: message, buttons: choices.map { .init(choice: $0, label: label($0)) })
    }

    /// Also the title of ADR 0018's alert (`StoreWording.externalChangeAlert`).
    public static let changedOnDiskTitle = "This book was changed by another program."

    public static func label(_ choice: QuitAlertChoice) -> String {
        switch choice {
        case .retry: "Retry"
        case .wait: "Wait"
        case .quitAnyway: "Quit Anyway"
        case .cancel: "Cancel"
        }
    }

    /// Why a save failed, as one sentence. The status bar and every save alert use it.
    public static func reason(_ error: SaveError) -> String {
        switch error {
        case .fileSystem(let error):
            switch error.cause {
            case .noSpace: "The disk is full."
            case .readOnlyVolume: "The disk is read-only."
            case .permissionDenied: "Scene It doesn't have permission to write to the book."
            case .notFound, .alreadyExists, .unsupported, .io, .filedCopy, .other:
                "The disk reported an error."
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
