import Foundation

/// The tags the writer can see in a book (PLAN §8.3): those of the story's scenes and the
/// Boneyard's, never a deleted scene's (ADR 0031). Tags that differ only in case are one tag,
/// shown in the book's spelling of it.
public struct BookTags: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        /// The book's spelling: of the case variants the scenes use, the one the most scenes
        /// use, and of those, the first in code-point order (so `Mara` before `mara`).
        public let tag: String
        /// How many scenes have the tag, in any case.
        public let scenes: Int
    }

    /// Most-used first; ties alphabetically, ignoring case.
    public let entries: [Entry]

    public init(_ book: Book) {
        self.init(book.visibleScenes)
    }

    init(_ scenes: [BookScene]) {
        var spellings: [String: [String: Int]] = [:]
        for scene in scenes {
            var seen: Set<String> = []
            for tag in scene.tags where seen.insert(SceneTag.key(tag)).inserted {
                spellings[SceneTag.key(tag), default: [:]][tag, default: 0] += 1
            }
        }
        entries = Self.sorted(
            spellings.values.map { variants in
                let spelling = variants.min { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }!
                return Entry(tag: spelling.key, scenes: variants.values.reduce(0, +))
            })
    }

    /// Most-used first; ties alphabetically, ignoring case.
    static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            $0.scenes != $1.scenes ? $0.scenes > $1.scenes : SceneTag.key($0.tag) < SceneTag.key($1.tag)
        }
    }

    /// What `typed`, as the writer typed it into the Tags tab, adds to a scene: `SceneTag.typed`
    /// in the book's spelling, if the book has the tag in any case (the owner, #20); `nil` if
    /// it's no tag.
    public func spelling(of typed: String) -> String? {
        guard let tag = SceneTag.typed(typed) else { return nil }
        return entries.first { SceneTag.key($0.tag) == SceneTag.key(tag) }?.tag ?? tag
    }
}

/// One scene tag (PLAN §8.3): stored without its `#`, one line `CharacterPolicy` admits.
public enum SceneTag {
    /// What two tags that are the same tag share: tags compare ignoring case, and admitted text
    /// is ASCII (ADR 0028), so lowercasing is exact.
    public static func key(_ tag: String) -> String {
        tag.lowercased()
    }

    /// Whether `tags` hold `tag` in any case.
    public static func contains(_ tags: [String], _ tag: String) -> Bool {
        tags.contains { key($0) == key(tag) }
    }

    /// The tag the writer means by `text`: admitted as one line, without the spaces around it
    /// and any leading `#`; `nil` if nothing is left.
    public static func typed(_ text: String) -> String? {
        var tag = CharacterPolicy.admittedLine(text).trimmingCharacters(in: .whitespaces)
        while tag.hasPrefix("#") { tag = String(tag.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return tag.isEmpty ? nil : tag
    }

    /// How the panel shows a tag (the mockup's `#Mara`).
    public static func shown(_ tag: String) -> String {
        "#" + tag
    }

    /// What the Search sheet searches for to find `tag` (PLAN §8.3's ⌕): the tag itself if it's
    /// one word, so its endings match as a word's do; otherwise its words as a quoted phrase, so
    /// they're found together. A `"` in the tag would end the phrase, so it becomes a space.
    public static func searchText(_ tag: String) -> String {
        if SearchQuery(tag).keywords.count <= 1, !tag.contains("\"") { return tag }
        return "\"" + tag.replacingOccurrences(of: "\"", with: " ") + "\""
    }
}
