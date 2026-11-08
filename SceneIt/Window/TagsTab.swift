import AppKit
import SceneItCore
import SwiftUI

/// What the Tags tab's controls do (PLAN §8.3). Each edit is a step on the scene's page undo
/// (the owner, #20), so it leaves the keyboard focus on the page, where ⌘Z and the toolbar's
/// Undo reach it.
struct TagActions {
    let book: AppOpenBook
    let page: SceneTextView
    let search: SearchSheetModel
    let mode: Binding<WindowMode>

    /// The + tag field's Return.
    @discardableResult
    func add(_ typed: String, to scene: SceneID) -> Bool {
        edit { book.addTag(typed, to: scene) }
    }

    /// A chip's ×.
    @discardableResult
    func remove(_ tag: String, from scene: SceneID) -> Bool {
        edit { book.removeTag(tag, from: scene) }
    }

    /// A click on a row of the book's tags.
    @discardableResult
    func toggle(_ tag: String, on scene: SceneID) -> Bool {
        edit { book.toggleTag(tag, on: scene) }
    }

    /// A row's ⌕: the Search sheet, finding `tag` in the whole book's tags and text.
    func search(_ tag: String) {
        search.prepare(searchingFor: tag)
        mode.wrappedValue = .search
    }

    private func edit(_ change: () -> Bool) -> Bool {
        guard book.isEditable else { return false }
        // Typing on the page after the tag edit is a step of its own.
        page.breakUndoCoalescing()
        let changed = change()
        page.takeFocus()
        return changed
    }
}

/// The Tags tab (PLAN §8.3, mockup 06): the open scene's tags as chips with a + tag field, then
/// every tag in the book, most-used first, each a toggle for the open scene with a ⌕ that
/// searches the book for it. Read-only, it only shows them, and the ⌕ still searches.
struct TagsTab: View {
    let book: AppOpenBook
    let actions: TagActions
    @Environment(\.self) private var environment

    var body: some View {
        let editability = SceneTextEditor.Editability(book, in: environment)
        let scene = book.location.scene
        VStack(alignment: .leading, spacing: 0) {
            SceneTagsSection(scene: scene, actions: actions, editability: editability)
            Divider()
            BookTagsList(
                tags: book.tags, scene: scene, actions: actions,
                editability: scene == nil ? .readOnly : editability)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "This scene", and the open scene's tags as chips, with the + tag field while it's editable.
private struct SceneTagsSection: View {
    let scene: BookScene?
    let actions: TagActions
    let editability: SceneTextEditor.Editability

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.Tags.headerGap) {
            Text(TagWording.thisScene).font(WindowMetrics.Tags.headerFont)
            if let scene {
                if scene.tags.isEmpty, editability == .readOnly {
                    Text(TagWording.sceneHasNoTags).font(WindowMetrics.Tags.textFont).foregroundStyle(
                        .secondary)
                } else {
                    ChipFlow(spacing: ChipSpacing(points: WindowMetrics.Tags.chipGap)) {
                        ForEach(scene.tags, id: \.self) { tag in
                            TagChip(tag: tag, remove: removal(of: tag, from: scene.id))
                        }
                        if editability == .editable {
                            NewTagField(scene: scene.id, actions: actions)
                                .modifier(AddFieldFrame(look: WindowMetrics.Tags.look.addField))
                                .id(scene.id)
                        }
                    }
                }
            } else {
                Text(WindowWording.noSceneOpen).font(WindowMetrics.Tags.textFont).foregroundStyle(.secondary)
            }
        }
        .padding(WindowMetrics.Tags.sectionPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func removal(of tag: String, from scene: SceneID) -> (() -> Void)? {
        editability == .editable ? { actions.remove(tag, from: scene) } : nil
    }
}

/// One of the open scene's tags, with its × while it can be removed.
private struct TagChip: View {
    let tag: String
    let remove: (() -> Void)?

    var body: some View {
        let look = WindowMetrics.Tags.look.chip
        HStack(spacing: 3) {
            Text(SceneTag.shown(tag))
                .font(WindowMetrics.Tags.chipFont)
                .lineLimit(1)
                .truncationMode(.tail)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(TagWording.removeHelp(tag))
                .accessibilityLabel(TagWording.removeHelp(tag))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: WindowMetrics.Tags.chipHeight)
        .background(look.fill, in: look.shape)
        .help(SceneTag.shown(tag))
    }
}

/// "All tags in the book" and its rows, scrolling once there are more than fit.
private struct BookTagsList: View {
    let tags: BookTags
    let scene: BookScene?
    let actions: TagActions
    let editability: SceneTextEditor.Editability

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(WindowMetrics.Tags.sectionPadding)
            if tags.entries.isEmpty {
                Text(TagWording.bookHasNoTags)
                    .font(WindowMetrics.Tags.textFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, WindowMetrics.Tags.sectionPadding.leading)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: WindowMetrics.Tags.rowGap) {
                        ForEach(tags.entries, id: \.tag) { entry in
                            TagRow(
                                entry: entry,
                                isOnScene: scene.map { SceneTag.contains($0.tags, entry.tag) } ?? false,
                                toggle: toggle(entry.tag), search: { actions.search(entry.tag) })
                        }
                    }
                    .padding(.horizontal, WindowMetrics.Tags.listInset)
                    .padding(.bottom, WindowMetrics.Tags.listInset)
                }
            }
        }
    }

    private var header: some View {
        let title = Text(TagWording.allTags).font(WindowMetrics.Tags.headerFont)
        let hint = Text(TagWording.hintSeparator + TagWording.allTagsHint)
            .font(WindowMetrics.Tags.hintFont)
            .foregroundStyle(.secondary)
        return Text("\(title)\(editability == .editable ? hint : Text(""))")
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toggle(_ tag: String) -> (() -> Void)? {
        guard editability == .editable, let scene else { return nil }
        return { actions.toggle(tag, on: scene.id) }
    }
}

