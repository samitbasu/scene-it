import AppKit
import Foundation
import Testing

@testable import SceneItCore

/// The adversarial review's properties (PR #64), kept as regression tests. `FUZZ_SALT`
/// varies the seeds; `ADV_ROUNDS` sets how many rounds each property runs.
@Suite struct AdversarialTests {
    static let rounds = Int(ProcessInfo.processInfo.environment["ADV_ROUNDS"] ?? "1500") ?? 1500

    // MARK: Text conservation

    /// Every word typed anywhere in a file, among any amount of structure and damage,
    /// survives parse → serialize: the parser drops nothing it can't place.
    @Test func everyWordSurvivesParseAndSerialize() throws {
        let noise = try FuzzDictionary.strings("book-noise")
        var random = SplitMix64(seed: fuzzSalt ^ 0xC0_5E4E)
        var markers = 0
        for round in 0..<Self.rounds {
            var expected: [String] = []
            var lines: [String] = []
            for _ in 0..<Int.random(in: 0...25, using: &random) {
                var line = ""
                for _ in 0..<Int.random(in: 0...4, using: &random) {
                    if Int.random(in: 0..<3, using: &random) == 0 {
                        markers += 1
                        let word = "wq" + String(markers)
                        expected.append(word)
                        line += " " + word + " "
                    } else {
                        line += noise.randomElement(using: &random)!
                    }
                }
                lines.append(line)
            }
            let separator = ["\n", "\n", "\n\n", "\r\n"].randomElement(using: &random)!
            var bytes = Array(lines.joined(separator: separator).utf8)
            if Int.random(in: 0..<4, using: &random) == 0, !bytes.isEmpty {
                bytes.insert(
                    UInt8.random(in: 0x80...0xFF, using: &random),
                    at: Int.random(in: 0..<bytes.count, using: &random))
            }
            let input = String(decoding: bytes, as: UTF8.self)
            let output = serialized(parse(Data(bytes)).book)
            for word in expected where input.contains(word) {
                #expect(output.contains(word), "round \(round) lost \(word)")
            }
        }
        #expect(markers > 1000, "precondition: words were placed")
    }

    // MARK: Escaping over books built through the model's API

    static let latin1: [Character] = (Array(0x20...0x7E) + Array(0xA0...0xFF)).map {
        Character(Unicode.Scalar(UInt8($0)))
    }
    static let tokens = [
        "# ", "## x", "### Notes", "# Boneyard", "- ", "-", "---", "<br>", "<BR/>", "<br />", "**", "*", "~~",
        "~",
        "\\", "\\\\", "\\n", "|", ",", "\"", "id: x", "key:", "  ", " ", "_", "`", "[line]", "- [line] x",
        "c0-1",
        "\u{A0}", "\u{AD}", "* * *", "***", "a*b*c", ":", "tags: a", "C:\\", "\u{1F30A}", "\u{2014}", "\t",
    ]

    /// Random books over the whole of Latin-1 and every token that looks like structure.
    struct Nasty {
        var random: SplitMix64

