import AppKit

/// A text view with no input method (ADR 0028), for every editor of manuscript text: the page,
/// the title field and the notes. Keys reach it through the key bindings alone, as `insertText`,
/// so there's no dead key, press-and-hold accent or IME composition, and it never holds marked
/// text. Whatever it's given, its owner puts through the character policy.
class KeyboardTextView: NSTextView {
    override var inputContext: NSTextInputContext? {
        nil
    }

    /// Writing Tools rewrites text through paths the character policy's veto may never see, so
    /// it's off for good; setting it does nothing.
    override var writingToolsBehavior: NSWritingToolsBehavior {
        get { .none }
        set {}
    }

    /// Without an input context nothing should call this; if anything does, its text is typed
    /// rather than marked, without the attributes marked text carries.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let plain = (string as? NSAttributedString)?.string ?? string
        insertText(plain, replacementRange: replacementRange)
    }

    /// The character policy's veto, for an editor to apply before every change: `strings` as
    /// `admit` leaves them, or `nil` if it leaves every one as it is.
    static func corrected(_ strings: [String], by admit: (String) -> String) -> [String]? {
        let admitted = strings.map(admit)
        // Code units, not `String ==`, which calls canonically equivalent strings equal.
        return zip(admitted, strings).contains { !$0.utf16.elementsEqual($1.utf16) } ? admitted : nil
    }

    /// A range of the text replaced with `length` characters.
    struct Edit {
        let range: NSRange
        let length: Int
    }

    /// `selection` once `edits` (in text order, not overlapping) are made: a selected range that
    /// is one of the edited ranges, as when typing over it, becomes a caret after its
    /// replacement; every other edge stays with the text around it.
    static func selection(_ selection: [NSRange], after edits: [Edit]) -> [NSRange] {
        func moved(_ position: Int) -> Int {
            var shift = 0
            for edit in edits {
                let range = edit.range
                if position >= range.upperBound {
                    shift += edit.length - range.length
                } else if position > range.location {
                    return range.location + shift + edit.length
                } else {
                    break
                }
            }
            return position + shift
        }
        return selection.map { range in
            if edits.contains(where: { $0.range == range }) {
                return NSRange(location: moved(range.upperBound), length: 0)
            }
            let start = moved(range.location)
            return NSRange(location: start, length: max(0, moved(range.upperBound) - start))
        }
    }
}
