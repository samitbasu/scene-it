import AppKit
import SceneItCore
import SwiftUI

/// The center of the window (PLAN §4.3, ADR 0015): the editor control bar, the scene's title
/// field, and the page on its gray desk.
struct EditorArea: View {
    let book: AppOpenBook
    let preferences: AppPreferences
    let formatting: EditorFormatting
    let focus: PageFocus
    let editors: SceneEditors

    var body: some View {
        let scene = book.location.scene
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FormattingBar(formatting: formatting, part: .body)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: WindowMetrics.barHeight)
            Divider()
            if let scene {
                SceneTitleField(book: book, scene: scene.id, focus: focus)
                    .frame(width: WindowMetrics.pageSize.width)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, WindowMetrics.titleStripPadding)
                Divider()
                PageView(
                    book: book, preferences: preferences, editors: editors, scene: scene.id,
                    paragraphs: scene.body)
            } else {
                ScrollView(.vertical) {
                    Page {
                        Text(WindowWording.noSceneOpen)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(WindowMetrics.deskPadding)
                    .frame(maxWidth: .infinity)
                }
                .background(WindowMetrics.deskColor)
            }
        }
        .focusedSceneValue(\.page, focus)
    }
}

extension FocusedValues {
    /// The focused window's page, for View → Fit Width.
    @Entry var page: PageFocus?
}

extension EnvironmentValues {
    /// The window's page, for views that hand the focus back to it.
    @Entry var pageFocus: PageFocus?
}

/// An empty white US Letter page with 1 in margins, drawn as `ManuscriptTextView` draws a
/// scene's page.
private struct Page<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(WindowMetrics.pageMargin)
            .frame(width: WindowMetrics.pageSize.width, height: WindowMetrics.pageSize.height)
            .background(Color.white)
            .shadow(
                color: .black.opacity(WindowMetrics.pageShadow.opacity),
                radius: WindowMetrics.pageShadow.radius,
                y: WindowMetrics.pageShadow.drop)
    }
}

/// The scene's title (ADR 0015): one line of plain text, above the page rather than on it.
struct SceneTitleField: View {
    let book: AppOpenBook
    let scene: SceneID
    var focus = PageFocus()

    var body: some View {
        let label = WindowWording.titleLabel
        // The label sits in the page's left margin, so the field spans the text column.
        HStack(spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: WindowMetrics.pageMargin - WindowMetrics.titleLabelGap, alignment: .trailing)
                .padding(.trailing, WindowMetrics.titleLabelGap)
            TitleTextField(
                book: book, scene: scene, title: book.book.scene(scene)?.title.text ?? "", focus: focus
            )
            .disabled(!book.isEditable)
            Spacer(minLength: WindowMetrics.pageMargin)
        }
    }
}

/// The title's text field: Return and Tab go on to the body, and spelling is checked as the
/// writer types (decision 0015). Each scene's title has its own undo history. Opening another
/// scene ends the editing first, so what was typed stays in the scene it was typed in; if the
/// title had the focus, the next scene's title gets it.
private struct TitleTextField: NSViewRepresentable {
    let book: AppOpenBook
    let scene: SceneID
    let title: String
    let focus: PageFocus

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AdmittingTextField {
        let editor = AdmittingTextView.fieldEditor(admitting: { SceneTitle(pasted: $0).text })
        editor.isContinuousSpellCheckingEnabled = true
        let field = AdmittingTextField(string: title, editor: editor)
        context.coordinator.field = field
        let center = NotificationCenter.default
        center.addObserver(
            context.coordinator, selector: #selector(Coordinator.sceneWillSwitch),
            name: .openBookWillSwitchScene, object: book)
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            center.addObserver(
                context.coordinator, selector: #selector(Coordinator.historyChanged), name: name, object: nil)
        }
        field.bezelStyle = .roundedBezel
        field.placeholderString = WindowWording.untitledScene
        field.setAccessibilityLabel(WindowWording.titleLabel)
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        focus.title = field
        return field
    }

    func updateNSView(_ field: AdmittingTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.book = book
        coordinator.scene = scene
        coordinator.focus = focus
        field.editor?.history = book.titleUndo(for: scene)
        if field.currentEditor() == nil, field.stringValue != title { field.stringValue = title }
        if coordinator.resumesEditing {
            coordinator.resumesEditing = false
            DispatchQueue.main.async { [weak field] in
                guard let field, field.window?.makeFirstResponder(field) == true else { return }
                let end = (field.stringValue as NSString).length
                field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
            }
        }
        let enabled = context.environment.isEnabled
        if field.isEnabled != enabled || field.isEditable != enabled {
            if !enabled, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
            field.isEnabled = enabled
            field.isEditable = enabled
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var book: AppOpenBook?
        var scene: SceneID?
        var focus: PageFocus?
        weak var field: NSTextField?
        /// The scene whose title is being edited: fixed when the editing begins, so typing
        /// can't reach a scene opened since.
        private var editing: SceneID?
        /// Whether the title had the focus when the writer opened another scene.
        var resumesEditing = false

        @objc func sceneWillSwitch(_ notification: Notification) {
            guard let field, field.currentEditor() != nil else { return }
            resumesEditing = true
            field.window?.makeFirstResponder(nil)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            editing = scene
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            editing = nil
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let editor = Self.editor(notification) else { return }
            sync(editor)
        }

        /// An undo or redo in the field changes its text without telling the field's delegate,
        /// so the title is taken from the field editor here instead.
        @objc func historyChanged(_ notification: Notification) {
            guard let editor = field?.currentEditor() as? NSTextView,
                let history = notification.object as? UndoManager, history === editor.undoManager
            else { return }
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

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                focus?.focusBodyStart()
                return true
            default:
                return false
            }
        }

        private static func editor(_ notification: Notification) -> NSTextView? {
            notification.userInfo?["NSFieldEditor"] as? NSTextView
        }
    }
}
