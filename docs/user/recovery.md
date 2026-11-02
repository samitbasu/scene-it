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
| `My Novel.sceneit/book.json.conflict-<time>` | a version another program wrote while Scene It was saving | until you delete it |
| `My Novel.sceneit/Backups/book-<time>.json` | snapshots | one per 10 minutes for a day, one per day for 30 days, then one per week |
| `~/Library/Application Support/Scene It/Backups/<id>/book-<time>.json` | the same snapshots, outside the book, so they survive the book being deleted | the same |

- `<time>` is in UTC (Greenwich time), written `20261101T143005Z` for 1 November 2026 at
  14:30:05 UTC.
- `<id>` is the text in `My Novel.sceneit/Backups/book-id`. Each folder under
  `Application Support/Scene It/Backups/` also has a `package-path` file naming the book
  it belongs to. A duplicated book gets its own id, and so its own folder, the first time
  it's saved.
- To open `~/Library`, choose **Go ▸ Go to Folder…** in Finder and type
  `~/Library/Application Support/Scene It/Backups`.

To restore a version: copy the book somewhere safe first, then replace its `book.json`
with a copy of the backup, renamed to `book.json`.
