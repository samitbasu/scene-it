import Foundation
import SceneItTestSupport
import Testing

@testable import SceneItCore

/// A sanity check, not a benchmark: a long novel (120,000 words) parses and serializes in
/// well under a second in a debug build run on its own (the printed times). The assertions
/// are loose enough to hold when other suites load the machine: a ceiling far above that,
/// and the novel costing about twice half of it (`expectLinear`).
@Suite struct PerformanceTests {
    static func novel(words: Int) -> Book {
        var random = SplitMix64(seed: 120)
        let vocabulary = [
            "the", "harbor", "Mara", "watched", "letter", "caf\u{E9}", "island", "and", "of", "gulls",
        ]
        let sceneCount = 60
        let scenes = (0..<sceneCount).map { number in
            let comment = CommentID(rawValue: "c\(number)")
            let paragraphs = (0..<(words / sceneCount / 100)).map { paragraph in
                func words(_ count: Int) -> String {
                    (0..<count).map { _ in vocabulary.randomElement(using: &random)! }.joined(separator: " ")
                }
                return Paragraph([
                    Run(words(40) + " ", comments: paragraph == 0 ? [comment] : []),
                    Run(words(3), styles: [.italic], color: paragraph == 1 ? .red : nil),
                    Run(" " + words(57)),
                ])
            }
            return BookScene(
                id: SceneID(rawValue: "scene\(number)"),
                modified: Timestamp(secondsSince1970: 0, offset: .zero),
                title: SceneTitle("Scene \(number)"), tags: ["draft"], body: paragraphs,
                notes: [[Run("A note.")]],
                comments: [
                    Comment(
                        id: comment, color: .blue, text: "Check.",
                        created: Timestamp(secondsSince1970: 0, offset: .zero))
                ])
        }
        return Book(title: "Long", scenes: scenes)
    }

    @Test func aLongNovelParsesAndSerializesQuickly() throws {
        let book = Self.novel(words: 120_000)
        let words = book.scenes.flatMap(\.body).map { $0.text.split(separator: " ").count }.reduce(0, +)
        #expect(words >= 120_000, "precondition: a long novel")
        let clock = ContinuousClock()
        var bytes = Data()
        let serializing = clock.measure { bytes = BookFormat.serialize(book) }
        var parsed: ParsedBook?
        let parsing = clock.measure { parsed = parse(bytes) }
        let verifying = clock.measure { _ = try? BookFormat.verifiedSerialization(of: book) }
        #expect(parsed?.book == book)
        print(
            "book format, \(words) words, \(bytes.count) bytes: serialize \(serializing), parse \(parsing), verified save \(verifying)"
        )
        #expect(serializing < .seconds(10))
        #expect(parsing < .seconds(10))
        expectLinear("parsing", doubling: 60_000) { words in
            let bytes = BookFormat.serialize(Self.novel(words: words))
            return { _ = parse(bytes) }
        }
    }
}
