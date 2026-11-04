import Foundation
import Testing

@testable import SceneItCore

/// Book format §6: every byte sequence parses, the parse can always be saved, and damage
/// stays local. Seeded, so a failure reproduces.
@Suite struct FuzzTests {
    @Test func randomBytesAlwaysParseToASaveableBook() throws {
        let structural = Array(try FuzzDictionary.tokens("book-bytes").joined())
        var random = SplitMix64(seed: fuzzSalt ^ 0xB0_0C)
        for round in 0..<3000 {
            let length = Int.random(in: 0...300, using: &random)
            let bytes = (0..<length).map { _ in
                Bool.random(using: &random)
                    ? structural.randomElement(using: &random)!
                    : UInt8.random(in: .min ... .max, using: &random)
            }
            let book = parse(Data(bytes)).book
            #expect(throws: Never.self, "round \(round)") { try BookFormat.verifiedSerialization(of: book) }
        }
    }

    @Test func randomLinesOfStructureAlwaysParseToASaveableBook() throws {
        let pieces = try FuzzDictionary.strings("book-lines")
        var random = SplitMix64(seed: fuzzSalt ^ 0x11_E5)
        for round in 0..<3000 {
            let text = (0..<Int.random(in: 0...30, using: &random)).map { _ in
                pieces.randomElement(using: &random)!
            }
            .joined(separator: "\n")
            let book = parse(text).book
            #expect(throws: Never.self, "round \(round)") { try BookFormat.verifiedSerialization(of: book) }
        }
    }

    // MARK: Mutations of valid files

    @Test func severalMutationsAlwaysParseToASaveableBook() throws {
        let mutator = try Mutator()
        var random = SplitMix64(seed: fuzzSalt ^ 0x5E_7E4A1)
        for base in try Self.bases() {
            for _ in 0..<250 {
                var bytes = [UInt8](base)
                for _ in 0..<Int.random(in: 2...6, using: &random) {
                    _ = mutator.mutate(&bytes, Mutation.allCases.randomElement(using: &random)!, &random)
                }
                let book = parse(Data(bytes)).book
                #expect(throws: Never.self) { try BookFormat.verifiedSerialization(of: book) }
            }
        }
    }

    private enum Mutation: CaseIterable {
        case insert, delete, flip, truncate, duplicateLine, insertStructure
    }

    private struct Mutator {
        /// The lines `insertStructure` inserts.
        let structureLines: [[UInt8]]

        init() throws {
            structureLines = try FuzzDictionary.tokens("book-insertions")
        }

        /// Mutates `bytes`, returning the half-open byte range of the original that the
        /// mutation touched.
        func mutate(_ bytes: inout [UInt8], _ mutation: Mutation, _ random: inout SplitMix64) -> Range<Int> {
            let index = Int.random(in: 0..<max(1, bytes.count), using: &random)
            switch mutation {
            case .insert:
                bytes.insert(UInt8.random(in: .min ... .max, using: &random), at: index)
                return index..<index
            case .delete:
                guard !bytes.isEmpty else { return 0..<0 }
                bytes.remove(at: index)
                return index..<index + 1
            case .flip:
                guard !bytes.isEmpty else { return 0..<0 }
                bytes[index] = UInt8.random(in: .min ... .max, using: &random)
                return index..<index + 1
            case .truncate:
                let count = bytes.count
                bytes.removeLast(count - index)
                return index..<Int.max
            case .duplicateLine, .insertStructure:
                let starts =
                    [0]
                    + bytes.indices.filter { bytes[$0] == ASCII.newline }.map { $0 + 1 }.filter {
                        $0 < bytes.count
                    }
                let at = starts.randomElement(using: &random) ?? 0
                let line: [UInt8]
                if mutation == .duplicateLine {
                    let from = starts.randomElement(using: &random) ?? 0
                    let end = bytes[from...].firstIndex(of: ASCII.newline).map { $0 + 1 } ?? bytes.count
                    line = Array(bytes[from..<end])
                } else {
                    line = structureLines.randomElement(using: &random)!
                }
                bytes.insert(contentsOf: line, at: at)
                return at..<at
            }
        }
    }

    /// Where each scene's lines are in a canonical file: from its `##` line up to the next
    /// scene's (a `# Boneyard` line counts as the scene before it).
    private static func sceneSpans(_ bytes: [UInt8]) -> [Range<Int>] {
        var starts: [Int] = []
        var lineStart = 0
        for index in 0...bytes.count where index == bytes.count || bytes[index] == ASCII.newline {
            let line = bytes[lineStart..<index]
            if line.starts(with: Array("## ".utf8)) || line.elementsEqual(Array("##".utf8)) {
                starts.append(lineStart)
            }
            lineStart = index + 1
        }
        return starts.indices.map { starts[$0]..<(($0 + 1 < starts.count) ? starts[$0 + 1] : bytes.count) }
    }

