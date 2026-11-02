# Novel writing app — build bundle

This bundle is everything an agent needs to start building the app. Read this file first, then `PLAN.md` in full before writing any code.

## What's here

| Path | What it is |
| --- | --- |
| `PLAN.md` | The build plan and spec: stack, architecture, file format, every feature, shortcuts, milestones with acceptance criteria, open questions. **This is the source of truth.** |
| `mockups/novel-app-mockup.html` | An interactive HTML mockup of the whole app. Open it in a browser and click around: editing, comments, notes, tags, the Scenes sheet and Boneyard, Search, the File Cabinet, read-only copies, the print and File a copy dialogs. |
| `mockups/screenshots/*.png` | Screenshots of every screen in the mockup, numbered in a sensible reading order. |

The mockup is easier to understand by clicking than by reading. Things to try:
- select text on the page;
- use a comment's ⋯ menu;
- type `#red` in the comments search;
- drag a card into the Boneyard at the bottom of the Scenes sheet;
- switch Search to File Cabinet;
- click a File Cabinet card to open a read-only copy.

## What the app is

A **macOS-only** app for writing a novel as an ordered list of scenes. It's built in **Swift**: **SwiftUI** for the app, plus an **AppKit `NSTextView`** (TextKit 2) for the manuscript page and the notes. The whole book is stored in **one JSON file**. Filed copies are saved into an `Archive/` folder.

## Working rules

1. **Read `PLAN.md` end to end before starting.** Build in the milestone order it gives, and keep the app building and runnable at the end of every milestone.
2. **The mockup shows behaviour and layout, not code.** It's HTML/JS, and none of it is meant to be ported. Where `PLAN.md` and the mockup disagree, `PLAN.md` wins. Native macOS conventions win over the mockup's look; for example, use real `NSSearchField`, menus, popovers and tooltips.
3. **No third-party dependencies** without asking first. Everything in the plan is achievable with Apple's SDKs.
4. **The file format is a contract.** Don't change the JSON shape in `PLAN.md` §5 without asking. Every format change needs a `format` version bump and a migration.
5. **Never lose the writer's text.** Writes are atomic, backups rotate, and filed copies are never modified. When in doubt, choose the option that cannot destroy data.
6. **Prefer the compiler to runtime checks.** Use typed models, enums for closed sets (palette colors, fields), and `Codable` with strict decoding. Use Swift 6 language mode, with UI types on `@MainActor`.
7. **Write tests** for the model, the save/load round trip, the run ↔ attributed-string conversion, search matching and ranking, and archive reconciliation (see each milestone's acceptance criteria).
8. **Ask, don't guess, on anything listed under Open questions** in `PLAN.md` §13. Use the stated default if you need to keep moving, and flag that you did.
9. When a milestone is done, report what was built, what was tested, and any deviations from the plan.
