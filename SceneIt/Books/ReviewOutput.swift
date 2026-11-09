import AppKit
import SceneItCore

/// Copy Review and Save Review… (ADR 0029, review format §5–§7) for the open review, from the
/// File menu. Both put out the review as it is now, saved or not, and work on a read-only review.
extension BookController {
    /// The open review, while it has comments or notes to put out.
    var shareableReview: AppOpenBook? {
        guard let book = store.current, book.hasReviewReport else { return nil }
        return book
    }

    /// Copy Review: the report as HTML and plain text, on the clipboard.
    func copyReview() {
        guard let report = shareableReview?.reviewReport(on: CalendarDay(.now, in: .current)) else { return }
        ReviewClipboard.put(report, on: reviewPasteboard)
    }

    /// Save Review…: the save panel asks where, and the store writes the page there. `nil` if the
    /// panel was cancelled or there's nothing to save.
    @discardableResult
    func saveReview() async -> SaveReviewResult? {
        guard let book = shareableReview, case .review(let context) = book.document,
            let url = await reviewDestination.choose(
                ReviewOutputWording.defaultFileName(copy: context.copyFile))
        else { return nil }
        return await store.saveReview(of: book, to: url, on: CalendarDay(.now, in: .current))
    }
}

/// Copy Review's two representations (review format §6), together on one pasteboard.
enum ReviewClipboard {
    static func put(_ report: ReviewReport, on pasteboard: NSPasteboard) {
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString(ReviewHTML.clipboard(report), forType: .html)
        pasteboard.setString(ReviewPlainText.text(report), forType: .string)
    }
}

extension SaveDestination {
    static let reviewPanel = savePanel(
        title: ReviewOutputWording.panelTitle, prompt: ReviewOutputWording.panelPrompt,
        fileExtension: ReviewOutputWording.fileExtension)
}
