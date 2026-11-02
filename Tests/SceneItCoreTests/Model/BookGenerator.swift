import Foundation

@testable import SceneItCore

/// Random books from a seed that satisfy the model's invariants (book format §7.5), for
/// round-trip properties. Runs are maximal, as the parser makes them, so a parsed book can
/// be compared with the one that was written.
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

    /// Characters that need escaping or look like structure, plus Latin-1 beyond ASCII.
    static let lineAlphabet = Array("abc XYZ  \u{E9}\u{FF}\u{A0}\"\\/<>&{}[]:,*_~#-|!`.")
    private static let anyAlphabet = lineAlphabet + ["\n"]
    private static let words = [
        "# ", "- ", "---", "<br>", "**", "* ", " *", "~~", "\\", "## x", "c1-2", "\"q\"",
    ]

    mutating func book() -> Book {
        let scenes = (0..<int(0...4)).map { _ in scene() }
        let boneyard = (0..<int(0...2)).map { _ in scene() }
        return Book(
            title: string(Self.anyAlphabet, 0...12), scenes: scenes, boneyard: boneyard, errors: errors())
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
            comments: comments,
            errors: errors())
    }

    private mutating func paragraph(_ commentIDs: [CommentID]) -> Paragraph {
        let runs = (0..<int(0...4)).map { _ in
            Run(
                text(),
                styles: Set(TextStyle.allCases.filter { _ in Bool.random(using: &random) }),
                color: Bool.random(using: &random) ? pick(TextColor.allCases) : nil,
                highlight: Bool.random(using: &random) ? pick(HighlightColor.allCases) : nil,
                comments: Set(commentIDs.filter { _ in Bool.random(using: &random) }))
        }
        return Paragraph(Self.merged(runs))
    }

    private mutating func text() -> String {
        Bool.random(using: &random)
            ? pick(Self.words) + string(Self.lineAlphabet, 0...6) : string(Self.lineAlphabet, 1...16)
    }

    static func merged(_ runs: [Run]) -> [Run] {
        runs.reduce(into: []) { merged, run in
            if var last = merged.last, last.styles == run.styles, last.color == run.color,
                last.highlight == run.highlight, last.comments == run.comments
            {
                last.text += run.text
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
    }

    private mutating func errors() -> [ErrorEntry] {
        (0..<int(0...2)).map { _ in
            var payload = string(Self.lineAlphabet, 0...20).trimmingCharacters(in: .init(charactersIn: " "))
            while payload.hasSuffix("\\") { payload.removeLast() }
            return ErrorEntry(
                pick(ErrorTag.allCases), payload.trimmingCharacters(in: .init(charactersIn: " ")))
        }
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