    /// The corpus's mutation bases, then generated books.
    private static func bases() throws -> [Data] {
        let url = try #require(Corpus.root).appending(path: "fuzz-seeds/mutation-bases.txt")
        let paths = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n")
        var bases = try paths.map { path in
            try Data(
                contentsOf: try #require(Corpus.root).appending(path: String(path)).appending(
                    path: "input.md"))
        }
        for seed in UInt64(1000)..<1006 {
            var generator = BookGenerator(seed: seed ^ fuzzSalt)
            bases.append(BookFormat.serialize(generator.book()))
        }
        return bases
    }

    private enum List {
        case story, boneyard
    }

    /// The book's scenes in file order, each with the list it's in.
    private static func placed(_ book: Book) -> [(list: List, scene: BookScene)] {
        book.scenes.map { (List.story, $0) } + book.boneyard.map { (List.boneyard, $0) }
    }

    /// How many lines are a `# Boneyard` heading, as §1.8 recognizes one.
    private static func boneyardHeadings(_ bytes: [UInt8]) -> Int {
        BookParser.lines(CharacterPolicy.fileText(BookTextDecoder.decode(Data(bytes)).text).bytes).count {
            line in
            if case .heading(1, let name) = Lexical.kind(of: line) {
                return Lexical.equalsIgnoringCase(name, "boneyard")
            }
            return false
        }
    }

    /// Whether `candidate` is `original` as it should read after damage elsewhere. Apart
    /// from moving between the lists, the spec lets that damage reach an untouched scene in
    /// exactly two ways (§6):
    /// - an earlier scene took its id, so it gets a fresh one and a notice (§2.2);
    /// - an earlier `# Boneyard` made the real one a second Boneyard heading, which is a
    ///   `[line]` entry of the scene it ends (§1.8).
    private static func isUndamaged(_ candidate: BookScene, original: BookScene) -> Bool {
        guard candidate != original else { return true }
        var restored = candidate
        restored.errors.removeAll {
            $0.tag == .line && Lexical.equalsIgnoringCase($0.payload.utf8, "# boneyard")
        }
        if let notice = restored.errors.last, notice.tag == .notice,
            notice.payload.hasPrefix("This scene's id \(original.id) was already used")
        {
            restored.id = original.id
            restored.errors.removeLast()
        }
        return restored == original
    }

    /// A scene the mutation didn't touch parses as before (see `isUndamaged`). Damage to a
    /// scene's heading can merge the scene into the one before, so that one counts as
    /// touched too; so does a scene whose first or last byte is next to the damage.
    @Test func damageStaysLocal() throws {
        let mutator = try Mutator()
        var random = SplitMix64(seed: fuzzSalt ^ 0xDA_4A6E)
        var checked = 0
        var mutatedFiles = 0
        for base in try Self.bases() {
            let original = [UInt8](base)
            let spans = Self.sceneSpans(original)
            let placedScenes = Self.placed(parse(base).book)
            try #require(placedScenes.count == spans.count, "precondition: every scene found")
            for _ in 0..<500 {
                var bytes = original
                let mutation = Mutation.allCases.randomElement(using: &random)!
                let touched = mutator.mutate(&bytes, mutation, &random)
                mutatedFiles += 1
                let after = parse(Data(bytes)).book
                #expect(throws: Never.self) { try BookFormat.verifiedSerialization(of: after) }
                let afterScenes = Self.placed(after)
                var affected = Set<Int>()
                for (index, span) in spans.enumerated() {
                    let widened = (span.lowerBound - 1)..<(span.upperBound + 1)
                    if touched.overlaps(widened) || (touched.isEmpty && widened.contains(touched.lowerBound))
                    {
                        affected.formUnion([index - 1, index])
                    }
                }
                // Adding, removing or breaking a `# Boneyard` line moves scenes between the
                // lists (§6's locality exceptions); otherwise each keeps its list.
                let listsMayChange = Self.boneyardHeadings(bytes) != Self.boneyardHeadings(original)
                var next = 0
                for (index, (list, scene)) in placedScenes.enumerated() where !affected.contains(index) {
                    checked += 1
                    let found = afterScenes[next...].firstIndex { candidate in
                        (listsMayChange || candidate.list == list)
                            && Self.isUndamaged(candidate.scene, original: scene)
                    }
                    #expect(
                        found != nil,
                        "scene \(index) changed, moved or was reordered though \(mutation) at \(touched) didn't touch it"
                    )
                    next = found.map { $0 + 1 } ?? next
                }
            }
        }
        #expect(mutatedFiles == 4000)
        #expect(checked > 10_000, "precondition: the property was exercised (\(checked) scenes)")
    }
}
