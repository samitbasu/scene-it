# Novel Writing App — Build Plan

Status: ready to build · Platform: macOS 14+ · Language: Swift (Swift 6 language mode) · UI: SwiftUI + AppKit `NSTextView` (TextKit 2) · Storage: one JSON file per book · Dependencies: Apple SDKs only

---

## 1. Product summary

A Mac app for writing a novel as an ordered list of **scenes**. The window is built around a manuscript-style page:
- **Typography:** Times New Roman 12 pt, double-spaced, with indented paragraphs.
- **Left:** an icon rail that opens full-width **sheets** (Scenes, Search, File Cabinet).
- **Right:** a panel with **Comments**, **Notes** and **Tags** tabs.

Other key ideas:
- **The Boneyard:** cut scenes go here, and can be restored at any time.
- **Filed copies:** **File a copy** saves a dated, tagged, read-only snapshot of the whole book into an archive. The archive can be browsed, searched and opened read-only.

**Out of scope for v1:** Windows, Linux, iPad, dark mode, sync, collaboration, AI features, importing from other apps, search by meaning (embeddings).

---

## 2. Technology decisions (settled)

| Concern | Decision | Notes |
| --- | --- | --- |
| App UI | SwiftUI, macOS 14+ | `@Observable` needs macOS 14. Light appearance only: force `.light` on the window (`NSApp.appearance = NSAppearance(named: .aqua)`). |
| Manuscript page & notes | AppKit `NSTextView` with TextKit 2, wrapped in `NSViewRepresentable` | Needed for: vetoing edits (locked title line), `typingAttributes`, custom drawing of comment underlines, character hit-testing, spellcheck, find bar, printing. **Never touch `textView.layoutManager`**: it silently falls back to TextKit 1. Use `textLayoutManager` only. |
| Model & state | Plain Swift value types (`Codable`) + one `@Observable` `BookStore` | The store owns the open book, saving, the archive and search. |
| Storage | `JSONEncoder`/`JSONDecoder` (pretty-printed, sorted keys), `Data.write(options: .atomic)`, `FileManager` | No database. |
| Spellcheck | `NSTextView` continuous spell checking | System dictionary, with Learn/Ignore Spelling. |
| Undo | `NSTextView`'s `UndoManager`, plus a book-level `UndoManager` for structural changes | See §8.6. |
| Read aloud | `AVSpeechSynthesizer` | Reads the selection only. |
| Word export | `NSAttributedString` → `.officeOpenXML` | macOS writes the .docx. |
| Print | `NSPrintOperation` on an offscreen text view | Portrait for text only; landscape for text with comments (§10.1). |
| Search | In-memory keyword scan behind a `SearchIndex` protocol | See §9. Room for FTS5, tantivy or embeddings later. |
| Drag & drop | SwiftUI `.draggable` / `.dropDestination` (or a custom gesture if reordering in a grid needs it) | Scenes grid and Boneyard. |
| Menus | SwiftUI `.commands` | Every toolbar and rail action has a menu item and a shortcut. |

---

## 3. Architecture

```
App (SwiftUI)
 ├─ BookStore (@Observable, @MainActor)
 │    ├─ book: Book                       // in-memory working book
 │    ├─ openScene: Scene.ID?             // nil = no scene open
 │    ├─ archive: ArchiveStore            // Archive/index.json + lazy copies
 │    ├─ search: SearchIndex              // protocol; v1 = KeywordSearch
 │    ├─ structureUndo: UndoManager       // add/reorder/cut/restore/delete scenes
 │    └─ save(), autosave scheduling, backups, fileACopy(), reconcileArchive()
 ├─ MainWindow
 │    ├─ Toolbar, IconRail, StatusBar
 │    ├─ PageView (NSViewRepresentable → ManuscriptTextView: NSTextView)
 │    ├─ RightPanel: CommentsTab | NotesTab (NSTextView) | TagsTab
 │    └─ Sheets: ScenesSheet | SearchSheet | FileCabinetSheet
 └─ Output: PrintController, WordExporter, ReadAloudController
```

Suggested folders: `Model/`, `Store/`, `Editor/`, `Views/` (`Rail/`, `RightPanel/`, `Sheets/`, `Dialogs/`), `Search/`, `Output/`, `Tests/`.

