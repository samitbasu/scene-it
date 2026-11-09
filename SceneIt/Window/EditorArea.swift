import AppKit
import SceneItCore
import SwiftUI

/// The center of the window (PLAN §4.3, ADR 0015): the editor control bar, the scene's title
/// field, and the page on its gray desk.
struct EditorArea: View {
    let book: AppOpenBook
    let preferences: AppPreferences
    let formatting: EditorFormatting
    let readAloud: ReadAloud
    let focus: PageFocus
    let editors: SceneEditors

    var body: some View {
        let scene = book.location.scene
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: WindowMetrics.Bar.groupSpacing) {
                    FormattingBar(formatting: formatting, part: .body)
                    ReadAloudButton(readAloud: readAloud)
                }
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
                PageView(
                    book: book, preferences: preferences, editors: editors, scene: scene.id,
                    paragraphs: scene.body, comments: scene.comments)
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
        .focusedSceneValue(\.page, focus)
    }
}

extension FocusedValues {
    /// The focused window's page, for View → Fit Width.
    @Entry var page: PageFocus?
}

extension EnvironmentValues {
    /// The window's page, for views that hand the focus back to it.
    @Entry var pageFocus: PageFocus?
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
            .disabled(!book.accepts(.manuscript))
            Spacer(minLength: WindowMetrics.pageMargin)
        }
    }
}

/// The title's text field: Return and Tab go on to the body, and spelling is checked as the
/// writer types (decision 0015). Each scene's title has its own undo history. Opening another
/// scene ends the editing first, so what was typed stays in the scene it was typed in; if the
/// title had the focus, the next scene's title gets it.
private struct TitleTextField: NSViewRepresentable {
    let book: AppOpenBook
    let scene: SceneID
    let title: String
    let focus: PageFocus
    @Environment(\.windowKeys) private var keys

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AdmittingTextField {
        let field = AdmittingTextField.sceneTitle(title, in: book)
        context.coordinator.field = field
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.sceneWillSwitch),
            name: .openBookWillSwitchScene, object: book)
        field.setAccessibilityLabel(WindowWording.titleLabel)
        field.delegate = context.coordinator
        focus.title = field
        return field
    }

    func updateNSView(_ field: AdmittingTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.show(scene, of: book)
        coordinator.focus = focus
        coordinator.keys = keys
        if field.currentEditor() == nil, field.stringValue != title { field.stringValue = title }
        if coordinator.resumesEditing {
            coordinator.resumesEditing = false
            DispatchQueue.main.async { [weak field] in
                guard let field, field.window?.makeFirstResponder(field) == true else { return }
                let end = (field.stringValue as NSString).length
                field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
            }
        }
        let enabled = context.environment.isEnabled
        if field.isEnabled != enabled || field.isEditable != enabled {
            if !enabled, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
            field.isEnabled = enabled
            field.isEditable = enabled
            // Read-only, it reads as the title it is rather than as a field (mockup 13).
            field.isBezeled = enabled
            field.drawsBackground = enabled
            field.textColor = enabled ? .controlTextColor : .labelColor
        }
        // A read-only book's title can't take the focus, so its selection is dropped.
        if let range = focus.titleSelection.take(showing: scene), enabled {
            DispatchQueue.main.async { [weak field] in
                guard let field, field.window?.makeFirstResponder(field) == true else { return }
                let length = (field.stringValue as NSString).length
                field.currentEditor()?.selectedRange = range.clamped(toLength: length)
            }
        }
    }

    final class Coordinator: TitleFieldCoordinator {
        var focus: PageFocus?
        weak var keys: WindowKeys?
        /// Whether the title had the focus when the writer opened another scene.
        var resumesEditing = false

        @objc func sceneWillSwitch(_ notification: Notification) {
            guard let field, field.currentEditor() != nil else { return }
            resumesEditing = true
            field.window?.makeFirstResponder(nil)
        }

        override func command(_ selector: Selector, in textView: NSTextView) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                focus?.focusBodyStart()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                return keys?.tab(.backward, from: .page) ?? false
            case #selector(NSResponder.cancelOperation(_:)):
                return keys?.escape(from: .focusedView) == .handled
            default:
                return false
            }
        }
    }
}
