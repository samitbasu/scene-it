import AppKit
import SceneItCore

/// Answers the store's questions with app-modal `NSAlert`s. App-modal rather than a sheet,
/// because a question can arrive when the main window is closed.
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
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for label in buttons {
            alert.addButton(withTitle: label)
        }
        let response = alert.runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
