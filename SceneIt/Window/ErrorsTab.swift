import AppKit
import SceneItCore
import SwiftUI

/// The right panel's Errors tab (book format §5.4): the book's error entries, grouped by the
/// book and then each scene, each with its reason and what can be done with it. On a
/// read-only book the entries can only be read and copied.
struct ErrorsTab: View {
    let book: AppOpenBook
    @Environment(\.errorsLook) private var look
    @Environment(\.errorsEditing) private var editing

    var body: some View {
        let groups = book.book.errorGroups
        if groups.isEmpty {
            Text(ErrorsWording.empty)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: look.rows == .compact ? 0 : 8) {
                    ForEach(groups, id: \.owner) { group in
                        Text(ErrorsWording.group(group.owner, in: book.book))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 8)
                            .padding(.bottom, look.rows == .compact ? 4 : 0)
                        ForEach(group.refs, id: \.self) { ref in
                            ErrorRow(book: book, ref: ref, draft: ref == editing ? ref.entry.payload : nil)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }
}

/// Puts an entry's payload on a pasteboard as plain text, so the writer can salvage it.
enum EntryClipboard {
    static func copy(_ entry: ErrorEntry, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(entry.payload, forType: .string)
    }
}

private struct ErrorRow: View {
    let book: AppOpenBook
    let ref: ErrorRef
    @State var draft: String?
    @State private var expanded = true
    @Environment(\.errorsLook) private var look

    var body: some View {
        let reason = ErrorsWording.reason(BookFormat.reason(for: ref, in: book.book))
        switch look.rows {
        case .cards: card(reason)
        case .compact: compact(reason)
        case .disclosure: disclosure(reason)
        }
    }

    /// A notice's payload is Scene It's own sentence, so it reads as the row's text, with the
    /// reason under it; any other payload is the writer's line, shown as written.
    private var isNotice: Bool {
        ref.entry.tag == .notice
    }

    private func headline(_ reason: String) -> some View {
        Text(isNotice ? ref.entry.payload : reason)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func detail(_ reason: String) -> some View {
        if isNotice {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            payloadOrEditor
        }
    }

    // MARK: The three looks

    private func card(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TagLabel(tag: ref.entry.tag)
            headline(reason)
            detail(reason)
            if draft == nil {
                HStack(spacing: 14) {
                    copyButton
                    if ref.entry.tag.isRepairable { fixButton }
                    Spacer()
                    deleteButton
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6)
                .fill(Color.orange)
                .frame(width: 3)
        }
    }

    private func compact(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNotice ? ref.entry.payload : reason)
                        .font(.callout)
                        .lineLimit(isNotice ? 3 : 2)
                    if isNotice {
                    } else if draft == nil {
                        Text(ref.entry.payload)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        payloadOrEditor
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    copyButton
                    if ref.entry.tag.isRepairable { fixButton }
                    Divider()
                    deleteButton
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.vertical, 6)
            Divider()
        }
    }

    private func disclosure(_ reason: String) -> some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                detail(reason)
                if draft == nil {
                    HStack(spacing: 14) {
                        copyButton
                        if ref.entry.tag.isRepairable { fixButton }
                        Spacer()
                        deleteButton
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                TagLabel(tag: ref.entry.tag)
                headline(reason)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Parts

    @ViewBuilder private var payloadOrEditor: some View {
        if let draft {
            VStack(alignment: .trailing, spacing: 6) {
                TextField(
                    ErrorsWording.fix,
                    text: Binding(get: { draft }, set: { self.draft = $0 }), axis: .vertical
                )
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                HStack {
                    Button(ErrorsWording.cancel) { self.draft = nil }
                    Button(ErrorsWording.apply) { apply(draft) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        } else {
            Text(ref.entry.payload)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    private var copyButton: some View {
        Button(ErrorsWording.copy) { EntryClipboard.copy(ref.entry) }
    }

    private var fixButton: some View {
        Button(ErrorsWording.fix) { draft = ref.entry.payload }
            .disabled(!book.isEditable)
    }

    private var deleteButton: some View {
        Button(ErrorsWording.delete) { book.deleteError(ref) }
            .disabled(!book.isEditable)
    }

    private func apply(_ payload: String) {
        switch book.repairError(ref, as: payload) {
        case .repaired, .kept: draft = nil
        case .refused: break
        }
    }
}

private struct TagLabel: View {
    let tag: ErrorTag

    var body: some View {
        Text(ErrorsWording.tag(tag))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
