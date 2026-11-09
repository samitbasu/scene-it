import AppKit
import SceneItCore
import SwiftUI

/// What the Tags tab's controls do (PLAN §8.3). Each edit is a step on the scene's page undo
/// (the owner, #20). None moves the keyboard focus (the owner): ⌘Z reaches a tag edit once the
/// page has the focus.
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

    /// A row's ⌕: the Search sheet, finding `tag` in the whole book's tags and text. Nothing if
    /// the tag has no word to search for.
    func search(_ tag: String) {
        guard search.prepare(searchingFor: tag) else { return }
        mode.wrappedValue = .search
    }

    private func edit(_ change: () -> Bool) -> Bool {
        guard book.isEditable else { return false }
        // Typing on the page before and after the tag edit are steps of their own.
        page.breakUndoCoalescing()
        return change()
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
        let editability = Editability(book, in: environment)
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
    let editability: Editability

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.Tags.headerGap) {
            Text(TagWording.thisScene).font(WindowMetrics.Tags.headerFont)
            if let scene {
                if scene.tags.isEmpty, editability == .readOnly {
                    Text(TagWording.sceneHasNoTags).font(WindowMetrics.Tags.textFont)
                        .foregroundStyle(.secondary)
                } else {
                    ChipFlow(spacing: ChipSpacing(points: WindowMetrics.Tags.chipGap)) {
                        // A hand-edited file can repeat a tag, so a chip is known by its place.
                        ForEach(Array(scene.tags.enumerated()), id: \.offset) { _, tag in
                            TagChip(label: SceneTag.shown(tag), remove: removal(of: tag, from: scene.id))
                        }
                        if editability == .editable {
                            NewTagField(
                                book: actions.book, add: { actions.add($0, to: scene.id) },
                                leave: { _ in actions.page.takeFocus() }
                            )
                            .frame(width: WindowMetrics.Tags.addFieldWidth)
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

    private func removal(of tag: String, from scene: SceneID) -> TagChip.Removal? {
        guard editability == .editable else { return nil }
        return TagChip.Removal(label: TagWording.removeHelp(tag)) { actions.remove(tag, from: scene) }
    }
}

/// "All tags in the book" and its rows, scrolling once there are more than fit.
private struct BookTagsList: View {
    let tags: BookTags
    let scene: BookScene?
    let actions: TagActions
    let editability: Editability

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
                                toggle: toggle(entry.tag),
                                search: SceneTag.searchText(entry.tag) == nil
                                    ? nil : { actions.search(entry.tag) })
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

/// A tag of the book: its name (bold, on a tinted row, while the open scene has it), how many
/// scenes use it, and ⌕, off for a tag with no word to search for. A click toggles it on the open
/// scene, while it can.
private struct TagRow: View {
    let entry: BookTags.Entry
    let isOnScene: Bool
    let toggle: (() -> Void)?
    let search: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let toggle {
                Button(action: toggle) { label }
                    .buttonStyle(.plain)
                    .help(isOnScene ? TagWording.removeHelp(entry.tag) : TagWording.addRowHelp(entry.tag))
            } else {
                label.help(SceneTag.shown(entry.tag))
            }
            Button {
                search?()
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(search == nil)
            .help(TagWording.searchHelp(entry.tag))
            .accessibilityLabel(TagWording.searchHelp(entry.tag))
        }
        .padding(.horizontal, 8)
        .frame(height: WindowMetrics.Tags.rowHeight)
        .background(
            isOnScene ? WindowMetrics.Tags.onSceneFill : Color.clear,
            in: RoundedRectangle(cornerRadius: WindowMetrics.Tags.rowCornerRadius)
        )
        .contentShape(Rectangle())
    }

    private var label: some View {
        HStack(spacing: 6) {
            Text(SceneTag.shown(entry.tag))
                .font(WindowMetrics.Tags.textFont)
                .fontWeight(isOnScene ? .semibold : .regular)
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

extension WindowMetrics {
    /// The Tags tab, from mockup 06, with the chip and field the owner picked (#20).
    enum Tags {
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
        static let chipCornerRadius: CGFloat = 4
        /// Of the accent color, behind a chip.
        static let chipOpacity = 0.16
        static let addFieldWidth: CGFloat = 96
        static let listInset: CGFloat = 12
        static let rowHeight: CGFloat = 28
        static let rowGap: CGFloat = 2
        static let rowCornerRadius: CGFloat = 6
        static let onSceneFill = Color(red: 0xE6 / 255, green: 0xEE / 255, blue: 0xFA / 255)
    }
}
