# 0023 — Word counts match Microsoft Word

**Status:** Accepted (2026-11-02)

A word is a maximal run of non-whitespace characters. A run made only of punctuation (a standalone `--`, `...` or `-`) doesn't
count. So "well-known" is 1 word and "dawn--and" is 1 word, as in Word and Pages, whose counts publishers and contests
ask for. Counts cover scene bodies only: no titles, no notes, and the Boneyard excluded. They're cached per scene and recomputed
only for the scene whose body changed.

**Not chosen:** macOS linguistic word boundaries, which count hyphenated and dash-joined words as several and so disagree with
the writer's exported Word document.

**Open detail (moot since [0028](0028-strict-ascii-no-input-methods.md), which stores U+00A0 as a space):** a non-breaking space (U+00A0, allowed by Latin-1) currently separates words. Whether Word treats it the same way is unverified; revisit if a writer reports a mismatch.
