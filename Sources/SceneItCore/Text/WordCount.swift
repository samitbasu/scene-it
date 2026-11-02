/// How many words some text has, counted as Microsoft Word counts them (the owner's decision):
/// a word is a maximal run of non-whitespace characters, except that a run of punctuation alone
/// (a standalone `--`, `...` or `-`) isn't a word. So "well-known", "dawn--and", "don't" and
/// "“Quoted,”" are one word each.
public struct WordCount: Hashable, Comparable, Sendable {
    public let words: Int

    public init(words: Int) {
        self.words = words
    }

    public static let zero = WordCount(words: 0)

    /// Paragraph breaks always separate words.
    public init(_ paragraphs: [Paragraph]) {
        var words = 0
        for paragraph in paragraphs {
            var inRun = false
            var runHasWordCharacter = false
            for run in paragraph.runs {
                for scalar in run.text.unicodeScalars {
                    if scalar.properties.isWhitespace {
                        if inRun, runHasWordCharacter { words += 1 }
                        inRun = false
                        runHasWordCharacter = false
                    } else {
                        inRun = true
                        runHasWordCharacter = runHasWordCharacter || !Self.isPunctuation(scalar)
                    }
                }
            }
            if inRun, runHasWordCharacter { words += 1 }
        }
        self.words = words
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
            .initialPunctuation, .finalPunctuation, .otherPunctuation:
            true
        default:
            false
        }
    }

    public static func + (lhs: WordCount, rhs: WordCount) -> WordCount {
        WordCount(words: lhs.words + rhs.words)
    }

    public static func < (lhs: WordCount, rhs: WordCount) -> Bool {
        lhs.words < rhs.words
    }
}

extension BookScene {
    /// The body's words; the title isn't counted.
    public var wordCount: WordCount {
        WordCount(body)
    }
}

/// Each scene's word count, kept by `OpenBook` so an edit recounts only the scene whose body
/// changed, never the whole book.
public struct SceneWordCounts: Hashable, Sendable {
    private var counts: [SceneID: WordCount]
    /// How many scenes have been counted, for tests that prove an edit didn't recount.
    private(set) var countsMade = 0

    public init(_ book: Book) {
        counts = [:]
        for scene in book.scenes + book.boneyard { recount(scene) }
    }

    /// Counts `scene` again, after its body changed or it was added.
    public mutating func recount(_ scene: BookScene) {
        counts[scene.id] = scene.wordCount
        countsMade += 1
    }

    public subscript(_ scene: SceneID) -> WordCount {
        counts[scene] ?? .zero
    }

    /// The manuscript's words: every scene in the story, and none in the Boneyard (PLAN §7.3).
    /// Summed from the counts, so reordering or cutting scenes needs no recount.
    public func manuscript(of book: Book) -> WordCount {
        book.scenes.reduce(.zero) { $0 + self[$1.id] }
    }
}
