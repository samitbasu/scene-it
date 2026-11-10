import SwiftUI

/// The frame the window's dialogs share (File a Copy, Export as SceneIt): a tinted icon beside
/// the title and a line of explanation, with any notes under it, then the dialog's own content,
/// 440 pt wide.
struct WindowDialog<Content: View>: View {
    let icon: String
    let title: String
    let explanation: String
    var notes: [String] = []
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30)).foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Self.explaining(explanation)
                    ForEach(notes, id: \.self, content: Self.explaining)
                }
            }
            content
        }
        .padding(20)
        .frame(width: 440)
    }

    private static func explaining(_ line: String) -> some View {
        Text(line)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// A dialog sheet's Esc: the key equivalent and the fallback for a `cancelOperation:` nothing
    /// answered both go to the window's keys, which its views also find in the environment.
    func windowDialogKeys(_ keys: WindowKeys) -> some View {
        background(EscapeKey(keys: keys))
            .background(WindowEscapeFallback(keys: keys, commands: .keyAndCancelOperation))
            .environment(\.windowKeys, keys)
    }
}
