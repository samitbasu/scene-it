# Getting an older version of your book back

> A stub: issue #40 turns this into a full guide. It lists where every backup lives.

Scene It has no restore command yet. Every backup is an ordinary `book.md` file that
you can copy back by hand. Quit Scene It first.

To see inside a book in Finder, Control-click `My Novel.sceneit` and choose
**Show Package Contents**.

| Where | What | How long it's kept |
| --- | --- | --- |
| `My Novel.sceneit/book.md` | the book | |
| `My Novel.sceneit/book.md.bak1`, `.bak2`, `.bak3` | the three versions before the last save, newest first | until the next three saves |
| `My Novel.sceneit/book.md.conflict-<time>`, also `-<time>-2`, `-<time>-3`, … | a version another program wrote while Scene It was saving (the number is added when there was more than one in the same second). Rarely, if that name couldn't be used, the version is first left in a hidden `.book.md.<…>.tmp` file, and a save at least 10 minutes later renames it to `book.md.recovered-<time>.md` | until you delete it |
| `My Novel.sceneit/book.md.original-<time>.md`, also `-<time>-2.md`, `-<time>-3.md`, … | the book's file exactly as it was when Scene It found it damaged (or changed by hand in a way it couldn't fully read) and you chose **Make Editable**; `<time>` is when you chose it | until you delete it: Scene It never deletes, rotates or replaces it |
| `My Novel.sceneit/book.md.recovered-<time>.md`, also `-<time>-2.md`, `-<time>-3.md`, … | a version left behind by a save that was interrupted (a crash, or another program writing at the same moment) and found nowhere else in the book; `<time>` is when that version was written | until you delete it |
| `My Novel.sceneit/Archive/save0001.md`, `save0002.md`, … | the copies you filed with **File a Copy…**, each exactly the book as it was when you filed it. Locked (Finder shows them as Locked) | until you delete them: Scene It never changes, renames or deletes one |
| `My Novel.sceneit/Archive/index.md` | the File Cabinet's list: each filed copy's date, tags, note and counts. A plain text file | rewritten when you file a copy |
| `My Novel.sceneit/Backups/book-<time>.md` | snapshots | one per 10 minutes for a day, one per day for 30 days, then one per week |
| `My Novel.sceneit/Backups/book.md.recovered-<time>.md`, also `-<time>-2.md`, … | a snapshot that was interrupted before it was finished (a crash), holding a version found nowhere else in the book; `<time>` is when that version was written | until you delete it |
| `~/Library/Application Support/Scene It/Backups/<id>/book-<time>.md` | the same snapshots, outside the book, so they survive the book being deleted | the same |
| `~/Library/Application Support/Scene It/Backups/<id>/book.md.recovered-<time>.md`, also `-<time>-2.md`, … | an interrupted snapshot holding a version found in no other snapshot in that folder | until you delete it |

- `<time>` is in UTC (Greenwich time), written `20261101T143005Z` for 1 November 2026 at
  14:30:05 UTC.
- When Scene It can't read part of `book.md` as written (a sync service emptied or cut it
  short, or a text editor saved it in another encoding), it repairs the book while opening
  it and opens it **read-only**, so nothing is saved over the damaged file. Choosing
  **Make Editable** first keeps the file exactly as it was, as `book.md.original-<time>.md`,
  and only then lets Scene It save. If the repaired book is missing something, that file
  is where to find it: open it in any text editor.
- A book saved by a newer version of Scene It also opens read-only, and stays that way:
  this version can't save it without losing what the newer one added.
- A book from an early test version of Scene It holds `book.json` instead of
  `book.md`. This version can't open it, and leaves it untouched.
- Hidden files named `.book.md.<…>.tmp`, `.book.md.bak1.<…>.tmp` or `.book.md.original-<time>.md.<…>.tmp` belong to a save (or a Make Editable) in
  progress, or to one that was interrupted. Once one is 10 minutes old, the next save
  deletes it if `book.md`, a `.bak` file or a snapshot already holds exactly the same
  text, and otherwise renames it to `book.md.recovered-<time>.md`. It is never deleted
  while its text exists nowhere else.
- Hidden files in `Backups/` or in a book's folder in `Application Support` belong to a
  snapshot being written, or to one that was interrupted: `.book-<time>.md.<…>.tmp`,
  `.book-id.<…>.tmp` and `.package.json.<…>.tmp`. Once one is 10 minutes old, the next
  snapshot clears it away. A `.book-<time>.md.<…>.tmp` file is deleted if a snapshot in
  the same folder (or, in `Backups/`, `book.md` or a `.bak` file) already holds exactly the
  same text, and otherwise renamed to `book.md.recovered-<time>.md` in the same folder,
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

