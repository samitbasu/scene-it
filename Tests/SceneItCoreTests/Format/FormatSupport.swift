import Foundation
import Testing

@testable import SceneItCore

/// Fresh scene ids `id-A0`, `id-B0`, …, so tests can name the ids the parser hands out. The
/// corpus's parse defaults (Tests/Corpus/README.md) are these and `openedAt`.
struct LetteredIDs: SceneIDSource {
    private var next = 0

    mutating func sceneID() -> SceneID {
        defer { next += 1 }
        return SceneID(
            rawValue: "id-" + String(UnicodeScalar(UInt8(ascii: "A") + UInt8(next % 26))) + String(next / 26))
    }
}

extension SceneID {
    /// The `n`th id `LetteredIDs` hands out, from 0.
    static func lettered(_ n: Int) -> SceneID {
        var ids = LetteredIDs()
        for _ in 0..<n { _ = ids.sceneID() }
        return ids.sceneID()
    }
}

/// When the parsed book was "opened", for missing `modified` dates.
let openedAt = Timestamp(secondsSince1970: 1_793_635_200, offset: UTCOffset(minutes: -480)!)

func parse(_ data: Data) -> ParsedBook {
    var ids = LetteredIDs()
    return BookFormat.parse(data, opened: openedAt, ids: &ids)
}

func parse(_ text: String) -> ParsedBook {
    parse(Data(text.utf8))
}

func serialized(_ book: Book) -> String {
    String(decoding: BookFormat.serialize(book), as: UTF8.self)
}

/// A file holding just the front matter and `body` as one scene's text.
func file(scene body: String) -> String {
    "---\ntitle: T\nformat: 2\n---\n\n## S\nid: s1\nmodified: 2026-01-01T00:00:00+00:00\n\n" + body + "\n"
}

/// The only scene of `text`, which must have exactly one.
func onlyScene(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> BookScene {
    let book = parse(text).book
    try #require(book.scenes.count == 1 && book.boneyard.isEmpty, sourceLocation: sourceLocation)
    return book.scenes[0]
}

/// Whatever `scene` holds, made into a file.
func file(_ scene: BookScene) -> String {
    serialized(Book(title: "T", scenes: [scene]))
}

func plainScene(body: [Paragraph] = [], notes: [Paragraph] = []) -> BookScene {
    BookScene(
        id: SceneID(rawValue: "s1"), modified: Timestamp(secondsSince1970: 0, offset: .zero), title: "S",
        body: body, notes: notes)
}

/// Mixed into every fuzz and property seed. `FUZZ_SALT=<n> swift test` explores new cases;
/// a failure reproduces with the same salt.
let fuzzSalt = UInt64(ProcessInfo.processInfo.environment["FUZZ_SALT"] ?? "0") ?? 0
