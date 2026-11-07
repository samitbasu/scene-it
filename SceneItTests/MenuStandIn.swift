import AppKit

/// Draws an `NSMenu`'s shown items as macOS 26 shows an open menu, near enough for a look
/// review: titles, check marks, separators, submenu arrows, key equivalents and enabled state are
/// the menu's own; the chrome, row heights and insets are approximations.
enum MenuStandIn {
    static let padding: CGFloat = 5
    static let separatorHeight: CGFloat = 11
    static let checkColumn: CGFloat = 22
    static let trailingInset: CGFloat = 14

    static func draw(_ menu: NSMenu, in rect: NSRect) {
        let chrome = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        NSColor(white: 0.97, alpha: 1).setFill()
        chrome.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        chrome.stroke()

        let font = NSFont.menuFont(ofSize: 0)
        for (item, row) in rows(of: menu, in: rect) {
            if item.isSeparatorItem {
                NSColor.black.withAlphaComponent(0.1).setFill()
                NSRect(x: rect.minX + 12, y: row.midY, width: rect.width - 24, height: 1).fill()
                continue
            }
            let ink: NSColor = item.isEnabled || item.hasSubmenu ? .labelColor : .tertiaryLabelColor
            let title = NSMutableAttributedString(
                attributedString: item.attributedTitle
                    ?? NSAttributedString(string: item.title, attributes: [.font: font]))
            title.addAttribute(
                .foregroundColor, value: ink, range: NSRange(location: 0, length: title.length))
            let size = title.size()
            title.draw(at: NSPoint(x: row.minX + checkColumn, y: row.midY - size.height / 2))
            if item.state == .on {
                let check = NSAttributedString(
                    string: "\u{2713}", attributes: [.font: font, .foregroundColor: ink])
                check.draw(at: NSPoint(x: row.minX + 7, y: row.midY - check.size().height / 2))
            }
            let trailing = item.hasSubmenu ? "\u{203A}" : keyEquivalent(of: item)
            if !trailing.isEmpty {
                let key = NSAttributedString(
                    string: trailing,
                    attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                key.draw(
                    at: NSPoint(
                        x: row.maxX - trailingInset - key.size().width, y: row.midY - key.size().height / 2))
            }
        }
    }

    /// Where each shown item of `menu`, drawn in `rect`, is drawn.
    static func rows(of menu: NSMenu, in rect: NSRect) -> [(NSMenuItem, NSRect)] {
        let shown = menu.items.filter { !$0.isHidden }
        let separators = CGFloat(shown.count { $0.isSeparatorItem })
        let rowHeight =
            (rect.height - 2 * padding - separators * separatorHeight) / (CGFloat(shown.count) - separators)
        var top = rect.maxY - padding
        return shown.map { item in
            let height = item.isSeparatorItem ? separatorHeight : rowHeight
            top -= height
            return (item, NSRect(x: rect.minX, y: top, width: rect.width, height: height))
        }
    }

    private static func keyEquivalent(of item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let modifiers: [(NSEvent.ModifierFlags, String)] = [
            (.control, "\u{2303}"), (.option, "\u{2325}"), (.shift, "\u{21E7}"), (.command, "\u{2318}"),
        ]
        var key = item.keyEquivalent
        var mask = item.keyEquivalentModifierMask
        if key != key.lowercased() { mask.insert(.shift) }
        switch key {
        case "\u{8}", "\u{7F}": key = "\u{232B}"
        default: key = key.uppercased()
        }
        return modifiers.filter { mask.contains($0.0) }.map(\.1).joined() + key
    }
}
