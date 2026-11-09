/// A review report as plain text (review format §6.3), Copy Review's other representation: styles
/// dropped, each passage in square brackets, blocks a blank line apart.
public enum ReviewPlainText {
    static let box = "\u{2610} "
    static let indent = "    "

    public static func text(_ report: ReviewReport) -> String {
        var blocks = [ReviewOutputWording.heading(report.title) + "\n" + ReviewOutputWording.date(report.day)]
        if !report.notes.isEmpty {
            blocks.append(underlined(ReviewOutputWording.generalNotes))
            blocks += report.notes.map(\.plain)
        }
        for scene in report.scenes {
            blocks.append(underlined(scene.title))
            blocks += scene.items.map(item)
            if !scene.notes.isEmpty {
                blocks.append(ReviewOutputWording.sceneNotesPlain)
                blocks += scene.notes.map(\.plain)
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func underlined(_ heading: String) -> String {
        heading + "\n" + String(repeating: "-", count: heading.count)
    }

    /// An anchored item's comment is indented under its quote. A line break in a comment starts
    /// another indented line, in a detached item too.
    private static func item(_ item: ReviewReport.Item) -> String {
        var lines = item.comment.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let quote = item.quote {
            if item.comment.isEmpty { lines = [] }
            lines.insert(quote.before.plain + "[" + quote.passage.plain + "]" + quote.after.plain, at: 0)
        }
        return ([box + lines[0]] + lines.dropFirst().map { indent + $0 }).joined(separator: "\n")
    }
}
