import Foundation

/// Every string File a Copy shows (PLAN §7.1), in one place so the owner can review the wording
/// as a whole. The owner approved all of it (#32, 2026-11-03); the dialog's text follows the
/// mockup (14-file-a-copy-dialog.png).
public enum ArchiveWording {
    public static let menuItem = "File a Copy…"

    // MARK: The dialog

    public static let dialogTitle = "File a copy"
    public static let dialogExplanation =
        "Saves a read-only copy of the whole manuscript, with every scene's notes and comments, "
        + "to the File Cabinet."
    public static let tagsLabel = "Tags"
    public static let tagsPlaceholder = "Type a tag, press Return"
    public static let dateLabel = "Date"
    public static let noteLabel = "Note"
    public static let cancel = "Cancel"
    public static let confirm = "File copy"

    public static func removeTag(_ tag: String) -> String {
        "Remove \(tag)"
    }

    // MARK: Afterwards

    /// The toast: "Filed in the File Cabinet · Nov 3, 2026 · draft 4".
    public static func toast(_ record: FilingRecord) -> String {
        (["Filed in the File Cabinet", day(record.filed)] + record.tags.prefix(2)).joined(separator: " · ")
    }

    public static func day(_ day: CalendarDay) -> String {
        day.noon(in: .current).formatted(date: .abbreviated, time: .omitted)
    }

    /// What the writer is told after File copy, when something didn't happen; `nil` when the
    /// copy is filed, locked and indexed (the toast says so). Wherever what the writer typed
    /// might not be kept, the message repeats it, so it can be typed again.
    public static func notice(for result: FilingResult, record: FilingRecord) -> Notice? {
        switch result {
        case .unavailable:
            return Notice(
                title: couldntFile,
                message: "The book isn't open for editing, so nothing was filed." + typed(record))
        case .failed(let failure):
            return Notice(title: couldntFile, message: reason(failure) + typed(record))
        case .filed(let outcome):
            var problems: [String] = []
            switch outcome.lock {
            case .locked: break
            case .notLocked: problems.append(notLocked)
            case .unverified: problems.append(unverified)
            }
            if case .notUpdated(let failure) = outcome.index {
                problems.append(reason(failure) + typed(record))
            }
            guard !problems.isEmpty else { return nil }
            return Notice(
                title: "The copy was filed, but not everything worked.",
                message: problems.joined(separator: "\n\n"))
        }
    }

    private static let couldntFile = "Scene It couldn't file a copy."

    /// Asked before quitting or closing the book while the dialog holds typed text. Cancel is
    /// first, so it's the default (Return); its label also answers Escape.
    public static func unfiledDraftAlert(_ record: FilingRecord, leaving: Leaving) -> UnfiledDraftAlert {
        let (verb, anyway) =
            switch leaving {
            case .quit: ("Quit", "Quit Anyway")
            case .closeBook: ("Close", "Close Anyway")
            }
        return UnfiledDraftAlert(
            title: "\(verb) without filing the copy?",
            message: unfiled(record) + typed(record),
            buttons: [.init(choice: .cancel, label: cancel), .init(choice: .leaveAnyway, label: anyway)])
    }

    /// What wasn't filed, as the writer typed it: tags (a tag still being typed counts), a
    /// note, or both.
    static func unfiled(_ record: FilingRecord) -> String {
        switch (!record.tags.isEmpty, !record.note.isEmpty) {
        case (true, false): "The tags you typed haven't been filed."
        case (false, true): "The note you typed hasn't been filed."
        case (true, true), (false, false): "The tags and note you typed haven't been filed."
        }
    }

    /// "Your tags: "draft 4", "before the ending". Your note: "Before the rewrite"."
    static func typed(_ record: FilingRecord) -> String {
        var parts: [String] = []
        if !record.tags.isEmpty {
            parts.append("Your tags: " + record.tags.map(quoted).joined(separator: ", ") + ".")
        }
        if !record.note.isEmpty { parts.append("Your note: " + quoted(record.note) + ".") }
        return parts.isEmpty ? "" : "\n\n" + parts.joined(separator: " ")
    }

    private static func quoted(_ text: String) -> String {
        "\u{201C}\(text)\u{201D}"
    }

    private static func reason(_ failure: FilingFailure) -> String {
        switch failure {
        case .save(let error):
            "The book couldn't be saved first. " + QuitWording.reason(error)
        case .stillSaving:
            "The book is still being saved. Try again in a moment."
        case .bookChangedOnDisk:
            "Another program changed the book while it was being filed."
        case .copyDiffers:
            "The copy didn't match the book when it was read back, so it wasn't kept."
        case .archiveNotAFolder:
            "Something that isn't a folder is where the book's Archive folder should be."
        case .noFreeNumber:
            "The book's Archive folder already holds a copy numbered \(FiledCopyNumber.highest.fileName), "
                + "the highest number Scene It uses, or every name after the last copy is taken."
        case .unavailable:
            "The book was closed, so nothing was filed."
        case .fileSystem(let error):
            "The disk reported a problem: \(error.cause)."
        }
    }

    private static let notLocked =
        "This disk can't lock files, so other programs could change the copy. Scene It never will."
    private static let unverified =
        "Scene It locked the copy but couldn't check that the lock held. It checks again the next "
        + "time the book opens."

    private static func reason(_ failure: IndexFailure) -> String {
        switch failure {
        case .newerFormat:
            "The File Cabinet's list was saved by a newer version of Scene It, so this version leaves "
                + "it as it is. The copy will be listed without its tags or note."
        case .couldNotRead, .notWritten:
            "Scene It couldn't save the copy's tags and note to the File Cabinet's list yet. It tries "
                + "again with the next save while the book is open."
        }
    }
}

public typealias UnfiledDraftAlert = WriterAlert<UnfiledDraftChoice>

/// Leaving the book while File a Copy's dialog holds typed text.
public enum UnfiledDraftChoice: Hashable, Sendable {
    case cancel
    /// Leave, losing what's typed in the dialog.
    case leaveAnyway
}
