# 0043 — In the Scenes sheet, a double click opens a scene and a click selects a card

**Status:** Accepted (2026-11-09, the owner's request: "On the scenes sorter - to edit a scene should
require a double click."). Deviates from PLAN §7.2 ("Click a card to open that scene and close the
sheet") and §7.3 ("Click a tile to open the scene and edit it").

## Context
A single click on a story card or a Boneyard tile opened its scene and closed the sheet. A stray
click while sorting (aiming for a card's grip, or just to look at it) threw the writer out of the
sheet. The sheet already has a keyboard card focus (#29): the arrows move a focus ring between
cards, Return opens the focused card, Delete cuts it.

## Decision
The Finder's convention:
1. **A double click on a card or a tile opens its scene** and closes the sheet, as a click did.
2. **A single click on a card selects it at once:** the sheet takes the keys and the card gets the
   card focus, so the arrows, Return and Delete act on it. The first click of a double click selects
   too; nothing waits to tell the two apart. Selecting scrolls the card fully into view, which can
   move another card under the pointer, so a double click opens a card only if its first click
   selected it; otherwise it just selects the card it landed on.
3. **A single click on a Boneyard tile does nothing.** The card focus is the story grid's (its arrows,
   Option+arrows and Delete are moves in the story), so a tile can't hold it cleanly.
4. The card's own controls (the title field, + tag, the tag chips) take their clicks as before, and a
   drag still moves, cuts or restores.
5. The accessibility default action and the tile's context menu Open still open the scene. A
   read-only book opens and selects the same way.
6. The tooltips say so: "Double-click to open this scene" on a card, "Double-click to open this
   scene, or drag it onto the grid to restore it" on a tile.

The policy lives once, in `ScenesActions.click(_:on:)`, which both the card and the tile reach through
one modifier, `sceneClicks(_:actions:)`. That modifier is one tap gesture reading the event's click
count (`SceneClick(NSApp.currentEvent)`). A separate double-tap gesture beside a single-tap one would
hold the single click back until a double click could no longer come.

## Alternatives
- **A single click on a tile selects it too.** The focus would need a second kind of target, and
  every key would need a Boneyard meaning. Not worth it for the tray.
- **A single click does nothing anywhere.** Unlike the Finder, and wastes the click.

## Learning notes
SwiftUI's `onTapGesture(count: 2)` and `onTapGesture(count: 1)` on the same view compete: the single
tap is recognised only once the double tap has failed, after the system's double-click interval. On
macOS the click count is already on the `NSEvent` (`clickCount`), and SwiftUI calls a tap's action
while handling the mouse-up, so `NSApp.currentEvent` is that event. One gesture, counting as the
system does, answers both at once.
