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
    @ObservationIgnored private let destination: () -> ExportDestination
    /// The chooser is up exactly while there's a choice.
    var choice: ExportChoice?

    /// `destination` is asked each time, so a test can set where the copy goes after the window
    /// is up.
    init(book: AppOpenBook, destination: @escaping () -> ExportDestination) {
        self.book = book
        self.destination = destination
    }

    /// Export as SceneIt… can begin: the book is open and not being closed, it has story scenes,
    /// and the chooser isn't up already. A read-only book can be exported: nothing in it changes.
    func canBegin(in store: AppBookStore) -> Bool {
        store.openBook === book && choice == nil && !book.book.scenes.isEmpty
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
        let name = ExportWording.defaultFileName(title: book.book.title, package: book.layout.root)
        guard let url = await destination().choose(name) else { return nil }
        var ids = IDGenerator.system
        return await store.exportReviewCopy(
            of: book, chosen: choice.ticked, to: url, export: ids.exportID(),
            exported: Timestamp(.now, in: .current))
    }
}

/// Where Export as SceneIt… writes: the save panel in the app. The test host never shows one:
/// by default nothing is chosen, and a test names a file in its own temporary folder.
struct ExportDestination {
    let choose: @MainActor (_ suggestedName: String) async -> URL?

    static let savePanel = ExportDestination { name in
        let panel = NSSavePanel()
        panel.title = ExportWording.panelTitle
        panel.prompt = ExportWording.panelPrompt
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: ExportWording.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static let nowhere = ExportDestination { _ in nil }

    static func fixed(_ url: URL) -> ExportDestination {
        ExportDestination { _ in url }
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 30)).foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ExportWording.dialogTitle).font(.headline)
                    Text(ExportWording.dialogExplanation)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
        .padding(20)
        .frame(width: 440)
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
                    Toggle(ExportWording.row(row), isOn: ticked(row.id))
                        .toggleStyle(.checkbox)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ticked(_ scene: SceneID) -> Binding<Bool> {
        Binding(
            get: { choice.isTicked(scene) },
            set: { _ in flow.click(scene, NSEvent.modifierFlags.contains(.shift) ? .extendingRange : .single)
            })
    }
}
