A book saved by an editor as Windows-1252 (or Latin-1, which agrees from 0xA0 up): every byte from 0x80 to
0xFF on its own, between two `x`s. None is valid UTF-8, so each is read as its Windows-1252 character
(one encoding notice for the book), which the transliteration table then spells in ASCII or, if it has no
entry (and for the five bytes 1252 leaves undefined), replaces with `[?]`. This is how a book written by
a Latin-1 build of Scene It, or by another editor, reads: as repaired, so it opens read-only (ADR 0024).