**Text bridge.** Inside the app, text lives in `NSTextStorage` (an `NSAttributedString`). On disk it's paragraphs of runs (§5). A `RunCodec` converts in both directions:
- **Loading** builds attributed strings: palette color and highlight names become `NSColor`; comment ids go into a custom `.comments` attribute; the paragraph style is applied.
- **Saving** walks the attribute runs back out into `Run` values. Spacing and indents are display-only and never saved.
- Wrap the custom `NSAttributedString.Key`s in a typed `AttributeScope` (`NovelAttributes`) so attributes are typed when converting to `AttributedString`.

---

## 4. Window layout

See `mockups/screenshots/01-main-window.png`.

### 4.1 Top toolbar (left → right)
- **Breadcrumb:** book title › current scene ("1. The ferry"). For a scene in the Boneyard: "Boneyard › Title".
- **Undo ↶ / Redo ↷:** act on whatever has focus (§8.6). Grayed out when there's nothing to undo or redo.
- **Zoom:** − 100% + (range 50–300%; Cmd+= / Cmd+− / Cmd+0; a View menu item for Fit Width). Implemented with `NSScrollView` magnification; zoom never changes line breaks.
- **Print…** (§10.1)
- **Export to Word** (§10.2)
- **File a copy…:** the prominent button (§7.1). Hidden when viewing a filed copy.

### 4.2 Left icon rail (56 pt)
1. **Current scene:** a page icon with a badge showing the scene number (**B** when the open scene is in the Boneyard). Clicking it shows the page and closes any sheet. It's highlighted whenever the page is showing. **Grayed out with no badge when no scene is open** (an empty book, or after the open scene is deleted permanently). Its tooltip shows the scene number and title.
2. A divider.
3. **Scenes** (Cmd+1), **Search** (Cmd+Shift+F), **File Cabinet**. Each opens a **sheet**: a panel that slides out from the rail and covers the page and the right panel. The open sheet's icon is highlighted.
4. **Closing a sheet:** click its icon again, click ×, press Esc, click Current scene, or open a scene from inside the sheet.

### 4.3 Center: the page
- **Editor control bar** above the page (§6.2).
- **The page:** a white 8.5 × 11 in page with 1 in margins (a 6.5 in text column) on a gray desk that scrolls.
- **No tabs:** the page always shows the scene's text.

### 4.4 Right panel (290 pt, collapsible)
- **Tabs:** **Comments | Notes | Tags**, plus a collapse control ». When collapsed, the panel becomes a thin strip with «. Cmd+] toggles it.
- **Saved state:** the open/closed state and the selected tab are app-wide preferences, kept in UserDefaults, not in the book (ADR 0022).

### 4.5 Status bar
"Scene n of N · words", "Book · words", and then "Saved" / "Unsaved changes" / "Read only". For a Boneyard scene: "In the Boneyard (not in the manuscript)".

### 4.6 Focus mode
Cmd+Shift+Enter hides the rail, toolbar, right panel and status bar. Esc leaves.

### 4.7 Appearance
- **Light only:** there's no dark mode, and the page is always black on white.
- **Native controls:** use the standard macOS controls (`NSSearchField`/`.searchable` style fields, popovers, menus, tooltips).

---

## 5. Files and data model

### 5.1 Folder layout (one folder per book)

```
My Book/
  book.json                the working book (all document state)
  book.json.bak1 … bak3    the last three saves (rotated before each save)
  Archive/
    index.json             date, tags, note and counts for each filed copy
    save0001.json          filed copy 1: exact copy of book.json when filed
    save0002.json
```

### 5.2 `book.json`

```json
{
  "format": 1,
  "title": "My Novel",
  "settings": {
    "zoom": 1.0,
    "voice": "com.apple.voice.premium.en-US.Zoe",
    "rate": 0.5,
    "rightPanel": "comments",
    "rightPanelOpen": true,
    "scenesView": "cards"
  },
  "boneyard": [ /* cut scenes, most recently cut first, same shape as scenes */ ],
  "scenes": [
    {
      "id": "01JC4K",
      "modified": "2026-10-31T20:54:00-07:00",
      "title": [ { "text": "The ferry" } ],
      "tags": ["opening", "Mara"],
      "body": [
        [ { "text": "He found the " },
          { "text": "letter", "comments": ["c7"] },
          { "text": " under the bench.", "color": "purple", "italic": true } ]
      ],
      "notes": [ [ { "text": "Check the tide tables." } ] ],
      "comments": [
        { "id": "c7", "color": "purple", "text": "Too early for this reveal?",
          "created": "2026-10-31T20:40:00-07:00" }
      ]
    }
  ]
}
```

