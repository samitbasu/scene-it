import AppKit
import SceneItCore
import SwiftUI
import Testing

@testable import SceneIt

/// Export to Word's Include comments (#183, ADR 0048): the save panel's accessory alone,
/// unticked and ticked, since the system panel around it can't be drawn offscreen; and a sample
/// .docx of the ferry scene with six comments, two of them overlapping and one running over a
/// paragraph break, to open in Word and Pages.
extension WindowRenders {
    @Test func wordComments() async throws {
        let output = try #require(renderFolder).appending(path: "word-comments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for choice in [WordCommentChoice.omit, .include] {
            let options = WordExportOptions()
            options.comments = choice
            let state = choice == .omit ? "unticked" : "ticked"
            let view = WordExportAccessory(options: options).background(
                Color(nsColor: .windowBackgroundColor))
            for scale in [1, 2] {
                let rep = try await Self.withHostedView(view) { Self.bitmap(of: $0, scale: scale) }
                try Self.png(rep).write(to: output.appending(path: "accessory-\(state)@\(scale)x.png"))
            }
        }
        let sample = try WordExport.document(of: Self.wordCommentsSample(), comments: .included(by: .account))
        try sample.write(to: output.appending(path: "sample-with-comments.docx"))
    }

    /// The ferry scene with six comments: "packed in the dark" and "in the dark, by feel"
    /// overlap, and "already ashore." runs into the next paragraph's "Nobody met her".
    static func wordCommentsSample() -> BookScene {
        let created = Timestamp("2026-11-03T10:15:00-08:00")!
        func comment(_ number: Int, _ color: PaletteColor, _ text: String) -> SceneItCore::Comment {
            SceneItCore::Comment(
                id: CommentID(rawValue: "01JC4K0000000000000000C0\(String(format: "%02d", number))"),
                color: color, text: text, created: created)
        }
        let schedule = comment(1, .red, "Check the ferry schedule for the 1950s.")
        let packed = comment(2, .blue, "Packed what? One case, or two?")
        let feel = comment(3, .green, "\"By feel\" -- echo this when she unpacks.")
        let girl = comment(4, .blue, "How old was she when she left?\nKeep this consistent with chapter 3.")
        let reveal = comment(5, .purple, "Too early for this reveal?")
        let ashore = comment(6, .pink, "Too neat. Let her see the letter go over the side instead?")
        let body: [Paragraph] = [
            [
                Run("The ferry left at dawn", comments: [schedule.id]),
                Run(", and Mara watched the harbor lights go out one by one behind her."),
            ],
            [
                Run("She had "), Run("packed ", comments: [packed.id]),
                Run("in the dark", comments: [packed.id, feel.id]), Run(", by feel", comments: [feel.id]),
                Run(", the way she used to as a "), Run("girl", comments: [girl.id]),
                Run(" when the house was asleep and leaving still seemed like a "),
                Run("game", styles: [.italic]), Run("."),
            ],
            [
                Run(
                    "Halfway across, the engine coughed and the deckhand swore at it in a language she half "
                        + "remembered. He found the "),
                Run("letter", color: .purple, comments: [reveal.id]),
                Run(" under the bench an hour later, but by then she was "),
                Run("already ashore.", highlight: .green, comments: [ashore.id]),
            ],
            [
                Run("Nobody met her", comments: [ashore.id]),
                Run(
                    " at the landing, which she had half expected and wholly dreaded. \"Well,\" she said to "
                        + "nobody -- and then, to the gulls, \"well...\""),
            ],
        ]
        return BookScene(
            id: SceneID(rawValue: "ferry"), modified: created, title: "The ferry", body: body,
            comments: [schedule, packed, feel, girl, reveal, ashore])
    }
}
