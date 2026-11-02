# Getting an older version of your book back

> A stub: issue #40 turns this into a full guide. It lists where every backup lives.

Scene It has no restore command yet. Every backup is an ordinary `book.json` file that
you can copy back by hand. Quit Scene It first.

To see inside a book in Finder, Control-click `My Novel.sceneit` and choose
**Show Package Contents**.

| Where | What | How long it's kept |
| --- | --- | --- |
| `My Novel.sceneit/book.json` | the book | |
| `My Novel.sceneit/book.json.bak1`, `.bak2`, `.bak3` | the three versions before the last save, newest first | until the next three saves |
| `My Novel.sceneit/book.json.conflict-<time>`, also `-<time>-2`, `-<time>-3`, … | a version another program wrote while Scene It was saving (the number is added when there was more than one in the same second). Rarely, if that name couldn't be used, the version is first left in a hidden `.book.json.<…>.tmp` file, and a save at least 10 minutes later renames it to `book.json.recovered-<time>.json` | until you delete it |
| `My Novel.sceneit/book.json.recovered-<time>.json`, also `-<time>-2.json`, `-<time>-3.json`, … | a version left behind by a save that was interrupted (a crash, or another program writing at the same moment) and found nowhere else in the book; `<time>` is when that version was written | until you delete it |
| `My Novel.sceneit/Backups/book-<time>.json` | snapshots | one per 10 minutes for a day, one per day for 30 days, then one per week |
| `My Novel.sceneit/Backups/book.json.recovered-<time>.json`, also `-<time>-2.json`, … | a snapshot that was interrupted before it was finished (a crash), holding a version found nowhere else in the book; `<time>` is when that version was written | until you delete it |
| `~/Library/Application Support/Scene It/Backups/<id>/book-<time>.json` | the same snapshots, outside the book, so they survive the book being deleted | the same |
| `~/Library/Application Support/Scene It/Backups/<id>/book.json.recovered-<time>.json`, also `-<time>-2.json`, … | an interrupted snapshot holding a version found in no other snapshot in that folder | until you delete it |

- `<time>` is in UTC (Greenwich time), written `20261101T143005Z` for 1 November 2026 at
  14:30:05 UTC.
- Hidden files named `.book.json.<…>.tmp` or `.book.json.bak1.<…>.tmp` belong to a save in
  progress, or to one that was interrupted. Once one is 10 minutes old, the next save
  deletes it if `book.json`, a `.bak` file or a snapshot already holds exactly the same
  text, and otherwise renames it to `book.json.recovered-<time>.json`. It is never deleted
  while its text exists nowhere else.
- Hidden files in `Backups/` or in a book's folder in `Application Support` belong to a
  snapshot being written, or to one that was interrupted: `.book-<time>.json.<…>.tmp`,
  `.book-id.<…>.tmp` and `.package.json.<…>.tmp`. Once one is 10 minutes old, the next
  snapshot clears it away. A `.book-<time>.json.<…>.tmp` file is deleted if a snapshot in
  the same folder (or, in `Backups/`, `book.json` or a `.bak` file) already holds exactly the
  same text, and otherwise renamed to `book.json.recovered-<time>.json` in the same folder,
  which is never deleted automatically. A `.book-id.<…>.tmp` or `.package.json.<…>.tmp` file
  is deleted once `book-id` or `package.json` beside it is valid: it holds an id or a record
  that was never used, so nothing is lost.
- The daily and weekly snapshots are the **first** of that UTC day or week: they show
  your book as it was when you started working that day or week, not at the end of it.
  The newest snapshot is always kept too.
- `<id>` is the text in `My Novel.sceneit/Backups/book-id`. Each folder under
  `Application Support/Scene It/Backups/` also has a `package.json` file naming the book
  it belongs to. A duplicated book gets its own id, and so its own folder, the first time
  it's saved; its earlier history stays in the original's folder and in its own
  `Backups/`.
- One limit: an exact clone that sits where the original was can't be told apart from it.
  That means a whole drive cloned block by block, or a copy put in the original's place on
  a volume without a UUID (some network shares). If you use both, their snapshots in the
  `Application Support` folder can mix. Each book's own `Backups/` folder is still right.
- To open `~/Library`, choose **Go ▸ Go to Folder…** in Finder and type
  `~/Library/Application Support/Scene It/Backups`.

To restore a version: copy the book somewhere safe first, then replace its `book.json`
with a copy of the backup, renamed to `book.json`.