Rules:
- **Story order:** the order of `scenes` is the story order. Reordering moves an element in the array. Renaming a scene means editing its title.
- **Ids:** scene and comment ids are ULIDs, or any stable unique string.
- **Text:** `body` and `notes` are arrays of paragraphs, and a paragraph is an array of runs. Every attribute on a run is optional: `bold`, `italic`, `strike`, `color` (palette name), `highlight` (highlight name), `comments` (comment ids).
- **Comments:** a comment's anchor is the set of runs listing its id, so overlapping comments are simply runs listing both ids. Comment text, color and date live in the scene's `comments`.
- **Not stored:** spacing, indents and fonts. They're display settings.
- **Tags:** `tags` is the scene's tags as plain strings, stored without `#`.
- **Strict decoding:** `TextColor` and `HighlightColor` are enums, so a misspelled value fails to decode. On load, also check that every comment id used in the text exists in `comments`.
- **Rejecting bad files:** a file that fails decoding or validation is rejected with a clear error. It must never half-load.

### 5.3 Swift model (sketch)

```swift
enum TextColor: String, Codable, CaseIterable { case black, purple, red, blue, green, gray, pink }
enum HighlightColor: String, Codable, CaseIterable { case purple, red, blue, green, gray, pink }

struct Run: Codable, Hashable {
    var text: String
    var bold: Bool? = nil, italic: Bool? = nil, strike: Bool? = nil
    var color: TextColor? = nil
    var highlight: HighlightColor? = nil
    var comments: Set<Comment.ID>? = nil
}
typealias Paragraph = [Run]

struct Comment: Codable, Identifiable, Hashable {
    var id: String
    var color: TextColor
    var text: String
    var created: Date
}

struct Scene: Codable, Identifiable {
    var id: String
    var modified: Date
    var title: Paragraph          // exactly one line
    var tags: [String]
    var body: [Paragraph]
    var notes: [Paragraph]
    var comments: [Comment]
}

struct Settings: Codable { var zoom: Double; var voice: String?; var rate: Float
    var rightPanel: RightPanelTab; var rightPanelOpen: Bool; var scenesView: ScenesView }

struct Book: Codable { var format: Int; var title: String; var settings: Settings
    var scenes: [Scene]; var boneyard: [Scene] }
```

### 5.4 Saving
- **When:** autosave runs 2 s after typing stops, at least every 30 s during continuous typing, and on scene switch, app deactivation and quit. **Cmd+S** saves immediately.
- **Order of operations:**
  1. Encode, then validate by decoding the encoded data again.
  2. Rotate the backups: `bak2`→`bak3`, `bak1`→`bak2`, `book.json`→`bak1`.
  3. Write `book.json` with `.atomic`.
- **Undo:** saving never touches the undo stacks.
- **Status:** the status bar reflects the save state.

### 5.5 Archive (`Archive/`)
- **`saveNNNN.json`:** an exact copy of `book.json` at filing time. It's written once, then locked with `FileManager`'s `.immutable` attribute, and **never modified**.
- **`index.json`:** holds everything editable about a copy:

  ```json
  { "copies": [ { "file": "save0002.json", "filed": "2026-10-31", "tags": ["draft 4"],
                  "note": "Before the ending rewrite", "scenes": 24, "words": 51336, "comments": 44 } ] }
  ```

  Editing tags or a note rewrites only `index.json`, atomically.
- **Launch reconciliation:**
  - a save file with no index entry is listed with no tags, and its counts are computed;
  - an index entry whose file is missing is dropped;
  - `NNNN` is always one more than the highest existing number.

---

## 6. The page (manuscript editor)

### 6.1 Scene structure
| Part | Style | Rules |
| --- | --- | --- |
| Title | Heading 1: Times New Roman **18 pt bold**, single-spaced, no indent | Exactly one line, always the first paragraph, can't be deleted. The delegate (`shouldChangeTextIn`) blocks line breaks inside it and deletion of its paragraph break. Return in the title moves the cursor to the start of the body. |
| Body | "Body": Times New Roman **12 pt**, `lineHeightMultiple` 2.0, `firstLineHeadIndent` 36 pt (0.5 in) | One or more paragraphs; no headings. |

Times New Roman ships with macOS; no bundled font is needed.

