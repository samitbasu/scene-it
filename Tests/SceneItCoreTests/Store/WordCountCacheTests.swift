import Foundation
import Testing

@testable import SceneItCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WordCountCacheTests {
    @Test func onlyABodyEditRecountsAndOnlyItsScene() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let first = try #require(book.write("One two three"))
            let second = try #require(book.write("Four five"))
            #expect(book.manuscriptWordCount.words == 5)
            #expect(book.wordCounts[first].words == 3)

            let made = book.wordCounts.countsMade
            book.setTitle(of: first, to: "A title of five words")
            book.replaceNotes(of: first, with: [[Run("Notes are not counted")]])
            book.select(second)
            #expect(book.wordCounts.countsMade == made, "title, notes and selection don't recount")
            #expect(book.manuscriptWordCount.words == 5)

            book.replaceBody(of: second, with: [[Run("Four five six")]])
            #expect(book.wordCounts.countsMade == made + 1, "only the edited scene is counted")
            #expect(book.wordCounts[second].words == 3)
            #expect(book.manuscriptWordCount.words == 6)

            let third = try #require(book.addScene(after: first))
            #expect(book.wordCounts[third] == .zero)
            #expect(book.manuscriptWordCount.words == 6)
            #expect(book.manuscriptWordCount == WordCount(book.book.scenes.flatMap(\.body)))
        }
    }

    @Test func aBodyEditInABigBookStaysCheap() async throws {
        try await withTemporaryFolder { folder in
            let store = makeStore(in: folder)
            try await createBook("Novel", in: folder, store: store)
            let book = try #require(store.current)
            let paragraph: Paragraph = [Run(Array(repeating: "word", count: 200).joined(separator: " "))]
            var scenes: [SceneID] = []
            for _ in 0..<100 {
                let scene = try #require(book.addScene(after: nil))
                book.replaceBody(of: scene, with: Array(repeating: paragraph, count: 6))
                scenes.append(scene)
            }
            #expect(book.manuscriptWordCount.words == 120_000, "precondition: a 120k-word book")

            let made = book.wordCounts.countsMade
            let start = ContinuousClock.now
            for edit in 1...50 {
                book.replaceBody(
                    of: scenes[0], with: Array(repeating: paragraph, count: 6) + [[Run("x \(edit)")]])
                _ = book.manuscriptWordCount
            }
            #expect(book.wordCounts.countsMade == made + 50)
            #expect(book.manuscriptWordCount.words == 120_002)
            // Recounting the whole book on each edit took about 290 ms; 50 of those is ~15 s.
            #expect(ContinuousClock.now - start < .seconds(3))
        }
    }
}
