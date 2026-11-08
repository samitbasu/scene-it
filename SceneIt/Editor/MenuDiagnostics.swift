// TEMPORARY (#127): diagnoses which step brings the automatic-change toggles back into a real
// right-click's context menu. Debug builds only; to be removed once the owner's trial is read.
// It logs through os.Logger directly, not Log: it needs AppKit's runtime menu titles, which Log's
// static messages can't carry, and it must stay out of log.jsonl. It never logs a menu title that
// comes from the manuscript (Look Up's word, the spelling guesses); only AppKit's own toggle titles.
#if DEBUG
    import AppKit
    import os

    enum MenuDiagnostics {
        static let log = Logger(subsystem: "com.samitbasu.SceneIt", category: "menu-diag")

        /// The context menus `KeyboardTextView.menu(for:)` returned, to tell them from others.
        private static let returned = NSHashTable<NSMenu>.weakObjects()
        private static let delegate = Delegate()

        static func id(_ menu: NSMenu?) -> String {
            menu.map {
                "\($0.title.isEmpty ? "-" : $0.title)#\(UInt(bitPattern: ObjectIdentifier($0).hashValue) % 100_000)"
            }
                ?? "nil"
        }

        /// Every item under `menu` that offers an automatic action, with whether it's hidden and
        /// which menu holds it.
        static func automaticItems(_ menu: NSMenu) -> String {
            func walk(_ menu: NSMenu) -> [String] {
                menu.items.flatMap { item in
                    (AutomaticTextChanges.isAutomatic(item)
                        ? ["\(item.title)[\(item.isHidden ? "hidden" : "SHOWN") in \(id(menu))]"] : [])
                        + (item.isHidden && item.submenu != nil ? ["(\(item.title) submenu hidden)"] : [])
                        + (item.submenu.map(walk) ?? [])
                }
            }
            let found = walk(menu)
            return found.isEmpty ? "none" : found.joined(separator: ", ")
        }

        static func launch() {
            let same = NSTextView.defaultMenu === NSTextView.defaultMenu
            log.notice("launch: NSTextView.defaultMenu same object on two calls: \(same, privacy: .public)")
        }

        static func menuForEvent(_ event: NSEvent, view: NSView, appKits: NSMenu?, returned menu: NSMenu) {
            returned.add(menu)
            installDelegate(on: menu)
            // Counted, never named: a guess is spelled from the manuscript's word.
            let guesses = menu.items.count { $0.action == Selector(("_changeSpellingFromMenu:")) }
            log.notice(
                """
                menu(for:) \(String(describing: type(of: view)), privacy: .public) at \
                \(NSStringFromPoint(event.locationInWindow), privacy: .public): AppKit's \(id(appKits), privacy: .public) \
                [\(appKits.map(automaticItems) ?? "nil", privacy: .public)] -> copy \(id(menu), privacy: .public) \
                [\(automaticItems(menu), privacy: .public)] spelling guesses: \(guesses, privacy: .public)
                """)
        }

        static func willOpen(_ stage: String, _ menu: NSMenu, view: NSView) {
            log.notice(
                """
                willOpenMenu \(stage, privacy: .public) \(String(describing: type(of: view)), privacy: .public) \
                \(id(menu), privacy: .public) ours=\(returned.contains(menu), privacy: .public): \
                \(automaticItems(menu), privacy: .public)
                """)
        }

        static func beganTracking(_ stage: String, _ menu: NSMenu) {
            guard menu !== NSApp.mainMenu else { return }
            log.notice(
                """
                didBeginTracking \(stage, privacy: .public) \(id(menu), privacy: .public) \
                ours=\(returned.contains(menu), privacy: .public): \(automaticItems(menu), privacy: .public)
                """)
        }

        static func added(_ item: NSMenuItem, to menu: NSMenu) {
            guard AutomaticTextChanges.isAutomatic(item), !isInMainMenu(menu) else { return }
            var chain: NSMenu? = menu
            var ours = false
            while let current = chain {
                if returned.contains(current) { ours = true }
                chain = current.supermenu
            }
            log.notice(
                """
                didAddItem \(item.title, privacy: .public) to \(id(menu), privacy: .public) \
                leadsToOurs=\(ours, privacy: .public) defaultMenu=\(id(NSTextView.defaultMenu), privacy: .public)
                """)
        }

        private static func isInMainMenu(_ menu: NSMenu) -> Bool {
            var chain: NSMenu? = menu
            while let current = chain {
                if current === NSApp.mainMenu { return true }
                chain = current.supermenu
            }
            return false
        }

        private static func installDelegate(on menu: NSMenu) {
            if menu.delegate == nil { menu.delegate = delegate }
            for item in menu.items { if let submenu = item.submenu { installDelegate(on: submenu) } }
        }

        final class Delegate: NSObject, NSMenuDelegate {
            func menuNeedsUpdate(_ menu: NSMenu) {
                MenuDiagnostics.log.notice(
                    "menuNeedsUpdate \(MenuDiagnostics.id(menu), privacy: .public): \(MenuDiagnostics.automaticItems(menu), privacy: .public)"
                )
            }

            func menuWillOpen(_ menu: NSMenu) {
                MenuDiagnostics.log.notice(
                    "menuWillOpen \(MenuDiagnostics.id(menu), privacy: .public): \(MenuDiagnostics.automaticItems(menu), privacy: .public)"
                )
            }
        }
    }
#endif