        mutating func pick<T>(_ options: [T]) -> T { options.randomElement(using: &random)! }
        mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &random) }
        mutating func bool() -> Bool { Bool.random(using: &random) }

        mutating func text(_ length: ClosedRange<Int>, newlines: Bool = false) -> String {
            var result = ""
            for _ in 0..<int(length) {
                switch int(0...4) {
                case 0: result += pick(AdversarialTests.tokens)
                case 1 where newlines: result += "\n"
                default: result.append(pick(AdversarialTests.latin1))
                }
            }
            return result
        }

        mutating func paragraph(_ ids: [CommentID]) -> Paragraph {
            if int(0...6) == 0 { return Paragraph([]) }
            let runs = (0..<int(1...5)).map { _ in
                Run(
                    text(0...4),
                    styles: Set(TextStyle.allCases.filter { _ in bool() }),
                    color: bool() ? pick(TextColor.allCases) : nil,
                    highlight: int(0...3) == 0 ? pick(HighlightColor.allCases) : nil,
                    comments: Set(ids.filter { _ in int(0...3) == 0 }))
            }
            return Paragraph(runs).withMaximalRuns
        }

        mutating func scene(_ number: Int) -> BookScene {
            let comments = (0..<int(0...3)).map { index in
                Comment(
                    id: CommentID(rawValue: "c\(index)"), color: pick(PaletteColor.allCases),
                    text: text(0...5, newlines: true),
                    created: Timestamp(secondsSince1970: Int64(int(0...2_000_000_000)), offset: .zero))
            }
            return BookScene(
                id: SceneID(rawValue: "s\(number)"),
                modified: Timestamp(secondsSince1970: 0, offset: .zero),
                title: SceneTitle(text(0...5, newlines: true)),
                tags: (0..<int(0...3)).map { _ in text(0...3, newlines: true) },
                body: (0..<int(0...4)).map { _ in paragraph(comments.map(\.id)) },
                notes: (0..<int(0...2)).map { _ in paragraph(comments.map(\.id)) },
                comments: comments,
                errors: (0..<int(0...2)).map { _ in
                    ErrorEntry(pick(ErrorTag.allCases), text(0...6, newlines: true))
                })
        }

        mutating func book() -> Book {
            let scenes = (0..<int(0...3)).map { scene($0) }
            let boneyard = (0..<int(0...2)).map { scene(10 + $0) }
            return Book(
                title: text(0...5, newlines: true), scenes: scenes, boneyard: boneyard,
                errors: (0..<int(0...2)).map { _ in
                    ErrorEntry(pick(ErrorTag.allCases), text(0...6, newlines: true))
                })
        }
    }

    /// Whatever the model's API lets a caller build reads back as itself, and its save
    /// verifies: the types admit only what the format can store (book format §7.5).
    @Test func booksBuiltThroughTheAPIReadBackAsThemselves() {
        var nasty = Nasty(random: SplitMix64(seed: fuzzSalt ^ 0x5E_41A1))
        for round in 0..<Self.rounds {
            let book = nasty.book()
            #expect(parse(BookFormat.serialize(book)).book == book, "round \(round)")
            #expect(throws: Never.self, "round \(round)") { try BookFormat.verifiedSerialization(of: book) }
        }
    }
}

/// Hand-editing gotchas (book format §3.7): what a writer typing in another editor gets.
@Suite struct HandEditingGotchaTests {
    @Test func aBackslashAtTheEndOfALineIsASpace() throws {
        let scene = try onlyScene(case: "s3.7-gotcha-backslash-at-line-end")
        #expect(scene.body.map(\.text) == ["The file is at C: ", "Or at C:\\"])
    }

    @Test func backslashNInCommentTextIsALineBreak() throws {
        let scene = try onlyScene(case: "s3.7-gotcha-backslash-n-in-comment-text")
        #expect(scene.comments.map(\.text) == ["see C:\new"])
    }

    @Test func asterisksInATitleAreFormattingAndAreDropped() throws {
        let scene = try onlyScene(case: "s3.7-gotcha-asterisks-in-title")
        #expect(scene.title == "Chapter 234 and a_b x")
    }
}

/// The paths the review found quadratic, now linear: doubling the input must not much
/// more than double the time. The bounds are generous (3× plus slack, with retries) so they
/// don't flake under load.
@Suite(.serialized) struct ScalingTests {
    private static let head =
        "---\ntitle: T\nformat: 2\n---\n\n## S\nid: s1\nmodified: 2026-01-01T00:00:00+00:00\n\n"

    /// Times both sizes, interleaved so a burst of load from other suites hits both, and
    /// keeps the fastest of three of each. A comparison gets three attempts: noise passes on
    /// a retry, but a quadratic path (4×) fails every one.
    private func expectLinear(
        _ what: String, sizes: (Int, Int), sourceLocation: SourceLocation = #_sourceLocation,
        _ work: (Int) -> () -> Void
    ) {
        let (smallWork, largeWork) = (work(sizes.0), work(sizes.1))
        var attempts: [(Duration, Duration)] = []
        for _ in 0..<3 {
            var small: [Duration] = []
            var large: [Duration] = []
            for _ in 0..<3 {
                small.append(ContinuousClock().measure(smallWork))
                large.append(ContinuousClock().measure(largeWork))
            }
            attempts.append((small.min()!, large.min()!))
            if large.min()! < small.min()! * 3 + .milliseconds(30) { return }
        }
        Issue.record(
            "\(what) grew faster than linearly: \(sizes.0) vs \(sizes.1) took \(attempts)",
            sourceLocation: sourceLocation)
    }

