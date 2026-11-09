import SceneItCore
import SwiftUI

/// A slim strip across the window, under the toolbar, saying why the open book is read-only for
/// as long as it is, when the reason is the book's own content (ADR 0024, book format §10 Q7), and
/// offering Make Editable… where that applies. Its look follows the mockup's filed-copy banner
/// (13-read-only-filed-copy.png).
struct ReadOnlyBanner: View {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences

    var body: some View {
        if case .readOnly(let reason) = book.status, let banner = ErrorsWording.banner(for: reason) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    Text(banner.title).fontWeight(.semibold)
                    Text(banner.detail).foregroundStyle(.secondary)
                    Spacer()
                    if banner.offersMakeEditable {
                        Button(ErrorsWording.showRepairs) { preferences.reveal(.errors) }
                        Button(ErrorsWording.makeEditableItem) { Task { await store.confirmMakeEditable() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canMakeEditable)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: WindowMetrics.bannerHeight)
                .background(WindowMetrics.bannerColor)
                Divider()
            }
        }
    }
}

/// The strip across a review's window (ADR 0042), in the read-only banner's look: what's being
/// reviewed, and that only comments and notes change. A review the read-only banner explains
/// (repaired while opening, say) shows that one instead.
struct ReviewBanner: View {
    let book: AppOpenBook

    var body: some View {
        if case .review = book.document, !showsReadOnlyBanner {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.secondary)
                    Text(ReviewWording.bannerTitle(book.book.title)).fontWeight(.semibold)
                    Text(ReviewWording.bannerDetail).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: WindowMetrics.bannerHeight)
                .background(WindowMetrics.bannerColor)
                Divider()
            }
        }
    }

    private var showsReadOnlyBanner: Bool {
        if case .readOnly(let reason) = book.status {
            ErrorsWording.banner(for: reason) != nil
        } else {
            false
        }
    }
}

/// The strip across a filed copy (PLAN §7.5, mockup 13), in the read-only banner's look: "Filed
/// copy · Oct 13, 2026 · draft 3 — read only", and Close, which returns to the book at the scene
/// that was open. Close's menu holds Restore This Scene to My Book and New Book from This Copy….
struct FiledCopyBanner: View {
    let book: AppOpenBook
    let store: AppBookStore
    let newBook: SaveDestination

    var body: some View {
        if case .filedCopy(let context) = book.document {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    // One run of text, so the title, the date and tags, and "read only" are spaced as
                    // words, not as views.
                    let title = Text(FiledCopyWording.bannerTitle).fontWeight(.semibold)
                    let detail = FiledCopyWording.bannerDetail(context)
                    let readOnly = Text(FiledCopyWording.readOnly).foregroundStyle(.secondary)
                    Text("\(title) \(detail) \(readOnly)")
                    Spacer()
                    Menu {
                        let actions = FiledCopyActions(copy: book, store: store, newBook: newBook)
                        Button(FiledCopyWording.restoreScene) { Task { await actions.restore() } }
                        Button(FiledCopyWording.newBook) { Task { await actions.makeNewBook() } }
                    } label: {
                        Text(FiledCopyWording.close)
                    } primaryAction: {
                        store.closeFiledCopy()
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help(FiledCopyWording.closeHelp)
                    .accessibilityHint(FiledCopyWording.moreLabel)
                }
                .padding(.horizontal, 16)
                .frame(height: WindowMetrics.bannerHeight)
                .background(WindowMetrics.bannerColor)
                Divider()
            }
        }
    }
}

/// The banner's Restore This Scene to My Book and New Book from This Copy…. Both stay enabled:
/// macOS shows no tooltip on a menu item, so a refused one tells the writer why instead, through
/// the store, and writes nothing.
struct FiledCopyActions {
    let copy: AppOpenBook
    let store: AppBookStore
    let newBook: SaveDestination

    func restore() async {
        await store.restoreScene(from: copy)
    }

    /// Refused before the save panel, so the writer isn't asked where for nothing.
    func makeNewBook() async {
        if let refusal = store.refusalToMakeBook(from: copy) {
            await store.tell(refusal)
            return
        }
        guard case .filedCopy(let context) = copy.document,
            let url = await newBook.choose(FiledCopyWording.newBookName(title: copy.book.title, context))
        else { return }
        await store.newBook(from: copy, at: url)
    }
}
