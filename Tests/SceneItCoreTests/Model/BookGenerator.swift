import Foundation

@testable import SceneItCore

/// Random valid books from a seed, for round-trip properties.
struct BookGenerator {
    private var random: SplitMix64
    private var ids: IDGenerator<SplitMix64>

    init(seed: UInt64) {
        random = SplitMix64(seed: seed)
        var clock = SplitMix64(seed: ~seed)
        ids = IDGenerator(
            now: { Date(timeIntervalSince1970: Double.random(in: 0...4e9, using: &clock)) },
            random: SplitMix64(seed: seed &* 31))
    }

    private static let lineAlphabet = Array("abc XYZ é\"\\/\t\u{0}😀☕️—'<>&{}[]:,")
    private static let anyAlphabet = lineAlphabet + ["\n", "\r\n", "\u{2028}"]

    mutating func book() -> Book {
        let scenes = (0..<int(0...4)).map { _ in scene() }
        let boneyard = (0..<int(0...2)).map { _ in scene() }
        return Book(
            title: string(Self.anyAlphabet, 0...12), settings: settings(), scenes: scenes, boneyard: boneyard)
    }

    private mutating func settings() -> BookSettings {
        BookSettings(
            zoom: Zoom(clamping: Double.random(in: ZoomBounds.range, using: &random)),
            voice: Bool.random(using: &random) ? string(Self.lineAlphabet, 1...20) : nil,
            rate: SpeechRate(clamping: Float.random(in: SpeechRateBounds.range, using: &random)),
            rightPanel: pick(RightPanelTab.allCases),
            rightPanelOpen: pick([.open, .closed]),
            scenesView: pick(ScenesView.allCases))
    }

    private mutating func scene() -> BookScene {
        let comments = (0..<int(0...3)).map { _ in
            Comment(
                id: ids.commentID(), color: pick(PaletteColor.allCases),
                text: string(Self.anyAlphabet, 0...30),
                created: timestamp())
        }
        let commentIDs = comments.map(\.id)
        return BookScene(
            id: ids.sceneID(),
            modified: timestamp(),
            title: SceneTitle(string(Self.lineAlphabet, 0...16)),
            tags: (0..<int(0...3)).map { _ in string(Self.anyAlphabet, 1...8) },
            body: (0..<int(0...4)).map { _ in paragraph(commentIDs) },
            notes: (0..<int(0...2)).map { _ in paragraph(commentIDs) },
            comments: comments)
    }

    private mutating func paragraph(_ commentIDs: [CommentID]) -> Paragraph {
        Paragraph(
            (0..<int(0...4)).map { _ in
                Run(
                    string(Self.lineAlphabet, 1...16),
                    styles: Set(TextStyle.allCases.filter { _ in Bool.random(using: &random) }),
                    color: Bool.random(using: &random) ? pick(TextColor.allCases) : nil,
                    highlight: Bool.random(using: &random) ? pick(HighlightColor.allCases) : nil,
                    comments: Set(commentIDs.filter { _ in Bool.random(using: &random) }))
            })
    }

    private mutating func timestamp() -> Timestamp {
        let seconds = Double(Int64.random(in: -62_000_000_000...250_000_000_000, using: &random))
        let offset = TimeZone(secondsFromGMT: int(-14 * 60...14 * 60) * 60)!
        return Timestamp(Date(timeIntervalSince1970: seconds), in: offset)
    }

    private mutating func string(_ alphabet: [Character], _ length: ClosedRange<Int>) -> String {
        String((0..<int(length)).map { _ in pick(alphabet) })
    }

    private mutating func int(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &random)
    }

    private mutating func pick<T>(_ options: [T]) -> T {
        options.randomElement(using: &random)!
    }
}
