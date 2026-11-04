# 0033 — Search: Whole word keeps the possessive; contractions stay whole; tags are single-line, one per line; punctuation goes to the find bar

**Status:** Accepted (2026-11-03). Refines PLAN §9.2; resolves the open questions of PR #84 (#89).

1. **Whole word** turns the endings off but still matches a possessive `'s`. `James` finds `James's`, and `bear`
   finds `bear's`, but not `bears`. There is no substring mode.
2. **Contractions aren't possessives,** in any mode. A short list, kept as data in one place
   (`SearchText.contractions`): it's, he's, she's, that's, let's, what's, there's, here's, who's, where's, how's, why's,
   when's. Each is kept whole, so `it` doesn't find `it's`, and `it's` finds only `it's` (in any case, unless Match case
   is on).
3. **Tags:** a scene's tag set stays one search unit, but its tags are joined by a line break instead of `", "`. A line
   break ends a sentence, so a phrase can't span two tags: `"red door"` matches only a tag that says `red door`.
4. **Tags are single-line,** as a scene title is: a line break typed or pasted into a tag becomes a space
   (`CharacterPolicy.admittedTags`, applied by `BookScene.tags` and `FiledCopy.tags`). So a `"\n"` in a tag unit is
   always a separator between two tags, which the Search sheet (#31) can rely on to split or show them.
5. **Punctuation:** the Search window stays word-based and can't find literal punctuation. A stray straight quote, `--`
   or `...` is found with the scene's find bar (Cmd+F, PLAN §8).

Known gap, accepted: the stemmer doesn't join an `-es` plural of a word that ends in `s`, so `James` doesn't find
`Jameses` and `bus` doesn't find `buses`, in any mode. `horse`/`horses` and `house`/`houses` do match (the `s` is
dropped from a stem that ends in `e`). `pluralsOfWordsEndingInSAreAKnownGap` pins this.

Unchanged: hyphenated query words are separate keywords, ranked by adjacency. Since ADR 0028 accents no longer matter for
Match case.

## Alternatives
- **Whole word as an exact match** (as first built), so `bear` misses `bear's`. A writer looking for a name nearly always
  wants its possessive too.
- **A substring mode** (`bear` in `bearing`). Declined: the find bar already does literal matching within a scene.
- **Treating every `'s` as a possessive** (as first built), so `it` finds `it's`. A writer searching for `it` doesn't
  mean `it is`.
- **One unit per tag.** Gives the same phrase boundary, but a scene's tags would then compete as separate hits and
  repeat the "+N more" count. A line break gets the boundary from the sentence rule that already exists.
- **Searching punctuation in the Search window.** `"` already delimits phrases, and a token model that keeps
  punctuation would complicate every other query for a rare need.

## Consequences
- One private function, `SearchText.possessor`, decides what a possessive is (an `'s` that isn't on the contraction
  list). The stemmer and Whole word (`withoutPossessive`) both call it, so they can't disagree.
- Each distinct spelling is interned under six comparison keys instead of four.
- The contraction list is closed: an `'s` contraction not on it (`one's`, `John's` meaning "John is") reads as a
  possessive. Adding one is a one-line change to the list.
- **Book format:** `\n` in a `tags:` value is still an escape for a line break (§4.1). Read from a file, it's a
  **repair**: the tag gets a space, and its owner gets a notice (`This scene's tags held line breaks, which were changed
  to spaces.`, or the filed copy's equivalent).
  - In `book.md`, the scene's notice makes the book open read-only as repaired, with its original kept (ADR 0024).
  - In `Archive/index.md`, ADR 0024 doesn't apply. The filed copy's notice follows the archive index's own rule: a
  rewrite that changes what was written first keeps `Archive/index.md.original-<UTC>.md` (book format §8, PR #85).
  - Typing and pasting stay silent (ADR 0028), and so does repairing a `[metadata] tags:` entry in the Errors tab,
  which is the writer's own edit: such an entry reads as `.readsNow`, and applying it stores the spaces.
  `CharacterPolicy.admittedTags` is the model's backstop.
  The writer never writes `\n` in a tag. The app never produced such tags, so only a hand-edited file can hold one.
  Corpus cases `s2.2-tags-line-break-noticed` and `s8-tags-line-break-noticed` pin it.
- Phrases still compare words exactly: `"bear claw"` doesn't find `bear's claw`.
- Words that occur in different tags of a scene rank in the paragraph tier, not the sentence tier.

## Learning notes
A Swift enum with `Int` raw values and `CaseIterable` gives `allCases` in declaration order and `rawValue` as an index,
which is how `Comparison.ordinal` indexes `FormKeys`' interned keys without a hand-written `switch` per combination;
Rust would reach for `#[repr(u8)]` plus a `strum::EnumIter` derive.