### 6.2 Editor control bar (above the page)
| Control | Shortcut | Implementation |
| --- | --- | --- |
| **B** Bold | Cmd+B | Toggle the bold font trait |
| *I* Italic | Cmd+I | Toggle the italic trait |
| ~~S~~ Strikethrough | Cmd+Shift+X | `.strikethroughStyle` |
| **A** Text color + ▾ palette | Cmd+1…7 | `.foregroundColor` plus a custom palette-name attribute. Black removes the color. The button applies the last-used color; ▾ opens the palette. |
| Highlight + ▾ palette | — | `.backgroundColor` plus a palette-name attribute; "None" removes it |
| ▶ Read aloud (icon only, tooltip "Read aloud") | Cmd+Shift+R | Selection on the page only (§10.3) |

Each button shows its on/off state for the current selection.

**Palette**, stored by name:

| Name | Text color | Highlight |
| --- | --- | --- |
| Black | #000000 | — |
| Purple | #7B2FBE | #E9DDF7 |
| Red | #C62828 | #F8D7D7 |
| Blue | #1E5BC6 | #D7E4F8 |
| Green | #2E7D32 | #D9EDDA |
| Gray | #757575 | #E6E6E6 |
| Pink | #D81B7A | #F8D5E7 |

**Only one bar is active at a time.** The Notes tab has a compact copy of the bar, with everything except ▶. Only the bar belonging to the editor that has focus (page or notes) is active; the other is dimmed, with a tooltip saying "Click in the page/notes to format". See `05-notes-tab-focus-bars.png`.

### 6.3 Other editor behaviour
| Requirement | Implementation |
| --- | --- |
| Spacing and indent | A paragraph style applied on load and in `typingAttributes`. Never stored, and no tab characters. |
| Spellcheck | `isContinuousSpellCheckingEnabled = true`. The right-click menu gives suggestions plus Learn and Ignore Spelling. |
| Find in scene | Cmd+F opens the standard find bar (`usesFindBar = true`) |
| Zoom | `NSScrollView.magnification` (50–300%), saved in settings |

---

## 7. Scenes, the Boneyard and the File Cabinet

### 7.1 File a copy (main window only)
- **Where:** the toolbar button and File → File a copy. Not available from the File Cabinet or while viewing a filed copy.
- **Dialog** (`14-file-a-copy-dialog.png`): **Tags** as chips (type and press Return; ⌫ removes the last one), **Date** (today by default, editable) and an optional **Note**.
- **On confirm:**
  1. Save the working book.
  2. Copy `book.json` to the next `Archive/saveNNNN.json` and lock it.
  3. Add its entry to `index.json`.
  4. Add it to the search index.
- **Afterwards:** confirm with a brief toast.

### 7.2 Scenes sheet (Cmd+1)
See `07-scenes-cards-boneyard.png`, `08-scenes-light-table.png` and `09-new-scene-inline-title.png`.

**Header:** title and totals, then **+ New scene**, a **Cards / Light table** switch (remembered), a filter field and ×.

**Cards view:** a grid of cards in story order. Each card shows:
- the order number in a circle, the title and a drag handle;
- the word count and when it was last modified ("3 hours ago", "yesterday", via `RelativeDateTimeFormatter`, refreshed every minute);
- the first sentence, cut to 120 characters with an ellipsis;
- the scene's tags as chips with ×, plus **+ tag**.

**Light table view:** a dense grid showing only the number, the title (up to 2 lines) and tags, so about 100 scenes fit on one screen. **+ tag** appears on hover.

**Interactions:**
- **Opening and reordering:**
  - Click a card to open that scene and close the sheet.
  - Drag a card to reorder it. Alt+Arrow keys move the focused card.
  - The new order is saved as the order of the `scenes` array, and numbers update everywhere.
- **Adding scenes:**
  - **+ New scene** in the header inserts after the open scene.
  - A dashed **+ New scene** tile at the end of the grid adds at the end.
  - The new card appears with an inline title field (Return accepts it). The sheet stays open, so you can outline several scenes in a row.
- **Tags on cards:** **+ tag** opens a small field on the card, and Return adds the tag and keeps the field open for the next one.
- **Filter:** matches title, text and tags.

### 7.3 The Boneyard
A tray along the bottom of the Scenes sheet, labelled "Boneyard (n)" with a one-line hint.

- **Cutting a scene:** drag a card onto the tray, which highlights red while you're over it, or press Delete with the card focused. The scene moves from `scenes` to the front of `boneyard`, and the rest of the manuscript renumbers.
- **Restoring a scene:**
  - Drag a Boneyard tile onto the grid. A dashed "Restore here" slot shows where it will land.
  - Or click the tile's ↩ to restore it to the end of the manuscript.
