import AppKit
import SceneItCore
import SwiftUI
import UniformTypeIdentifiers

/// Export as SceneIt… (ADR 0029) for one open book: the scene chooser while it's up, then the
/// save panel, then the store's verified write.
@MainActor
@Observable
final class ExportFlow {
    @ObservationIgnored let book: AppOpenBook
    @ObservationIgnored private let destination: () -> SaveDestination
    /// The chooser is up exactly while there's a choice.
    var choice: ExportChoice?

    /// `destination` is asked each time, so a test can set where the copy goes after the window
    /// is up.
    init(book: AppOpenBook, destination: @escaping () -> SaveDestination) {
        self.book = book
        self.destination = destination
    }

    /// Export as SceneIt… can begin: the book is open and not being closed, it has story scenes,
    /// and the chooser isn't up already. A read-only book can be exported: nothing in it changes.
    func canBegin(in store: AppBookStore) -> Bool {
        store.openBook === book && book.document.kind == .book && choice == nil && !book.book.scenes.isEmpty
    }

    func begin() {
        guard choice == nil else { return }
        choice = ExportChoice(story: book.book.scenes)
    }

    func cancel() {
        choice = nil
    }

    /// A scene's checkbox, clicked with Shift held or not.
    func click(_ scene: SceneID, _ kind: ChoiceClick) {
        choice?.click(scene, kind)
    }

    /// The chooser's Export…: the chooser closes, the save panel asks where, and the store writes
    /// the copy there (telling the writer if it can't). `nil` if nothing was chosen or the panel
    /// was cancelled.
    @discardableResult
    func confirm(in store: AppBookStore) async -> ExportResult? {
        guard let choice, choice.canExport else { return nil }
        self.choice = nil
        let name = ExportWording.defaultFileName(title: book.book.title, package: book.document.url)
        guard let url = await destination().choose(name) else { return nil }
        var ids = IDGenerator.system
        return await store.exportReviewCopy(
            of: book, chosen: choice.ticked, to: url, export: ids.exportID(),
            exported: Timestamp(.now, in: .current))
    }
}

/// Where a save panel's command writes (Export as SceneIt…, Save Review…): the save panel in the
/// app. The test host never shows one: by default nothing is chosen, and a test names a file in its
/// own temporary folder.
struct SaveDestination {
    let choose: @MainActor (_ suggestedName: String) async -> URL?

    /// The save panel, with its title and prompt, for files with `fileExtension`.
    static func savePanel(title: String, prompt: String, fileExtension: String) -> SaveDestination {
        SaveDestination { name in
            let panel = NSSavePanel()
            panel.title = title
            panel.prompt = prompt
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    }

    static let exportPanel = savePanel(
        title: ExportWording.panelTitle, prompt: ExportWording.panelPrompt,
        fileExtension: ExportWording.fileExtension)

    static let newBookPanel = savePanel(
        title: FiledCopyWording.newBookPanelTitle, prompt: FiledCopyWording.newBookPanelPrompt,
        fileExtension: PackageLayout.pathExtension)

    static let nowhere = SaveDestination { _ in nil }

    static func fixed(_ url: URL) -> SaveDestination {
        SaveDestination { _ in url }
    }
}

extension FocusedValues {
    /// The focused window's Export as SceneIt…, for the File menu.
    @Entry var exportFlow: ExportFlow?
}

// MARK: - The chooser

/// The chooser, as a sheet on the book's window, laid out as File a Copy's dialog is: an icon
/// and explanation, the scenes as checkboxes, then Cancel and Export….
struct ExportChooserDialog: View {
    let flow: ExportFlow
    let confirm: () -> Void

    var body: some View {
        WindowDialog(
            icon: "square.and.arrow.up.fill", title: ExportWording.dialogTitle,
            explanation: ExportWording.dialogExplanation
        ) {
            if let choice = flow.choice {
                ExportSceneList(flow: flow, choice: choice)
                    .frame(height: 240)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack {
                    Button(ExportWording.selectAll) { flow.choice?.tickAll() }
                        .disabled(choice.allTicked)
                    Button(ExportWording.selectNone) { flow.choice?.untickAll() }
                        .disabled(!choice.canExport)
                    Spacer()
                    Text(ExportWording.tickedCount(choice.ticked.count, of: choice.rows.count))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(ExportWording.rangeHint).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(ExportWording.cancel) { flow.cancel() }
                    Button(ExportWording.confirm, action: confirm)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!choice.canExport)
                }
            }
        }
    }
}

/// The story scenes as checkboxes, numbered as the rail numbers them. A click with Shift held
/// sets the run of scenes from the last one clicked.
struct ExportSceneList: View {
    let flow: ExportFlow
    let choice: ExportChoice

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(choice.rows) { row in
                    Toggle(ExportWording.row(row), isOn: Self.ticked(row.id, in: flow, choice))
                        .toggleStyle(.checkbox)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A scene's checkbox. `modifiers` are the keys held as it's clicked: the click is still being
    /// handled when the binding is set, so the keyboard's state now is the click's.
    static func ticked(
        _ scene: SceneID, in flow: ExportFlow, _ choice: ExportChoice,
        modifiers: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    ) -> Binding<Bool> {
        Binding(
            get: { choice.isTicked(scene) },
            set: { _ in flow.click(scene, ChoiceClick(modifiers())) })
    }
}

extension ChoiceClick {
    /// The kind of click the modifier keys held make it: Shift extends the run.
    init(_ modifiers: NSEvent.ModifierFlags) {
        self = modifiers.contains(.shift) ? .extendingRange : .single
    }
}