## Filed copies

- A filed copy is a complete `book.md`: to read one, open it in any text editor, or copy it
  out of the package and rename it `book.md` to restore it as below.
- Scene It locks each filed copy as it files it, so nothing (Scene It included) can change,
  rename or delete it by accident. On a disk that can't lock files (some network shares)
  Scene It says so when you file; it still never writes to the copy.
- If `index.md` is lost, nothing is lost but the tags and notes: the next time the book opens,
  every `saveNNNN.md` is listed again, with its date and counts. A line that `index.md`
  doesn't understand is kept in it, under `### Unparsed`, and so is the entry of a copy whose
  file isn't there (renamed or moved, say). Before Scene It rewrites an `index.md` like that,
  it keeps the file exactly as it was, as `Archive/index.md.original-<time>.md` (never
  deleted automatically). An `index.md` saved by a newer version of Scene It is left exactly
  as it is.
- Hidden files named `.save0001.md.<…>.tmp` or `.index.md.<…>.tmp` in `Archive/` were left by
  a filing that was interrupted. Once one is 10 minutes old, the next save deletes a
  `.saveNNNN.md.<…>.tmp` if a filed copy, `book.md`, a `.bak` file or a snapshot holds exactly
  the same text (otherwise it's renamed to `Archive/book.md.recovered-<time>.md`), and a
  `.index.md.<…>.tmp` once `index.md` beside it reads cleanly. A filed copy itself is never
  touched.
- A file named `save` and more than six digits (`save1234567.md`) isn't counted as a filed
  copy, so it can't use the numbers up; it's still never changed.
- **To unlock a filed copy** (to delete it, say), quit Scene It, then in Terminal:

  ```sh
  chflags nouchg "My Novel.sceneit/Archive/save0001.md"
  ```

  Or select it in Finder (Show Package Contents), choose **File ▸ Get Info**, and uncheck
  **Locked**. `chflags uchg` locks it again.

To restore a version: copy the book somewhere safe first, then replace its `book.md`
with a copy of the backup, renamed to `book.md`.

## Bringing back a scene you deleted from the Boneyard

Deleting a scene from the Boneyard doesn't remove it from your book. Scene It moves it to
the end of `book.md`, under a line that says `# Deleted`, and stops showing it anywhere:
not in the Boneyard, search, word counts, exports or printouts. Its text, notes and
comments are all still there, so it's also in every backup and filed copy. Scene It has no
command to bring it back; you do that in a text editor:

1. Quit Scene It.
2. Copy the book somewhere safe first.
3. Open `My Novel.sceneit/book.md` in a plain text editor (TextEdit works: choose
   **Format ▸ Make Plain Text** if it isn't already). Control-click the book in Finder and
   choose **Show Package Contents** to find it.
4. Find the `# Deleted` line near the end. Each scene after it starts with a line beginning
   `## ` (its title), followed by `id:` and `modified:` lines. The most recently deleted
   scene comes first.
5. Select the scene's lines: from its `## ` line down to just before the next `## ` line
   (or the end of the file). Cut them.
6. Paste them where you want the scene:
   - **back in the Boneyard:** just after the `# Boneyard` line. If there's no `# Boneyard`
     line (the Boneyard was empty), type `# Boneyard` on its own line just above
     `# Deleted`, and paste the scene between the two, so it's **above** `# Deleted`.
     Anything below `# Deleted` stays deleted;
   - **back in the story:** just before the `## ` line of the scene it should come before,
     or, to make it the story's last scene, just above `# Boneyard` (or just above
     `# Deleted`, if there's no `# Boneyard` line).

   Keep a blank line before the scene's `## ` line and after its last line.
7. Save the file and open the book in Scene It.

If the `# Deleted` line is now empty (no scenes after it), you can delete it or leave it:
Scene It drops it the next time it saves. Don't change the `id:` line: it's how Scene It
knows the scene. If something you pasted doesn't read, Scene It opens the book read-only
and lists what it couldn't understand in the **Errors** tab, so nothing is lost; your copy
from step 2 is there too.

### If scenes vanished after you edited `book.md`

Look for a line that says `# Deleted` (in any capitals) in the wrong place. Scene It treats
every scene after that line as deleted, and when nothing after it gives the mistake away
it hides them **silently**: the book opens normally, with nothing in the **Errors** tab.
The scenes are still in the file. Quit Scene It, move the `# Deleted` line back to where it
belongs (after the Boneyard's scenes), or delete it if your book had no deleted scenes,
then open the book again.
