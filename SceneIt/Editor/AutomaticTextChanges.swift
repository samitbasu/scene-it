import AppKit

/// The system's ways of changing the writer's words for them (#127, ADR 0028): correcting
/// spelling, replacing text, smart quotes, dashes, links and data, smart copy and paste. The
/// writer's words are changed only by the writer, so no menu offers these and no editor answers
/// them (`KeyboardTextView`).
enum AutomaticTextChanges {
    /// The actions that turn one on or make one at once, including the Substitutions panel's.
    /// The one-shot replacements aren't in AppKit's headers, so they're named by their selectors.
    nonisolated static let actions: Set<Selector> = [
        #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)),
        #selector(NSTextView.toggleAutomaticTextReplacement(_:)),
        #selector(NSTextView.toggleAutomaticTextCompletion(_:)),
        #selector(NSTextView.toggleSmartInsertDelete(_:)),
        #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)),
        #selector(NSTextView.toggleAutomaticDashSubstitution(_:)),
        #selector(NSTextView.toggleAutomaticLinkDetection(_:)),
        #selector(NSTextView.toggleAutomaticDataDetection(_:)),
        #selector(NSTextView.orderFrontSubstitutionsPanel(_:)),
        Selector(("replaceQuotesInSelection:")),
        Selector(("replaceDashesInSelection:")),
        Selector(("addLinksInSelection:")),
        Selector(("replaceTextInSelection:")),
    ]

    static func isAutomatic(_ item: NSMenuItem) -> Bool {
        item.action.map(actions.contains) == true
    }

    /// Hides every item of `menu` and its submenus that offers one, a submenu left offering
    /// nothing else (Substitutions), and the separators that leaves stranded. Items are hidden
    /// rather than removed, so a menu SwiftUI builds stays as SwiftUI knows it.
    static func hide(in menu: NSMenu) {
        guard menu.items.contains(where: offersOne) else { return }
        for item in menu.items where !item.isHidden {
            if isAutomatic(item) {
                item.isHidden = true
            } else if let submenu = item.submenu {
                hide(in: submenu)
                if offersOne(item), !submenu.items.contains(where: offersOther) { item.isHidden = true }
            }
        }
        placeSeparators(in: menu)
    }

    /// Keeps them out of the main menu, which SwiftUI builds and may build again: once items
    /// stop being added (so a half-built menu's separators aren't judged), and before the menu
    /// bar opens.
    static func keepOutOfTheMainMenu() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !mainMenuPassPending else { return }
                mainMenuPassPending = true
                DispatchQueue.main.async { hideInMainMenu() }
            }
        }
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideInMainMenu() }
        }
    }

    private static var mainMenuPassPending = false

    private static func hideInMainMenu() {
        mainMenuPassPending = false
        if let menu = NSApp.mainMenu { hide(in: menu) }
    }

    private static func offersOne(_ item: NSMenuItem) -> Bool {
        isAutomatic(item) || item.submenu?.items.contains(where: offersOne) == true
    }

    private static func offersOther(_ item: NSMenuItem) -> Bool {
        !item.isHidden && !item.isSeparatorItem && !isAutomatic(item)
    }

    /// The separators this hid as stranded, which it shows again if they're needed again.
    private static let strandedSeparators = NSHashTable<NSMenuItem>.weakObjects()

    /// Hides each separator with no shown item between it and the menu's start or end, or the
    /// shown separator before it, and shows again each it hid that no longer is. Separators
    /// hidden by anyone else stay as they are.
    private static func placeSeparators(in menu: NSMenu) {
        var lastShown: NSMenuItem?
        for item in menu.items {
            if item.isSeparatorItem, !item.isHidden || strandedSeparators.contains(item) {
                if lastShown?.isSeparatorItem != false {
                    strand(item)
                } else {
                    unstrand(item)
                    lastShown = item
                }
            } else if !item.isHidden {
                lastShown = item
            }
        }
        if let last = lastShown, last.isSeparatorItem { strand(last) }
    }

    private static func strand(_ separator: NSMenuItem) {
        separator.isHidden = true
        strandedSeparators.add(separator)
    }

    private static func unstrand(_ separator: NSMenuItem) {
        separator.isHidden = false
        strandedSeparators.remove(separator)
    }
}
