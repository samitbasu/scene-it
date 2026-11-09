import AppKit
import SceneItCore

extension AdmittingTextField {
    /// A scene's title field (decision 0015): one line, spelling checked as the writer types,
    /// "Untitled scene" while it's empty. The page's title strip and a new card in the Scenes
    /// sheet both use it, with a `TitleFieldCoordinator` as its delegate.
    static func sceneTitle(_ title: String, in book: AppOpenBook) -> AdmittingTextField {
        let editor = AdmittingTextView.fieldEditor(
            admitting: { SceneTitle(pasted: $0).text },
            editability: { [weak book] in Editability(book, for: .manuscript) })
        editor.isContinuousSpellCheckingEnabled = true
        let field = AdmittingTextField(string: title, editor: editor, lineBreakMode: .byTruncatingTail)
        field.bezelStyle = .roundedBezel
        field.placeholderString = WindowWording.untitledScene
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
}

/// Writes what's typed in a scene's title field into the book as it's typed, so the title is
/// saved, filed and kept on quitting like any other edit, and Undo in the field goes on the
/// scene's own title history (`OpenBook.titleUndo(for:)`).
class TitleFieldCoordinator: NSObject, NSTextFieldDelegate {
    var book: AppOpenBook?
    var scene: SceneID?
    weak var field: AdmittingTextField?
    /// The scene whose title is being edited: fixed when the editing begins, so typing can't
    /// reach a scene opened since.
    private var editing: SceneID?
    private let heardUndo = HeardUndo()

    /// Points the field at `scene` of `book`, and its Undo at that scene's title history.
    func show(_ scene: SceneID, of book: AppOpenBook) {
        self.book = book
        self.scene = scene
        let history = book.titleUndo(for: scene)
        field?.editor?.history = history
        heardUndo.hear(history, by: self, calling: #selector(historyChanged))
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        editing = scene
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        editing = nil
        endedEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        command(selector, in: textView)
    }

    /// A command the field editor is about to perform (Return, Tab, Esc): `true` if it was
    /// handled here instead.
    func command(_ selector: Selector, in textView: NSTextView) -> Bool {
        false
    }

    /// After the field stopped being edited, with the title written.
    func endedEditing() {}

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        sync(editor)
    }

    /// An undo or redo in the field changes its text without telling the field's delegate, so
    /// the title is taken from the field editor here instead.
    @objc func historyChanged(_ notification: Notification) {
        guard let editor = field?.currentEditor() as? NSTextView else { return }
        sync(editor)
    }

    private func sync(_ editor: NSTextView) {
        guard let book, let scene = editing ?? scene else { return }
        let typed = editor.string
        let title = SceneTitle(pasted: typed)
        book.setTitle(of: scene, to: title)
        guard !title.text.utf16.elementsEqual(typed.utf16) else { return }
        // A backstop: the editor's veto keeps out what the title can't hold, so only an edit
        // that skipped it gets here. Mid-undo the text is between two steps of a change that
        // ends admitted, so it's left alone.
        if let history = editor.undoManager, history.isUndoing || history.isRedoing { return }
        let caret = min(editor.selectedRange().location, (typed as NSString).length)
        let before = (typed as NSString).substring(to: caret)
        let all = NSRange(location: 0, length: (typed as NSString).length)
        guard let storage = editor.textStorage,
            editor.shouldChangeText(in: all, replacementString: title.text)
        else { return }
        storage.replaceCharacters(in: all, with: title.text)
        editor.didChangeText()
        editor.setSelectedRange(NSRange(location: SceneTitle(pasted: before).text.utf16.count, length: 0))
    }
}
