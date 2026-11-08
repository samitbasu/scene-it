import AppKit
import SceneItCore
import SwiftUI

/// File a Copy (PLAN §7.1) for one open book: the dialog while it's up, then the toast. The
/// owner chose the look (#32): labels in a column beside the fields, the archive box by the
/// title, and the toast above the status bar.
///
/// The dialog's contents are the book's `filingDraft`, so quitting or closing the book sees
/// what's typed there and asks first.
@MainActor
@Observable
final class FilingFlow {
    @ObservationIgnored let book: AppOpenBook
    private(set) var stage = FilingStage.editing
    private(set) var toast: Toast?

    struct Toast: Equatable {
        let id = UUID()
        let text: String
    }

    static let toastDuration = Duration.seconds(3)

    init(book: AppOpenBook) {
        self.book = book
    }

    /// The dialog is up exactly while there's a draft.
    var draft: FilingDraft? {
        get { book.filingDraft }
        set { book.filingDraft = newValue }
    }

    /// The draft for the dialog's views. It writes only while the dialog is up, so nothing
    /// arriving as the dialog closes, or from a view that outlived it, can bring a draft back.
    var draftBinding: Binding<FilingDraft> {
        Binding(
            get: { self.draft ?? FilingDraft(today: CalendarDay(.now, in: .current)) },
            set: { if self.draft != nil { self.draft = $0 } })
    }

    /// This flow while it can be started in `store` (`BookStore.fileableBook`), else nil: what
    /// the window hands the toolbar and the File menu.
    func offered(in store: AppBookStore) -> FilingFlow? {
        store.fileableBook === book ? self : nil
    }

    func begin(today: CalendarDay = CalendarDay(.now, in: .current)) {
        draft = FilingDraft(today: today)
    }

    func cancel() {
        draft = nil
    }

    /// The dialog's File copy. The dialog stays up, as it was and not editable, until the copy
    /// is filed, so a filing that fails (the store's alert says why) loses nothing the writer
    /// typed. A copy filed, locked and indexed gets the toast; anything less gets the alert.
    @discardableResult
    func confirm(in store: AppBookStore) async -> FilingResult? {
        guard let draft, stage == .editing else { return nil }
        stage = .filing
        defer { stage = .editing }
        let record = draft.record
        let result = await store.fileACopy(as: record)
        switch result {
        case .filed(let outcome):
            self.draft = nil
            if outcome.isComplete { show(ArchiveWording.toast(record)) }
        case .unavailable:
            self.draft = nil
        case .failed:
            break
        }
        return result
    }

    func show(_ text: String) {
        let toast = Toast(text: text)
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            if self?.toast == toast { self?.toast = nil }
        }
    }
}

/// Whether the dialog's File copy is running: while it is, the whole dialog waits.
enum FilingStage: Equatable {
    case editing
    case filing
}

// MARK: - The dialog

