import AppKit

/// A `KeyboardTextView` for plain text that applies the character policy's veto as the page
/// does: a change it can't hold is refused, and its admitted reading is made instead as one
/// undoable change. The title field and File a Copy's tags and note use it.
class AdmittingTextView: KeyboardTextView {
    /// What the text may hold of a replacement string (`CharacterPolicy.admittedLine` and the
    /// like).
    var admit: (String) -> String = { $0 }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?)
        -> Bool
    {
        guard let strings = replacementStrings, let admitted = Self.corrected(strings, by: admit) else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        let ranges = affectedRanges.map(\.rangeValue)
        guard let storage = textStorage,
            super.shouldChangeText(inRanges: affectedRanges, replacementStrings: admitted)
        else { return false }
        let selection = selectedRanges.map(\.rangeValue)
        storage.beginEditing()
        for (range, string) in zip(ranges, admitted).reversed() {
            storage.replaceCharacters(in: range, with: string)
        }
        storage.endEditing()
        didChangeText()
        let edits = zip(ranges, admitted).map { Edit(range: $0, length: $1.utf16.count) }
        selectedRanges = Self.selection(selection, after: edits).map(NSValue.init(range:))
        return false
    }
}
