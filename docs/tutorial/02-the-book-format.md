# 02 — The book format

How `book.md` becomes Swift values and back, explained for someone who knows serde and nom.

A writer's novel lives in one text file. [ADR 0022](../decisions/0022-markdown-book-format.md)
makes that file tolerant Markdown that a person can read and edit in any editor, and
[`docs/format/book-format.md`](../format/book-format.md) is its grammar. This chapter is
about the code that implements that grammar, and about the one requirement that shapes all
of it: **the parser never fails.** Every byte sequence parses to a book. Whatever the parser
can't understand is kept, verbatim, as an *error entry* that the writer sees in the Errors
tab and that stays in the file until they deal with it.

The first version of this chapter taught the opposite: a strict JSON model where a file
decoded only if it had exactly the right shape. That format never shipped, and ADR 0022
replaced it. If you know serde, the contrast is the lesson: serde gives you
`Result<Book, Error>`, and this format needs a function that has no `Err`.

## Where the code is

| File | What it holds |
| --- | --- |
| [`Model/Book.swift`](../../Sources/SceneItCore/Model/Book.swift) | `Book`, with its book-level error entries |
| [`Model/BookScene.swift`](../../Sources/SceneItCore/Model/BookScene.swift) | `BookScene`, `Comment`, detached comments |
| [`Model/ErrorEntry.swift`](../../Sources/SceneItCore/Model/ErrorEntry.swift) | `ErrorEntry`, `ErrorTag` |
| [`Model/Run.swift`](../../Sources/SceneItCore/Model/Run.swift) | `Run`, `TextStyle`, `Paragraph` |
| [`Model/CharacterPolicy.swift`](../../Sources/SceneItCore/Model/CharacterPolicy.swift) | which characters text may hold; bytes to text; `RepairNotice` |
| [`Format/BookFormat.swift`](../../Sources/SceneItCore/Format/BookFormat.swift) | the public API: `parse`, `serialize`, `verifiedSerialization` |
| [`Format/BookParser.swift`](../../Sources/SceneItCore/Format/BookParser.swift) | the line-by-line reader |
| [`Format/BookSerializer.swift`](../../Sources/SceneItCore/Format/BookSerializer.swift) | the canonical writer |
| [`Format/Lexical.swift`](../../Sources/SceneItCore/Format/Lexical.swift) | trimming, headings, `key: value`, field escapes |
| [`Format/Inline.swift`](../../Sources/SceneItCore/Format/Inline.swift) | bold, italic and strikethrough, read and written |
| [`Format/Entries.swift`](../../Sources/SceneItCore/Format/Entries.swift) | comment, mark and Unparsed entries, and the E1–E10 problems |
| [`Format/SceneText.swift`](../../Sources/SceneItCore/Format/SceneText.swift) | a scene's plain text while marks and comments are applied |

The tests are in [`Tests/SceneItCoreTests/Format/`](../../Tests/SceneItCoreTests/Format/).
The fixtures there are the owner's demo book and the two worked examples from the spec,
copied verbatim.

---

## 1. Why not serde, and why not nom

With serde you describe the shape and the library walks the input. The first thing that
doesn't fit ends the walk: `serde_json::from_slice::<Book>(bytes)` is either a whole `Book`
or an error with a line and column. That's right for a config file and wrong for a novel.
A stray character in one comment line would cost the writer the whole book until they found
and fixed it in a text editor.

nom (or any parser-combinator library) gets you closer. It composes small parsers, and
`alt`, `opt` and `many0` let you say "try this, else that". But a combinator parser's
failure still propagates: a parser returns `IResult<I, O, E>`, and recovering means
deciding, at each level, how much input to skip and what to put in the output instead.
You end up writing the recovery by hand anyway, inside a framework that assumes failure is
the exceptional path.

Here failure *is* the common path, and the recovery rule is fixed and simple: **the unit of
damage is the line.** So the parser is a hand-written state machine over lines. Every line
either takes effect or becomes an error entry of the scene (or the book) it was found in.
That's the same idea as error recovery in rust-analyzer or tree-sitter, which put an
`ERROR` node in the tree and keep going, with one difference: our error nodes are kept *in
the file*, so the next save writes them back unchanged.

The type says it. Compare a serde-style signature with ours:

```rust
fn from_slice(bytes: &[u8]) -> Result<Book, Error>          // serde_json
```

```swift
    public static func parse(
        _ bytes: Data, opened: Timestamp, ids: inout some SceneIDSource
    ) -> ParsedBook {
```