struct FileACopyDialog: View {
    @Binding var draft: FilingDraft
    let stage: FilingStage
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 30)).foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ArchiveWording.dialogTitle).font(.headline)
                    Text(ArchiveWording.dialogExplanation)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text(ArchiveWording.tagsLabel + ":").gridColumnAlignment(.trailing)
                    TagEntry(draft: $draft)
                }
                GridRow {
                    Text(ArchiveWording.dateLabel + ":")
                    DatePicker(ArchiveWording.dateLabel, selection: date, displayedComponents: .date)
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .fixedSize()
                }
                GridRow {
                    Text(ArchiveWording.noteLabel + ":")
                    note
                }
            }
            buttons
        }
        .padding(20)
        .frame(width: 440)
        .disabled(stage == .filing)
    }

    private var date: Binding<Date> {
        Binding(
            get: { draft.filed.noon(in: .current) },
            set: { draft.filed = CalendarDay($0, in: .current) })
    }

    private var note: some View {
        NoteTextView(draft: $draft)
            .padding(4)
            .frame(height: 56)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .accessibilityLabel(ArchiveWording.noteLabel)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(ArchiveWording.cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(ArchiveWording.confirm, action: confirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Tags as chips

/// The tags field (PLAN §7.1): the tags as chips, each with ×, then a field where Return adds
/// the typed text as a tag and ⌫ with nothing typed removes the last.
private struct TagEntry: View {
    @Binding var draft: FilingDraft

    var body: some View {
        ChipFlow(spacing: ChipSpacing(points: 5)) {
            ForEach(draft.tags, id: \.self) { tag in
                TagChip(tag: tag) { draft.remove(tag) }
            }
            TagTextField(draft: $draft)
                .frame(minWidth: 150)
                .layoutPriority(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

private struct TagChip: View {
    let tag: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(tag).font(.callout).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(ArchiveWording.removeTag(tag))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.14), in: Capsule())
    }
}

/// An `AdmittingTextField`, so Return and ⌫ arrive as the field editor's commands
/// (`insertNewline:`, `deleteBackward:`) whatever SwiftUI does with keys, and what's typed goes
/// through the character policy as in the editors. The field has its own undo history; adding
/// a tag clears it, since the text it would bring back is the tag's.
struct TagTextField: NSViewRepresentable {
    @Binding var draft: FilingDraft

    func makeCoordinator() -> Coordinator {
        Coordinator(draft: $draft)
    }

    func makeNSView(context: Context) -> AdmittingTextField {
        Self.field(draft.pendingTag, context.coordinator)
    }

    /// The field `makeNSView` makes, wired to `coordinator`.
    static func field(_ text: String, _ coordinator: Coordinator) -> AdmittingTextField {
        let editor = AdmittingTextView.fieldEditor(admitting: CharacterPolicy.admittedLine)
        editor.history = coordinator.history
        let field = AdmittingTextField(string: text, editor: editor, lineBreakMode: .byClipping)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = ArchiveWording.tagsPlaceholder
        field.setAccessibilityLabel(ArchiveWording.tagsLabel)
        field.delegate = coordinator
        coordinator.field = field
        return field
    }

    func updateNSView(_ field: AdmittingTextField, context: Context) {
        context.coordinator.draft = $draft
        if field.stringValue != draft.pendingTag { field.stringValue = draft.pendingTag }
    }

    /// The dialog closed: the field and its editor let go of the coordinator, so nothing they
    /// do later reaches the draft.
    static func dismantleNSView(_ field: AdmittingTextField, coordinator: Coordinator) {
        field.delegate = nil
        field.editor?.history = nil
        coordinator.field = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var draft: Binding<FilingDraft>
        let history = UndoManager()
        weak var field: AdmittingTextField?

        init(draft: Binding<FilingDraft>) {
            self.draft = draft
            super.init()
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(historyChanged), name: name, object: history)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field, notification.object as? NSTextField === field,
                let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView
            else { return }
            draft.wrappedValue.pendingTag = editor.string
        }

        /// An undo or redo changes the editor's text without telling the delegate.
        @objc func historyChanged(_ notification: Notification) {
            guard let editor = field?.editor else { return }
            draft.wrappedValue.pendingTag = editor.string
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                draft.wrappedValue.pendingTag = textView.string
                draft.wrappedValue.commitPendingTag()
                textView.string = ""
                history.removeAllActions()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty else { return false }
                return draft.wrappedValue.deleteBackward()
            default:
                return false
            }
        }
    }
}

/// The note, in an `AdmittingTextView`: no input method, and the character policy applied as
/// the writer types or pastes (ADR 0028). It grows with its text and scrolls past its frame.
/// Its changes reach the draft through the view's own `onChange`, cleared when the dialog
/// closes, never through the notification center.
struct NoteTextView: NSViewRepresentable {
    @Binding var draft: FilingDraft

    func makeCoordinator() -> Coordinator {
        Coordinator(draft: $draft)
    }

    func makeNSView(context: Context) -> NSScrollView {
        Self.scrollView(draft.note, context.coordinator)
    }

    /// The scroll view and editor `makeNSView` makes, wired to `coordinator`.
    static func scrollView(_ text: String, _ coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = AdmittingTextView(admitting: CharacterPolicy.admittedInput)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.setAccessibilityLabel(ArchiveWording.noteLabel)
        view.string = text
        view.onChange = { [weak coordinator] in coordinator?.draft.wrappedValue.note = $0 }
        scroll.holdGrowingText(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.draft = $draft
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != draft.note { view.string = draft.note }
    }

    /// The dialog closed: the editor tells no one of its changes from here on.
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? AdmittingTextView)?.onChange = nil
    }

    final class Coordinator {
        var draft: Binding<FilingDraft>

        init(draft: Binding<FilingDraft>) {
            self.draft = draft
        }
    }
}

/// The gap between chips, and between their lines.
private struct ChipSpacing {
    let points: CGFloat
}

/// Lays its views out left to right, wrapping to a new line where the next doesn't fit; the
/// last view (the text field) takes the rest of its line.
private struct ChipFlow: Layout {
    let spacing: ChipSpacing

    /// How wide a line of chips may be.
    private struct LineWidth {
        let points: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let rows = arrange(subviews, within: LineWidth(points: width))
        let height = rows.reduce(0) { $0 + $1.height } + spacing.points * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, within: LineWidth(points: bounds.width)) {
            var x = bounds.minX
            for (index, size) in row.items {
                let isLast = index == subviews.count - 1
                let width = isLast ? bounds.maxX - x : size.width
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing.points
            }
            y += row.height + spacing.points
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        private func gap(_ spacing: ChipSpacing) -> CGFloat {
            items.isEmpty ? 0 : spacing.points
        }

        /// An empty line takes anything.
        func fits(_ size: CGSize, _ spacing: ChipSpacing, _ line: LineWidth) -> Bool {
            items.isEmpty || width + gap(spacing) + size.width <= line.points
        }

        mutating func add(_ index: Int, _ size: CGSize, _ spacing: ChipSpacing) {
            width += gap(spacing) + size.width
            height = max(height, size.height)
            items.append((index, size))
        }
    }

    private func arrange(_ subviews: Subviews, within line: LineWidth) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].fits(size, spacing, line) { rows.append(Row()) }
            rows[rows.count - 1].add(index, size, spacing)
        }
        return rows
    }
}

// MARK: - The toast

struct FilingToastView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Puts the toast over the window, centered just above the status bar.
struct FilingToastOverlay: ViewModifier {
    let flow: FilingFlow

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = flow.toast {
                FilingToastView(text: toast.text)
                    .padding(.bottom, 44)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(toast.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: flow.toast)
    }
}

extension FocusedValues {
    /// The focused window's File a Copy, for File → File a Copy….
    @Entry var filingFlow: FilingFlow?
}
