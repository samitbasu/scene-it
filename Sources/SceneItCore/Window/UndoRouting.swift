/// What has the keyboard focus in the main window, as far as undo is concerned.
public enum UndoFocus: Hashable, Sendable {
    /// A text view or field: the page, the notes, the scene's title, a field in a sheet.
    case text
    /// The Errors tab, which takes the focus when the writer deletes or fixes an entry, and
    /// keeps it until the writer goes back to the page.
    case errorsTab
    /// Anything else, or nothing.
    case elsewhere
}

/// The history Undo and Redo act on (PLAN §8.6). The toolbar's buttons and the Edit menu both
/// go where this says, so they can't disagree.
public enum UndoStack: Hashable, Sendable {
    /// The focused text view's own: a scene's page (`OpenBook.pageUndo(for:)`) or notes, or a
    /// field's.
    case focusedText
    /// `OpenBook.structureUndo`: changes to the book's scenes.
    case structure
    /// `OpenBook.errorsUndo`: the Errors tab's Delete and Fix.
    case errors
    /// Nothing to undo here.
    case none

    /// While a dialog is attached to the window (File a Copy's), only a text field in it: what's
    /// behind it can't be undone. Otherwise, while the Scenes sheet is open, the structure, unless
    /// a field in the sheet (a new scene's title, + tag, the filter) has the focus: then its own
    /// typing (#28). Otherwise what has the focus decides.
    public init(mode: WindowMode, focus: UndoFocus, dialog: UndoDialog) {
        if dialog == .attached {
            self = focus == .text ? .focusedText : .none
            return
        }
        if mode == .scenes {
            self = focus == .text ? .focusedText : .structure
            return
        }
        switch focus {
        case .text: self = .focusedText
        case .errorsTab: self = .errors
        case .elsewhere: self = .none
        }
    }
}

/// Whether a dialog (an AppKit sheet) is attached to the window, which takes the focus that
/// decides from the window behind it.
public enum UndoDialog: Hashable, Sendable {
    case none
    case attached
}