No `throws`, no `Result`, no optional. The errors are *inside* the value: `book.errors` and
each scene's `errors` are `[ErrorEntry]`.

Two Swift notes on that signature:

- `inout some SceneIDSource` is Rust's `ids: &mut impl SceneIdSource`. `some P` in a
  parameter position is sugar for a generic parameter, so this is monomorphized, not a
  trait object.
- The parser takes the clock and the id generator as inputs because some defaults need them:
  a scene with no `modified` gets the time the book was opened, and a scene with no id gets a
  fresh one. Each such default is recorded as a `[notice]` entry, and the tests pass a
  deterministic id source so they can name the ids they expect.

## 2. Bytes to characters

Before any line is read, the bytes go through §1.2 of the spec. Every step is total.

**Decode.** UTF-8, but a byte that isn't part of a well-formed sequence decodes on its own
as its Windows-1252 character, and the book gets one notice. Rust's
`String::from_utf8_lossy` would turn each bad sequence into U+FFFD, losing the original.
Here a Windows-1252 `“` (byte 0x93) becomes `“`, which the next step straightens to `"`, so
a file saved by an old Windows editor loses nothing. "Well-formed" is Unicode's Table 3-7,
which is short enough to write out:

```swift
    static func wellFormedLength(_ bytes: [UInt8], at index: Int) -> Int {
        let lead = bytes[index]
        let second: ClosedRange<UInt8>
        let length: Int
        switch lead {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: (second, length) = (0x80...0xBF, 2)
        case 0xE0: (second, length) = (0xA0...0xBF, 3)
        case 0xE1...0xEC, 0xEE...0xEF: (second, length) = (0x80...0xBF, 3)
        case 0xED: (second, length) = (0x80...0x9F, 3)
        case 0xF0: (second, length) = (0x90...0xBF, 4)
        case 0xF1...0xF3: (second, length) = (0x80...0xBF, 4)
        case 0xF4: (second, length) = (0x80...0x8F, 4)
        default: return 0
        }
```

The common case never gets here: `String(validating: bytes, as: UTF8.self)` succeeds for a
valid file, and only an invalid one takes the byte-by-byte path.

**Admit.** Then `CharacterPolicy.admitLatin1` normalizes line endings, applies NFC, straightens
typographic punctuation, turns tabs into spaces, and replaces every character outside
printable Latin-1 with `[?]`, remembering which line each replacement was on (for the
notice of the scene it was in). The editor will call the public `CharacterPolicy.admit` on
typing and pasting, which is the same code, so the two can't disagree.

The output is `[UInt8]`, one byte per character. That's a deliberate choice of
representation. Swift's `String` is a sequence of grapheme clusters, and its `==` compares
*canonical equivalence*, so `"é"` (one scalar) equals `"e\u{301}"` (two). That's right for
UI text and wrong for a file format, where offsets must count something exact. After
admission every character is one Latin-1 code point, so a byte array gives us what Rust's
`&[u8]` gives you: offsets are indices, slicing is O(1), and equality is bytewise. The
model's `String`s are built only at the end, from Latin-1 bytes.

NFC has a fast path worth knowing about. Composition needs a combining mark, and every
combining mark is at U+0300 or above, whose UTF-8 lead byte is 0xCC or more. So:

```swift
        let normalized =
            text.utf8.allSatisfy { $0 < 0xCC } ? text : text.precomposedStringWithCanonicalMapping
```

## 3. The state machine

After admission the text is split into lines and each is trimmed (§1.3). Then
`BookParser`'s reader walks them once. Its state is small: the current scene (if any), the
section within it (metadata, body, notes, comments, marks, unparsed), an open paragraph and
an open entry. Each line is classified as blank, heading-shaped or text, and handled by
that. Here is how an entry section reads its lines; it's typical:

```swift
    private func entryLine(_ line: [UInt8], _ number: Int) {
        if Lexical.isEntryStart(line) {
            endEntry()
            entry = LogicalLine(line: number, text: line)
        } else if entry != nil {
            entry?.text += [Lexical.space] + line
        } else {
            switch current?.section {
            case .comments?: record(.comments, line, number)
            case .marks?: record(.marks, line, number)
            default: record(.line, line, number)
            }
        }
    }
```

