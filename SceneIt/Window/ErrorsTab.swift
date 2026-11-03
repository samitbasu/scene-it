import AppKit
import SceneItCore
import SwiftUI

/// The right panel's Errors tab (book format §5.4): the book's error entries, grouped by the
/// book and then each scene, each with its reason and what can be done with it. On a
/// read-only book the entries can only be read and copied.
struct ErrorsTab: View {
    let book: AppOpenBook
    /// Kept here, by each entry's identity, so a row being fixed stays open while the rows
    /// around it change, and a fix that still doesn't read stays open on the edited line.
    @State private var fixes: [ErrorRef.Identity: Fix] = [:]
    /// Deleting or fixing an entry gives the tab the focus, which it keeps, with a ring
    /// around it, until Esc or a click goes back to the page; meanwhile Undo undoes the
    /// tab's own operations.
    @State private var focus = UndoFocusAnchor()
    @Environment(\.pageFocus) private var pageFocus

    var body: some View {
        entries
            .background(
                UndoFocusHolder(
                    focus: .errorsTab, anchor: focus, showsFocusRing: true,
                    escape: { [pageFocus] in pageFocus?.focusBody() }))
    }

    @ViewBuilder private var entries: some View {
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
                        ForEach(
                            group.refs.map { Row(ref: $0, identity: book.book.identity(of: $0)) },
                            id: \.identity
                        ) {
                            row in
                            ErrorRow(
                                book: book, ref: row.ref, fix: $fixes[row.identity],
                                delete: {
                                    focus.takeFocus()
                                    book.deleteError(row.ref)
                                },
                                apply: {
                                    focus.takeFocus()
                                    apply($0, to: row.ref)
                                })
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }
}

extension ErrorsTab {
    private struct Row {
        let ref: ErrorRef
        let identity: ErrorRef.Identity
    }

    struct Fix: Hashable {
        var draft: String
        /// Why the last Apply didn't take effect.
        var note: String?
    }

    private func apply(_ payload: String, to ref: ErrorRef) {
        let identity = book.book.identity(of: ref)
        switch book.repairError(ref, as: payload) {
        case .repaired:
            fixes[identity] = nil
        case .kept(let reason):
            fixes[identity] = nil
            if let edited = book.book.errorRef(ref.owner, at: ref.index) {
                fixes[book.book.identity(of: edited)] = Fix(
                    draft: edited.entry.payload, note: ErrorsWording.stillUnreadable(reason))
            }
        case .refused:
            fixes[identity]?.note = ErrorsWording.cantApply
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
    @Binding var fix: ErrorsTab.Fix?
    let delete: () -> Void
    let apply: (String) -> Void

    var body: some View {
        let reason = ErrorsWording.reason(BookFormat.reason(for: ref, in: book.book))
        VStack(alignment: .leading, spacing: 6) {
            TagLabel(tag: ref.entry.tag)
            headline(reason)
            detail(reason)
            if fix == nil {
                HStack(spacing: 14) {
                    Button(ErrorsWording.copy) { EntryClipboard.copy(ref.entry) }
                    if ref.entry.tag.isRepairable {
                        Button(ErrorsWording.fix) { fix = ErrorsTab.Fix(draft: ref.entry.payload) }
                            .disabled(!book.isEditable)
                    }
                    Spacer()
                    Button(ErrorsWording.delete, action: delete)
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
        if let fix {
            VStack(alignment: .trailing, spacing: 6) {
                TextField(
                    ErrorsWording.fix,
                    text: Binding(get: { fix.draft }, set: { self.fix?.draft = $0 }), axis: .vertical
                )
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                if let note = fix.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(ErrorsWording.cancel) { self.fix = nil }
                    Button(ErrorsWording.apply) { apply(fix.draft) }
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