- **Cut scenes stay fully alive:**
  - They keep their text, notes, comments and tags.
  - Click a tile to open the scene and edit it. The breadcrumb reads "Boneyard ›" and the rail badge shows **B**.
- **Where they count:**
  - **Excluded:** word counts, the grid, Print and Word export.
  - **Included:** search (marked "Boneyard") and filed copies.
- **Deleting for good:** **Delete permanently** is in the tile's context menu and asks for confirmation. If the open scene is deleted, the page shows "no scene open" and the rail's Current scene icon is grayed out.
- **Undo:** cutting, restoring and deleting are all undoable on the structure undo stack (§8.6).

### 7.4 File Cabinet sheet
See `12-file-cabinet.png`.
- **Layout:** a grid of cards, one per filed copy, newest first. Each card shows the date, how long ago that was, the scene, word and comment counts, the tags (editable on the card with × and **+ tag**, saved to `index.json`) and the note.
- **Filters:** a search box (tags, notes or text), a date range and tag chips.
- **Clicking a card** opens that version of the whole book read-only (§7.5).

### 7.5 Read-only filed copy
See `13-read-only-filed-copy.png`.
- **Window:** the normal main window, with a pale yellow banner reading "🔒 Filed copy · date · tags — read only" and a **Close** button that returns to the working book and the scene that was open.
- **Locked:** the text views get `isEditable = false` (selection still works), and the page background is light gray. Disabled: both control bars, comment creation and the ⋯ menus, scene drag/add/cut, File a copy, Undo/Redo and autosave. Nothing is ever written to the copy.
- **Still works:** selecting and copying text (Cmd+C), Search (scoped to the copy), read aloud, Print, Export to Word, the Scenes sheet (view only), and the Notes and Tags tabs (view only).
- **Banner actions** (secondary menu):
  - **Restore this scene to my book:** appends a copy of the scene to the working book as a new scene.
  - **New book from this copy…**

---

## 8. Right panel

### 8.1 Comments tab
See `02-select-to-comment.png`, `03-comment-menu.png` and `04-comment-search-color.png`.

**Model:** a comment is a custom `.comments` text attribute (a set of ids) on the text it covers, plus an entry in the scene's `comments` list. The `BookStore` changes both together.

**Creating a comment:**
1. Select text on the page. A small **💬 Comment** button appears at the end of the selection; click it. That's the primary path: one drag, one click.
2. Alternatively, use the **+** button next to the comments search field, or Cmd+Option+M.
3. With no selection, the comment attaches to the word at the cursor.
4. The new card opens with the cursor in it, in the last color used.

**Not inheriting:** strip `.comments` from `typingAttributes` on every selection change. Typing at the edge of a commented span must never extend the comment.

**Underline:** commented text is underlined in the comment's color. Overlapping comments stack their underlines 2 px apart. Implement this with a custom TextKit 2 `NSTextLayoutFragment` subclass, or see open question Q1 for the simpler alternative.

**Linking:** clicking a card selects its text and scrolls it into view; clicking underlined text selects its card (use `characterIndex(for:)` for hit-testing). If several comments cover the clicked spot, select the newest; clicking again cycles through them.

**Cards:** each card shows a colored left bar, the comment text (editable in place, selectable, Cmd+C copies) and a short quote of the anchored text. There are no inline color controls and no ×.

**⋯ menu** (top-right of the card; visible on hover or when the card is selected): a row of the 7 color swatches with the current one ringed, then **Dismiss**. ⌫ while the menu is open also dismisses. Choosing a color recolors the card and its underline, and becomes the default for the next comment.

**Search field:**
- Plain words match the comment text; all words must appear.
- `#color` tokens filter by color. `#grey` and `#gray` are both accepted, several colors mean any of them, and colors combine with words: `#red ferry`.
- Recognized colors appear as small chips below the field. An unknown `#name` is flagged together with the valid names.

**Detached comments:** if all of a comment's text is deleted, the comment is kept in a "Detached" group at the bottom of the panel, where it can be dismissed or re-anchored to a new selection.

**Undo:** create, edit text (committed as one step when the card loses focus), recolor and dismiss are all registered on the text view's `UndoManager`. Undoing a dismiss restores both the card and its underline.

