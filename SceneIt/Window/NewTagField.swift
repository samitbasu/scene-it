import AppKit
import SceneItCore
import SwiftUI

/// The + tag field of the Tags tab, the Scenes sheet's cards and the File Cabinet's cards: an
/// `AdmittingTextField` (ADR 0028), so Return and Esc arrive as its field editor's commands. Return hands what's typed
/// to `add` and empties the field, which keeps the focus for the next tag (the owner, #20); Esc
/// empties it and calls `leave`, which says where the focus goes. The field's own typing history,
/// which ⌘Z undoes while it has the focus, goes with what it held.
struct NewTagField: NSViewRepresentable {
    let book: AppOpenBook
    /// What a tag added here changes: a scene's tags, or a filed copy's record.
    var kind = EditKind.manuscript
    let add: (String) -> Void
    let leave: (NSTextView) -> Void
    var opening = Opening.unfocused
    /// Called when the field stops being edited with nothing in it.
    var ended: (() -> Void)?

    /// Whether the field takes the focus as it appears.
    enum Opening {
        case unfocused, focused
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AdmittingTextField {
        let coordinator = context.coordinator
        coordinator.actions = (add, leave, ended)
        let editor = AdmittingTextView.fieldEditor(
            admitting: CharacterPolicy.admittedLine,
            editability: { [weak book, kind] in Editability(book, for: kind) })
        editor.history = coordinator.history
        let field = AdmittingTextField(string: "", editor: editor, lineBreakMode: .byClipping)
        field.font = .systemFont(ofSize: WindowMetrics.Tags.chipPointSize)
        field.bezelStyle = .roundedBezel
        field.placeholderString = TagWording.addPlaceholder
        field.setAccessibilityLabel(TagWording.addLabel)
        field.toolTip = TagWording.addHelp
        field.delegate = coordinator
        if opening == .focused { field.firstFocus = .pending }
        return field
    }

    func updateNSView(_ field: AdmittingTextField, context: Context) {
        context.coordinator.actions = (add, leave, ended)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: AdmittingTextField, context: Context)
        -> CGSize?
    {
        CGSize(width: proposal.width ?? field.fittingSize.width, height: field.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ field: AdmittingTextField, coordinator: Coordinator) {
        field.delegate = nil
        field.editor?.history = nil
        coordinator.actions = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var actions: (add: (String) -> Void, leave: (NSTextView) -> Void, ended: (() -> Void)?)?
        let history = UndoManager()

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let typed = textView.string
                empty(textView)
                actions?.add(typed)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                empty(textView)
                actions?.leave(textView)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field.stringValue.isEmpty else { return }
            actions?.ended?()
        }

        private func empty(_ textView: NSTextView) {
            textView.string = ""
            history.removeAllActions()
        }
    }
}
