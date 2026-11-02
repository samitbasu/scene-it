# 06 — Attributed strings and the `RunCodec`

How a scene's paragraphs of runs become the text an `NSTextView` edits, and how
the edited text becomes runs again. Read it after [chapter 02](02-model-and-codable.md),
which introduces `Run` and `Paragraph`.

## Where the code is

Everything lives in [`Sources/SceneItCore/Text/`](../../Sources/SceneItCore/Text/):

| File | What it holds |
| --- | --- |
| [`NovelAttributes.swift`](../../Sources/SceneItCore/Text/NovelAttributes.swift) | our three custom attributes and their `AttributeScope` |
| [`ParagraphRole.swift`](../../Sources/SceneItCore/Text/ParagraphRole.swift) | title, body and notes: fonts and paragraph styles |
| [`PaletteSwatches.swift`](../../Sources/SceneItCore/Text/PaletteSwatches.swift) | palette names to `NSColor` (PLAN §6.2's hex values) |
| [`RunCodec.swift`](../../Sources/SceneItCore/Text/RunCodec.swift) | runs to `NSAttributedString` and back |

The tests are in [`Tests/SceneItCoreTests/Text/`](../../Tests/SceneItCoreTests/Text/).

---

## 1. What an attributed string is

An attributed string is a string plus a set of key–value attributes over ranges of
it. Think of a `String` paired with a `Vec<(Range<usize>, HashMap<Key, Box<dyn Any>>)>`
whose ranges tile the string with no gaps. Each tile is an **attribute run**: a
maximal stretch where every attribute is the same. AppKit draws from the
attributes it knows (`.font`, `.foregroundColor`, `.paragraphStyle`, …) and
ignores, but carries along, any key it doesn't.

That is almost exactly our `Run`, which is why the model is shaped the way it is.
The differences are what the codec has to deal with:

- AppKit stores *display* values (an `NSFont`, an `NSColor`). The model stores
  *meaning* (`bold`, `"red"`).
- AppKit has no notion of a paragraph as a container. A paragraph is just the text
  between two `"\n"`s (or any of seven other separators; see §6).
- AppKit splits runs whenever *any* attribute differs, including ones we don't
  save, so two runs AppKit keeps apart may be the same `Run` to us.

## 2. Two attributed string types

Foundation has two:

| | `NSAttributedString` | `AttributedString` |
| --- | --- | --- |
| Kind | Objective-C class (`NSMutableAttributedString` for edits) | Swift value type, copy-on-write |
| Attribute values | `[NSAttributedString.Key: Any]` | typed, through *attribute scopes* |
| Indices | `NSRange` of UTF-16 code units | `AttributedString.Index`, like `String.Index` |
| Used by | `NSTextStorage`, so `NSTextView` and TextKit 2 | SwiftUI `Text`, Markdown |

In Rust terms, `NSAttributedString` is the `dyn Any` map and `AttributedString` is
the version with a type per key. They convert into each other, but conversion
copies the whole string.

**The codec works on `NSAttributedString`.** The page editor's text lives in an
`NSTextStorage`, which *is* an `NSMutableAttributedString`. Going through
`AttributedString` would copy the scene twice on every save. Worse, the typed
conversion fails as a whole when one value doesn't convert. That was checked on
this toolchain: a custom key whose value is `"purpel"` makes
`AttributedString(_:including:)` throw `The value is invalid.` The save path has to
read whatever the user pasted and drop what it doesn't understand, so it reads the
untyped dictionary and treats a bad value as absent.

The typed scope still exists (§4), so code that wants `AttributedString` (a SwiftUI
preview of a comment's quote, say) gets the same keys with types.

## 3. The text bridge in one picture

```
book.json ─decode─▶ [Paragraph] ─RunCodec.attributedString─▶ NSAttributedString ─▶ NSTextStorage
                         ▲                                                              │
                         └──────────────── RunCodec.page(from:) / notes(from:) ◀────────┘
```

The public API is four functions, two per editor:

```swift
    public static func attributedString(for page: ScenePage) -> NSAttributedString {
        attributedString([page.title] + page.body, layout: .page)
    }
```

A `ScenePage` is the title paragraph plus the body, because the page editor shows
both in one text view. The notes tab has its own pair,
`attributedString(forNotes:)` and `notes(from:)`.

Which role each paragraph has is a single function that both directions use, so
loading and saving can't disagree about which paragraph is the title:

```swift
private enum TextLayout {
    case page, notes

    func role(ofParagraph index: Int) -> ParagraphRole {
        switch self {
        case .page: index == 0 ? .title : .body
        case .notes: .notes
        }
    }
}
```

## 4. Custom attributes, `AttributeScope` and dynamic member lookup

Three things a run carries have no AppKit attribute: its palette color *name*, its
highlight name and its comment ids. Each is a key type. A key type is an empty enum
(a type used only as a name, like a Rust marker struct) conforming to
`AttributedStringKey`, with an associated `Value` type and a string `name`. The
name is what appears in the `NSAttributedString` dictionary.

`ObjectiveCConvertibleAttributedStringKey` adds the conversion to and from an
Objective-C value for when the attribute lives in an `NSAttributedString`. Comments
are stored as an `NSSet` of id strings:

```swift
    public enum CommentsAttribute: ObjectiveCConvertibleAttributedStringKey {
        public typealias Value = Set<CommentID>
        public typealias ObjectiveCValue = NSSet
        public static let name = "SceneIt.comments"
```

A *set* of ids is what makes overlapping comments (PLAN §8.1) work: the characters
two comments share carry both ids.

The two palette-name keys differ only in their value type, so they share a
protocol with a default implementation, which is Swift's equivalent of a blanket
`impl<T: RawRepresentable<String>> ...`:

```swift
public protocol PaletteNameAttribute: ObjectiveCConvertibleAttributedStringKey
where Value: RawRepresentable<String>, ObjectiveCValue == NSString {}
```

```swift
    public enum TextColorAttribute: PaletteNameAttribute {
        public typealias Value = TextColor
        public static let name = "SceneIt.textColor"
    }
```

**A scope** groups keys so `AttributedString` can find them. It's a struct whose
stored properties' *types* are the keys. No value of it is ever made; the compiler
reads it through key paths. Including `AppKitAttributes` pulls in the standard keys
(`font`, `foregroundColor`, …):

```swift
public struct NovelAttributes: AttributeScope {
    public let textColor: TextColorAttribute
    public let highlight: HighlightAttribute
    public let comments: CommentsAttribute
    public let appKit: AttributeScopes.AppKitAttributes
```

Two extensions make the scope usable. The first lets you name it as `\.novel`
when converting. The second is **dynamic member lookup**: `AttributeDynamicLookup`
is marked `@dynamicMemberLookup`, so `run.comments` compiles into a call to this
subscript with the key path `\NovelAttributes.comments`. Rust has no direct
equivalent. The nearest is a `Deref` to a struct with one field per key, but here
the "fields" are resolved at compile time from the key path's type:

```swift
extension AttributeScopes {
    public var novel: NovelAttributes.Type { NovelAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<NovelAttributes, T>
    ) -> T {
        self[T.self]
    }
}
```

The test that this works converts the codec's output and reads typed values:

```swift
        let typed = try AttributedString(source, including: \.novel)
        let marked = try #require(typed.runs.first { $0.comments != nil })
        #expect(String(typed[marked.range].characters) == "marked")
        #expect(marked.comments == ids)
        #expect(marked.textColor == .pink)
```

The untyped side, which the codec uses, reads the same key definitions through a
subscript on the attribute dictionary, so the name and the conversion are written
once:

```swift
    subscript<K: ObjectiveCConvertibleAttributedStringKey>(novel key: K.Type) -> K.Value? {
        get {
            (self[NSAttributedString.Key(K.name)] as? K.ObjectiveCValue).flatMap { try? K.value(for: $0) }
        }
```

## 5. Loading: display attributes come from the role

Every run gets a font, a paragraph style and a foreground color, plus the custom
names. One type, `RunFormat` ("a `Run` without its text"), owns the mapping in both
directions:

```swift
    func attributes(in role: ParagraphRole) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: role.font(styles),
            .paragraphStyle: role.paragraphStyle,
            .foregroundColor: PaletteColor(color).nsColor,
        ]
```

`PaletteColor(color)` maps "no color" to black ([decision
0013](../decisions/0013-black-means-no-color.md)), and the hex values live in one
`switch` per palette column in
[`PaletteSwatches.swift`](../../Sources/SceneItCore/Text/PaletteSwatches.swift).

### Fonts and traits

An `NSFont` is a concrete face at a size. Bold and italic aren't flags on a font;
they're different faces in the same family, so making text bold means *finding the
bold face*. A font descriptor describes a font by attributes, and
`withSymbolicTraits` asks for the face with the given traits:

```swift
    public func font(_ styles: Set<TextStyle>) -> NSFont {
        let traits = styles.reduce(into: baseTraits) { traits, style in
            traits.formUnion(style.fontTrait)
        }
        let size = pointSize
        let base = NSFont(name: Self.fontFamily, size: size) ?? .systemFont(ofSize: size)
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
    }
```

Times New Roman has all four faces. The tests check that they really resolve
(`TimesNewRomanPSMT`, `TimesNewRomanPS-BoldMT`, `TimesNewRomanPS-ItalicMT`,
`TimesNewRomanPS-BoldItalicMT`), because if a face were missing, the descriptor
lookup would quietly hand back the regular face and bold would be lost on the next
save. Strikethrough isn't a face at all. It's a separate `.strikethroughStyle`
attribute.

The title is 18 pt **bold**. That bold belongs to the heading, so it's the role's
`baseTraits` and not a style. Saving subtracts the base traits, so a title run can't
carry a separate bold style. A `bold` flag on a title run in `book.json` loads (it
looks the same) and is dropped on the next save.

Every font is resolved on the main actor. In the test runner, eight threads
resolving `Times New Roman` at once hung, every thread waiting on a reply from
the font server. Running the same tests on the main actor finished in under a
second. AppKit text belongs on the main thread anyway, since `NSTextStorage` is
edited there, so `RunCodec` is `@MainActor` ([ADR
0011](../decisions/0011-mainactor-default-isolation.md) explains the isolation
model).

## 6. Saving: read meaning, drop display

Saving splits the whole string into paragraphs, then walks each paragraph's
attribute runs:

```swift
        let string = text.string
        let lines = string.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
```

`Character.isNewline` is true for `\n`, `\r`, `\r\n` (one `Character`), U+000B,
U+000C, U+0085, U+2028 and U+2029, the same test `BookValidator` applies. A paste
from Word that contains U+2029 becomes a paragraph break instead of a run that the
encoder would refuse to save. Splitting the *whole string* first, not each attribute
run, matters for `\r\n`: if the `\r` is bold and the `\n` isn't, they're two
attribute runs but still one `Character` and one break.

Each attribute run becomes a `RunFormat` read back from the dictionary:

```swift
    init(_ attributes: [NSAttributedString.Key: Any], in role: ParagraphRole) {
        if let font = attributes[.font] as? NSFont {
            styles = role.styles(of: font)
        }
        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
            styles.insert(.strike)
        }
        color = attributes[novel: NovelAttributes.TextColorAttribute.self]
        highlight = attributes[novel: NovelAttributes.HighlightAttribute.self]
        comments = attributes[novel: NovelAttributes.CommentsAttribute.self] ?? []
    }
```

Nothing else is read, and that is the whole policy for foreign attributes:
links, underlines, kerning, other fonts' sizes and families are never saved. Three
consequences are deliberate:

- **Color comes from the name, not the `NSColor`.** A pasted red has a
  `.foregroundColor` but no `SceneIt.textColor`, so it saves as no color (black).
  Matching `NSColor`s back to palette entries would make the saved file depend on
  color-space conversions.
- **Bold and italic come from the font's traits,** whatever the family. Pasted
  Helvetica Bold saves as bold.
- **Spacing and indent are never stored.** They come from the paragraph's role
  every time the text loads, so changing the body style later needs no migration.

Runs that end up with the same `RunFormat` merge, and empty pieces are skipped, so
the output has no empty runs and no two neighbouring runs alike. An empty paragraph
saves as zero runs, which is how the model writes a blank line. Notes have one more
rule: empty text is no notes (`[]`), not one empty paragraph.

### The UTF-16 gotcha

`NSAttributedString` predates Unicode-correct strings. Its `length` and every
`NSRange` count **UTF-16 code units**. Swift's `String.count` counts grapheme
clusters, and Rust's `len()` counts UTF-8 bytes. For `"😀é"` that's three
different numbers: `count` is 2, `utf16.count` and `NSString.length` are 3, and the
UTF-8 length is 6. Never mix them. Convert at the boundary with
`NSRange(_:in:)` and `Range(_:in:)`, as the save loop does:

```swift
            text.enumerateAttributes(in: lineRange) { attributes, range, _ in
                // Slicing rounds an index inside a surrogate pair down, so a range that
                // splits a pair yields the whole scalar once and an empty piece.
                guard let bounds = Range(range, in: string) else { return }
                let piece = String(string[bounds])
```

The comment covers the nasty case. An attribute can start in the middle of a
surrogate pair (half an emoji bold), because `NSAttributedString` doesn't stop
you. Converting that `NSRange` gives a `String.Index` inside a scalar, and slicing
rounds it down. So the first piece is empty and the second holds the whole emoji.
`aRunBoundaryInsideASurrogatePairKeepsTheTextIntact` pins this down.

## 7. How the tests prove it

- **Round trips** of every color × highlight × style combination (392 runs, checked
  to be pairwise distinct so nothing merges), overlapping comments, and empty
  paragraphs.
- **Generated scenes**: `generatedScenesRoundTrip` reuses the model tests'
  `BookGenerator`. Since run boundaries may legitimately move, it compares the text
  scalar by scalar together with each scalar's format, checks the output is
  canonical, checks `save(load(save(x))) == save(x)`, and validates the resulting
  book.
- **Hostile input**: every separator, foreign attributes, malformed custom values,
  a pasted color without a name, and random mixtures of all of them.