### 8.2 Notes tab
- **What it is:** the scene's notes, in an `NSTextView`: single-spaced Times New Roman, with bold, italic, strikethrough, color and highlight. Stored in `scene.notes`.
- **Formatting:** a compact control bar; only the focused editor's bar is active (§6.2).
- **Placement:** the notes sit beside the page, so the text and its notes are visible together.

### 8.3 Tags tab
See `06-tags-tab.png`.
- **This scene:** the open scene's tags as chips with ×, plus a **+ tag** field (Return adds; a leading `#` is stripped).
- **All tags in the book:** every tag used in the scenes and the Boneyard, with how many scenes use it.
  - **Sorted by frequency, most-used first.** Ties are broken alphabetically, ignoring case.
  - Clicking a tag toggles it on the open scene, so you reuse existing tags and keep spellings consistent.
  - Each row has a ⌕ that opens Search with that tag searched, "Search tags" ticked, and the Whole book scope.

### 8.4 Keyboard and focus
Tab moves between the page, the right panel and the search field. Esc closes menus and popovers first, then sheets.

### 8.5 Read-only state
All three tabs are view-only when a filed copy is open (§7.5).

### 8.6 Undo model
- **Text:** each scene's page and notes have their own `UndoManager` stacks, kept for the session. They're not persisted.
- **Comments:** comment actions register on the page's undo manager.
- **Structure:** add, reorder, cut, restore and delete-permanently register on `BookStore.structureUndo`.
- **Routing:** the toolbar Undo/Redo buttons and Cmd+Z / Shift+Cmd+Z go to the focused text view's undo manager. While the Scenes sheet is open, they go to `structureUndo`.

---

## 9. Search

See `10-search-whole-book.png` and `11-search-file-cabinet-range.png`.

