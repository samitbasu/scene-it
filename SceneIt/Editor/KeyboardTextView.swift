import AppKit

/// A text view with no input method (ADR 0028), for every editor of manuscript text: the page,
/// the title field and the notes. Keys reach it through the key bindings alone, as `insertText`,
/// so there's no dead key, press-and-hold accent or IME composition, and it never holds marked
/// text. Whatever it's given, its owner puts through the character policy. Text neither drops
/// into it nor drags out of it (ADR 0036): it arrives typed or pasted.
class KeyboardTextView: NSTextView {
    // MARK: No automatic text changes (#127)

    /// What text checking may do: mark spelling and grammar. Every other type changes the
    /// writer's words for them (correction, replacement, quotes, dashes, links, data,
    /// capitalization, a period for a double space).
    static let checkedTypes: NSTextCheckingTypes =
        NSTextCheckingResult.CheckingType.spelling.rawValue
        | NSTextCheckingResult.CheckingType.grammar.rawValue

    /// Turns off what AppKit turned on from the writer's System Settings as the view was made.
    /// Every subclass's setup calls this; after it, the overrides below keep them off.
    func leaveTheWritersWordsAlone() {
        enabledTextCheckingTypes = super.enabledTextCheckingTypes
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        inlinePredictionType = .no
    }

    /// Spelling correction, text replacement, smart quotes and dashes, and link and data
    /// detection are bits of this. Their own switches below set those bits without coming
    /// through here, so each is held off as well.
    override var enabledTextCheckingTypes: NSTextCheckingTypes {
        get { super.enabledTextCheckingTypes }
        set { super.enabledTextCheckingTypes = newValue & Self.checkedTypes }
    }

    /// Where AppKit applies what a check found: only its spelling and grammar marks get through.
    override func handleTextCheckingResults(
        _ results: [NSTextCheckingResult], forRange range: NSRange, types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:], orthography: NSOrthography, wordCount: Int
    ) {
        super.handleTextCheckingResults(
            results.filter { $0.resultType.rawValue & Self.checkedTypes != 0 }, forRange: range,
            types: checkingTypes & Self.checkedTypes, options: options, orthography: orthography,
            wordCount: wordCount)
    }

    override var isAutomaticSpellingCorrectionEnabled: Bool {
        get { super.isAutomaticSpellingCorrectionEnabled }
        set { super.isAutomaticSpellingCorrectionEnabled = false }
    }

    override var isAutomaticTextReplacementEnabled: Bool {
        get { super.isAutomaticTextReplacementEnabled }
        set { super.isAutomaticTextReplacementEnabled = false }
    }

    override var isAutomaticQuoteSubstitutionEnabled: Bool {
        get { super.isAutomaticQuoteSubstitutionEnabled }
        set { super.isAutomaticQuoteSubstitutionEnabled = false }
    }

    override var isAutomaticDashSubstitutionEnabled: Bool {
        get { super.isAutomaticDashSubstitutionEnabled }
        set { super.isAutomaticDashSubstitutionEnabled = false }
    }

    override var isAutomaticLinkDetectionEnabled: Bool {
        get { super.isAutomaticLinkDetectionEnabled }
        set { super.isAutomaticLinkDetectionEnabled = false }
    }

    override var isAutomaticDataDetectionEnabled: Bool {
        get { super.isAutomaticDataDetectionEnabled }
        set { super.isAutomaticDataDetectionEnabled = false }
    }

    override var isAutomaticTextCompletionEnabled: Bool {
        get { super.isAutomaticTextCompletionEnabled }
        set { super.isAutomaticTextCompletionEnabled = false }
    }

    override var smartInsertDeleteEnabled: Bool {
        get { super.smartInsertDeleteEnabled }
        set { super.smartInsertDeleteEnabled = false }
    }

    override var inlinePredictionType: NSTextInputTraitType {
        get { super.inlinePredictionType }
        set { super.inlinePredictionType = .no }
    }

    /// Their actions, from a menu or the Substitutions panel, pass this view by.
    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        !AutomaticTextChanges.actions.contains(aSelector) && super.responds(to: aSelector)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event)?.copy() as? NSMenu else { return nil }
        AutomaticTextChanges.hide(in: menu)
        return menu
    }

    override var inputContext: NSTextInputContext? {
        nil
    }

    /// Writing Tools rewrites text through paths the character policy's veto may never see, so
    /// it's off for good; setting it does nothing.
    override var writingToolsBehavior: NSWritingToolsBehavior {
        get { .none }
        set {}
    }

    // MARK: No drag and drop (ADR 0036)

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        []
    }

    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        false
    }

    /// A press on the selection followed by a drag starts a drag here when presses go through
    /// `mouseDown`: always before macOS 27, and from it in a view that overrides `mouseDown`, as
    /// the page does.
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        false
    }

    /// From macOS 27 a text view that leaves `mouseDown` alone is its own
    /// `NSTextSelectionManager`'s delegate, and the manager asks it for the drag of a pressed
    /// selection; `NSTextView` doesn't declare the method, so this replaces it by its selector.
    /// `nil` means no drag.
    @available(macOS 27, *)
    @objc(selectionManager:makeDraggingSessionWithGesture:)
    func selectionManager(_ manager: NSTextSelectionManager, makeDraggingSession gesture: NSGestureRecognizer)
        -> NSDraggingSession?
    {
        nil
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
