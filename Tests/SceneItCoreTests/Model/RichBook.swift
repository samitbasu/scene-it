import Foundation
import Testing

@testable import SceneItCore

/// A book that uses every part of the model: every run attribute, overlapping and detached
/// comments, notes marks, an empty paragraph, error entries, a Boneyard scene, several UTC
/// offsets, and characters the format must escape.
enum RichBook {
    static func make() throws -> Book {
        let c1 = CommentID(rawValue: "01JC4K0000000000000000C001")
        let c2 = CommentID(rawValue: "01JC4K0000000000000000C002")
        let c3 = CommentID(rawValue: "01JC4K0000000000000000C003")
        let c4 = CommentID(rawValue: "c4")
        let ferry = BookScene(
            id: SceneID(rawValue: "01JC4K00000000000000000001"),
            modified: try timestamp("2026-10-31T20:54:00-07:00"),
            title: "The *ferry*, \\ and_more ",
            tags: ["opening", "Mara", "a, b", "#hash"],
            body: [
                [
                    Run("He found the "),
                    Run("letter", comments: [c1]),
                    Run(" under the", comments: [c1, c2]),
                    Run(" bench.", styles: [.italic], color: .purple, comments: [c2]),
                ],
                [],
                [
                    Run("Bold", styles: [.bold]),
                    Run(" struck", styles: [.strike], highlight: .green),
                    Run(" all three", styles: [.bold, .italic, .strike], color: .red, highlight: .pink),
                    Run(" \"quoted\" and/or back\\slash, caf\u{E9} * _ ~ "),
                ],
                [Run("# not a heading")],
            ],
            notes: [[Run("Check the ", color: .gray), Run("tide tables.", color: .gray, comments: [c4])]],
            comments: [
                Comment(
                    id: c2, color: .blue, text: "Overlaps the first.\nTwo lines.",
                    created: try timestamp("2026-10-31T20:41:30-07:00")),
                Comment(
                    id: c1, color: .purple, text: "Too early for this reveal? | maybe",
                    created: try timestamp("2026-10-31T20:40:00-07:00")),
                Comment(id: c4, color: .gray, text: "", created: try timestamp("2026-10-31T20:42:00-07:00")),
                Comment(
                    id: CommentID(rawValue: "gone"), color: .pink, text: " detached ",
                    created: try timestamp("2026-10-31T20:43:00-07:00")),
            ],
            errors: [ErrorEntry(.metadata, "mood: grim"), ErrorEntry(.notice, "Something was repaired.")])
        let station = BookScene(
            id: SceneID(rawValue: "01JC4K00000000000000000002"),
            modified: try timestamp("2026-11-01T09:15:07+05:30"),
            title: "The station",
            body: [[Run("Rain.")]])
        let cut = BookScene(
            id: SceneID(rawValue: "01JC4K00000000000000000003"),
            modified: try timestamp("2025-02-28T23:59:59+00:00"),
            title: "A cut scene",
            tags: ["cut"],
            body: [[Run("Gone", highlight: .red, comments: [c3])]],
            comments: [
                Comment(
                    id: c3, color: .black, text: "Why cut?",
                    created: try timestamp("2025-02-28T12:00:00-03:30"))
            ])
        return Book(
            title: "My Novel",
            scenes: [ferry, station],
            boneyard: [cut],
            errors: [ErrorEntry(.frontMatter, "author: S. Basu")])
    }
}
