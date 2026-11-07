import AppKit
import SceneItCore

/// Answers the store's questions with app-modal `NSAlert`s. App-modal rather than a sheet,
/// because a question can arrive with the main window minimized or behind another app's.
final class AlertPrompts: StorePrompts {
    func ask<Choice>(_ alert: WriterAlert<Choice>) async -> Choice {
        let index = Self.runAlert(
            title: alert.title, message: alert.message, buttons: alert.buttons.map(\.label))
        return alert.buttons[alert.buttons.indices.contains(index) ? index : 0].choice
    }

    func tell(_ notice: Notice) async {
        _ = Self.runAlert(title: notice.title, message: notice.message, buttons: [])
    }

    /// The index of the button chosen; with no buttons, AppKit's own OK.
    private static func runAlert(title: String, message: String, buttons: [String]) -> Int {
        let response = alert(title: title, message: message, buttons: buttons).runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// The alert as the writer sees it; the renders draw this one too.
    static func alert(title: String, message: String, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for label in buttons {
            alert.addButton(withTitle: label)
        }
        return alert
    }
}

/// For the test host and previews, where a modal alert would hang the run: records every
/// question and answers with its default button. Hosted tests assert that nothing was asked
/// that they didn't expect.
final class HeadlessPrompts: StorePrompts {
    private(set) var titles: [String] = []

    func ask<Choice>(_ alert: WriterAlert<Choice>) async -> Choice {
        Log.app.error("a question was answered without the writer (test host or preview)")
        titles.append(alert.title)
        return alert.choices[0]
    }

    func tell(_ notice: Notice) async {
        titles.append(notice.title)
    }

    /// The titles so far, which are then forgotten.
    func takeTitles() -> [String] {
        defer { titles = [] }
        return titles
    }
}
