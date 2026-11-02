import Foundation
import Testing

@testable import SceneItCore

/// The value stored in `Fixtures/rich-book.json`: every run attribute, overlapping
/// comments, a boneyard scene, several UTC offsets, and characters JSON must escape.
enum RichBook {
    static func make() throws -> Book {
        let c1 = CommentID(rawValue: "01JC4K0000000000000000C001")
        let c2 = CommentID(rawValue: "01JC4K0000000000000000C002")
        let c3 = CommentID(rawValue: "01JC4K0000000000000000C003")
        let ferry = BookScene(
            id: SceneID(rawValue: "01JC4K00000000000000000001"),
            modified: try timestamp("2026-10-31T20:54:00-07:00"),
            title: "The ferry",
            tags: ["opening", "Mara"],
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
                    Run(" \"quoted\" and/or back\\slash, café ☕️"),
                ],
            ],
            notes: [[Run("Check the tide tables.", color: .gray)]],
            comments: [
                Comment(
                    id: c2, color: .blue, text: "Overlaps the first.\nTwo lines.",
                    created: try timestamp("2026-10-31T20:41:30-07:00")),
                Comment(
                    id: c1, color: .purple, text: "Too early for this reveal?",
                    created: try timestamp("2026-10-31T20:40:00-07:00")),
            ])
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
            settings: BookSettings(
                zoom: try #require(Zoom(exactly: 1.25)),
                voice: "com.apple.voice.premium.en-US.Zoe",
                rate: try #require(SpeechRate(exactly: 0.5)),
                rightPanel: .notes,
                rightPanelOpen: .closed,
                scenesView: .lightTable),
            scenes: [ferry, station],
            boneyard: [cut])
    }
}
