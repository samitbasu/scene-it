A no-break space is ASCII whitespace to nothing in the file: it isn't trimmed, and a line holding only
one isn't blank. It becomes a space as text, silently, so offsets counted over the file's characters
still hold: the second paragraph is one space (`c1`), and `c2` still finds `After.`.
