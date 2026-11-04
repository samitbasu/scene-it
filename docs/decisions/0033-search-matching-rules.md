# 0033 — Search: Whole word keeps the possessive; tags are one per line; punctuation goes to the find bar

**Status:** Accepted (2026-11-03). Refines PLAN §9.2; resolves the open questions of PR #84 (#89).

1. **Whole word** turns the endings off but still matches a possessive `'s`. `James` finds `James's`, and `bear`
   finds `bear's`, but not `Jameses` or `bears`. There is no substring mode.
2. **Tags:** a scene's tag set stays one search unit, but its tags are joined by a line break instead of `", "`. A line
   break ends a sentence, so a phrase can't span two tags: `"red door"` matches only a tag that says `red door`.
3. **Punctuation:** the Search window stays word-based and can't find literal punctuation. A stray straight quote, `--`
   or `...` is found with the scene's find bar (Cmd+F, PLAN §8).

Unchanged: hyphenated query words are separate keywords, ranked by adjacency. Since ADR 0028 accents no longer matter for
Match case.

## Alternatives
- **Whole word as an exact match** (as first built), so `bear` misses `bear's`. A writer looking for a name nearly always
  wants its possessive too.
- **A substring mode** (`bear` in `bearing`). Declined: the find bar already does literal matching within a scene.
- **One unit per tag.** Gives the same phrase boundary, but a scene's tags would then compete as separate hits and
  repeat the "+N more" count. A line break gets the boundary from the sentence rule that already exists.
- **Searching punctuation in the Search window.** `"` already delimits phrases, and a token model that keeps
  punctuation would complicate every other query for a rare need.

## Consequences
- `SearchText.withoutPossessive` is shared by the stemmer and Whole word, so the two can't disagree on what a possessive is.
- Each distinct spelling is interned under six comparison keys instead of four.
- Whole word's possessive rule also applies to contractions spelled with `'s`: `it` finds `it's`, as it already did
  without Whole word.
- Phrases still compare words exactly: `"bear claw"` doesn't find `bear's claw`.
- Words that occur in different tags of a scene rank in the paragraph tier, not the sentence tier.

## Learning notes
A Swift enum with `Int` raw values and `CaseIterable` gives `allCases` in declaration order and `rawValue` as an index,
which is how `Comparison.ordinal` indexes `FormKeys`' interned keys without a hand-written `switch` per combination;
Rust would reach for `#[repr(u8)]` plus a `strum::EnumIter` derive.