    private static func commentFile(count: Int) -> Data {
        let body = String(repeating: "abcdefghij ", count: count)
        let comments = (0..<count).map {
            "- c\($0) | red | 2026-01-01T00:00:00Z | c\($0 * 11)-\($0 * 11 + 10) | \"abcdefghij\" | note \($0)"
        }
        return Data((head + body + "\n\n### Comments\n" + comments.joined(separator: "\n") + "\n").utf8)
    }

    private static func wideCommentFile(count: Int) -> Data {
        let body = String(repeating: "abcdefghij ", count: 2000)
        let comments = (0..<count).map {
            "- c\($0) | red | 2026-01-01T00:00:00Z | c0-\(body.count - 1) | \"\(body.dropLast())\" | wide"
        }
        return Data((head + body + "\n\n### Comments\n" + comments.joined(separator: "\n") + "\n").utf8)
    }

    @Test func aParagraphWithManyRuns() {
        expectLinear("serialize", sizes: (4000, 8000)) { count in
            let book = parse(
                Data((Self.head + String(repeating: "wo*rd* ~~x~~ \\_ ", count: count) + "\n").utf8)
            ).book
            return { _ = BookFormat.serialize(book) }
        }
        expectLinear("parse", sizes: (4000, 8000)) { count in
            let data = Data((Self.head + String(repeating: "wo*rd* ~~x~~ \\_ ", count: count) + "\n").utf8)
            return { _ = parse(data) }
        }
    }

    @Test func manyComments() {
        expectLinear("parse", sizes: (1500, 3000)) { count in
            let data = Self.commentFile(count: count)
            return { _ = parse(data) }
        }
        expectLinear("serialize", sizes: (3000, 6000)) { count in
            let book = parse(Self.commentFile(count: count)).book
            return { _ = BookFormat.serialize(book) }
        }
    }

    @Test func overlappingWideComments() {
        expectLinear("parse", sizes: (15, 30)) { count in
            let data = Self.wideCommentFile(count: count)
            return { _ = parse(data) }
        }
        expectLinear("serialize", sizes: (30, 60)) { count in
            let book = parse(Self.wideCommentFile(count: count)).book
            return { _ = BookFormat.serialize(book) }
        }
    }

    @Test func longFreeText() {
        expectLinear("serialize", sizes: (200_000, 400_000)) { count in
            let text = String(repeating: "a\\b, \"c\" ", count: count / 10)
            var scene = plainScene(body: [[Run("x", comments: [CommentID(rawValue: "c")])]])
            scene.comments = [
                Comment(id: CommentID(rawValue: "c"), color: .red, text: text, created: openedAt)
            ]
            scene.tags = [text]
            let book = Book(title: text, scenes: [scene])
            return { _ = BookFormat.serialize(book) }
        }
    }

    /// Merging many neighbouring pieces of the same format admits the text once, not once
    /// per piece.
    @Test func manyPiecesOfOneFormat() {
        expectLinear("RunCodec.body(from:)", sizes: (5000, 10_000)) { count in
            let text = NSMutableAttributedString(string: String(repeating: "word ", count: count))
            for piece in stride(from: 0, to: count, by: 2) {
                text.addAttribute(.underlineStyle, value: 1, range: NSRange(location: piece * 5, length: 5))
            }
            return { _ = RunCodec.body(from: text) }
        }
        expectLinear("verifiedSerialization", sizes: (5000, 10_000)) { count in
            let book = Book(
                title: "T", scenes: [plainScene(body: [Paragraph((0..<count).map { _ in Run("word ") })])])
            return { _ = try? BookFormat.verifiedSerialization(of: book) }
        }
    }

    @Test func manyScenes() {
        expectLinear("parse", sizes: (5000, 10_000)) { count in
            let scenes = (0..<count).map { "## S\($0)\nid: s\($0)\nmodified: 2026-01-01T00:00:00Z\n\nx\n" }
            let data = Data(("---\ntitle: T\nformat: 2\n---\n\n" + scenes.joined(separator: "\n")).utf8)
            return { _ = parse(data) }
        }
    }
}
