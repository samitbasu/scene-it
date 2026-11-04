The transliteration table (§1.2) applies to the whole file before any line is read, so the id `café` reads as
`cafe`, which is a valid id: the scene keeps it, and the only entry for it is the transliteration notice. (Before
ADR 0028 this case was `s2.2-invalid-id-latin1-letter`: `é` was stored, and outside an id's characters.)
