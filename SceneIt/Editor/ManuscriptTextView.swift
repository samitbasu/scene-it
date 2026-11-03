import AppKit
import SceneItCore
import SwiftUI

extension NSPasteboard.PasteboardType {
    static let pageClip = Self(PageClip.pasteboardType)
}

/// The page (PLAN §4.3, §6): a TextKit 2 text view that draws itself as a white US Letter page
/// with 1 in margins on the gray desk, and grows downward as the scene does. It holds the
/// scene's body only (decision 0015); `PageEditor` keeps it in step with the model.
final class ManuscriptTextView: NSTextView {
    weak var editor: PageEditor?
    /// While the input method updates its marked (uncommitted) text, which the character
    /// policy leaves alone until it's committed.
    private(set) var isComposing = false

    static func page() -> ManuscriptTextView {
        let view = ManuscriptTextView(usingTextLayoutManager: true)
        view.isRichText = true
        view.importsGraphics = false
        view.allowsImageEditing = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        // `CharacterPolicy` would only straighten them again.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.usesInspectorBar = false
        view.drawsBackground = true
        view.backgroundColor = NSColor(WindowMetrics.deskColor)
        view.insertionPointColor = .black
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: WindowMetrics.pageSize.height + 2 * WindowMetrics.deskPadding)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.typingAttributes = ParagraphRole.body.typingAttributes
        return view
    }

    // MARK: The page on the desk

    /// The white sheet, centred on the desk, as tall as the text needs and never shorter
    /// than a page.
    var pageRect: NSRect {
        let width = WindowMetrics.pageSize.width
        let x = max(WindowMetrics.deskPadding, (bounds.width - width) / 2)
        return NSRect(
            x: x, y: WindowMetrics.deskPadding, width: width,
            height: max(WindowMetrics.pageSize.height, bounds.height - 2 * WindowMetrics.deskPadding))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let page = pageRect
        let inset = NSSize(
            width: page.minX + WindowMetrics.pageMargin,
            height: WindowMetrics.deskPadding + WindowMetrics.pageMargin)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func drawBackground(in rect: NSRect) {
        backgroundColor.setFill()
        rect.fill()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(WindowMetrics.pageShadow.opacity)
        shadow.shadowBlurRadius = WindowMetrics.pageShadow.radius
        shadow.shadowOffset = NSSize(width: 0, height: -WindowMetrics.pageShadow.drop)
        shadow.set()
        NSColor.white.setFill()
        pageRect.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { editor?.keyboardFocusChanged(.page) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { editor?.keyboardFocusChanged(.elsewhere) }
        return resigned
    }

    // MARK: Keys

    /// PLAN §8.4: Tab moves the focus on rather than typing a tab, which the body can't hold.
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    /// Shift-Tab at the very start of the body goes back to the title (decision 0015).
    override func insertBacktab(_ sender: Any?) {
        if selectedRange() == NSRange(location: 0, length: 0) {
            editor?.focus.focusTitle()
        } else {
            super.insertBacktab(sender)
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        do {
            isComposing = true
            defer { isComposing = false }
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
        editor?.compositionMayHaveEnded()
    }

    override func unmarkText() {
        super.unmarkText()
        editor?.compositionMayHaveEnded()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        editor?.compositionMayHaveEnded()
    }

    // MARK: The pasteboard (decision 0017)

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.pageClip] + super.writablePasteboardTypes
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .pageClip else { return super.writeSelection(to: pboard, type: type) }
        guard let data = editor?.clipData(of: selectedRanges.map(\.rangeValue)) else { return false }
        return pboard.setData(data, forType: type)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        PageEditor.readableTypes
    }

    /// Every paste and drop arrives here, and goes through the codec and the character policy.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        editor?.paste(from: pboard, type: type) ?? false
    }

    // MARK: Edits

    /// Replaces each range with its string as one undoable change, and puts the caret after the
    /// last. A string replacing text takes that text's format, comments included, as Find and
    /// Replace or a spelling correction would: the format of the first character it replaces,
    /// when it spans several runs. A string inserted at the caret takes the typing attributes.
    func replace(_ ranges: [NSRange], with strings: [String]) {
        guard let storage = textStorage, ranges.count == strings.count,
            shouldChangeText(inRanges: ranges.map(NSValue.init(range:)), replacementStrings: strings)
        else { return }
        let formats = ranges.map { range in
            range.length > 0 && range.location < storage.length
                ? ParagraphRole.body.attributes(
                    normalizing: storage.attributes(at: range.location, effectiveRange: nil))
                : typingAttributes
        }
        storage.beginEditing()
        for ((range, string), attributes) in zip(zip(ranges, strings), formats).reversed() {
            storage.replaceCharacters(
                in: range, with: NSAttributedString(string: string, attributes: attributes))
        }
        storage.endEditing()
        didChangeText()
        let shift = zip(ranges, strings).dropLast().reduce(0) { $0 + $1.1.utf16.count - $1.0.length }
        if let last = ranges.last, let string = strings.last {
            setSelectedRange(NSRange(location: last.location + shift + string.utf16.count, length: 0))
        }
    }
}
