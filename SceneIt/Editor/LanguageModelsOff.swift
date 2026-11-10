import AppKit
import SwiftUI

/// Scene It's text never reaches a language model (ADR 0049): no text view in it offers Apple
/// Intelligence's Writing Tools or predicts words (inline, or in the Touch Bar's candidate
/// list), and the menus offer no Writing Tools. Scene It's own editors are `KeyboardTextView`s,
/// which hold all three off for good; `FocusedTextWatch` covers every other text view that takes
/// the focus in one of the app's windows.
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

    /// Takes Writing Tools out of the main menu now, and again whenever AppKit adds it back:
    /// on the next turn of the run loop, so a run of insertions finishes undisturbed first.
    static func keepWritingToolsOutOfTheMenus() -> NSObjectProtocol {
        removeWritingTools(from: NSApp.mainMenu)
        return NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await removeWritingToolsSoon() }
        }
    }

    private static var removal = Removal.none

    private enum Removal {
        case none, pending
    }

    /// One removal for a run of insertions, once they're done.
    private static func removeWritingToolsSoon() async {
        guard removal == .none else { return }
        removal = .pending
        await Task.yield()
        removal = .none
        removeWritingTools(from: NSApp.mainMenu)
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

    /// A Writing Tools item (`showWritingTools:`), or a submenu that holds nothing else.
    static func offersWritingTools(_ item: NSMenuItem) -> Bool {
        if isWritingTools(item) { return true }
        guard let items = item.submenu?.items.filter({ !$0.isSeparatorItem }), !items.isEmpty else {
            return false
        }
        return items.allSatisfy(isWritingTools)
    }

    private static func isWritingTools(_ item: NSMenuItem) -> Bool {
        item.action == #selector(NSResponder.showWritingTools(_:))
    }
}

extension View {
    /// SwiftUI's fields here offer no Writing Tools (ADR 0049); `FocusedTextWatch` does the rest.
    func languageModelsOff() -> some View {
        writingToolsBehavior(.disabled)
    }
}

/// Holds Writing Tools and word predictions off in each text view that takes the focus in any of
/// the app's windows (its own, and the panels AppKit shows in its process: open, save, print),
/// before a key reaches it. A field's editor belongs to whoever made the field (SwiftUI, the find
/// bar, a panel), and only the focus says which one is at work. Each window is watched from its
/// first update, which comes before the writer can type in it.
final class FocusedTextWatch {
    private var watching: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var notifications: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        notifications = [
            center.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) {
                [weak self] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated { window.map { self?.watch($0) } }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
                [weak self] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated { window.map { self?.watching[ObjectIdentifier($0)] = nil } }
            },
        ]
    }

    isolated deinit {
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
    }

    private func watch(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard watching[id] == nil else { return }
        watching[id] = window.observe(\.firstResponder, options: [.initial, .new]) { window, _ in
            MainActor.assumeIsolated {
                if let text = window.firstResponder as? NSTextView { LanguageModelsOff.keepOff(text) }
            }
        }
    }
}