### 9.1 Search sheet (Cmd+Shift+F)
- **Search box,** with a **Search tags** checkbox right next to it. It's off by default and works in every scope.
- **Scope switch:** **This scene · Whole book · File Cabinet.**
  - *This scene:* the open scene (even if it's in the Boneyard).
  - *Whole book:* every scene plus the Boneyard (marked).
  - *File Cabinet:* adds a **copy picker** (all filed copies or a single one) and an optional **date range** (filed from / to; either end can be left blank). The range narrows both the copies searched and the picker.
- **Match case** and **Whole word** checkboxes.

**What's searched:** titles, body text, notes and comments. With **Search tags** ticked, also scene tags, and in File Cabinet each copy's own tags.

**Results:**
- **Grouping:** by version (File Cabinet: copy date and tags, "opens read-only"), then by scene, with the scene number, or **B** for Boneyard scenes.
- **Rows:** each row shows a snippet with the match highlighted, labelled TITLE / TEXT / NOTES / COMMENT / TAGS.
- **Clicking a result:**
  - Opens the scene and selects the match.
  - For a comment match, selects its card; for notes, switches to the Notes tab; for tags, switches to the Tags tab.
  - A result in a filed copy opens that copy read-only at the match.
- **Summary line,** for example: "12 matches in 9 scenes across 3 filed copies · tags match on 2 copies".

### 9.2 Engine (v1): in-memory keyword search
- **Search units:**
  - each paragraph (title, body, notes) and each comment;
  - each scene's tag set, and each filed copy's tag set.
- **What a unit records:** the version ("working" or a save file name), scene id, scene title, field (title, body, notes, comment or tags) and text.
- **Working book:** scanned directly, so results include unsaved text.
- **Filed copies:** the first time a File Cabinet search runs, a background task decodes each `saveNNNN.json` and keeps only its search units in memory (about 1.2 MB of text per copy; 50 copies ≈ 60 MB). File a copy adds the new copy's units immediately.
- **Copy-level tag units** come straight from `index.json`, so tag search over the cabinet is instant even before the copies have loaded. Editing tags updates them immediately.
- **Matching:**
  - case- and diacritic-insensitive (`.caseInsensitive`, `.diacriticInsensitive`), on whole words;
  - simple word endings, so `bear` matches `bears` and `bear's`;
  - `"quotes"` for an exact phrase;
  - Match case and Whole word override the defaults.
- **Ranking** (sorted in this order):
  1. **Coverage:** the number of distinct keywords matched.
  2. **Proximity tier:** all matched words in one sentence, then within one paragraph.
  3. **Fine score:**
     - a smaller span between the matched words;
     - rarer keywords (weighted by how few units contain them);
     - the query's word order (a bonus for adjacent words, as in a phrase);
     - a boost for title matches and for tag matches;
     - diminishing returns for repeated occurrences.
- **Scene order:** scenes are ordered by their best unit, with "+N more in this scene".
- **Near matches:** when no unit contains every keyword, show the best partial matches under "No exact matches · Near matches". Highlight the matched words and underline the neighbouring words that differ (for example *bear paw* when the search was *bear claw*).
- **Protocol:** everything sits behind a `SearchIndex` protocol so SQLite FTS5, Rust `tantivy` (via UniFFI) or embeddings can be added later without UI changes.

**Performance target:** results within about 100 ms for the working book, and within about 500 ms across 50 filed copies once loaded. Run the search off the main actor and show results progressively.

---

## 10. Output

### 10.1 Print
See `15-print-dialog.png`.
- **Dialog:** two layouts plus a range (This scene / Whole manuscript; the Boneyard is excluded).
- **Text only: portrait.** Letter paper in manuscript format: TNR 12 pt, double-spaced, 1 in margins, page breaks, the title as Heading 1.
- **Text with comments: landscape.**
  - **Columns:** the text is a column on the left (same type size and spacing). The right third of the page is a comments column.
  - **Placement:** each comment is printed level with the line it refers to, with a colored bar and a thin connector to its underlined text.
  - **Collisions:** crowded comments are pushed down to avoid overlapping; pages break so no comment is split.
- **Implementation:** an offscreen `NSTextView` laid out for paper and printed with `NSPrintOperation`. Set `NSPrintInfo.orientation` as needed; the comment column is drawn by the print view itself. The standard macOS print dialog also offers Save as PDF.

### 10.2 Export to Word
- **What:** File → Export to Word saves the **current scene** as a .docx.
- **How:** build an `NSAttributedString` and write it with the `.officeOpenXML` document type.
  - **Title:** TNR 18 pt bold.
  - **Body:** TNR 12 pt, double-spaced, 0.5 in first-line indent.
  - **Formatting:** bold, italic, strikethrough, text colors and highlights carry over. Comments are omitted.
- **Verify early:** check whether Word sees the title as its Heading 1 style. If named styles matter, add a small post-processing step that sets the paragraph style ids in the .docx XML.

### 10.3 Read aloud
- **Trigger:** select text on the page and press ▶ (Cmd+Shift+R). It reads **only the selection**, and only on the page (not notes or comments). The button is disabled with no selection.
- **How:** `AVSpeechSynthesizer`. The `willSpeakRangeOfSpeechString` callback highlights the sentence being read (display-only). ▶ becomes ■ Stop while reading.
- **Settings:** voice and rate are saved in `settings`. Everything is on-device.

---

## 11. Menus and shortcuts

| Action | Shortcut |
| --- | --- |
| Save now | Cmd+S |
| Undo / Redo | Cmd+Z / Shift+Cmd+Z |
| Bold / Italic / Strikethrough | Cmd+B / Cmd+I / Cmd+Shift+X |
| Text color 1–7 | Cmd+1…7 *(note: conflicts with Scenes Cmd+1; see Q4)* |
| New comment | Cmd+Option+M |
| Read aloud | Cmd+Shift+R |
| Find in scene | Cmd+F |
| Search sheet | Cmd+Shift+F |
| Scenes sheet | Cmd+1 |
| Toggle right panel | Cmd+] |
| Focus mode | Cmd+Shift+Enter (Esc leaves) |
| Zoom in / out / reset | Cmd+= / Cmd+− / Cmd+0 |

Menus are built with `.commands`:
- **File:** New Book, Open Book, Save, File a Copy…, Export to Word, Print…
- **Edit:** Undo, Redo, Find, Search All…, New Comment
- **View:** Zoom In/Out/Actual Size/Fit Width, Show Scenes, Search, File Cabinet, Toggle Right Panel, Focus Mode
- **Format:** Bold, Italic, Strikethrough, Text Color ▸, Highlight ▸

---

## 12. Milestones

Every milestone ends with the app building, launching and passing its tests. Don't start the next milestone until the acceptance criteria are met.

### M1 — Shell and storage
- **Build:**
  - Xcode project (macOS 14+, Swift 6 mode, light appearance).
  - Main window skeleton: toolbar, rail, an empty page area, right panel tabs, status bar.
  - `Book`/`Scene`/`Run`/`Comment` model and `BookStore` with New/Open/Save, autosave timing, atomic writes, backup rotation, and validation on load.
