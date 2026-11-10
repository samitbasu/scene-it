import AppKit
import SwiftUI

/// Scene It's text never reaches a language model (ADR 0049): no text view in it offers Apple
/// Intelligence's Writing Tools or predicts words (inline, or in the Touch Bar's candidate
/// list), and the menus offer no Writing Tools. Scene It's own editors are `KeyboardTextView`s,
/// which hold all three off for good; this covers every other text view a window's focus
/// reaches: SwiftUI's fields and the find bar's.
enum LanguageModelsOff {
    static func keepOff(_ view: NSTextView) {
        if view.writingToolsBehavior != .none { view.writingToolsBehavior = .none }
        if view.inlinePredictionType != .no { view.inlinePredictionType = .no }
        if view.isAutomaticTextCompletionEnabled { view.isAutomaticTextCompletionEnabled = false }
    }

    static func areOff(in view: NSTextView) -> Bool {
        view.writingToolsBehavior == .none && view.inlinePredictionType == .no
            && !view.isAutomaticTextCompletionEnabled
    }

    // MARK: The menus

    /// Takes Writing Tools out of the main menu now, and again whenever AppKit adds it back.
    static func keepWritingToolsOutOfTheMenus() -> NSObjectProtocol {
        removeWritingTools(from: NSApp.mainMenu)
        return NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { removeWritingTools(from: NSApp.mainMenu) }
        }
    }

    /// Removes every item of `menu` and its submenus that offers Writing Tools, with the
    /// separator that set it apart.
    static func removeWritingTools(from menu: NSMenu?) {
        guard let menu else { return }
        let doomed = menu.items.filter(offersWritingTools)
        for item in menu.items {
            removeWritingTools(from: item.submenu)
        }
        guard !doomed.isEmpty else { return }
        for item in doomed {
            menu.removeItem(item)
        }
        for (index, item) in menu.items.enumerated().reversed() where item.isSeparatorItem {
            let next = menu.items.indices.contains(index + 1) ? menu.items[index + 1] : nil
            if index == 0 || next == nil || next?.isSeparatorItem == true { menu.removeItem(item) }
        }
    }

    /// The Writing Tools item (`showWritingTools:`), or a submenu of them.
    static func offersWritingTools(_ item: NSMenuItem) -> Bool {
        item.action == #selector(NSResponder.showWritingTools(_:))
            || item.submenu?.items.contains { $0.action == #selector(NSResponder.showWritingTools(_:)) }
                == true
    }
}

extension View {
    /// Every text view in this view's window: Writing Tools and inline predictions off (ADR 0049).
    func languageModelsOff() -> some View {
        writingToolsBehavior(.disabled)
            .background(FocusedTextWatch())
    }
}

/// Holds Writing Tools and inline predictions off in each text view that takes its window's
/// focus, before a key reaches it. A field's editor belongs to whoever made the field (SwiftUI,
/// the find bar), and only the focus says which one is at work.
private struct FocusedTextWatch: NSViewRepresentable {
    func makeNSView(context: Context) -> WatchView {
        WatchView()
    }

    func updateNSView(_ view: WatchView, context: Context) {}

    final class WatchView: NSView {
        private var watching: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watching = window?.observe(\.firstResponder, options: [.initial, .new]) { window, _ in
                MainActor.assumeIsolated {
                    if let text = window.firstResponder as? NSTextView { LanguageModelsOff.keepOff(text) }
                }
            }
        }
    }
}
