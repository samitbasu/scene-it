Book format §9.2 as the bytes the spec describes: `\r\n` endings, no final newline (it's cut off inside the last
line), and the two single bytes 0x93 and 0x94 (Windows-1252 curly quotes, invalid as UTF-8) where the spec shows
`⟨93⟩` and `⟨94⟩`. The spec's table of the parse is `entries.txt`'s twelve rows.