A line starting `- ` opens an entry, a line right under one continues it (an editor
hard-wrapped it), and anything else is stray and recorded on the spot. There's no `return
Err` anywhere: `record` appends an `ErrorEntry` and the loop moves on.

`entry?.text += …` is Swift's optional chaining used for mutation: if `entry` is `nil` the
whole statement does nothing, like `if let Some(e) = entry.as_mut() { … }`.

### Deferred work: comments and marks

A comment entry is checked against the scene's plain text: `c13-19 | "letter"` is valid only
if the characters at 13..<19 are `letter`. But in the file, `### Notes` may come *after*
`### Comments`, and a comment can point into the notes. So entries aren't checked as
they're read. The reader keeps each logical line with its line number, and when the scene
ends it builds the texts, then checks every mark and comment against them:

```swift
        var body = SceneText(scene.body)
        var notes = SceneText(scene.notes)
        let marks = scene.markLines.compactMap { logical -> ParsedMark? in
            switch Entries.mark(logical.text, in: EntryContext(body: body, notes: notes, commentIDs: [])) {
            case .success(let mark): return mark
            case .failure: record(.marks, logical.text, logical.line, in: scene)
            }
            return nil
        }
```

Entries recorded at different times are sorted by line number at the end, so the Errors tab
lists them in file order whichever check produced them.

`Entries.mark` returns `Result<ParsedMark, EntryProblem>`, where `EntryProblem` is the
spec's E1–E10. The parser doesn't store the problem (§5.4: the reason is derived, never
stored), but the tests assert it for every class, and the Errors tab will use the same
function to explain each row.

## 4. Damage stays local

Never failing isn't enough on its own: a parser could "succeed" by misreading everything
after the first bad line. The second property is that damage costs only what it touches.
The design gets that by keeping almost no state across a scene boundary. When a `##` line
arrives, the reader finishes the current scene and starts a new one from scratch. The only
facts that cross are:

- whether the Boneyard has started, which changes which list a scene goes in but not what
  it contains;
- the ids already used, because a duplicate scene id gets a fresh one (§2.2). Fresh ids are
  assigned after the whole file is read, avoiding every id that appears anywhere in it.

The fuzz suite (§7) found one more, which the spec allows: a `# Boneyard` typed early
makes the real one a "second Boneyard heading", which becomes an error entry in the scene
it used to end. That's the kind of thing a property test is for: the rule was in the spec
all along, and the test made its reach visible.

## 5. Inline markup: toggles

Bold, italic and strikethrough are read as **toggles** (§3.4): `**` flips bold, `*` flips
italic, `~~` flips strike. Toggles commute, so any overlap of styles can be written without
CommonMark's nesting and flanking rules, and the reader is two passes. The first finds the
maximal delimiter runs and what each stands for:

```swift
    private struct DelimiterRun {
        let range: Range<Int>
        let delimiter: UInt8
        let freeStanding: Bool

        /// Step 3: a `*` run is ⌊n/2⌋ bold toggles then, if n is odd, an italic one; a `~`
        /// run is ⌊n/2⌋ strike toggles then, if n is odd, a literal `~`.
        var pairs: StyleBits { delimiter == Lexical.star ? .bold : .strike }
        var pairCount: Int { freeStanding ? 0 : range.count / 2 }
        var hasItalic: Bool { !freeStanding && delimiter == Lexical.star && range.count % 2 == 1 }
    }
```

The second walks the characters, flipping styles at each run. A free-standing run
(whitespace on both sides, like a `* * *` scene break) is text, and if a style has an odd
number of toggles its last one is text too, so `He said **wow.` reads as typed. Unbalanced
markup is never an error.

The writer is the mirror image, and its one subtle rule is about spaces. A delimiter with a
space on both sides would read back as text, so the serializer escapes a space that
follows a delimiter run that itself follows a space: bold `" for"` after `"Wait "` is
written `Wait **\ for** it.`

## 6. Canonical output and save verification

`serialize` is total and canonical: equal books give equal bytes. The format writes
comments and marks as ranges over plain text, while the model keeps them as attributes on
runs, so the serializer turns runs back into ranges. One observation makes that short. In
the flattened list of a body's runs, two consecutive runs are separated by nothing, or only
by paragraph breaks, because runs are non-empty and contiguous within a paragraph. And a
range may bridge paragraph breaks (§4.2). So "the maximal ranges of runs with this comment"
is just grouping consecutive runs:

```swift
    func ranges(where predicate: (Run) -> Bool) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var open: Range<Int>?
        for (range, run) in runs where !range.isEmpty {
            if predicate(run) {
                open = open.map { $0.lowerBound..<range.upperBound } ?? range
            } else if let finished = open {
                ranges.append(finished)
                open = nil
            }
        }
        if let open { ranges.append(open) }
        return ranges
    }
```

