import SceneItCore
import SwiftUI

/// Says why the open book is read-only, for as long as it is, when the reason is the book's own
/// content (ADR 0024, book format §10 Q7), and offers Make Editable where that applies.
struct ReadOnlyBanner: View {
    let book: AppOpenBook
    let store: AppBookStore
    let preferences: AppPreferences
    /// Where the banner sits; the window places one of each and each shows only in its place.
    let placement: BannerStyle
    @Environment(\.errorsLook) private var look

    var body: some View {
        if look.banner == placement, case .readOnly(let reason) = book.status,
            let banner = ErrorsWording.banner(for: reason)
        {
            switch placement {
            case .yellowStrip: strip(banner)
            case .infoBar: infoBar(banner)
            case .inline: inline(banner)
            }
        }
    }

    private func strip(_ banner: ErrorsWording.Banner) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                Text(banner.title).fontWeight(.semibold)
                Text(banner.detail).foregroundStyle(.secondary)
                Spacer()
                buttons(banner)
            }
            .padding(.horizontal, 16)
            .frame(height: WindowMetrics.bannerHeight)
            .background(WindowMetrics.bannerColor)
            Divider()
        }
    }

    private func infoBar(_ banner: ErrorsWording.Banner) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(banner.title).fontWeight(.semibold)
                Text(banner.detail).foregroundStyle(.secondary)
                Spacer()
                buttons(banner)
            }
            .padding(.horizontal, 16)
            .frame(height: WindowMetrics.bannerHeight)
            .background(.bar)
            Divider()
        }
    }

    private func inline(_ banner: ErrorsWording.Banner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title).fontWeight(.semibold)
                Text(banner.detail).foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            buttons(banner)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(WindowMetrics.bannerColor))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.08)))
        .padding(.horizontal, WindowMetrics.deskPadding)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func buttons(_ banner: ErrorsWording.Banner) -> some View {
        if banner.offersMakeEditable {
            Button(ErrorsWording.showRepairs) { preferences.reveal(.errors) }
            Button(ErrorsWording.makeEditableItem) {
                Task { await store.makeEditable() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
