import AppKit
import SceneItCore
import SwiftUI

/// A card's ⋯ menu (PLAN §8.1, the owner's pick, #25): a standard pull-down menu of the seven
/// colors, each its name and a line in its color, the comment's own checked; then, for a
/// detached comment, Re-anchor to Selection; then Dismiss, which ⌫ also chooses while the menu
/// is open.
enum CommentMenu {
    /// Whether the comment still covers text, which decides whether it can be re-anchored.
    enum Kind {
        case anchored, detached
    }

    /// What the menu's items do.
    struct Actions {
        let recolor: (PaletteColor) -> Void
        /// `nil` while the page has no selection to re-anchor to.
        let reanchor: (() -> Void)?
        let dismiss: () -> Void
    }

    static func make(for comment: Comment, _ kind: Kind, _ actions: Actions) -> NSMenu {
        let menu = NSMenu(title: CommentWording.options)
        menu.autoenablesItems = false
        for (index, color) in PaletteColor.allCases.enumerated() {
            let item = item(title: label(color)) { actions.recolor(color) }
            item.attributedTitle = sampled(item.title, in: color)
            item.state = color == comment.color ? .on : .off
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if kind == .detached {
            let reanchor = item(title: CommentWording.reanchor) { actions.reanchor?() }
            reanchor.isEnabled = actions.reanchor != nil
            menu.addItem(reanchor)
        }
        let dismiss = item(title: CommentWording.dismiss, action: actions.dismiss)
        dismiss.keyEquivalent = "\u{8}"
        dismiss.keyEquivalentModifierMask = []
        menu.addItem(dismiss)
        return menu
    }

    /// The color an item of the menu stands for: its tag is the color's place in the palette.
    static func color(of item: NSMenuItem) -> PaletteColor? {
        item.attributedTitle == nil || item.isSeparatorItem
            || !PaletteColor.allCases.indices.contains(item.tag)
            ? nil : PaletteColor.allCases[item.tag]
    }

    static func label(_ color: PaletteColor) -> String {
        switch CommentPanelCandidates.colorLabel {
        case .capitalized: WindowWording.paletteName(color)
        case .lowercase: color.rawValue
        }
    }

    private static func item(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let handler = Handler(action)
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

    private final class Handler: NSObject {
        let action: () -> Void

        init(_ action: @escaping () -> Void) {
            self.action = action
        }

        @objc func run(_ sender: Any?) {
            action()
        }
    }
}

/// The ⋯ control at a card's top right: pulls down the card's `CommentMenu`, right-aligned
/// under it, and selects the card's comment as it opens.
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
        button.toolTip = CommentWording.optionsHelp
        button.setAccessibilityLabel(CommentWording.options)
        return button
    }

    func updateNSView(_ button: Control, context: Context) {
        let (book, formatting, editors, scene, id) = (book, formatting, editors, scene, comment)
        button.comment = id
        button.makeMenu = {
            guard let current = book.book.scene(scene),
                let comment = current.comments.first(where: { $0.id == id })
            else { return nil }
            editors.comments.select(id, in: scene)
            let page = editors.page.editor
            let reanchor = formatting.commentablePage.map { page in { _ = page.reanchor(id) } }
            return CommentMenu.make(
                for: comment, current.isDetached(id) ? .detached : .anchored,
                .init(
                    recolor: { page.recolor(id, to: $0) }, reanchor: reanchor, dismiss: { page.dismiss(id) }))
        }
    }

    /// Opens on the press, as a pull-down menu does, and on a click from the keyboard or
    /// accessibility.
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

        @objc func showMenu(_ sender: Any?) {
            guard let menu = makeMenu?() ?? nil else { return }
            highlight(true)
            menu.popUp(positioning: nil, at: menuOrigin(menu), in: self)
            highlight(false)
        }

        /// Where the menu's top left goes: right-aligned under the button, so it stays over the
        /// panel.
        func menuOrigin(_ menu: NSMenu) -> NSPoint {
            NSPoint(x: bounds.maxX - menu.size.width, y: isFlipped ? bounds.maxY + 2 : bounds.minY - 2)
        }
    }
}
