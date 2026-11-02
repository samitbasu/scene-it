import AppKit
import SceneItCore
import SwiftUI

/// The right panel's Errors tab (book format §5.4): the book's error entries, grouped by the
/// book and then each scene, each with its reason and what can be done with it. On a
/// read-only book the entries can only be read and copied.
struct ErrorsTab: View {
    let book: AppOpenBook

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
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups, id: \.owner) { group in
                        Text(ErrorsWording.group(group.owner, in: book.book))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 8)
                        ForEach(group.refs, id: \.self) { ref in
                            ErrorRow(book: book, ref: ref)
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
    /// The payload being fixed, while it is.
    @State private var draft: String?

    var body: some View {
        let reason = ErrorsWording.reason(BookFormat.reason(for: ref, in: book.book))
        VStack(alignment: .leading, spacing: 6) {
            TagLabel(tag: ref.entry.tag)
            headline(reason)
            detail(reason)
            if draft == nil {
                HStack(spacing: 14) {
                    Button(ErrorsWording.copy) { EntryClipboard.copy(ref.entry) }
                    if ref.entry.tag.isRepairable {
                        Button(ErrorsWording.fix) { draft = ref.entry.payload }
                            .disabled(!book.isEditable)
                    }
                    Spacer()
                    Button(ErrorsWording.delete) { book.deleteError(ref) }
                        .disabled(!book.isEditable)
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
