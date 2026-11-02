# 02 — The model and `Codable`

How `book.json` becomes Swift values and back, explained for someone who knows serde.

The JSON format in PLAN [§5.2](../../novel-app-build-bundle/PLAN.md) is a contract:
other tools may read it, and backups and filed copies are kept for years. So the
model is built around one requirement: **a file decodes only if it's exactly in that
shape, and encoding is deterministic.** Most of this chapter is about the places
where Swift's defaults don't give you that, and the code that does.

## Where the code is

Everything lives in [`Sources/SceneItCore/Model/`](../../Sources/SceneItCore/Model/):

| File | What it holds |
| --- | --- |
| [`Book.swift`](../../Sources/SceneItCore/Model/Book.swift) | `Book`, the format check |
| [`BookSettings.swift`](../../Sources/SceneItCore/Model/BookSettings.swift) | `BookSettings`, `RightPanelTab`, `ScenesView`, `PanelVisibility` |
| [`BookScene.swift`](../../Sources/SceneItCore/Model/BookScene.swift) | `BookScene`, `Comment` |
| [`Run.swift`](../../Sources/SceneItCore/Model/Run.swift) | `Run`, `TextStyle`, `Paragraph` |
| [`Palette.swift`](../../Sources/SceneItCore/Model/Palette.swift) | `PaletteColor`, `TextColor`, `HighlightColor` |
| [`Identifier.swift`](../../Sources/SceneItCore/Model/Identifier.swift) | `SceneID`, `CommentID` |
| [`BoundedScalar.swift`](../../Sources/SceneItCore/Model/BoundedScalar.swift) | `Zoom`, `SpeechRate` |
| [`Timestamp.swift`](../../Sources/SceneItCore/Model/Timestamp.swift) | dates with their UTC offset |
| [`StrictDecoding.swift`](../../Sources/SceneItCore/Model/StrictDecoding.swift) | rejecting unknown keys, `null` and unknown enum values |
| [`BookCoding.swift`](../../Sources/SceneItCore/Model/BookCoding.swift) | the one encoder/decoder, readable errors |
| [`BookValidator.swift`](../../Sources/SceneItCore/Model/BookValidator.swift) | rules the types can't express |
| [`IDGenerator.swift`](../../Sources/SceneItCore/Model/IDGenerator.swift) | ULIDs |

The tests are in [`Tests/SceneItCoreTests/Model/`](../../Tests/SceneItCoreTests/Model/),
and the golden file is [`Fixtures/rich-book.json`](../../Tests/SceneItCoreTests/Model/Fixtures/rich-book.json).

---

## 1. `Codable` is serde's derive, synthesized by the compiler

`Codable` is `Encodable & Decodable`, the pair of protocols that play the roles of
`Serialize` and `Deserialize`. Declare a conformance on a type whose stored
properties are all `Codable`, and the compiler writes `encode(to:)` and
`init(from:)` for you. There's no proc macro and no `#[derive]`: the conformance
*is* the request.

The mapping:

| serde | Swift |
| --- | --- |
| `Serializer` / `Deserializer` | `Encoder` / `Decoder` (the format: `JSONEncoder`, `PropertyListEncoder`) |
| a `struct` visitor over named fields | a **keyed container**, `KeyedDecodingContainer<Key>` |
| a sequence visitor | an **unkeyed container** (JSON arrays) |
| `#[serde(transparent)]` | a **single-value container** |
| `#[serde(rename = "...")]` | a case in the nested `enum CodingKeys` |
| `skip_serializing_if = "Option::is_none"` | the default for every `Optional` |
| `#[serde(deny_unknown_fields)]` | nothing; see §3 |

Synthesis works per requirement. A type can write `init(from:)` by hand and still
get `encode(to:)` synthesized from the same `CodingKeys`. `Comment` does exactly
that. It declares `Encodable` on the type, so encoding is synthesized:

```swift
public struct Comment: Identifiable, Hashable, Sendable, Encodable {
    public var id: CommentID
    public var color: PaletteColor
    public var text: String
    public var created: Timestamp
```

Then an extension adds `Decodable` with a hand-written initializer:

```swift
extension Comment: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, color, text, created
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        id = try container.decode(CommentID.self, forKey: .id)
        color = try container.decode(PaletteColor.self, forKey: .color)
        text = try container.decode(String.self, forKey: .text)
        created = try container.decode(Timestamp.self, forKey: .created)
    }
}
```

