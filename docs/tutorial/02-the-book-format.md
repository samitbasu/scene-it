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
Here a Windows-1252 `“` (byte 0x93) becomes `“`, which the next step spells as `"`, so
a file saved by an old Windows editor keeps every character it can. "Well-formed" is Unicode's Table 3-7,
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

**Admit, in two stages.** Then `CharacterPolicy.fileText` normalizes line endings, turns tabs
into spaces, and looks every other character outside printable ASCII up in the transliteration
table (ADR 0028), recording what will happen to it and which line it's on, but **leaving it in
place**. The parser reads the lines' structure first, and only then does each piece of text a
line yields (a paragraph's characters in their styles, a title, a tag, a comment's text and
quote) go through `CharacterPolicy.transliterated`: `é` becomes `e`, `“` becomes `"`, `—`
becomes `--`, a no-break space becomes a space, and a character the table doesn't have becomes
`[?]`. The order matters. Transliterating the whole file first, as the first version of this
code did, let the table's output become markup: a pasted bullet `•` became `*` and then an
italic delimiter, and a no-break space became a space that trimming then ate, shifting every
comment offset after it. Transliterated characters must always be literal text, so the
serializer escapes them like any other `*`.

The recorded changes become notices, one per kind per scene, except that typographic
punctuation and the no-break space (the table's `silent` entries, which TextEdit and Word
write freely) are straightened without one. The editors call the public
`CharacterPolicy.admit` (through `admitted`, `admittedLine` and `admittedInput`) on typing and
pasting, which is the same table, so the two can't disagree.

The table is data, not code paths:

```swift
    public static let table: [Unicode.Scalar: Spelling] = [
        "\u{00A0}": .silent(" "), "\u{00A1}": .noticed(""), "\u{00A6}": .noticed("|"),
        // … 108 entries in all
    ]
```

and the spec's copy of it (§1.2) is the source of truth: `TransliterationTableTests` reads the
Markdown table out of `book-format.md` and fails if the two differ by one entry. That's a
pattern worth stealing for any rule a non-programmer must be able to review: keep it as a table
in a document, and make a test the bridge.

The cost is real, and the owner accepted it: a book can't hold an accented name. `Renée`
is stored as `Renee`, silently when it's pasted, and Greek or Japanese text becomes `[?]`. A
file that holds accented letters (one written by an earlier, Latin-1 build of Scene It, say)
gets a notice for them, so it opens read-only as repaired, and its original is
kept when the writer makes it editable (ADR 0024).

There's deliberately no Unicode normalization. A decomposed `e` + U+0301 is two scalars, an
`e` and a combining accent, and the table simply removes the accent, so it reads as `e`, just
like a precomposed `é`. A system transform such as Foundation's
`precomposedStringWithCanonicalMapping` or ICU's `Latin-ASCII` transliterator would do the job
in one call, but its tables move with the operating system, and a book must read the same on
every Mac.

The output is `[UInt8]`, one byte per character. That's a deliberate choice of
representation. Swift's `String` is a sequence of grapheme clusters, and its `==` compares
*canonical equivalence*, so `"é"` (one scalar) equals `"e\u{301}"` (two). That's right for
UI text and wrong for a file format, where offsets must count something exact. After
admission every character is one ASCII byte, so a byte array gives us what Rust's `&[u8]`
gives you: offsets are indices, slicing is O(1), and equality is bytewise. The model's
`String`s are built only at the end, from those bytes, and since they're ASCII a character is
also one UTF-16 unit, which is what AppKit's `NSRange` counts.

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

- which part of the file the reader is in: the story, the Boneyard or the Deleted section
  (`FilePart`, below). It changes which list a scene goes in but not what it contains;
- the ids already used, because a duplicate scene id gets a fresh one (§2.2). Fresh ids are
  assigned after the whole file is read, avoiding every id that appears anywhere in it.