/// A tag of the book: its name, how many scenes use it, and ⌕. A click toggles it on the open
/// scene, while it can.
private struct TagRow: View {
    let entry: BookTags.Entry
    let isOnScene: Bool
    let toggle: (() -> Void)?
    let search: () -> Void
    @State private var hovering = false

    var body: some View {
        let look = WindowMetrics.Tags.look
        HStack(spacing: 6) {
            if let toggle {
                Button(action: toggle) { label }
                    .buttonStyle(.plain)
                    .help(isOnScene ? TagWording.removeHelp(entry.tag) : TagWording.addRowHelp(entry.tag))
            } else {
                label.help(SceneTag.shown(entry.tag))
            }
            Button(action: search) {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(look.searchButton == .always || hovering ? 1 : 0)
            .help(TagWording.searchHelp(entry.tag))
            .accessibilityLabel(TagWording.searchHelp(entry.tag))
        }
        .padding(.horizontal, 8)
        .frame(height: WindowMetrics.Tags.rowHeight)
        .background(
            look.onScene == .tintedBold && isOnScene ? WindowMetrics.Tags.onSceneFill : Color.clear,
            in: RoundedRectangle(cornerRadius: WindowMetrics.Tags.rowCornerRadius)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var label: some View {
        let look = WindowMetrics.Tags.look
        return HStack(spacing: 6) {
            if look.onScene == .checkmark {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isOnScene ? 1 : 0)
                    .accessibilityHidden(true)
            }
            Text(SceneTag.shown(entry.tag))
                .font(WindowMetrics.Tags.textFont)
                .fontWeight(look.onScene == .tintedBold && isOnScene ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(entry.scenes)")
                .font(WindowMetrics.Tags.countFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel(TagWording.sceneCount(entry.scenes))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOnScene ? TagWording.onThisScene : "")
    }
}

/// The + tag field: an `AdmittingTextField` (ADR 0028), so Return and Esc arrive as its field
/// editor's commands. Return adds what's typed (`TagActions.add`) and empties the field, the focus
/// going to the page with the tag's undo; Esc empties it and goes back to the page. The field's
/// own typing history goes with what it held.
private struct NewTagField: NSViewRepresentable {
    let scene: SceneID
    let actions: TagActions

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AdmittingTextField {
        let field = Self.field(context.coordinator)
        context.coordinator.target = (scene, actions)
        return field
    }

    /// The field `makeNSView` makes, wired to `coordinator`.
    static func field(_ coordinator: Coordinator) -> AdmittingTextField {
        let editor = AdmittingTextView.fieldEditor(admitting: CharacterPolicy.admittedLine)
        editor.history = coordinator.history
        let field = AdmittingTextField(string: "", editor: editor, lineBreakMode: .byClipping)
        field.font = .systemFont(ofSize: WindowMetrics.Tags.chipPointSize)
        // A field without a bezel draws its placeholder in the text's color unless told.
        field.placeholderAttributedString = NSAttributedString(
            string: TagWording.addPlaceholder,
            attributes: [.font: field.font as Any, .foregroundColor: NSColor.tertiaryLabelColor])
        field.setAccessibilityLabel(TagWording.addLabel)
        field.toolTip = TagWording.addHelp
        switch WindowMetrics.Tags.look.addField {
        case .dashedCapsule:
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
        case .roundedBorder:
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
        }
        field.delegate = coordinator
        return field
    }

    func updateNSView(_ field: AdmittingTextField, context: Context) {
        context.coordinator.target = (scene, actions)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: AdmittingTextField, context: Context)
        -> CGSize?
    {
        CGSize(width: proposal.width ?? field.fittingSize.width, height: field.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ field: AdmittingTextField, coordinator: Coordinator) {
        field.delegate = nil
        field.editor?.history = nil
        coordinator.target = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var target: (scene: SceneID, actions: TagActions)?
        let history = UndoManager()

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let typed = textView.string
                finish(textView)
                if let target { target.actions.add(typed, to: target.scene) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(textView)
                target?.actions.page.takeFocus()
                return true
            default:
                return false
            }
        }

        private func finish(_ textView: NSTextView) {
            textView.string = ""
            history.removeAllActions()
        }
    }
}

/// The + tag field's size, and in the mockup's look its dashed capsule.
private struct AddFieldFrame: ViewModifier {
    let look: TagsLook.AddField

    func body(content: Content) -> some View {
        switch look {
        case .dashedCapsule:
            content
                .frame(width: look.width - 2 * WindowMetrics.Tags.chipPadding)
                .padding(.horizontal, WindowMetrics.Tags.chipPadding)
                .frame(height: WindowMetrics.Tags.chipHeight)
                .overlay {
                    Capsule()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(WindowMetrics.Tags.dashedBorder)
                }
        case .roundedBorder:
            content.frame(width: look.width)
        }
    }
}

/// The Tags tab's candidate looks (#20) until the owner picks: A is the mockup's.
struct TagsLook {
    enum Chip {
        /// The mockup's: a light gray capsule.
        case grayCapsule
        /// A rounded rectangle tinted with the accent color, as macOS's token fields draw tokens.
        case accentToken

        var fill: Color {
            switch self {
            case .grayCapsule: Color.primary.opacity(0.07)
            case .accentToken: Color.accentColor.opacity(0.16)
            }
        }

        var shape: AnyShape {
            switch self {
            case .grayCapsule: AnyShape(Capsule())
            case .accentToken: AnyShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    enum AddField {
        /// The mockup's: borderless inside a dashed capsule.
        case dashedCapsule
        /// macOS's standard rounded text field.
        case roundedBorder

        var width: CGFloat {
            switch self {
            case .dashedCapsule: 80
            case .roundedBorder: 96
            }
        }
    }

    /// How a row shows that the open scene has its tag.
    enum OnScene {
        /// The mockup's: the row tinted, its name bold.
        case tintedBold
        /// A check mark before the name, as a macOS menu marks its chosen items.
        case checkmark
    }

    enum SearchButton {
        /// The mockup's: on every row.
        case always
        /// Only on the row under the pointer.
        case onHover
    }

    var chip: Chip
    var addField: AddField
    var onScene: OnScene
    var searchButton: SearchButton

    static let a = TagsLook(
        chip: .grayCapsule, addField: .dashedCapsule, onScene: .tintedBold, searchButton: .always)
    static let b = TagsLook(
        chip: .accentToken, addField: .roundedBorder, onScene: .checkmark, searchButton: .onHover)
}

extension WindowMetrics {
    /// The Tags tab, from mockup 06.
    enum Tags {
        /// Provisional until the owner picks (#20).
        static var look = TagsLook.a
        static let sectionPadding = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        static let headerGap: CGFloat = 8
        static let headerFont = Font.system(size: 12, weight: .semibold)
        static let hintFont = Font.system(size: 12)
        static let textFont = Font.system(size: 13)
        static let countFont = Font.system(size: 12)
        static let chipPointSize: CGFloat = 12
        static let chipFont = Font.system(size: chipPointSize)
        static let chipHeight: CGFloat = 22
        static let chipPadding: CGFloat = 8
        static let chipGap: CGFloat = 5
        static let listInset: CGFloat = 12
        static let rowHeight: CGFloat = 28
        static let rowGap: CGFloat = 2
        static let rowCornerRadius: CGFloat = 6
        static let onSceneFill = Color(red: 0xE6 / 255, green: 0xEE / 255, blue: 0xFA / 255)
        static let dashedBorder = Color(red: 0xC8 / 255, green: 0xC6 / 255, blue: 0xC0 / 255)
    }
}
