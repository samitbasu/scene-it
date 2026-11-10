import AppKit
import Testing

@testable import SceneIt

extension OneAtATime.BookStoreIntegrationTests {
    @Test func runnerDiagnosticsTemp() {
        var lines: [String] = []
        for screen in NSScreen.screens {
            lines.append(
                "screen frame=\(screen.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor)"
            )
        }
        lines.append(
            "mainMode=\(String(describing: RunLoop.main.currentMode)) modal=\(String(describing: NSApp.modalWindow)) windows=\(NSApp.windows.map { "\(type(of: $0)) \($0.frame) visible=\($0.isVisible)" })"
        )
        lines.append("active=\(NSApp.isActive) keyWindow=\(String(describing: NSApp.keyWindow))")
        @MainActor func walk(_ menu: NSMenu?, _ path: String) {
            for item in menu?.items ?? [] {
                let here = "\(path) > \(item.title)"
                if item.title.contains("Dictation") || item.title.contains("Emoji")
                    || item.title.contains("Writing")
                    || item.title.contains("AutoFill")
                {
                    lines.append(
                        "\(here) hidden=\(item.isHidden) alt=\(item.isAlternate) key=\(item.keyEquivalent.debugDescription) mods=\(item.keyEquivalentModifierMask.rawValue) action=\(String(describing: item.action)) menu=\(ObjectIdentifier(menu!)) "
                    )
                }
                walk(item.submenu, here)
            }
        }
        walk(NSApp.mainMenu, "")
        let edit = NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu
        lines.append("edit items: \((edit?.items ?? []).map(\.title))")
        for line in lines { print("DIAG \(line)") }
        Issue.record(Comment(rawValue: "DIAG \(lines.joined(separator: "\n"))"))
    }
}
