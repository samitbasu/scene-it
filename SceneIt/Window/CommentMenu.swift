import AppKit
import SceneItCore
import SwiftUI

/// A card's ⋯ menu (PLAN §8.1, the owner's pick, #25): a standard pull-down menu of the seven
/// colors, each its name and a line in its color, the comment's own checked; then, for a
/// detached comment, Re-anchor to Selection; then Dismiss, which ⌫ also chooses while the menu
/// is open.
enum CommentMenu {
    /// What the menu's items do.
    struct Actions {
        let recolor: (PaletteColor) -> Void
        let dismiss: () -> Void
        let kind: Kind
    }

    /// Whether the comment still covers text; only a detached one can be re-anchored, and only
    /// to a selection the page has.
    enum Kind {
        case anchored
        /// `reanchor` is `nil` while the page has no selection a comment can cover.
        case detached(reanchor: (() -> Void)?)
    }

    static func make(for comment: Comment, _ actions: Actions) -> NSMenu {
        let menu = NSMenu(title: CommentWording.options)
        menu.autoenablesItems = false
        for color in PaletteColor.allCases {
            let item = item(WindowWording.paletteName(color), color: color) { actions.recolor(color) }
            item.attributedTitle = sampled(item.title, in: color)
            item.state = color == comment.color ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if case .detached(let reanchor) = actions.kind {
            let item = item(CommentWording.reanchor) { reanchor?() }
            item.isEnabled = reanchor != nil
            menu.addItem(item)
        }
        let dismiss = item(CommentWording.dismiss, action: actions.dismiss)
        dismiss.keyEquivalent = "\u{7F}"
        dismiss.keyEquivalentModifierMask = []
        menu.addItem(dismiss)
        return menu
    }

    /// The color `item` sets, if it's one of the color items.
    static func color(of item: NSMenuItem) -> PaletteColor? {
        (item.representedObject as? Handler)?.color
    }

    private static func item(_ title: String, color: PaletteColor? = nil, action: @escaping () -> Void)
        -> NSMenuItem
    {
        let handler = Handler(action, color: color)
        let item = NSMenuItem(title: title, action: #selector(Handler.run(_:)), keyEquivalent: "")
        item.target = handler
        // An item holds its target weakly; this keeps the handler for the item's life.
        item.representedObject = handler
        return item
    }

    /// `title`, then a thick line in `color`, in the menu's font.
    private static func sampled(_ title: String, in color: PaletteColor) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let size = WindowMetrics.Comments.menuSample
        let image = NSImage(size: size, flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: NSPoint(x: 0, y: (font.xHeight - size.height) / 2), size: size)
        let text = NSMutableAttributedString(string: title + "  ", attributes: [.font: font])
        text.append(NSAttributedString(attachment: attachment))
        return text
    }

    /// The action `item` runs, if it's one of this menu's items.
    static func action(of item: NSMenuItem) -> (() -> Void)? {
        (item.representedObject as? Handler)?.action
    }

    /// An item's target. Its method isn't `perform(_:)`, which would be `NSObject`'s
    /// `performSelector:` to `#selector`.
    private final class Handler: NSObject {
        let action: () -> Void
        let color: PaletteColor?

        init(_ action: @escaping () -> Void, color: PaletteColor?) {
            self.action = action
            self.color = color
        }

        @objc func run(_ sender: Any?) {
            action()
        }
    }
}

/// The ⋯ control at a card's top right: pulls down the card's `CommentMenu`, right-aligned
/// under it, and selects the card's comment as it opens. It never takes the keyboard focus, so
/// the page keeps its selection for Re-anchor (`EditorFormatting.commentablePage`).
struct CommentMenuButton: NSViewRepresentable {
    let book: AppOpenBook
    let formatting: EditorFormatting
    let editors: SceneEditors
    let scene: SceneID
    let comment: CommentID

    func makeNSView(context: Context) -> Control {
        let button = Control()
        button.image = NSImage(
            systemSymbolName: "ellipsis", accessibilityDescription: CommentWording.options)
        button.contentTintColor = .secondaryLabelColor
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.refusesFirstResponder = true
        button.toolTip = CommentWording.optionsHelp
        button.setAccessibilityLabel(CommentWording.options)
        return button
    }

    func updateNSView(_ button: Control, context: Context) {
        let (book, formatting, editors, scene, id) = (book, formatting, editors, scene, comment)
        button.comment = id
        button.makeMenu = { [weak button] in
            guard let current = book.book.scene(scene), let comment = current.comment(id) else { return nil }
            editors.comments.select(id, in: scene)
            let page = editors.page.editor
            let reanchor = formatting.commentablePage.map { page in { _ = page.reanchor(id) } }
            return CommentMenu.make(
                for: comment,
                .init(
                    recolor: { page.recolor(id, to: $0) },
                    dismiss: {
                        // A card's edit under way is one step, before the dismiss's.
                        (button?.window?.firstResponder as? CommentTextView)?.finishEditing()
                        page.dismiss(id)
                    },
                    kind: current.isDetached(id) ? .detached(reanchor: reanchor) : .anchored))
        }
    }

    /// Opens on the press, as a pull-down menu does, and on a click from accessibility.
    final class Control: NSButton {
        /// Builds the menu as it opens, from the comment and the page as they are then; `nil`
        /// once the comment is gone.
        var makeMenu: (() -> NSMenu?)?
        /// The comment whose menu this is.
        var comment: CommentID?

        override init(frame: NSRect) {
            super.init(frame: frame)
            target = self
            action = #selector(showMenu(_:))
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func mouseDown(with event: NSEvent) {
            showMenu(self)
        }

        /// The item chosen while the menu was open.
        private var chosen: NSMenuItem?

        /// The chosen item's action runs once the menu has closed, as a button's does after its
        /// click, never inside the menu's own tracking loop: a change made there reached the
        /// window only with the next one (the owner's bug A, #25).
        @objc func showMenu(_ sender: Any?) {
            guard let menu = openingMenu() else { return }
            highlight(true)
            menu.popUp(positioning: nil, at: menuOrigin(menu), in: self)
            highlight(false)
            runChosen()
        }

        /// The menu, its items choosing rather than acting while it's open.
        func openingMenu() -> NSMenu? {
            guard let menu = makeMenu?() ?? nil else { return nil }
            for item in menu.items where CommentMenu.action(of: item) != nil {
                item.target = self
                item.action = #selector(choose(_:))
            }
            chosen = nil
            return menu
        }

        /// Runs the action of the item chosen while the menu was open, if any.
        func runChosen() {
            if let item = chosen.take(), let action = CommentMenu.action(of: item) { action() }
        }

        @objc private func choose(_ item: NSMenuItem) {
            chosen = item
        }

        /// Where the menu's top left goes: right-aligned under the button, so it stays over the
        /// panel.
        func menuOrigin(_ menu: NSMenu) -> NSPoint {
            NSPoint(x: bounds.maxX - menu.size.width, y: isFlipped ? bounds.maxY + 2 : bounds.minY - 2)
        }
    }
}
