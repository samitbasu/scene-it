import Foundation

/// Every string the writer sees from opening, creating and saving books, in one place so the
/// owner can review the wording as a whole. Drafts awaiting the owner's approval. The quit and
/// read-only alerts are in `QuitWording` and `ReadOnlyWording`.
public enum StoreWording {
    // MARK: Menus and panels

    public static let newBookMenuItem = "New Book…"
    public static let openBookMenuItem = "Open Book…"
    public static let saveMenuItem = "Save"
    public static let newBookPanelTitle = "New Book"
    public static let newBookPanelPrompt = "Create"
    public static let newBookDefaultName = "Untitled"
    public static let windowTitle = "Scene It"

    // MARK: Status bar (PLAN §4.5)

    public static func status(_ status: BookStatus) -> String {
        switch status {
        case .saved: "Saved"
        case .unsaved: "Unsaved changes"
        case .saving: "Saving…"
        case .failed(let error): "Not saved: " + QuitWording.reason(error)
        case .changedOnDisk: "Changed on disk"
        case .backupsNotWorking: "Backups aren't working"
        case .readOnly: "Read only"
        case .closed: "Closed"
        }
    }

    // MARK: Changed on disk (ADR 0018)

    public static func externalChangeAlert(_ error: SaveError, myEditsName: String) -> WriterAlert<
        ExternalChangeChoice
    > {
        let keepLabel = "Keep My Version"
        let otherLabel = "Open Other Version"
        let keep = WriterAlert<ExternalChangeChoice>.Button(choice: .keepMyVersion, label: keepLabel)
        let other = WriterAlert<ExternalChangeChoice>.Button(choice: .openOtherVersion, label: otherLabel)
        let separately = "saves your version as a separate book, “\(myEditsName)”, next to this one"
        let choices =
            "\(keepLabel) saves your version here and keeps the other one as a backup. "
            + "\(otherLabel) \(separately), then opens the other version."
        let alert = { (message: String, buttons: [WriterAlert<ExternalChangeChoice>.Button]) in
            WriterAlert(title: QuitWording.changedOnDiskTitle, message: message, buttons: buttons)
        }
        switch error {
        case .externallyModified(.changed):
            return alert(
                "Another program, such as a sync service or Scene It on another Mac, saved a different "
                    + "version of this book while you were working. Scene It stopped saving so neither "
                    + "version is lost.\n\n" + choices,
                [keep, other])
        case .externallyModified(.removed):
            return alert(
                "Another program removed this book's contents while you were working. Scene It stopped "
                    + "saving.\n\n\(keepLabel) saves your version in its place. \(otherLabel) \(separately).",
                [keep, other])
        case .externallyModified(.notAFile):
            let openMine = "Open My Version"
            return alert(
                "Another program replaced this book's contents with something Scene It can't read or save "
                    + "over. Scene It stopped saving.\n\n\(openMine) \(separately), and opens it.",
                [.init(choice: .openOtherVersion, label: openMine)])
        case .externallyModified(.keptAsConflict(let fileName)):
            return alert(
                "Another program changed this book while Scene It was saving it. Your version was saved, "
                    + "and the other version was kept inside the book as “\(fileName)”. Scene It stopped "
                    + "saving until you've seen this.",
                [.init(choice: .keepMyVersion, label: "Continue")])
        case .couldNotBackUpTheirVersion(let fileSystemError):
            return alert(
                "Scene It couldn't keep a backup of the other version (\(fileSystemError.cause)), so it "
                    + "didn't save over it.\n\n" + choices,
                [keep, other])
        case .encoding, .writeProtected, .fileSystem:
            return alert(choices, [keep, other])
        }
    }

    /// After "Open My Version", when the original can't be read.
    public static func openedMyVersion(_ copy: URL) -> Notice {
        Notice(
            title: "Scene It opened your version.",
            message: "Scene It saved your version as “\(bookName(copy))” and opened it, because the original "
                + "can't be read.")
    }

    /// Books asked for together, beyond the one opened (ADR 0021).
    public static func oneBookAtATime(open: URL?, addedToRecents others: [URL]) -> Notice {
        let opened = open.map { "“\(bookName($0))” is open. " } ?? ""
        return Notice(
            title: "Scene It opens one book at a time.",
            message: opened + "These books were added to Recent Books instead: "
                + others.map { "“\(bookName($0))”" }.joined(separator: ", ") + ".")
    }

    /// A book's name as the writer sees it in Finder: the package name without `.sceneit`.
    public static func bookName(_ package: URL) -> String {
        package.deletingPathExtension().lastPathComponent
    }

    /// "<Title> (my edits).sceneit", then "(my edits 2)", … when the name is taken. A title
    /// that can't name a file (empty, or only slashes and colons) uses the original's name.
    public static func myEditsFileName(title: String, original: URL, attempt: Int) -> String {
        let cleaned = title.map { "/:".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-.")))
        let base = cleaned.isEmpty ? bookName(original) : cleaned
        let suffix = attempt > 1 ? "my edits \(attempt)" : "my edits"
        return "\(base) (\(suffix)).\(PackageLayout.pathExtension)"
    }

    public static func copyFailed(_ error: CopyError) -> Notice {
        let cause =
            switch error {
            case .create(let error): createReason(error)
            case .save(let error): QuitWording.reason(error)
            }
        return Notice(
            title: "Scene It couldn't save your version as a separate book.",
            message: cause + " Your version is still open, and Scene It hasn't saved over the other one.")
    }

    // MARK: Opening and creating

    public static func loadFailed(_ error: LoadError, myEditsSavedAs copy: URL? = nil) -> Notice {
        let saved = copy.map {
            "Your version was saved as “\(bookName($0))”.\n\n"
        }
        let backups =
            error.backups.isEmpty
            ? "There are no backups (book.md.bak1…3) in the book."
            : "Backups in the book, newest first:\n"
                + error.backups.map {
                    "• \($0.slot), saved \($0.modified.formatted(date: .abbreviated, time: .shortened))"
                }
                .joined(separator: "\n")
        return Notice(
            title: "Scene It couldn't open “\(bookName(error.package))”.",
            message: (saved ?? "") + "\(error.problem).\n\n" + backups)
    }

    public static func createFailed(_ error: CreateError) -> Notice {
        if case .alreadyExists(let url) = error {
            return Notice(
                title: "There's already something named “\(url.lastPathComponent)” there.",
                message: "Scene It didn't replace it. Choose another name for the new book.")
        }
        return Notice(title: "Scene It couldn't create the book.", message: createReason(error))
    }

    private static func createReason(_ error: CreateError) -> String {
        switch error {
        case .missingPackageExtension: "A book's name must end in .\(PackageLayout.pathExtension)."
        case .alreadyExists: "Something with that name already exists."
        case .encoding: "Scene It found a problem in the book while preparing to save it."
        case .fileSystem(let error): QuitWording.reason(.fileSystem(error))
        }
    }
}
