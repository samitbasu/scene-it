import AppKit
import SceneItCore
import SwiftUI

/// The center of the window (PLAN §4.3, ADR 0015): the editor control bar, the scene's title
/// field, and the page on its gray desk.
struct EditorArea: View {
    let book: AppOpenBook
    @State private var focus = PageFocus()

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
            if let scene {
                SceneTitleField(book: book, scene: scene.id, focus: focus)
                    .frame(width: WindowMetrics.pageSize.width)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, WindowMetrics.titleStripPadding)
                Divider()
                PageView(book: book, scene: scene.id, paragraphs: scene.body, focus: focus)
            } else {
                ScrollView(.vertical) {
                    Page {
                        Text(WindowWording.noSceneOpen)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(WindowMetrics.deskPadding)
                    .frame(maxWidth: .infinity)
                }
                .background(WindowMetrics.deskColor)
            }
        }
    }
}

/// An empty white US Letter page with 1 in margins, drawn as `ManuscriptTextView` draws a
/// scene's page.
private struct Page<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(WindowMetrics.pageMargin)
            .frame(width: WindowMetrics.pageSize.width, height: WindowMetrics.pageSize.height)
            .background(Color.white)
            .shadow(
                color: .black.opacity(WindowMetrics.pageShadow.opacity),
                radius: WindowMetrics.pageShadow.radius,
                y: WindowMetrics.pageShadow.drop)
    }
}

/// The scene's title (ADR 0015): one line of plain text, above the page rather than on it.
struct SceneTitleField: View {
    let book: AppOpenBook
    let scene: SceneID
    var focus = PageFocus()

    var body: some View {
        let label = WindowWording.titleLabel
        // The label sits in the page's left margin, so the field spans the text column.
        HStack(spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: WindowMetrics.pageMargin - WindowMetrics.titleLabelGap, alignment: .trailing)
                .padding(.trailing, WindowMetrics.titleLabelGap)
            TitleTextField(
                book: book, scene: scene, title: book.book.scene(scene)?.title.text ?? "", focus: focus
            )
            .disabled(!book.isEditable)
            Spacer(minLength: WindowMetrics.pageMargin)
        }
    }
}

/// The title's text field: Return and Tab go on to the body, and spelling is checked as the
/// writer types (decision 0015).
private struct TitleTextField: NSViewRepresentable {
    let book: AppOpenBook
    let scene: SceneID
    let title: String
    let focus: PageFocus

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = TitleField(string: title)
        field.bezelStyle = .roundedBezel
        field.placeholderString = WindowWording.untitledScene
        field.setAccessibilityLabel(WindowWording.titleLabel)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        focus.title = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.book = book
        context.coordinator.scene = scene
        context.coordinator.focus = focus
        if field.currentEditor() == nil, field.stringValue != title { field.stringValue = title }
        let enabled = context.environment.isEnabled
        if field.isEnabled != enabled || field.isEditable != enabled {
            if !enabled, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
            field.isEnabled = enabled
            field.isEditable = enabled
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var book: AppOpenBook?
        var scene: SceneID?
        var focus: PageFocus?

        func controlTextDidChange(_ notification: Notification) {
            guard let book, let scene, let editor = Self.editor(notification) else { return }
            let typed = editor.string
            let title = SceneTitle(pasted: typed)
            book.setTitle(of: scene, to: title)
            guard title.text != typed else { return }
            let caret = min(editor.selectedRange().location, (typed as NSString).length)
            let before = (typed as NSString).substring(to: caret)
            editor.string = title.text
            editor.setSelectedRange(NSRange(location: SceneTitle(pasted: before).text.utf16.count, length: 0))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                focus?.focusBodyStart()
                return true
            default:
                return false
            }
        }

        private static func editor(_ notification: Notification) -> NSTextView? {
            notification.userInfo?["NSFieldEditor"] as? NSTextView
        }
    }
}

/// A text field with a field editor of its own, which checks spelling as the writer types. (The
/// window's shared field editor serves every other field, which shouldn't.)
private final class TitleField: NSTextField {
    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    final class Cell: NSTextFieldCell {
        private lazy var editor: NSTextView = {
            let editor = NSTextView()
            editor.isFieldEditor = true
            editor.allowsUndo = true
            editor.isContinuousSpellCheckingEnabled = true
            return editor
        }()

        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            editor
        }
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