## 2. `CodingKeys` and keyed containers

`CodingKeys` is an ordinary nested enum conforming to `CodingKey`. With a `String`
raw value, each case's name is its JSON key. The compiler finds it by name. If you
don't write one, it synthesizes one with a case per stored property.

A keyed container is a typed view of a JSON object: `decode(_:forKey:)` throws if
the key is missing, `decodeIfPresent` returns `nil`, and `contains` tells you
whether the key is there. Because `CodingKeys` is an enum, it can have methods.
`Run` gives its keys an initializer from a `TextStyle`, so the style-to-key mapping
is a `switch` the compiler checks for exhaustiveness:

```swift
    enum CodingKeys: String, CodingKey, CaseIterable {
        case text, bold, italic, strike, color, highlight, comments

        init(_ style: TextStyle) {
            switch style {
            case .bold: self = .bold
            case .italic: self = .italic
            case .strike: self = .strike
            }
        }
    }
```

## 3. Strictness: unknown keys, `null` and unknown values

Synthesized `Decodable` is lenient in three ways that matter here. All three were
checked on this toolchain with a plain `struct R: Codable { var text: String; var
bold: Bool?; var color: Color? }`:

- **Unknown keys are ignored.** `{"text":"x","underline":true}` decodes. A keyed
  container's `allKeys` only lists keys that convert to its `Key` type, so the
  synthesized code never even sees `underline`.
- **`null` is "absent".** `decodeIfPresent` returns `nil` for `"bold": null`.
- **Error messages for enums are terse:** `Cannot initialize Color from invalid
  String value purpel`, with no list of valid values.

There's no `deny_unknown_fields`. The fix is to ask for a second view of the same
object, keyed by a type that accepts *any* string, and compare. That's done once,
generically, in [`StrictDecoding.swift`](../../Sources/SceneItCore/Model/StrictDecoding.swift):

```swift
extension Decoder {
    /// A keyed container that throws if the object holds a key outside `Key.allCases`.
    func strictContainer<Key: CodingKey & CaseIterable>(
        keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        let everything = try container(keyedBy: AnyCodingKey.self)
        let known = Set(Key.allCases.map(\.stringValue))
        let unknown = everything.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
```

`AnyCodingKey` is a `CodingKey` whose initializer never fails. The generic
constraint `CodingKey & CaseIterable` is why every model type's `CodingKeys` adds
`CaseIterable`. The cost is that every model type writes its `init(from:)` by hand,
one line per field. That's the price of strictness in Swift. Writing a custom
`Decoder` that wraps `JSONDecoder` to apply the check everywhere would be about
twenty methods of boilerplate.

`null` is handled by a three-line sibling that only decodes when the key is present,
so `null` reaches `decode` and fails there:

```swift
    func decodeUnlessAbsent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        contains(key) ? try decode(type, forKey: key) : nil
    }
```

## 4. Enums with raw values

`enum PaletteColor: String` gives each case a raw value, by default its name, and a
failable `init?(rawValue:)`. A `RawRepresentable` type whose raw value is `Codable`
doesn't become `Codable` on its own. Once it *declares* `Codable`, though, the
standard library supplies the implementation, which encodes the raw value. That's
serde's `rename_all = "lowercase"` for free. The palette in
[`Palette.swift`](../../Sources/SceneItCore/Model/Palette.swift) has all seven names:

```swift
public enum PaletteColor: String, StrictStringEnum {
    case black, purple, red, blue, green, gray, pink
}
```

A run's color has no `black`, because on the page black is the absence of a color
([decision 0013](../decisions/0013-black-means-no-color.md)). With both `nil` and
`.black`, two states would look identical on screen. So `TextColor` has six cases,
and a failable conversion from the palette sends black to `nil`:

```swift
    /// `nil` for black, which a run expresses by having no color.
    public init?(_ palette: PaletteColor) {
        self.init(rawValue: palette.rawValue)
    }
```

`Run` decodes a `PaletteColor` and maps it through that initializer, so a file
saying `"color": "black"` loads as "no color", and the next save drops the
attribute. That's the one place decoding normalizes instead of rejecting.
Comments keep `PaletteColor`, because black is one of their seven swatches.

`StrictStringEnum` replaces the standard library's `init(from:)` with one that
names the valid values. A default implementation in a protocol extension wins over
the standard library's, because `StrictStringEnum` refines `RawRepresentable` and
the more specific protocol is preferred:

```swift
extension StrictStringEnum {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            let valid = Self.allCases.map(\.rawValue).joined(separator: ", ")
```

A misspelt color now fails with
`scenes[0].body[0][3].color: unknown value "purpel"; expected one of: black, purple, red, blue, green, gray, pink`.
That exact string is asserted in
[`StrictDecodingTests.swift`](../../Tests/SceneItCoreTests/Model/StrictDecodingTests.swift).

## 5. Newtypes

**Ids.** A `SceneID` and a `CommentID` are both strings in JSON, but they must never
be mixed up. Rather than two copies of the same struct,
[`Identifier.swift`](../../Sources/SceneItCore/Model/Identifier.swift) uses a
*phantom type* parameter, as you would with `PhantomData` in Rust:

```swift
public struct Identifier<Owner>: RawRepresentable, Codable, Hashable, Comparable, Sendable {
```

```swift
public typealias SceneID = Identifier<BookScene>
public typealias CommentID = Identifier<Comment>
```

Unlike Rust, Swift doesn't complain about an unused type parameter, so no
`PhantomData` field is needed. Being `RawRepresentable` with a `String` raw value
makes it encode as a bare string, like `#[serde(transparent)]`.

(The model types are `BookScene` and `BookSettings`, not PLAN's `Scene` and
`Settings`, because SwiftUI has types with those names and Swift reports a name
that two imported modules define as ambiguous. See
[decision 0012](../decisions/0012-model-type-names.md).)

`Identifier` writes its own `==`, `hash(into:)` and `<` over the UTF-8 bytes.
`String`'s `==` uses Unicode canonical equivalence, so `"caf\u{E9}"` (é as one
scalar) equals `"cafe\u{301}"` (e plus a combining accent) even though they encode
differently. For ids, "the same" has to mean "the same bytes".

**Bounded numbers.** CLAUDE.md forbids naked floats. `Zoom` (0.5–3.0) and
`SpeechRate` (0–1) are the same idea with different bounds, so
[`BoundedScalar.swift`](../../Sources/SceneItCore/Model/BoundedScalar.swift) writes
the idea once as a generic struct, and each bound is a caseless enum:

```swift
public typealias Zoom = Bounded<ZoomBounds>

public enum ZoomBounds: ScalarBounds {
    public static let range: ClosedRange<Double> = 0.5...3.0
    public static let standard = 1.0
}
```

A protocol with a `Self` initializer would have been the obvious alternative, but
a protocol requirement is as public as the protocol, so the unchecked initializer
would have leaked. Here the only initializers are `init(clamping:)`, which maps NaN
to the standard value, and `init?(exactly:)`, which decoding uses. Both store `-0`
as `0`. Otherwise two values that compare equal would encode differently. Chapter 00 left open
whether decoding should clamp or reject an out-of-range zoom. It rejects:
`settings.zoom: 3.5 is outside the allowed range 0.5...3.0`.

## 6. The in-memory model is richer than the JSON

PLAN §5.3 sketches `Run` with `bold: Bool?`. That type has three states for two
meanings: `nil`, `false` and `true`. The real `Run` has one field for all three
styles:

```swift
public struct Run: Hashable, Sendable {
    public var text: String
    public var styles: Set<TextStyle>
    public var color: TextColor?
    public var highlight: HighlightColor?
    public var comments: Set<CommentID>
```

