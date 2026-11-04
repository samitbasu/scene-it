# The format test corpus

The test vectors of [`book.md` and `Archive/index.md`](../../docs/format/book-format.md) as plain files, so any
implementation of the format can be checked against the same cases (ADR 0025). Scene It's Swift tests read them from
here; nothing here depends on Swift.

```
Tests/Corpus/
  book/<case>/            a book.md case
  archive-index/<case>/   an Archive/index.md case
  fuzz-seeds/             dictionaries and seed lists for fuzzers
```

## A case

Each case is a directory named for the rule it shows, prefixed with the spec section (`s4.8-comment-e9-quote-mismatch`
is §4.8, rule E9). It holds:

| File | Holds |
| --- | --- |
| `input.md` | The file's raw bytes, exactly as they'd be on disk: any encoding damage, `\r\n` endings, byte-order mark or missing final newline is the point of the case. Can be empty. |
| `expected.md` | What serializing the parse of `input.md` must give, byte for byte: the canonical form (§7.1). |
| `entries.txt` | The parse's error entries, one per line, in the Errors tab's order (§5.4): the book's own, then each story scene's, each Boneyard scene's and each deleted scene's (§1.9), each in model order (§5.2). Empty if there are none. |
| `properties.txt` | The byte properties of `input.md` that are the point of the case, one per line: `has-bom`, `has-crlf`, `invalid-utf8`, `no-final-newline`, `trailing-space` (a line ending in a space or tab). It lists exactly the ones `input.md` has, and is left out when there are none. |
| `notes.md` | Optional: anything about the case worth saying that the files don't. |

An editor or a checkout that "cleans" a file (trims trailing spaces, adds a final newline, converts line endings or
the encoding) would leave a case that still passes but no longer tests what it says. `.gitattributes` and
`.editorconfig` here tell git and editors to keep the bytes, and Scene It's tests check every `input.md` against its
`properties.txt`, so a cleaned file fails.

Because the canonical form is lossless (§7.2: a parse result always reads back as itself), `expected.md` pins down the
whole parse: every title, paragraph, style, comment, mark and entry. `entries.txt` adds what isn't in the file: which
entries this parse made and why each is an error.

### `entries.txt`

```
<origin> <reason> - [<tag>] <payload>
```

The part from `- [` on is the entry exactly as an `### Unparsed` line writes it (§5.1; `- [<tag>]` alone for an empty
payload). The two words before it:

- **origin**: `new` if this parse made the entry (a line it couldn't read, or a notice), `preserved` if it was read
  from an `### Unparsed` section as it stands (ADR 0024: only new entries make a book open read-only).
- **reason**: the first rule the entry breaks, derived as §5.4 says, by reading its payload back in its place:

| Reason | Meaning |
| --- | --- |
| `E1` … `E10` | A `[comments]` or `[marks]` entry: §4.8's rule. |
| `not-a-field` | A `[front matter]` or `[metadata]` payload that isn't `key: value`. |
| `unknown-key`, `repeated-key` | A key the section doesn't have, or has already had (§1.5, §2.2). |
| `bad-id`, `bad-date`, `bad-format` | A value that doesn't parse (§2.2, §1.5). |
| `id-in-use` | An `id` another scene of the book has. |
| `other-format` | A `format` this version doesn't read as its own (§10 Q7). |
| `line`, `notice` | A `[line]` or `[notice]` entry, which has a fixed explanation. |
| `reads-now` | The payload reads correctly where it is now: repairing it as it stands would apply it. |
| `n/a` | An archive index entry: the index has no Errors tab (§10 Q12). |

## Running the corpus

For every case, with the parse defaults below:

0. Check that `input.md` has exactly the byte properties `properties.txt` lists (none, if there's no such file).
1. Parse `input.md`; serialize the result. It must equal `expected.md` byte for byte.
2. List the parse's entries as above. The text must equal `entries.txt` byte for byte (each line ends in `\n`).
3. Parse `expected.md`. Serializing it must give `expected.md` again, and its entries must be `entries.txt` with every
   origin `preserved`.

An implementation that has no Errors tab can compare the entries from `- [` on and ignore the first two words.

### Parse defaults

The parser takes the time a book was opened and an id generator as inputs (§5.3). The corpus fixes them:

| Input | Value |
| --- | --- |
| Opened at (for a missing `modified`) | `2026-11-02T08:00:00-08:00` |
| Fresh scene ids, in order | `id-A0`, `id-B0`, …, `id-Z0`, `id-A1`, …, skipping any the file already uses |
| A filed copy's modification day (for a missing or bad `filed`) | `2026-03-DD` with `DD` = 1 + (the copy's number mod 28): `save0005.md` gets `2026-03-06` |

### Fuzz seeds

`fuzz-seeds/` holds what Scene It's seeded fuzz tests build their inputs from, for a fuzzer of another implementation
to start from:

| File | Holds |
| --- | --- |
| `*.dict` | Dictionaries in libFuzzer's format: one `"token"` per line, `\\`, `\"` and `\xHH` escapes, `#` comments. Each file's first line says how the tests use it. |
| `mutation-bases.txt` | The cases (one `<group>/<case>` per line) whose `input.md` the mutation fuzzer damages. They're canonical, so a fuzzer can check that damage stays local (§6). |

## Adding or changing a case

Write `input.md` (and `properties.txt` and `notes.md` where they apply), then let Scene It write the results:

```
CORPUS_REGENERATE=1 swift test --filter CorpusConformance
```

That rewrites every case's `expected.md` and `entries.txt` from the Swift implementation, and the run **fails** on
purpose, one issue per case, so a regenerating run can never pass for a real one. **Review the diff**, then rerun
without the variable: a changed result is a change to the format's behaviour, and needs the spec to agree.
`scripts/check.sh` unsets `CORPUS_REGENERATE`, so the commit gate only ever checks the corpus.