A comment that no run carries is *detached* (its text was deleted), and it's written
`detached`. There's no separate field for that in the model: it's derived, so it can't
disagree with the runs.

Persistence never writes bytes it hasn't read back. `verifiedSerialization` is §7.2 of the
spec:

```swift
    public static func verifiedSerialization(of book: Book) throws(VerificationFailure) -> Data {
        let bytes = serialize(book)
        var ids = UnusedSceneIDs()
        let reread = parse(bytes, opened: verificationTime, ids: &ids).book
        guard reread.errorEntries == book.errorEntries else {
            throw .newEntries(newEntries(in: reread, comparedWith: book))
        }
        guard serialize(reread) == bytes else { throw .unstable }
        return bytes
    }
```

`throws(VerificationFailure)` is a *typed throw*, Swift's closest thing to
`Result<Data, VerificationFailure>`: the caller's `catch` gets a `VerificationFailure`, not
an `any Error`.

Why both checks? A book may legitimately carry error entries from an earlier load, so "no
entries" would make such a book unsaveable. What must not happen is a *new* entry: that
means the serializer wrote something the parser reads differently. And the byte comparison
catches the changes that don't produce entries: a paragraph whose run contains a line
break, say, is written on two lines and read back as one paragraph joined by a space. The
model forbids that state, but the type can't prevent it, so verification is the backstop:
it shows up as a refused save, never as a silently different file.

The comparison is on bytes, not on `Book ==`, for the canonical-equivalence reason in §2.

## 7. How it's tested

**The spec's examples, verbatim.** The owner's demo book is a fixture and must round-trip
byte for byte with no error entries. The spec's complete example (§9.1) must be its own
canonical form, and each row of its "parsed as" table is asserted. The damaged example
(§9.2) is rebuilt as bytes, with `\r\n` endings, the two Windows-1252 bytes and the cut-off
last line, and must produce exactly its twelve entries. Every table row in the spec with an
input and a result is a parameterized test.

**Round trip, as a property.** `BookGenerator` makes random books from a seed, using the
characters that need escaping and runs that start with `# `, `- `, `---` or `<br>`. For each
of 300 seeds, `serialize(parse(serialize(b)))` must equal `serialize(b)`, the parse must
find exactly `b`'s own error entries, and the parsed book must equal `b`. This is
`proptest` without the shrinking: a seeded `SplitMix64` makes each case reproducible, and a
separate test asserts that the generator really produces overlapping comments, detached
comments, empty paragraphs and every error tag, so the property can't quietly test less
than it claims.

**Fuzzing.** Three seeded suites:

- random bytes, and random lines of structure (headings, entries, fences), thousands of
  each: the parse must always produce a book whose `verifiedSerialization` succeeds. That's
  stronger than "doesn't crash": anything the writer opens can be saved;
- several random mutations of valid files (insert, delete or change a byte, truncate,
  duplicate a line, insert a structural line), with the same requirement;
- **damage locality**: 4,000 single mutations of valid files. The test knows where each
  scene's bytes are, so it knows which scenes a mutation touched. Every scene that wasn't
  touched (and isn't the one before a touched one, since breaking a `##` line merges a scene
  into its predecessor) must parse exactly as before, apart from the two non-local effects
  the spec defines (§4). About 16,000 untouched scenes are compared per run.

**Performance.** A 120,000-word novel (about 700 KB) parses in about 0.37 s and serializes
in about 0.09 s in a debug build, and in about 30 ms each in a release build. The test
asserts under a second in debug.

Debug Swift is slow in ways that matter here. Each array subscript is bounds-checked and
each closure call is real, so a per-character `zip(…).map { … }` that's free in release can
cost several times a plain loop. The two changes that mattered were a fast path for
paragraphs with no markup characters, and building the reader's delimiter runs once per
paragraph instead of one enum value per character.

## 8. Swift notes

- **Raw strings.** `#"C:\logs"#` is Rust's `r#"C:\logs"#`, with a twist: inside `#"…"#`,
  `\#` *is* an escape (it's how you interpolate, `\#(x)`). A test string containing a
  literal `\#` needs `##"…"##`.
- **`Comment` is ambiguous in tests.** Swift Testing also declares a `Comment` type, so a
  test file that imports both can't name ours as a type. It can still call
  `Comment(id:…)`: the ambiguity is only for type lookup.
- **`@testable import`** lets tests reach `internal` declarations such as `Entries` and
  `EntryProblem`, like Rust's `#[cfg(test)] mod tests` reaching private items, but from a
  separate module.
