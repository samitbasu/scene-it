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
