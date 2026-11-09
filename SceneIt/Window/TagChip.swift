import SwiftUI

/// A tag as a chip, with its × while it can be removed: the Tags tab's and File a Copy's. The
/// owner picked the accent-tinted token (#20). A label too long for its line truncates, and its
/// tooltip has it all.
struct TagChip: View {
    let label: String
    let remove: Removal?

    /// The × and what it does.
    struct Removal {
        /// Its tooltip and VoiceOver label.
        let label: String
        let action: () -> Void
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(WindowMetrics.Tags.chipFont)
                .lineLimit(1)
                .truncationMode(.tail)
            if let remove {
                Button(action: remove.action) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(remove.label)
                .accessibilityLabel(remove.label)
            }
        }
        .padding(.horizontal, WindowMetrics.Tags.chipPadding)
        .frame(height: WindowMetrics.Tags.chipHeight)
        .background(
            Color.accentColor.opacity(WindowMetrics.Tags.chipOpacity),
            in: RoundedRectangle(cornerRadius: WindowMetrics.Tags.chipCornerRadius)
        )
        .help(label)
    }
}