The fuzz suite (§7) found that the Boneyard heading is a third: a `# Boneyard` typed early
makes the real one a "second Boneyard heading", which becomes an error entry in the scene
it used to end, and a damaged real one sends the Boneyard's scenes back into the story.
That's the kind of thing a property test is for: the rules were in the spec all along, and
the test made their reach visible. The spec's §6 now lists all three exceptions.

### The Deleted section: an ordered enum

[ADR 0031](../decisions/0031-boneyard-delete-hides.md) added a third part: deleting a
Boneyard scene moves it under a `# Deleted` heading at the end of the file, where the app
never shows it (§1.9). Rather than a second `inDeleted: Bool` beside `inBoneyard: Bool`
(four states, one of them meaningless), the reader holds one value of an ordered enum:

```swift
enum FilePart: Comparable, CaseIterable, Sendable {
    case story, boneyard, deleted
    ...
}
```

A Swift enum with no associated values gets `Comparable` by declaring it, ordered by case
order, much like `#[derive(PartialOrd, Ord)]` on a fieldless Rust enum. That turns the
spec's order rule ("a heading moves the file forward to its part, never back") into one
comparison in the parser:

```swift
        case .heading(1, let name):
            guard let next = FilePart(heading: name), next > part else {
                startsAPart = false
                break
            }
```

A `# Boneyard` after `# Deleted`, or a second of either, fails `next > part` and falls
through to the "not understood" path, a `[line]` entry, exactly like any unknown heading.
The same enum maps each part to its list (`part.scenes` is a `WritableKeyPath<Book,
[BookScene]>`, roughly a typed lens), so the serializer and the parser walk
`FilePart.allCases` and can't disagree about the order.

The exclusion from the rest of the app is structural: `Book` keeps `scenes`, `boneyard` and
`deleted` as separate arrays, and search, word counts, filed-copy counts and navigation only
ever read the first two. What must see every scene (unique ids, error entries, the format
itself) reads `everyScene`, a name chosen to stand out in review.

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
range may bridge paragraph breaks (§4.2). So "the maximal ranges of runs with this color"
is just grouping consecutive runs (comments use the same grouping, for all of them in one pass):

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
        guard reread == book.withMaximalRuns else { throw .changed }
        guard serialize(reread) == bytes else { throw .unstable }
        return bytes
    }
```

`throws(VerificationFailure)` is a *typed throw*, Swift's closest thing to
`Result<Data, VerificationFailure>`: the caller's `catch` gets a `VerificationFailure`, not
an `any Error`.

Why three checks? A book may legitimately carry error entries from an earlier load, so "no
entries" would make such a book unsaveable. What must not happen is a *new* entry: that
means the serializer wrote something the parser reads differently.

The book comparison is the one the adversarial review added. Comparing bytes alone missed a
lossy save: a run carrying a comment id that the scene's comment list doesn't have is
written without it, so the bytes are perfectly stable, and the id is simply gone. Comparing
the re-read book with the original (after merging neighbouring runs, which is the one
change the format makes on purpose) catches that whole class: whatever the file can't
hold shows up as a refused save, never as a silently different book. Comparing `Book`s is
safe here, despite `String ==`'s canonical equivalence (§2), because every string in the
model is admitted ASCII, where equivalent means identical.

### Making bad text unrepresentable

The model's strings would be a hole in that argument if anything could go into them. So
the types apply the character policy themselves. `Run.text`, `SceneTitle.text`, tags,
comment text and the book's title admit their text in the initializer and on every
assignment:

```swift
    public var text: String {
        didSet { text = CharacterPolicy.admittedLine(text) }
    }
