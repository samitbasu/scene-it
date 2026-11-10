import AppKit
import SceneItCore
import SwiftUI

/// Export to Word… (PLAN §10.2) for one book window's open scene, from the File menu (through
/// `MainWindowChrome`) and the toolbar alike. It puts out the scene the window shows as it is now,
/// saved or not, and works on a read-only book, a review or a filed copy (PLAN §7.5).
@MainActor
@Observable
final class WordExportFlow {
    private let gate: OutputGate
    private let destination: () -> WordDestination

    init(gate: OutputGate, destination: @escaping () -> WordDestination) {
        self.gate = gate
        self.destination = destination
    }

    var book: AppOpenBook {
        gate.book
    }

    var scene: BookScene? {
        book.book.scene(book.openScene)
    }

    /// Whether Export to Word… can start: a scene is open, and the gate is open.
    var canBegin: Bool {
        scene != nil && gate.isOpen
    }

    /// The save panel asks where, and whether the comments go (ADR 0048), and the store writes the
    /// document there. `nil` if it can't start or the panel was canceled.
    @discardableResult
    func begin() async -> WordExportResult? {
        let options = WordExportOptions()
        guard canBegin, !gate.windowHasSheet, let scene,
            let url = await destination().choose(
                WordExportWording.defaultFileName(scene: scene, of: book.document), options)
        else { return nil }
        return await gate.store.exportToWord(
            of: book, scene: scene.id, to: url, comments: options.comments.comments(by: .account))
    }
}

/// The save panel's choices. Each export starts with the comments left out, so they never go
/// to a reader because an earlier export took them.
@Observable
final class WordExportOptions {
    var comments: WordCommentChoice = .omit
}

extension CommentAuthor {
    /// The Mac account's full name, as Word names a comment's author by the name it's set up with.
    static var account: CommentAuthor {
        CommentAuthor(fullName: NSFullUserName())
    }
}

/// Where Export to Word… writes, and with which options: the save panel with the options as its
/// accessory in the app; in the test host nowhere, unless a test names a file (`SaveDestination`).
struct WordDestination {
    let choose: @MainActor (_ suggestedName: String, _ options: WordExportOptions) async -> URL?

    static let panel = WordDestination { name, options in
        SaveDestination.run(savePanel(options), suggesting: name)
    }

    /// The save panel, not yet shown, with `options` as its accessory.
    static func savePanel(_ options: WordExportOptions) -> NSSavePanel {
        let panel = SaveDestination.panel(
            title: WordExportWording.panelTitle, prompt: WordExportWording.panelPrompt,
            fileExtension: WordExportWording.fileExtension)
        panel.accessoryView = accessory(options)
        return panel
    }

    /// The panel's accessory: the checkbox, showing `options`, at its own size.
    static func accessory(_ options: WordExportOptions) -> NSHostingView<WordExportAccessory> {
        let accessory = NSHostingView(rootView: WordExportAccessory(options: options))
        accessory.frame.size = accessory.fittingSize
        return accessory
    }

    static let nowhere = WordDestination { _, _ in nil }

    /// `url`, with the comments as the writer would have ticked them; left as the panel opens
    /// with when `choice` is `nil`.
    static func fixed(_ url: URL, choosing choice: WordCommentChoice? = nil) -> WordDestination {
        WordDestination { _, options in
            if let choice { options.comments = choice }
            return url
        }
    }
}

/// The Include comments checkbox, under the save panel's file browser.
struct WordExportAccessory: View {
    @Bindable var options: WordExportOptions

    var body: some View {
        Toggle(
            WordExportWording.includeComments,
            isOn: Binding {
                options.comments.isTicked
            } set: {
                options.comments = WordCommentChoice(ticked: $0)
            }
        )
        .toggleStyle(.checkbox)
        .fixedSize()
        .padding(.horizontal, WordExportAccessoryMetrics.horizontalPadding)
        .padding(.vertical, WordExportAccessoryMetrics.verticalPadding)
    }
}

enum WordExportAccessoryMetrics {
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 12
}
