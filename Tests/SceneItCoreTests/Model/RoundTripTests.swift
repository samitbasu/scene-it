import Foundation
import Testing

@testable import SceneItCore

@Suite struct RoundTripTests {
    @Test func richFixtureDecodesToTheExpectedBook() throws {
        let decoded = try BookCoding.decode(try Fixture.data("rich-book"))
        #expect(decoded == (try RichBook.make()))
    }

    @Test func richFixtureCoversEveryAttribute() throws {
        let book = try RichBook.make()
        let scenes = book.scenes + book.boneyard
        let runs = scenes.flatMap { $0.body + $0.notes }.flatMap(\.runs)
        #expect(Set(runs.flatMap(\.styles)) == Set(TextStyle.allCases))
        #expect(runs.contains { $0.color != nil })
        #expect(runs.contains { $0.highlight != nil })
        #expect(runs.contains { $0.comments.count >= 2 }, "overlapping comments")
        #expect(!book.boneyard.isEmpty)
        #expect(book.boneyard.contains { !$0.comments.isEmpty })
        #expect(book.settings.voice != nil)
        #expect(Set(scenes.map(\.modified.offset)).count >= 3, "several UTC offsets")
    }

    @Test func encodeDecodeEncodeIsByteIdenticalForTheRichFixture() throws {
        let fixture = try Fixture.data("rich-book")
        let reencoded = try BookCoding.encode(try BookCoding.decode(fixture))
        #expect(reencoded == fixture)
    }

    @Test func encodingDoesNotDependOnTheMachineTimeZone() throws {
        let original = ProcessInfo.processInfo.environment["TZ"]
        defer {
            if let original { setenv("TZ", original, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        let fixture = try Fixture.data("rich-book")
        var generator = BookGenerator(seed: 7)
        let generated = generator.book()
        var outputs: [[Data]] = []
        for zone in ["America/Los_Angeles", "Asia/Kolkata"] {
            setenv("TZ", zone, 1)
            NSTimeZone.resetSystemTimeZone()
            try #require(TimeZone.current.identifier == zone)
            let first = try BookCoding.encode(try BookCoding.decode(fixture))
            let second = try BookCoding.encode(try BookCoding.decode(try BookCoding.encode(generated)))
            outputs.append([first, second])
        }
        #expect(outputs[0] == outputs[1])
        #expect(outputs[0][0] == fixture)
    }

    @Test(arguments: 0..<200)
    func generatedBooksRoundTrip(seed: UInt64) throws {
        var generator = BookGenerator(seed: seed)
        let book = generator.book()
        #expect(BookValidator.problems(in: book).isEmpty)
        let encoded = try BookCoding.encode(book)
        let decoded = try BookCoding.decode(encoded)
        #expect(decoded == book)
        #expect(try BookCoding.encode(decoded) == encoded)
    }

    @Test func absentAttributesAreOmittedRatherThanFalseOrNull() throws {
        let book = Book(
            title: "T",
            scenes: [
                BookScene(
                    id: SceneID(rawValue: "s"), modified: try timestamp("2026-01-01T00:00:00+00:00"),
                    title: "plain")
            ])
        let json = String(decoding: try BookCoding.encode(book), as: UTF8.self)
        for absent in ["bold", "italic", "strike", "\"color\"", "highlight", "voice", "null", "false"] {
            #expect(!json.contains(absent), "\(absent) should be omitted")
        }
    }
}
