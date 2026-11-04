/// The Search sheet's scopes (PLAN §9.1); File Cabinet arrives with #34.
///
/// The sheet narrows the units it gives the engine (owner, #31), so a scope's exact and near
/// matches are its own: a scene with only near matches still shows them under This scene
/// when another scene has an exact match.
public enum SearchScope: Hashable, Sendable, CaseIterable {
    /// The open scene, even in the Boneyard. Nothing when no scene is open.
    case thisScene
    /// Every scene, the Boneyard's too.
    case wholeBook

    public func units(of all: [SearchUnit], openScene: SceneID?) -> [SearchUnit] {
        switch self {
        case .wholeBook: all
        case .thisScene: openScene.map { scene in all.filter { $0.scene == scene } } ?? []
        }
    }
}

/// One of the sheet's checkboxes, each turning on one of the query's `SearchOptions`.
public enum SearchCheckbox: Hashable, Sendable, CaseIterable {
    case searchTags
    case matchCase
    case wholeWord

    public var option: SearchOptions {
        switch self {
        case .searchTags: .searchTags
        case .matchCase: .matchCase
        case .wholeWord: .wholeWord
        }
    }
}

/// How many near matches the sheet lists (owner, #31): the best scenes, until the writer asks
/// for every one.
public enum NearMatchLimit: Hashable, Sendable {
    case best
    case all

    /// The scenes `best` lists. Each scene is one row, its best hit, so this is also the rows.
    public static let bestCount = 20
}

/// What the sheet lists for one update: its scenes, best first, cut to the near-match limit.
public struct SearchListing: Hashable, Sendable {
    public let scenes: [SceneHits]
    public let quality: MatchQuality
    public let progress: SearchProgress
    /// Every scene the update holds, listed or not.
    public let sceneCount: Int
    /// Every hit the update holds, listed or not.
    public let hitCount: Int

    public init(_ update: SearchUpdate, nearMatches limit: NearMatchLimit) {
        let capped = update.quality == .near && limit == .best
        scenes = capped ? Array(update.scenes.prefix(NearMatchLimit.bestCount)) : update.scenes
        quality = update.quality
        progress = update.progress
        sceneCount = update.scenes.count
        hitCount = update.hitCount
    }

    /// The scenes the near-match limit left out: "Show all N" while there are any.
    public var hiddenSceneCount: Int {
        sceneCount - scenes.count
    }
}

/// Where opening a hit goes (PLAN §9.1): the match to select, or the tab to show.
public enum SearchTarget: Hashable, Sendable {
    /// UTF-16 offsets into the title.
    case title(Range<Int>)
    /// UTF-16 offsets into the part's text, its paragraphs joined by line breaks as the text
    /// view holds them (`RunCodec`).
    case text(TextPart, Range<Int>)
    case comment(CommentID)
    case tags
    /// The scene, with nothing selected: the hit's text is no longer what the book holds.
    case scene
}

extension SearchHit {
    /// The first match, as a range of the unit's text: what opening the hit selects.
    public var firstMatch: Range<Int> {
        highlights.first { $0.kind == .match }?.range ?? 0..<0
    }

    /// Where opening the hit goes in `scene`, as the book holds it now. A hit whose text the
    /// book no longer holds there selects nothing, since its offsets would land on other words.
    public func target(in scene: BookScene) -> SearchTarget {
        switch unit.field {
        case .title:
            scene.title.text == unit.text ? .title(firstMatch) : .scene
        case .body(let paragraph):
            text(.body, paragraph, of: scene.body)
        case .notes(let paragraph):
            text(.notes, paragraph, of: scene.notes)
        case .comment(let id):
            scene.comments.contains { $0.id == id } ? .comment(id) : .scene
        case .tags:
            .tags
        }
    }

    private func text(_ part: TextPart, _ paragraph: Int, of paragraphs: [Paragraph]) -> SearchTarget {
        guard paragraphs.indices.contains(paragraph), paragraphs[paragraph].text == unit.text else {
            return .scene
        }
        let start = paragraphs.prefix(paragraph).reduce(0) { $0 + $1.text.utf16.count + 1 }
        return .text(part, (start + firstMatch.lowerBound)..<(start + firstMatch.upperBound))
    }
}

/// A stretch of a hit's text as the sheet shows it, with its highlights.
public struct SearchSnippet: Hashable, Sendable {
    /// What the sheet draws, an ellipsis included where the text was cut.
    public let text: String
    /// UTF-16 offsets into `text`.
    public let highlights: [Highlight]

    /// The sheet shows at most this much of the text before the first highlight, starting at a
    /// word, so the match is in view however long the paragraph; the row cuts the end.
    public static let leadingContext = 50
    public static let ellipsis = "\u{2026}"

    /// The unit's text, from a word shortly before the first highlight.
    public init(_ hit: SearchHit) {
        let text = Array(hit.unit.text.utf16)
        let first = hit.highlights.first?.range.lowerBound ?? 0
        var start = max(0, first - Self.leadingContext)
        if start > 0 {
            while start < first, text[start - 1] != UInt16(UInt8(ascii: " ")) { start += 1 }
        }
        let lead = start > 0 ? Self.ellipsis : ""
        let shift = lead.utf16.count - start
        self.text = lead + String(decoding: text[start...], as: UTF16.self)
        highlights = hit.highlights.map {
            Highlight(range: ($0.range.lowerBound + shift)..<($0.range.upperBound + shift), kind: $0.kind)
        }
    }

    init(text: String, highlights: [Highlight]) {
        self.text = text
        self.highlights = highlights
    }

    /// A tag unit's tags, one snippet each (ADR 0033: `SearchUnit.tagSeparator` only ever
    /// separates two tags), with the highlights that fall in each.
    public static func tags(_ hit: SearchHit) -> [SearchSnippet] {
        let separator = SearchUnit.tagSeparator.utf16.count
        var start = 0
        return hit.unit.text.components(separatedBy: SearchUnit.tagSeparator).map { tag in
            let end = start + tag.utf16.count
            let highlights = hit.highlights.compactMap { highlight -> Highlight? in
                let lower = max(highlight.range.lowerBound, start)
                let upper = min(highlight.range.upperBound, end)
                return lower < upper
                    ? Highlight(range: (lower - start)..<(upper - start), kind: highlight.kind) : nil
            }
            defer { start = end + separator }
            return SearchSnippet(text: tag, highlights: highlights)
        }
    }
}