- **Acceptance:**
  - Unit tests: (a) encode → decode → encode is byte-identical for a sample book; (b) a file with an unknown color, or a comment id missing from `comments`, is rejected with a clear error; (c) backup rotation produces `bak1`–`bak3` correctly.

### M2 — The page
- **Build:**
  - `NSTextView` (TextKit 2) in `NSViewRepresentable`, with the `RunCodec` in both directions.
  - Title/body rules, Times New Roman styles, spacing and indent, spellcheck, the find bar, zoom, undo/redo buttons, opening scenes.
- **Acceptance:**
  - Tests: (a) runs → attributed string → runs round-trips formatting and comment ids, including overlapping comments.
  - Manual checks:
    - the title can't be deleted or split; Return in the title jumps to the body;
    - typing at a styled edge behaves as expected;
    - spellcheck works;
    - `textView.layoutManager` is never referenced.

### M3 — Formatting and notes
- **Build:** the control bar (bold, italic, strike, color, highlight with palettes), Cmd+1…7 (subject to Q4), the Notes tab editor with its compact bar, the focus-based active bar, and the Tags tab.
- **Acceptance:** formatting persists through save and reload; only the focused editor's bar is active; tags are sorted by frequency then name.

### M4 — Comments
- **Build:**
  - the `.comments` attribute and `typingAttributes` stripping;
  - underline drawing with stacking (or the Q1 fallback) and hit-testing;
  - the comments panel: cards, ⋯ menu, `#color` search, + button, the floating 💬 button, the Detached group;
  - undo for all comment actions.
- **Acceptance:**
  - Tests: the `#color` query parser; detach detection.
  - Manual checks: overlapping comments show both underlines; undoing a dismiss restores the card and the underline; typing at a comment's edge never extends it.

### M5 — Sheets
- **Build:**
  - The Scenes sheet: cards and light table, drag to reorder, the new-scene flows, tags on cards, the Boneyard (drag in and out, ↩, open a Boneyard scene, delete permanently), structure undo.
  - The Search sheet: This scene and Whole book scopes, the full matching and ranking from §9.2, near matches, Search tags.
- **Acceptance:**
  - Tests: (a) matching (case, diacritics, word endings, quotes); (b) ranking order: coverage > sentence > paragraph > fine score; (c) near matches for *bear claw* → *bear paw*; (d) Boneyard scenes are excluded from counts but included in search.
  - Manual check: cut and restore round-trip a scene's notes, comments and tags.

### M6 — Archive and output
- **Build:**
  - File a copy (dialog, `saveNNNN.json`, lock, `index.json`) and launch reconciliation.
  - The File Cabinet sheet, the read-only copy view, and the File Cabinet search scope with copy picker, date range and tag search.
  - Print (portrait, and landscape with the comment column), Export to Word, read aloud.
- **Acceptance:**
  - Tests: reconciliation (a missing entry, a missing file, numbering); the date-range filter; that filed copies are byte-identical to `book.json` at filing time and that tag edits never modify them.
  - Manual checks: landscape print places comments next to their lines without overlap; the .docx opens in Word with the correct fonts and spacing.

---

## 13. Open questions (ask; defaults in brackets)

1. **Comment underline style.** Options: (a) stacked colored underlines for every comment, using a custom TextKit 2 layout fragment; or (b) a light wash behind all commented text, plus a single colored underline for the selected comment only, using TextKit 2 rendering attributes. Option (b) is simpler and lower risk, but it hides user highlights under the wash. The user found colored underlines easier to see but hasn't decided. [Default: (a). If it proves hard, fall back to one underline per run in the newest comment's color.]
2. **App name and bundle id.** [Use a placeholder such as `NovelApp`.]
3. **Minimum macOS.** [14. Raise it only if something requires it.]
4. **Shortcut conflict:** Cmd+1…7 for text colors versus Cmd+1 for the Scenes sheet. [Use Ctrl+Cmd+1…7 for colors and keep Cmd+1 for Scenes.]
5. **Word export heading style.** Does the title need to be Word's named Heading 1 style, or is directly formatted 18 pt bold enough? [Verify in M6; add the XML post-processing only if needed.]
6. **Default read-aloud voice and rate.** [The system default voice, rate 0.5.]
7. **Permanent delete from the Boneyard:** just a confirmation, or also a "trash" period? [Confirmation plus undo for the session.]