```

This is Rust's private field plus a smart constructor, with one Swift twist: a `didSet` that
assigns to its own property doesn't trigger itself again, so the property stays a plain
`var` at every call site (`run.text += "…"` still works) while no path can store text that
`book.md` can't hold. An emoji becomes `[?]`, `é` becomes `e`, `—` becomes `--`, and in
one-line fields a line break becomes a space, which is what the parser would make of them on
the next load anyway. An error entry's payload is normalized the same way, to a line as §1.3's trimming
leaves it. `Paragraph` drops empty runs the same way, so a stray empty run left behind by an
edit can't make a save fail: it had nothing to write.

The convenience has a cost, which the second review measured: `text += piece` re-admits the
*whole* string, so merging 20,000 pieces one `+=` at a time took 11.6 s instead of 0.1 s.
Code that builds text from pieces (merging runs, `RunCodec`) joins them first and admits
once, and a scaling test pins that down.

The alternative was a separate `AdmittedText` type for every field. That would have made the
invariant visible in signatures, but it would have rippled through the editor bridge, the
word counts and every test that writes `Run("…")`, for no extra guarantee: the property
observer makes the invalid state just as unreachable.

## 7. How it's tested

**The spec's examples, verbatim.** The owner's demo book is a fixture and must round-trip
byte for byte with no error entries. The spec's complete example (§9.1) must be its own
canonical form, and each row of its "parsed as" table is asserted. The damaged example
(§9.2) is rebuilt as bytes, with `\r\n` endings, the two Windows-1252 bytes and the cut-off
last line, and must produce exactly its fourteen entries. Every table row in the spec with an
input and a result is a parameterized test.

**Round trip, as a property.** `BookGenerator` makes random books from a seed, using the
characters that need escaping and runs that start with `# `, `- `, `---` or `<br>`. For each
of 300 seeds, `serialize(parse(serialize(b)))` must equal `serialize(b)`, the parse must
find exactly `b`'s own error entries, and the parsed book must equal `b`. This is
`proptest` without the shrinking: a seeded `SplitMix64` makes each case reproducible, and a
separate test asserts that the generator really produces overlapping comments, detached
comments, empty paragraphs and every error tag, so the property can't quietly test less
than it claims.

**Fuzzing.** Every seed is XORed with `FUZZ_SALT` from the environment, so
`FUZZ_SALT=7 swift test` explores fresh cases and a failure reproduces with the same salt.
The suites:

- random bytes, and random lines of structure (headings, entries, fences), thousands of
  each: the parse must always produce a book whose `verifiedSerialization` succeeds. That's
  stronger than "doesn't crash": anything the writer opens can be saved;
- several random mutations of valid files (insert, delete or change a byte, truncate,
  duplicate a line, insert a structural line), with the same requirement;
- **damage locality**: 4,500 single mutations of valid files. The test knows where each
  scene's bytes are, so it knows which scenes a mutation touched. Every scene that wasn't
  touched (and isn't the one before a touched one, since breaking a `##` line merges a scene
  into its predecessor) must parse exactly as before, apart from the two non-local effects
  the spec defines (§4). Each must also keep its part (story, Boneyard or Deleted) unless a
  `# Boneyard` or `# Deleted` line changed, and the untouched scenes must keep their order. About 16,000
  untouched scenes are compared per run;
- **conservation**: unique words scattered through files full of structure and damage must
  all survive parse → serialize: the parser may put a word in an error entry, but never
  drops one;
- **books built through the API**: random books over printable ASCII, every character the
  transliteration table spells, and every token that looks like structure must read back as
  themselves and pass verification.

**Performance.** A 120,000-word novel (about 700 KB) parses in about 0.37 s and serializes
in about 0.09 s in a debug build, and in about 30 ms each in a release build. The test
asserts under a second in debug.

**Scaling.** The review found five paths that were quadratic in the worst case:
appending to a `String.UnicodeScalarView` in a loop, rebuilding the set of earlier comment
ids for every comment line, scanning every run once per comment when writing, and hashing a
growing array per character to track overlapping comments. Each now builds into one
pre-sized buffer, keeps one growing set, or sweeps the comments' endpoints once. The
scaling tests double each input and require the time to grow by less than 3× (linear growth
is 2×, quadratic 4×), taking the fastest of three runs so scheduling noise doesn't flake
them.

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