`comments` is a `Set`, and the empty set means "no comments", so `[]` versus
absent can't happen either. Since the in-memory shape differs from the JSON,
`Run` writes both directions by hand (§2's excerpt). Encoding writes `true` for each
style present and the comment ids **sorted** by their bytes, because a `Set`'s
iteration order is not stable across runs.

Decoding goes one step further and **rejects** `"bold": false`, `"comments": []` and
repeated ids instead of normalizing them. The invariant this buys is narrower than it
might look: **our encoder's output is a fixed point**. Anything we wrote decodes and
re-encodes to the same bytes. A file from elsewhere can load and then be written back
differently. Examples are different whitespace, `"format": 1.0`, `-00:00`, unsorted
comment ids, `"zoom": 1.0` (written back as `1`) and `"color": "black"`.

One gap can't be closed through `Codable`: **duplicate keys** in a JSON object.
`JSONDecoder` keeps only one of them, and a keyed container never sees the other,
so `strictContainer` can't report it. Detecting duplicates would take a separate
pass with a tokenizer, which isn't worth it for a file only this app writes.

**Dates** follow the same reasoning. A `Date` is an instant with no time zone, so
encoding one with `JSONEncoder`'s `.iso8601` strategy picks an offset at encode
time, and a file written in California would change when re-saved in India.
[`Timestamp`](../../Sources/SceneItCore/Model/Timestamp.swift) stores the offset it
was written with, and whole seconds only:

```swift
public struct Timestamp: Hashable, Sendable, Codable, CustomStringConvertible {
    public let secondsSince1970: Int64
    public let offset: UTCOffset
```

Storing seconds as an integer makes "sub-second precision" unrepresentable, so
encode → decode is an identity. It formats and parses
`2026-10-31T20:54:00-07:00` with integer calendar arithmetic rather than
`Calendar`. Foundation's Gregorian calendar switches to the Julian calendar before
1582, and the formatting styles write `Z` for UTC, which wouldn't round-trip.

## 7. One encoder, and errors with paths

`JSONEncoder` emits object keys in an unspecified order unless asked otherwise. Everything
that encodes book data goes through
[`BookCoding`](../../Sources/SceneItCore/Model/BookCoding.swift):

```swift
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
```

A `DecodingError` carries a `codingPath: [any CodingKey]`, where array positions are
keys with an `intValue`. `BookDecodingError` renders that path as you would write it
in code (`scenes[0].body[2][1].color`) and turns the four `DecodingError` cases into
a short reason. `BookCoding.decode` uses **typed throws**,
`throws(BookDecodingError)`, the nearest Swift gets to `Result<Book, BookDecodingError>`:
callers know the error's type without a cast.

## 8. Validation is a separate, pure step

Some rules span values: a comment id in a run must exist in that scene's
`comments`, and scene ids must be unique across the scenes and the Boneyard.
[`BookValidator.problems(in:)`](../../Sources/SceneItCore/Model/BookValidator.swift)
returns *every* problem as a typed `BookProblem`, in document order, rather than
throwing at the first. Each prints the scene and the place, for example
`scene "01JC4K…" (boneyard[0]), body[0][0]: comment "c404" is not in the scene's comments`.

`BookCoding.encode` runs the validator first and throws
`BookEncodingError.invalid(problems)` if anything is wrong. The rules then live in one
place, and the app can't save a file that it would later refuse to open. A failed
save fails before any backup is rotated.

The format version is not checked here. `Book.init(from:)` reads `format` first and
refuses anything but 1 before looking at anything else, because a future format may
legitimately contain keys this version would call unknown.

## 9. Value semantics and `Sendable`

Every model type is a `struct` or `enum` made of strings, arrays, sets and other
model types. Chapter 00 §2 explains what that buys: `var draft = book` is a cheap
copy-on-write copy, and mutating `draft` can never affect `book`. That's what makes
`BookStore`'s "encode a snapshot on save" safe without locks.

Each type declares `Sendable` explicitly. For a non-`public` struct the compiler
infers it, but for a `public` type it doesn't, because inferring it would make a
private stored property part of the public contract. The compiler checks the
declaration: adding a `class` field without `Sendable` would be an error. That's
the same guarantee as Rust's auto-trait `Send`, but opt-in at the module boundary.

## 10. Testing it

- **Golden file.** [`RoundTripTests.swift`](../../Tests/SceneItCoreTests/Model/RoundTripTests.swift)
  decodes `rich-book.json` and checks that re-encoding gives the same bytes. Another
  test asserts that the fixture still covers every style, a color, a highlight,
  overlapping comments and the Boneyard, so it can't silently stop testing them.
- **Time zones.** The round trip is repeated with `TZ` set to two zones. Setting
  `NSTimeZone.default` is not enough on this toolchain: `TimeZone.current` ignores
  it. The test sets the `TZ` environment variable, calls
  `NSTimeZone.resetSystemTimeZone()`, and requires that `TimeZone.current` changed
  before trusting the result.
- **Generated books.** A seeded SplitMix64 generator (the test-only
  [`BookGenerator`](../../Tests/SceneItCoreTests/Model/BookGenerator.swift)) builds
  200 random valid books with awkward characters. Each must survive
  encode → decode unchanged and re-encode to identical bytes. Swift has no
  `proptest`, and a short generator was simpler than adding a dependency.
