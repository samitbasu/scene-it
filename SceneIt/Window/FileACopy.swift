import AppKit
import SceneItCore
import SwiftUI

/// File a Copy (PLAN §7.1) for one open book: the dialog while it's up, then the toast.
@MainActor
@Observable
final class FilingFlow {
    /// The dialog is up exactly while there's a draft.
    var draft: FilingDraft?
    /// The dialog's File copy is running; its buttons wait.
    private(set) var isFiling = false
    private(set) var toast: Toast?

    struct Toast: Equatable {
        let id = UUID()
        let text: String
    }

    static let toastDuration = Duration.seconds(3)

    func begin(today: CalendarDay = CalendarDay(.now, in: .current)) {
        draft = FilingDraft(today: today)
    }

    func cancel() {
        draft = nil
    }

    /// The dialog's File copy. The dialog stays up, as it was, until the copy is filed, so a
    /// filing that fails (the store's alert says why) loses nothing the writer typed. A copy
    /// filed, locked and indexed gets the toast; anything less gets the store's alert.
    @discardableResult
    func confirm(in store: AppBookStore) async -> FilingResult? {
        guard let draft, !isFiling else { return nil }
        isFiling = true
        defer { isFiling = false }
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

// MARK: - Candidates (#32): the owner picks one; the others go

/// The dialog's look. Rendered side by side for the owner's pick (CLAUDE.md); the provisional
/// default is the recommendation.
enum FilingDialogLayout: CaseIterable {
    /// The mockup's: each label above its field, the date a field with a calendar button.
    case stacked
    /// macOS's grouped form: labels on the left of rounded rows.
    case grouped
    /// Labels right-aligned in a column, the archive box beside the title, as an alert.
    case columns

    static let provisional = FilingDialogLayout.stacked
}

/// Where the toast appears.
enum FilingToastPlacement: CaseIterable {
    /// Centered over the page, just above the status bar.
    case bottom
    /// Centered under the toolbar.
    case top

    static let provisional = FilingToastPlacement.bottom
}

extension EnvironmentValues {
    @Entry var filingDialogLayout = FilingDialogLayout.provisional
    @Entry var filingToastPlacement = FilingToastPlacement.provisional
}

// MARK: - The dialog

struct FileACopyDialog: View {
    @Binding var draft: FilingDraft
    let isFiling: Bool
    let cancel: () -> Void
    let confirm: () -> Void
    @Environment(\.filingDialogLayout) private var layout

    var body: some View {
        Group {
            switch layout {
            case .stacked: stacked
            case .grouped: grouped
            case .columns: columns
            }
        }
        .frame(width: 440)
    }

    private var date: Binding<Date> {
        Binding(
            get: { draft.filed.noon(in: .current) },
            set: { draft.filed = CalendarDay($0, in: .current) })
    }

    private var tags: some View {
        TagEntry(draft: $draft)
    }

    private var note: some View {
        TextEditor(text: $draft.note)
            .font(.body)
            .scrollContentBackground(.hidden)
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
        .disabled(isFiling)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ArchiveWording.dialogTitle).font(.title3).fontWeight(.semibold)
                Text(ArchiveWording.dialogExplanation)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            labelled(ArchiveWording.tagsLabel) { tags }
            labelled(ArchiveWording.dateLabel) {
                DatePicker(ArchiveWording.dateLabel, selection: date, displayedComponents: .date)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
            }
            labelled(ArchiveWording.noteLabel) { note }
            buttons.padding(.top, 4)
        }
        .padding(20)
    }

    private func labelled(_ label: String, @ViewBuilder _ field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            field()
        }
    }

    private var grouped: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(ArchiveWording.tagsLabel) { tags }
                    DatePicker(ArchiveWording.dateLabel, selection: date, displayedComponents: .date)
                    LabeledContent(ArchiveWording.noteLabel) { note }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ArchiveWording.dialogTitle).font(.title3).fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Text(ArchiveWording.dialogExplanation)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 6)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 300)
            buttons.padding([.horizontal, .bottom], 20)
        }
    }

    private var columns: some View {
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
                    tags
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
    }
}

// MARK: - Tags as chips

/// The tags field (PLAN §7.1): the tags as chips, each with ×, then a field where Return adds
/// the typed text as a tag and ⌫ with nothing typed removes the last.
private struct TagEntry: View {
    @Binding var draft: FilingDraft

    var body: some View {
        ChipFlow(spacing: 5) {
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

/// An `NSTextField`, so Return and ⌫ arrive as the field editor's commands
/// (`insertNewline:`, `deleteBackward:`) whatever SwiftUI does with keys.
struct TagTextField: NSViewRepresentable {
    @Binding var draft: FilingDraft

    func makeCoordinator() -> Coordinator {
        Coordinator(draft: $draft)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: draft.pendingTag)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = ArchiveWording.tagsPlaceholder
        field.setAccessibilityLabel(ArchiveWording.tagsLabel)
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.draft = $draft
        if field.stringValue != draft.pendingTag { field.stringValue = draft.pendingTag }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var draft: Binding<FilingDraft>

        init(draft: Binding<FilingDraft>) {
            self.draft = draft
        }

        /// What's typed goes through `CharacterPolicy` as in the editors: the field shows only
        /// what the tag will keep, the caret where it was.
        func controlTextDidChange(_ notification: Notification) {
            guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            let typed = editor.string
            draft.wrappedValue.pendingTag = typed
            let kept = draft.wrappedValue.pendingTag
            guard !kept.utf16.elementsEqual(typed.utf16) else { return }
            let caret = min(editor.selectedRange().location, (typed as NSString).length)
            let before = CharacterPolicy.admittedLine((typed as NSString).substring(to: caret))
            editor.string = kept
            editor.setSelectedRange(NSRange(location: min(before.utf16.count, kept.utf16.count), length: 0))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                draft.wrappedValue.pendingTag = textView.string
                draft.wrappedValue.commitPendingTag()
                textView.string = ""
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

/// Lays its views out left to right, wrapping to a new line where the next doesn't fit; the
/// last view (the text field) takes the rest of its line.
private struct ChipFlow: Layout {
    let spacing: CGFloat

    /// How wide a line of chips may be.
    private struct LineWidth {
        let points: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let rows = arrange(subviews, within: LineWidth(points: width))
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
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
                x += width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, within line: LineWidth) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = (rows[rows.count - 1].items.isEmpty ? 0 : spacing) + size.width
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + needed > line.points {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append((index, size))
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
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

/// Puts the toast over the window, where `FilingToastPlacement` says.
struct FilingToastOverlay: ViewModifier {
    let flow: FilingFlow
    @Environment(\.filingToastPlacement) private var placement

    func body(content: Content) -> some View {
        content.overlay(alignment: placement == .bottom ? .bottom : .top) {
            if let toast = flow.toast {
                FilingToastView(text: toast.text)
                    .padding(placement == .bottom ? .bottom : .top, placement == .bottom ? 44 : 14)
                    .transition(.opacity.combined(with: .move(edge: placement == .bottom ? .bottom : .top)))
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
