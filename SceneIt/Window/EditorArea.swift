import SceneItCore
import SwiftUI

/// The center of the window (PLAN §4.3, ADR 0015): the editor control bar, the scene's title
/// field, and the page on its gray desk.
struct EditorArea: View {
    let book: AppOpenBook
    var body: some View {
        let scene = book.location.scene
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FormattingBarStandIn()
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: WindowMetrics.barHeight)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        Page {
                            if let scene {
                                TemporaryBodyEditor(book: book, scene: scene)
                            } else {
                                Text(WindowWording.noSceneOpen)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .padding(WindowMetrics.deskPadding)
                    } header: {
                        // Inside the scroll view, so it centres exactly as the page does.
                        if let scene {
                            VStack(spacing: 0) {
                                SceneTitleField(book: book, scene: scene.id)
                                    .frame(width: WindowMetrics.pageSize.width)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, WindowMetrics.titleStripPadding)
                                Divider()
                            }
                            .background(.background)
                        }
                    }
                }
            }
            .background(WindowMetrics.deskColor)
        }
    }
}

/// A white US Letter page with 1 in margins.
private struct Page<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(WindowMetrics.pageMargin)
            .frame(width: WindowMetrics.pageSize.width, height: WindowMetrics.pageSize.height)
            .background(Color.white)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

/// The scene's title (ADR 0015): one line of plain text, above the page rather than on it.
struct SceneTitleField: View {
    let book: AppOpenBook
    let scene: SceneID
    var body: some View {
        let label = WindowWording.titleLabel
        let text = Binding(
            get: { book.book.scene(scene)?.title.text ?? "" },
            set: { book.setTitle(of: scene, to: SceneTitle(pasted: $0)) })
        // The label sits in the page's left margin, so the field spans the text column.
        HStack(spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: WindowMetrics.pageMargin - WindowMetrics.titleLabelGap, alignment: .trailing)
                .padding(.trailing, WindowMetrics.titleLabelGap)
            TextField(label, text: text, prompt: Text(WindowWording.untitledScene))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            Spacer(minLength: WindowMetrics.pageMargin)
        }
        .disabled(!book.isEditable)
    }
}

/// Holds the formatting control bar's place until #18 builds it. Disabled; nothing here
/// formats anything.
private struct FormattingBarStandIn: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bold")
            Image(systemName: "italic")
            Image(systemName: "strikethrough")
            Divider().frame(height: 18)
            Image(systemName: "character")
            Image(systemName: "highlighter")
            Divider().frame(height: 18)
            Image(systemName: "play.fill")
        }
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
}

// TEMPORARY (#11 scaffolding, until #15's page editor): plain bodies are editable as plain text.

private struct TemporaryBodyEditor: View {
    let book: AppOpenBook
    let scene: BookScene
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if PlainBody.isPlain(scene) {
            // TextEditor stays editable when disabled, so a read-only book, or a page under a
            // sheet, shows the text instead.
            if isEnabled && book.isEditable {
                TextEditor(
                    text: Binding(
                        get: { PlainBody.text(scene.body) },
                        set: { book.replaceBody(of: scene.id, with: PlainBody.paragraphs($0)) })
                )
                .font(.custom("Times New Roman", size: 12))
                .lineSpacing(12)
                .scrollContentBackground(.hidden)
                .foregroundStyle(.black)
            } else {
                Text(PlainBody.text(scene.body))
                    .font(.custom("Times New Roman", size: 12))
                    .lineSpacing(12)
                    .foregroundStyle(.black)
                    .padding(.leading, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            Text(WindowWording.formattedSceneNotEditable)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A scene body as plain text, one line per paragraph. Only for bodies with no formatting
/// and no comments, which this conversion would silently drop.
enum PlainBody {
    static func isPlain(_ scene: BookScene) -> Bool {
        scene.comments.isEmpty
            && scene.body.allSatisfy { paragraph in paragraph.runs.allSatisfy { $0 == Run($0.text) } }
    }

    static func text(_ body: [Paragraph]) -> String {
        body.map(\.text).joined(separator: "\n")
    }

    static func paragraphs(_ text: String) -> [Paragraph] {
        guard !text.isEmpty else { return [] }
        return text.filter { !$0.isObjectReplacement }
            .split(omittingEmptySubsequences: false, whereSeparator: \.isLineBreak)
            .map { $0.isEmpty ? [] : [Run(String($0))] }
    }
}
