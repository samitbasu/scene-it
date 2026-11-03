import AppKit

/// A text view with no input method (ADR 0028), for every editor of manuscript text: the page,
/// the title field and the notes. Keys reach it through the key bindings alone, as `insertText`,
/// so there's no dead key, press-and-hold accent or IME composition, and it never holds marked
/// text. Whatever it's given, its owner puts through the character policy.
class KeyboardTextView: NSTextView {
    override var inputContext: NSTextInputContext? {
        nil
    }

    /// Without an input context nothing should call this; if anything does, its text is typed
    /// rather than marked.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        insertText(string, replacementRange: replacementRange)
    }
}
